<?php
declare(strict_types=1);
require __DIR__.'/runtime.php';
$reply=['decision'=>'rejected','reason'=>'request_invalid'];
try {
    $root=dirname(__DIR__); $release=NewsExtraction\verifyRuntime('/work/current',$root);
    $reply['release_id']=$release->id();
    require '/work/current/vendor/autoload.php';
    require $root.'/src/Fetcher.php'; require $root.'/src/Sanitizer.php'; require $root.'/src/Extractor.php';
    $limits=json_decode(file_get_contents($root.'/limits.json'),true,32,JSON_THROW_ON_ERROR);
    $raw=stream_get_contents(STDIN,$limits['request_bytes']+1);
    if (strlen($raw)>$limits['request_bytes']) { throw new RuntimeException('request_invalid'); }
    $request=json_decode($raw,true,16,JSON_THROW_ON_ERROR);
    if (!is_array($request) || array_diff(array_keys($request),['url','expected_release','validators']) || !is_string($request['url']??null) || ($request['expected_release']??'')!==$release->id() || !is_array($request['validators']??[])) { throw new RuntimeException('request_invalid'); }
    $fetch=(new NewsExtraction\Fetcher($limits))->fetch($request['url'],$request['validators']??[],hrtime(true)/1e9+$limits['fetch_seconds']);
    if (!$fetch['ok']) { $reply=['decision'=>'rejected','release_id'=>$release->id(),'reason'=>$fetch['reason']]+array_intersect_key($fetch,array_flip(['retry_after','final_url'])); }
    elseif ($fetch['status']===304) { $reply=['decision'=>'not_modified','release_id'=>$release->id(),'reason'=>'not_modified','validators'=>$fetch['validators']]; }
    else {
        $reply=(new NewsExtraction\Extractor('/work/current/rules',$limits))->extract($fetch['final_url'],$fetch['html']);
        $reply['release_id']=$release->id();
        if ($reply['decision']==='accepted') { $reply['final_url']=$fetch['final_url']; $reply['validators']=$fetch['validators']; }
    }
} catch (Throwable $e) { /* bounded fallback; never emit exception contents */ }
$encoded=json_encode($reply,JSON_UNESCAPED_SLASHES);
if ($encoded===false || strlen($encoded)>8388608) { $encoded=json_encode(['decision'=>'rejected','reason'=>'reply_invalid','release_id'=>$reply['release_id']??'']); }
echo $encoded;
