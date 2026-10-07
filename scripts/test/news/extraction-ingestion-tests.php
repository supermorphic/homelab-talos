<?php
declare(strict_types=1);
require '/var/www/FreshRSS/cli/_cli.php'; cliInitUser('reader');
function check(bool $ok,string $why): void { if (!$ok) { throw new RuntimeException($why); } }
check(class_exists('CommunityExtractionExtension'),'preservation extension is not enabled');
require_once '/var/www/FreshRSS/extensions/xExtension-CommunityExtraction/Client.php';
require_once '/var/www/FreshRSS/extensions/xExtension-CommunityExtraction/Preservation.php';
$manifest='/opt/news-extraction/release.json';
$metadata=json_decode(file_get_contents($manifest),true); $release=$metadata['id'];
$clock=0.0; $calls=[]; $decision='accepted'; $validatorInput=null; $during=null;
$transport=function ($method,$path,$body,$seconds) use (&$calls,&$decision,$release,&$validatorInput,&$clock,&$during): array {
    $calls[]=$path;
    if ($path==='/ready') { return [200,['release_id'=>$release]]; }
    $validatorInput=$body['validators']; $clock+=1;
    if ($during!==null) { $during(); $during=null; }
    if ($decision!=='accepted') { return [200,['decision'=>$decision==='not_modified'?'not_modified':'rejected','reason'=>$decision,'release_id'=>$release]]; }
    return [200,['decision'=>'accepted','reason'=>'community_rule','release_id'=>$release,'html'=>'<article><p>Selected editorial marker, with complete synthetic article text.</p></article>', 'final_url'=>$body['url'],'rules'=>['fixture.txt'=>str_repeat('a',64)],'validators'=>['etag'=>'"v1"']]];
};
$client=new CommunityExtraction\Client($manifest,$transport,function () use (&$clock) { return $clock; });
$preserve=new CommunityExtraction\Preservation($client,true);
$feed=new FreshRSS_Feed('https://fixture.example/feed'); $feed->_name('Synthetic'); $feed->_categoryId(1);
$feed->_attribute('community_extraction_mode','community');
$feeds=FreshRSS_Factory::createFeedDao(); $id=$feeds->addFeedObject($feed); check(is_int($id)&&$id>0,'feed save failed'); $feed->_id($id);
$dao=FreshRSS_Factory::createEntryDao();
$new=function ($guid,$rss='<p>RSS revision</p>',$url='https://fixture.example/article') use ($feed): FreshRSS_Entry {
    $e=new FreshRSS_Entry($feed->id(),$guid,'Identity title','Synthetic author',$rss,$url,1700000000);
    $e->_feed($feed); $e->_attribute('enclosures',[['url'=>'https://fixture.example/image.jpg','type'=>'image/jpeg']]); $e->_id(uTimeString()); return $e;
};
$entry=$new('accepted'); $hash=$entry->hash(); $preserve->beforeInsert($entry);
check(str_contains($entry->content(false),'Selected editorial'),'new body not selected'); check($entry->hash()===$hash,'enclosure/provenance altered RSS hash');
$accepted=$entry->content(false); $provenance=$entry->attributeArray('community_extraction');
check(($provenance['release_id']??'')===$release&&$entry->attributeString('community_original_rss')==='<p>RSS revision</p>','body/provenance/original pair incomplete');
check($dao->addEntry($entry->toArray())!==false,'entry save failed'); check($dao->commitNewEntries(),'entry commit failed');
$stored=$dao->searchByGuid($feed->id(),'accepted'); check($stored!==null,'entry missing'); $identity=$stored->id();
foreach (['restricted','no_rule','malformed','timeout','http_denied','not_modified','origin_cooldown','reply_invalid'] as $reason) {
    $decision=$reason; $client->resetContext(); $incoming=$new('accepted','<p>RSS '.$reason.'</p>'); $incoming->_isUpdated(true); $incoming->_isRead(null); $incoming->_isFavorite(null);
    $h=$incoming->hash(); $preserve->beforeInsert($incoming); $incoming->_content('upstream complete content'); $preserve->beforeUpdate($incoming);
    check($incoming->content(false)===$accepted&&$incoming->attributeArray('community_extraction')===$provenance,'accepted fallback pair lost: '.$reason);
    check($incoming->hash()===$h,'update hook changed upstream hash'); check($dao->updateEntry($incoming->toArray()),'update failed');
    check($dao->searchByGuid($feed->id(),'accepted')->id()===$identity,'update changed item identity');
}
$decision='restricted'; $client->resetContext(); $incoming=$new('accepted','<p>URL changed RSS</p>','https://fixture.example/new-url'); $preserve->beforeInsert($incoming);
check($validatorInput===[],'old URL validators sent to new URL'); check($incoming->attributeArray('community_extraction')===$provenance,'URL failure relabeled old provenance');
$off=new CommunityExtraction\Preservation($client,false); $n=count($calls); $incoming=$new('accepted','<p>Requests disabled RSS</p>'); $off->beforeInsert($incoming);
check($incoming->content(false)===$accepted&&count($calls)===$n,'disabled requests lost preservation or fetched');
$decision='accepted'; $client->resetContext(); $during=function () use ($dao,$identity): void { $dao->markRead($identity,true); $dao->markFavorite($identity,true); };
$incoming=$new('accepted','<p>Concurrent edit RSS</p>'); $incoming->_isRead(null); $incoming->_isFavorite(null); $preserve->beforeInsert($incoming); $dao->updateEntry($incoming->toArray());
$after=$dao->searchByGuid($feed->id(),'accepted'); check($after->isRead()&&$after->isFavorite(),'concurrent client state overwritten');
$feed->_attribute('community_extraction_mode','rss'); $n=count($calls); $rich=$new('rich','<article><p>Rich publisher body</p></article>'); $preserve->beforeInsert($rich); check($rich->content(false)==='<article><p>Rich publisher body</p></article>'&&count($calls)===$n,'RSS default fetched or changed content');
$feed->_attribute('community_extraction_mode','community'); $feed->_httpAuth('synthetic:synthetic'); $n=count($calls); $private=$new('private'); $preserve->beforeInsert($private); check(count($calls)===$n,'authenticated feed fetched'); $feed->_httpAuth('');
$client->resetContext(); $clock=0; $n=count($calls); for ($i=0;$i<100;$i++) { $preserve->beforeInsert($new('budget-'.$i)); }
check(count($calls)-$n===61,'shared budget/readiness does not bound requests');
// A transaction failure must roll back body and attributes together.
$dao->beginTransaction(); $candidate=$new('rollback'); $preserve->beforeInsert($candidate); $dao->addEntry($candidate->toArray()); $dao->commitNewEntries(); $dao->rollBack(); check($dao->searchByGuid($feed->id(),'rollback')===null,'failed persistence left partial accepted entry');
$client->resetContext(); $n=count($calls); $preserve->beforeUpdate($new('update-only'));
check(count($calls)===$n,'update validation fetched a second time');
$feed->_pathEntries('//article'); $feeds->updateFeed($feed->id(),['pathEntries'=>'//article']);
$configure=proc_open(['php','/var/www/FreshRSS/extensions/xExtension-CommunityExtraction/configure.php','--user','reader','--feed-id',(string)$feed->id(),'--mode','community'],[0=>['file','/dev/null','r'],1=>['file','/dev/null','w'],2=>['file','/tmp/configure-error','w']],$pipes);
check(proc_close($configure)===0&&$feeds->searchById($feed->id())->pathEntries()==='','explicit feed configuration did not clear competing selector');
@unlink('/run/news/extraction-circuit.json');
$wire=new CommunityExtraction\Client($manifest); $reply=$wire->extract('https://fixture.example/wire',[],2);
check(($reply['decision']??'')==='accepted','real worker client failed');
$wire->resetContext(); $reply=$wire->extract('https://fixture.example/oversized',[],2); check($reply['decision']==='rejected','real client accepted oversized reply');
@unlink('/run/news/extraction-circuit.json');
$client->resetContext(); $n=count($calls); $huge=$new(str_repeat('g',900)); $preserve->beforeInsert($huge);
check(count($calls)===$n&&!$huge->hasAttribute('community_extraction'),'unbounded item identity entered provenance');
$privateFeed=new FreshRSS_Feed('http://127.0.0.1/private'); $privateFeed->_id($feed->id()); $privateFeed->_attribute('community_extraction_mode','community');
$private=$new('private-feed'); $private->_feed($privateFeed); $preserve->beforeInsert($private);
check(count($calls)===$n,'private feed selected extraction');
// The actual ingestion controller, not a model-only imitation, must skip
// unchanged enclosure entries and evaluate filters against the selected body.
$clock=0; $client->resetContext(); $decision='accepted';
$feed->_filtersAction('read',['"Selected editorial"']);
check($feeds->updateFeed($feed->id(),['attributes'=>$feed->attributes()]),'feed filter save failed');
Minz_ExtensionManager::addHook(Minz_HookType::EntryBeforeInsert,[$preserve,'beforeInsert']);
Minz_ExtensionManager::addHook(Minz_HookType::EntryBeforeUpdate,[$preserve,'beforeUpdate']);
$filtered=0; Minz_ExtensionManager::addHook(Minz_HookType::EntryAutoRead,function ($e,$reason) use (&$filtered) { if ($reason==='filter') { $filtered++; } return $e; });
$push=function (string $guid,string $rss) use ($feed): void {
    $pie=new FreshRSS_SimplePieCustom(); $pie->enable_cache(false);
    $pie->set_raw_data('<rss version="2.0"><channel><title>Synthetic</title><link>https://fixture.example/</link><description>Test</description><item><guid isPermaLink="false">'.$guid.'</guid><title>Stable title</title><link>https://fixture.example/article</link><description><![CDATA['.$rss.']]></description><enclosure url="https://fixture.example/image.jpg" type="image/jpeg" length="12"/></item></channel></rss>');
    check($pie->init(),'synthetic feed parse failed');
    FreshRSS_feed_Controller::actualizeFeedsAndCommit($feed->id(),null,null,$pie);
};
$n=count($calls); $push('pipeline','<p>Pipeline RSS</p>'); $pipeline=$dao->searchByGuid($feed->id(),'pipeline');
check($pipeline!==null&&str_contains($pipeline->content(false),'Selected editorial')&&$pipeline->isRead(),'selected body did not reach controller/filter/storage');
check($filtered===1,'filter did not run exactly once'); $n=count($calls);
$push('pipeline','<p>Pipeline RSS</p>'); check(count($calls)===$n&&$filtered===1,'unchanged enclosure poll manufactured update/fetch/filter');
// With requests off, genuine RSS updates still retain accepted content.
Minz_ExtensionManager::init(); $push('pipeline','<p>Changed while requests disabled</p>');
check($dao->searchByGuid($feed->id(),'pipeline')->content(false)===$pipeline->content(false),'real enabled preservation did not retain accepted body');
// Actually disabling the extension deliberately returns updated entries to RSS.
FreshRSS_Context::systemConf()->extensions_enabled=[]; Minz_ExtensionManager::init();
$push('pipeline','<p>Changed with extension disabled</p>');
check($dao->searchByGuid($feed->id(),'pipeline')->content(false)==='<p>Changed with extension disabled</p>','disabled extension falsely claims preservation');
// Cold outage: one bounded availability probe, many new stored snippets.
FreshRSS_Context::systemConf()->extensions_enabled=['CommunityExtraction'=>true]; Minz_ExtensionManager::init();
@unlink('/run/news/extraction-circuit.json'); $outageCalls=0; $outage=false;
$unavailable=new CommunityExtraction\Client($manifest,function () use (&$outageCalls,&$outage,$release) { $outageCalls++; return $outage?[200,['release_id'=>$release]]:[0,[]]; });
$fallback=new CommunityExtraction\Preservation($unavailable,true);
Minz_ExtensionManager::addHook(Minz_HookType::EntryBeforeInsert,[$fallback,'beforeInsert']);
for ($i=0;$i<20;$i++) { $push('outage-'.$i,'<p>Cold RSS '.$i.'</p>'); check($dao->searchByGuid($feed->id(),'outage-'.$i)!==null,'outage dropped RSS item'); }
check($outageCalls===1,'outage waited once per item'); $outage=true; @unlink('/run/news/extraction-circuit.json'); $unavailable->resetContext();
for ($i=0;$i<20;$i++) { $push('outage-'.$i,'<p>Cold RSS '.$i.'</p>'); }
check($outageCalls===1,'worker recovery silently backfilled unchanged snippets');
echo "FreshRSS preservation/hash/state/budget/controller/filter/outage integration passed\n";
