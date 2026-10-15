<?php
declare(strict_types=1);
// JSON stdin contains private fixture data. stdout is private backend input, never a report.
ini_set('display_errors', '0');
function acceptanceCheck(bool $ok): void {
    if (!$ok) { throw new RuntimeException('acceptance invariant failed',debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS,1)[0]['line']); }
}
function acceptanceApi(string $path, ?array $data, string $auth=''): string {
    $ch=curl_init('http://127.0.0.1:8080/api/greader.php'.$path); $body='';
    $headers=['Connection: close'];
    if ($auth!=='') { $headers[]='Authorization: GoogleLogin auth='.$auth; }
    curl_setopt_array($ch,[CURLOPT_PROXY=>'',CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT_MS=>1000,CURLOPT_TIMEOUT_MS=>10000,CURLOPT_HTTPHEADER=>$headers,CURLOPT_WRITEFUNCTION=>function($ch,$part)use(&$body):int { if(strlen($body)+strlen($part)>16777216)return 0; $body.=$part;return strlen($part); }]);
    if ($data!==null) { curl_setopt_array($ch,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>http_build_query($data)]); }
    try { acceptanceCheck(curl_exec($ch)!==false&&(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE)===200); }
    finally { curl_close($ch); }
    return $body;
}
function acceptancePush(array $case, string $run): array {
    acceptanceCheck(is_string($case['id']??null)&&preg_match('/^[a-z0-9-]{1,64}$/D',$case['id'])===1);
    acceptanceCheck(in_array($case['mode']??null,['community','rss'],true)&&is_string($case['rss']??null)&&strlen($case['rss'])<2097152);
    acceptanceCheck(is_string($case['url']??null)&&strlen($case['url'])<4096&&str_starts_with($case['url'],'https://'));
    $feeds=FreshRSS_Factory::createFeedDao(); $entries=FreshRSS_Factory::createEntryDao();
    $url='https://example.com/news-acceptance-'.$case['id'];
    $feed=$feeds->searchByUrl($url);
    if ($feed===null) {
        $feed=new FreshRSS_Feed($url); $feed->_name('Acceptance '.$case['id']); $feed->_categoryId(1);
        $feed->_attribute('community_extraction_mode',$case['mode']);
        $id=$feeds->addFeedObject($feed); acceptanceCheck(is_int($id)&&$id>0); $feed->_id($id);
    }
    acceptanceCheck($feeds->updateFeed($feed->id(),['ttl'=>0]));
    $guid=$run.':'.$case['id']; $prior=$entries->searchByGuid($feed->id(),$guid);
    $priorId=$prior?->id(); $priorBody=$prior===null?null:hash('sha256',$prior->content(false));
    $escape=fn(string $v):string=>htmlspecialchars($v,ENT_XML1|ENT_QUOTES,'UTF-8');
    $rss=str_replace(']]>',']]]]><![CDATA[>',$case['rss']);
    $pie=new FreshRSS_SimplePieCustom(); $pie->enable_cache(false);
    $pie->set_raw_data('<rss version="2.0"><channel><title>News acceptance</title><link>https://example.com/</link><description>Private acceptance fixtures</description><item><guid isPermaLink="false">'.$escape($guid).'</guid><title>'.$escape('Acceptance '.$case['id']).'</title><link>'.$escape($case['url']).'</link><pubDate>'.gmdate(DATE_RSS,(int)$case['published']).'</pubDate><description><![CDATA['.$rss.']]></description></item></channel></rss>');
    acceptanceCheck($pie->init());
    try { FreshRSS_feed_Controller::actualizeFeedsAndCommit($feed->id(),null,null,$pie); }
    finally { acceptanceCheck($feeds->updateFeed($feed->id(),['ttl'=>-1])); }
    $entry=$entries->searchByGuid($feed->id(),$guid); acceptanceCheck($entry!==null);
    return ['case_id'=>$case['id'],'id'=>$entry->id(),'prior_id'=>$priorId,'prior_body_sha256'=>$priorBody,'body_sha256'=>hash('sha256',$entry->content(false)),'html'=>$entry->content(false),'read'=>$entry->isRead(),'favorite'=>$entry->isFavorite(),'provenance'=>$entry->attributeArray('community_extraction')];
}

