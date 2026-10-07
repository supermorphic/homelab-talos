<?php
declare(strict_types=1);
require '/app/scripts/runtime.php'; $release=NewsExtraction\verifyRuntime('/work/current','/app');
require '/work/current/vendor/autoload.php';
require '/app/src/Sanitizer.php'; require '/app/src/Extractor.php';
$rules='/work/current/rules';
if (($argv[1]??'')==='broken') {
    mkdir('/work/broken-rules'); foreach (glob($rules.'/*.txt') as $file) { if (basename($file)!=='arstechnica.com.txt') { copy($file,'/work/broken-rules/'.basename($file)); } } $rules='/work/broken-rules';
}
$manifest=json_decode(file_get_contents('/corpus/manifest.json'),true,64,JSON_THROW_ON_ERROR); $results=[];
foreach ($manifest['cases'] as $case) {
    if ($case['mode']==='rss') { $html=file_get_contents('/corpus/'.$case['rss']); $reply=['decision'=>'rss','reason'=>'publisher_rss','html'=>$html]; }
    else { $extractor=new NewsExtraction\Extractor($rules,json_decode(file_get_contents('/app/limits.json'),true)); $reply=$extractor->extract($case['url'],file_get_contents('/corpus/'.$case['html'])); }
    $results[]=['id'=>$case['id'],'decision'=>$reply['decision'],'reason'=>$reply['reason'],'html'=>$reply['html']??'', 'html_sha256'=>isset($reply['html'])?hash('sha256',$reply['html']):null];
}
echo json_encode($results,JSON_UNESCAPED_SLASHES|JSON_INVALID_UTF8_SUBSTITUTE|JSON_THROW_ON_ERROR);
