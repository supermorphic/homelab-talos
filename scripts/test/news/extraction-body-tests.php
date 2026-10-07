<?php
declare(strict_types=1);
check(is_file(APP.'/src/Extractor.php'), 'strict extractor is missing');
require '/work/current/vendor/autoload.php';
require APP.'/src/Sanitizer.php';
require APP.'/src/Extractor.php';
$limits=json_decode(file_get_contents(APP.'/limits.json'),true);
$extractor=new NewsExtraction\Extractor('/work/current/rules',$limits);
$paragraph=str_repeat('Independent synthetic editorial sentence. ',12);
$page='<html><head><title>Fixture</title></head><body><nav>Publisher navigation</nav><article><h2>Section</h2><p>'.$paragraph.'</p><figure><img src="/first.jpg" alt="First image"><figcaption>First caption</figcaption></figure><p>Second editorial paragraph.</p><figure><img src="/second.jpg"><figcaption>Second caption</figcaption></figure><ul><li>List item</li></ul><table><tr><th>Metric</th></tr><tr><td>Value</td></tr></table><a href="/reference">Reference</a></article></body></html>';
$result=$extractor->extract('https://arstechnica.com/fixture',$page);
check($result['decision']==='accepted','unchanged upstream rule did not accept matching article');
check(!str_contains($result['html'],'Publisher navigation'),'page chrome leaked');
check(str_contains($result['html'],'First caption') && strpos($result['html'],'first.jpg')<strpos($result['html'],'second.jpg'),'media order/captions lost');
check(str_contains($result['html'],'<table') && str_contains($result['html'],'<ul') && str_contains($result['html'],'https://arstechnica.com/reference'),'editorial structure/links lost');
check(isset($result['rules']['arstechnica.com.txt']),'actual matched rule provenance missing');
foreach ([['https://unsupported.invalid/',$page,'no_rule'],['https://arstechnica.com/','<html><body><p>'.$paragraph.'</p></body></html>','selector_miss'],['https://arstechnica.com/','<article><p>Subscribe to continue reading this article.</p></article>','restricted'],['https://arstechnica.com/','<html><script type="application/ld+json">{"isAccessibleForFree":false}</script>'.$page.'</html>','restricted'],['https://arstechnica.com/','<article><h2>This article is only for paid subscribers</h2><p>'.$paragraph.'</p></article>','restricted']] as [$url,$input,$reason]) {
    $r=$extractor->extract($url,$input);
    check($r['decision']==='rejected'&&!isset($r['html'])&&$r['reason']===$reason,'rejection lost: '.$reason);
}
$short='<article><p>Measurements.</p><table><tr><th>Metric</th></tr><tr><td>Value</td></tr></table></article>';
check($extractor->extract('https://arstechnica.com/',$short)['decision']==='accepted','legitimate short structured article rejected');
$extractedGate='<html><body><aside><p>'.$paragraph.'</p></aside><article><p>Subscribe to continue reading this article.</p></article></body></html>';
check(!NewsExtraction\Extractor::restricted($extractedGate),'extracted-gate test was already rejected at document level');
check($extractor->extract('https://arstechnica.com/',$extractedGate)['reason']==='restricted','extracted interstitial accepted');
foreach (['','plain malformed response','<article></article>'] as $bad) { check($extractor->extract('https://arstechnica.com/',$bad)['decision']==='rejected','empty or malformed output accepted'); }
$dirty='<p hidden aria-hidden="true" style="display:none" onclick="alert(1)">Visible editorial text</p><script>unsafe_script_marker</script><form>unsafe_form_marker</form><iframe>unsafe_embed_marker</iframe><img src="/hero.jpg" srcset="javascript:alert(1) 1x, /safe.jpg 2x" onerror="x"><a href="javascript:alert(1)">Safe text</a><a href="//cdn.example/reference">Reference</a>';
$clean=NewsExtraction\Sanitizer::clean($dirty,'https://arstechnica.com/fixture');
check(str_contains($clean,'Visible editorial text')&&str_contains($clean,'https://arstechnica.com/hero.jpg'),'safe editorial content lost');
foreach (['unsafe_script_marker','unsafe_form_marker','unsafe_embed_marker','onclick','onerror','javascript:','aria-hidden','hidden=','style='] as $unsafe) { check(!str_contains($clean,$unsafe),'unsafe HTML retained'); }
mkdir('/work/test-only-rules');
foreach (['global'=>'body: //article','bodyless'=>'title: //h1','login'=>"body: //article\nrequires_login: yes",'alternate'=>"body: //article\nsingle_page_link: //a[@rel='alternate']/@href",'multipage'=>"body: //article\nnext_page_link: //a[@rel='next']/@href"] as $name=>$rule) { file_put_contents('/work/test-only-rules/'.$name.'.example.txt',$rule); }
file_put_contents('/work/test-only-rules/global.txt','body: //article');
$testExtractor=new NewsExtraction\Extractor('/work/test-only-rules',$limits);
foreach (['unknown'=>'no_rule','bodyless'=>'no_body_rule','login'=>'restricted','alternate'=>'secondary_request_required','multipage'=>'secondary_request_required'] as $host=>$reason) {
    $r=$testExtractor->extract('https://'.$host.'.example/',$page);
    check($r['decision']==='rejected'&&$r['reason']===$reason&&!isset($r['html']),'unsafe directive accepted: '.$host);
}
echo "strict community extraction and sanitizer passed\n";
$client=new NewsExtraction\RefusingClient();
rejects(fn()=>$client->sendRequest(new GuzzleHttp\Psr7\Request('GET','https://unsupported.invalid/secondary')),'secondary client allowed request');
check($client->attempts===1,'swallowed secondary failure could not be detected');
$wired='<article class="main-content"><p aria-hidden="true" hidden>'.$paragraph.'</p><p>Visible continuation.</p></article>';
$r=$extractor->extract('https://www.wired.com/fixture',$wired);
check($r['decision']==='accepted'&&!str_contains($r['html'],'aria-hidden')&&str_contains($r['html'],$paragraph),'WIRED editorial text remained inaccessible');
$globalMiss=$testExtractor->extract('https://bodyless.example/',$page);
check($globalMiss['decision']==='rejected','global rule supplied bodyless host content');
$release=json_decode(file_get_contents(APP.'/release.json'),true);
$process=proc_open(['/usr/bin/php8.4','-d','extension=tidy','-d','memory_limit=512M',APP.'/scripts/job.php'],[0=>['pipe','r'],1=>['pipe','w'],2=>['file','/dev/null','w']],$pipes);
fwrite($pipes[0],json_encode(['url'=>'http://127.0.0.1/private','expected_release'=>$release['id']])); fclose($pipes[0]);
$reply=json_decode(stream_get_contents($pipes[1]),true); fclose($pipes[1]); $exit=proc_close($process);
check($exit===0&&$reply['decision']==='rejected'&&!isset($reply['html'])&&$reply['release_id']===$release['id'],'job failed to return safe protocol rejection');