$service=null; $refresh=null; $circuitBefore=null; $circuitOwned=false;
try {
    $p=json_decode(stream_get_contents(STDIN),true,64,JSON_THROW_ON_ERROR);
    acceptanceCheck(is_array($p)&&preg_match('/^news583_[a-f0-9]{12}$/D',$p['user']??'')===1&&preg_match('/^[a-f0-9]{64}$/D',$p['owner']??'')===1);
    acceptanceCheck(in_array($p['operation']??null,['create','rss','ingest','fault','inspect','state','delete'],true));
    $user=$p['user']; $owner=$p['owner']; $run=substr($user,8);
    acceptanceCheck(getenv('NEWS_EXTRACTION_REQUESTS_ENABLED')!=='true');
    $service=fopen('/run/news/service.lock','c'); $refresh=fopen('/run/news/refresh.lock','c');
    acceptanceCheck($service!==false&&$refresh!==false&&flock($service,LOCK_SH|LOCK_NB)&&!is_file('/run/news/maintenance-request')&&flock($refresh,LOCK_EX|LOCK_NB));
    putenv('NEWS_EXTRACTION_REQUESTS_ENABLED='.($p['operation']==='ingest'?'true':'false'));
    require '/var/www/FreshRSS/cli/_cli.php';
    acceptanceCheck(strcasecmp($user,FreshRSS_Context::systemConf()->default_user)!==0);
    $marker=(getenv('DATA_PATH')?:'/var/www/FreshRSS/data').'/users/'.$user.'/.news-acceptance-owner';
    if ($p['operation']==='create') {
        acceptanceCheck(!FreshRSS_user_Controller::userExists($user)&&!file_exists($marker));
        acceptanceCheck(is_string($p['password']??null)&&strlen($p['password'])>=32&&is_string($p['api_password']??null)&&strlen($p['api_password'])>=32);
        acceptanceCheck(FreshRSS_user_Controller::createUser($user,null,$p['password'],['language'=>'en'],false));
        acceptanceCheck(file_put_contents($marker,$owner,LOCK_EX)===strlen($owner)); chmod($marker,0600);
        cliInitUser($user); acceptanceCheck(FreshRSS_api_Controller::updatePassword($p['api_password'])===false);
        echo json_encode(['created'=>true],JSON_THROW_ON_ERROR); exit(0);
    }
    acceptanceCheck(FreshRSS_user_Controller::userExists($user)&&!is_link(dirname($marker))&&is_file($marker)&&!is_link($marker)&&hash_equals($owner,file_get_contents($marker)));
    cliInitUser($user);
    if ($p['operation']==='delete') {
        acceptanceCheck(FreshRSS_user_Controller::deleteUser($user));
        acceptanceCheck(!FreshRSS_user_Controller::userExists($user));
        echo json_encode(['deleted'=>true],JSON_THROW_ON_ERROR); exit(0);
    }
    if (in_array($p['operation'],['inspect','state'],true)) {
        $login=acceptanceApi('/accounts/ClientLogin',['Email'=>$user,'Passwd'=>$p['api_password']]);
        acceptanceCheck(preg_match('/^Auth=(.+)$/m',$login,$m)===1); $auth=trim($m[1]);
        if ($p['operation']==='state') {
            $token=trim(acceptanceApi('/reader/api/0/token',null,$auth));
            foreach ($p['changes'] as $change) {
                acceptanceCheck(in_array($change['tag'],['read','starred'],true)&&is_bool($change['value']));
                acceptanceApi('/reader/api/0/edit-tag',['T'=>$token,'i'=>$change['id'],$change['value']?'a':'r'=>'user/-/state/com.google/'.$change['tag']],$auth);
            }
        }
        $items=json_decode(acceptanceApi('/reader/api/0/stream/contents/reading-list?output=json&n=100',null,$auth),true,64,JSON_THROW_ON_ERROR);
        echo json_encode(['items'=>$items['items']],JSON_THROW_ON_ERROR); exit(0);
    }
    // Keep fault injection and its circuit counters local to this locked operation.
    $circuit='/run/news/extraction-circuit.json';
    $circuitBefore=is_file($circuit)?file_get_contents($circuit):false;
    acceptanceCheck(file_put_contents($circuit,json_encode(['news_acceptance_owner'=>$owner],JSON_THROW_ON_ERROR),LOCK_EX)!==false); $circuitOwned=true;
    if ($p['operation']==='fault') {
        acceptanceCheck(filter_var($p['worker_ip']??'',FILTER_VALIDATE_IP,FILTER_FLAG_IPV4)!==false);
        $calls=0;
        $transport=function(string $method,string $path,array $body,float $seconds)use($p,&$calls):array {
            $calls++; $ch=curl_init('http://'.$p['worker_ip'].':8080'.$path); $reply='';
            curl_setopt_array($ch,[CURLOPT_PROXY=>'',CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT_MS=>500,CURLOPT_TIMEOUT_MS=>1000,CURLOPT_WRITEFUNCTION=>function($ch,$part)use(&$reply):int{if(strlen($reply)+strlen($part)>8388608)return 0;$reply.=$part;return strlen($part);}]);
            if($method==='POST')curl_setopt_array($ch,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>json_encode($body,JSON_THROW_ON_ERROR)]);
            try {if(curl_exec($ch)===false)return [0,[]];return [(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE),json_decode($reply,true)];} finally {curl_close($ch);}
        };
        $client=new CommunityExtraction\Client('/opt/news-extraction/release.json',$transport);
        $preserve=new CommunityExtraction\Preservation($client,true);
        Minz_ExtensionManager::addHook(Minz_HookType::EntryBeforeInsert,[$preserve,'beforeInsert']);
        Minz_ExtensionManager::addHook(Minz_HookType::EntryBeforeUpdate,[$preserve,'beforeUpdate']);
    }
    acceptanceCheck(is_array($p['cases']??null)&&count($p['cases'])>0&&count($p['cases'])<=24);
    $result=[]; $started=microtime(true);
    foreach($p['cases'] as $case)$result[]=acceptancePush($case,$run);
    invalidateHttpCache($user);
    $reply=['cases'=>$result,'seconds'=>microtime(true)-$started];
    if($p['operation']==='fault')$reply['worker_calls']=$calls;
    echo json_encode($reply,JSON_THROW_ON_ERROR);
} catch(Throwable $error) {
    $failed=true;
    fwrite(STDERR,"News acceptance account operation failed at fixture line ".($error->getCode()?:$error->getLine())."\n");
} finally {
    if($circuitOwned) {
        $current=json_decode((string)@file_get_contents('/run/news/extraction-circuit.json'),true);
        if(($current['news_acceptance_owner']??null)===$p['owner']) {
            $restored=$circuitBefore===false
                ? unlink('/run/news/extraction-circuit.json')
                : file_put_contents('/run/news/extraction-circuit.json',$circuitBefore,LOCK_EX)!==false;
            if(!$restored)$failed=true;
        } else {
            $failed=true;
            fwrite(STDERR,"Acceptance circuit ownership changed; restoration refused\n");
        }
    }
    if(is_resource($refresh))fclose($refresh);
    if(is_resource($service))fclose($service);
}
if($failed??false)exit(1);
