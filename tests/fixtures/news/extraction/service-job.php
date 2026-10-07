<?php
posix_setpgid(0,0);
$request=json_decode(stream_get_contents(STDIN),true);
file_put_contents('/work/job-pid',(string)getmypid());
if (str_contains($request['url'],'/delayed-orphan')) {
    $orphan=pcntl_fork();
    if ($orphan===0) { fclose(STDIN); fclose(STDOUT); fclose(STDERR); usleep(200000); exit; }
    file_put_contents('/work/descendant-pid',(string)$orphan);
}
if (str_contains($request['url'],'/hang')) {
    $child=proc_open(['/usr/bin/php8.4','-r','sleep(30);'],[0=>['file','/dev/null','r'],1=>['file','/dev/null','w'],2=>['file','/dev/null','w']],$pipes);
    file_put_contents('/work/descendant-pid',(string)proc_get_status($child)['pid']);
    file_put_contents('/work/job-started','started'); sleep(30);
}
file_put_contents('/work/job-started','started');
if (str_contains($request['url'],'/stdout')) { echo str_repeat('x',8388609); exit; }
if (str_contains($request['url'],'/stderr')) { fwrite(STDERR,str_repeat('x',8193)); exit; }
$reply=['decision'=>'accepted','release_id'=>$request['expected_release'],'reason'=>'community_rule','html'=>'<p>synthetic body</p>','rules'=>['fixture.txt'=>str_repeat('a',64)],'final_url'=>$request['url'],'validators'=>[]];
if (str_contains($request['url'],'/rate')) { $reply=['decision'=>'rejected','release_id'=>$request['expected_release'],'reason'=>'rate_limited','retry_after'=>60]; }
if (str_contains($request['url'],'/conditional')) { $reply=['decision'=>'not_modified','reason'=>'not_modified','release_id'=>$request['expected_release']]; }
if (str_contains($request['url'],'/invalid')) { $reply['release_id']=str_repeat('0',64); }
echo json_encode($reply);
