<?php
declare(strict_types=1);
check(is_file(APP.'/src/Server.php'),'responsive supervised service is missing');
function httpRequest(string $path,?string $body=null,int $port=18082): array {
    $ch=curl_init('http://127.0.0.1:'.$port.$path);
    curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_TIMEOUT=>12,CURLOPT_PROXY=>'']);
    if ($body!==null) { curl_setopt_array($ch,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>$body,CURLOPT_HTTPHEADER=>['Content-Type: application/json']]); }
    $start=hrtime(true)/1e9; $out=curl_exec($ch); $code=curl_getinfo($ch,CURLINFO_RESPONSE_CODE); curl_close($ch);
    return ['status'=>$code,'body'=>$out,'seconds'=>hrtime(true)/1e9-$start];
}
function until(callable $condition,string $message,float $seconds=2): void {
    $end=hrtime(true)/1e9+$seconds;
    while (hrtime(true)/1e9<$end) { if ($condition()) { return; } usleep(10000); }
    throw new RuntimeException($message);
}
$release=json_decode(file_get_contents(APP.'/release.json'),true)['id'];
$request=fn($url,$id=null)=>json_encode(['url'=>$url,'expected_release'=>$id??$release]);
$server=proc_open(['/usr/bin/php8.4','-d','extension=tidy','/repo/scripts/test/news/extraction-service-bootstrap.php'],[0=>['file','/dev/null','r'],1=>['file','/dev/null','w'],2=>['file','/work/server-error','w']],$pipes);
try {
    until(fn()=>httpRequest('/ready')['status']===200,'service not ready');
    check(httpRequest('/extract','{')['status']===400,'malformed JSON admitted');
    check(httpRequest('/extract',str_repeat('x',8193))['status']===413,'oversized JSON admitted');
    check(httpRequest('/extract',$request('https://fixture.example/ok',str_repeat('0',64)))['status']===503,'mixed release admitted');
    check(!is_file('/work/job-started'),'invalid request fetched publisher');
    $ok=httpRequest('/extract',$request('https://fixture.example/ok'));
    check($ok['status']===200&&json_decode($ok['body'],true)['decision']==='accepted','valid supervised reply lost');
    $rate=httpRequest('/extract',$request('https://rate.example/rate'));
    check(json_decode($rate['body'],true)['reason']==='rate_limited','publisher denial lost');
    $rate=httpRequest('/extract',$request('https://rate.example/ok'));
    check(json_decode($rate['body'],true)['reason']==='origin_cooldown','publisher cooldown ignored');
    check(json_decode(httpRequest('/extract',$request('https://another.example/ok'))['body'],true)['decision']==='accepted','origin cooldown disabled another publisher');
    $metrics=httpRequest('/metrics',null,18083)['body'];
    check(str_contains($metrics,'news_extraction_request_seconds_count 3'),'invalid/cooldown request spawned a job');
    foreach (['stdout'=>'reply_invalid','stderr'=>'job_failed','invalid'=>'reply_invalid','conditional'=>'not_modified'] as $case=>$reason) {
        $reply=json_decode(httpRequest('/extract',$request('https://another.example/'.$case))['body'],true);
        check(($reply['reason']??'')===$reason,'bounded/conditional reply case failed: '.$case);
    }
    unlink('/work/job-started');
    $socket=stream_socket_client('tcp://127.0.0.1:18082');
    $body=$request('https://fixture.example/hang');
    fwrite($socket,"POST /extract HTTP/1.1\r\nHost: fixture\r\nContent-Type: application/json\r\nContent-Length: ".strlen($body)."\r\n\r\n".$body);
    until(fn()=>is_file('/work/job-started'),'hung job did not start');
    $ready=httpRequest('/ready'); check($ready['status']===200&&$ready['seconds']<1,'readiness blocked by extraction');
    check(httpRequest('/extract',$request('https://another.example/ok'))['status']===429,'busy service queued a request');
    $pid=(int)file_get_contents('/work/job-pid');
    fclose($socket);
    until(fn()=>!posix_kill($pid,0),'cancelled child not reaped');
    $descendant=(int)file_get_contents('/work/descendant-pid');
    until(fn()=>!posix_kill($descendant,0),'cancelled descendant survived');
    $slow=stream_socket_client('tcp://127.0.0.1:18082');
    fwrite($slow,"POST /extract HTTP/1.1\r\nHost: fixture\r\nContent-Length: 100\r\n\r\nx");
    stream_set_timeout($slow,2); $start=hrtime(true)/1e9; $out=stream_get_contents($slow); fclose($slow);
    check(hrtime(true)/1e9-$start<1.4&&str_contains($out,'408'),'slow body was not bounded');
    $slow=stream_socket_client('tcp://127.0.0.1:18082'); fwrite($slow,"GET /ready HTTP/1.1\r\nHost:");
    stream_set_timeout($slow,2); $start=hrtime(true)/1e9; stream_get_contents($slow); fclose($slow);
    check(hrtime(true)/1e9-$start<1.4,'slow headers were not bounded');
    $timed=httpRequest('/extract',$request('https://fixture.example/hang'));
    check($timed['seconds']<10&&json_decode($timed['body'],true)['reason']==='job_timeout','hung child exceeded client deadline');
    $metrics=httpRequest('/metrics',null,18083)['body'];
    check(str_contains($metrics,'news_extraction_active_jobs 0')&&!str_contains($metrics,'fixture.example'),'metrics exposed origin or stale job');
    unlink('/work/job-started');
    $socket=stream_socket_client('tcp://127.0.0.1:18082'); $body=$request('https://fixture.example/hang');
    fwrite($socket,"POST /extract HTTP/1.1\r\nHost: fixture\r\nContent-Type: application/json\r\nContent-Length: ".strlen($body)."\r\n\r\n".$body);
    until(fn()=>is_file('/work/job-started'),'shutdown job did not start'); $pid=(int)file_get_contents('/work/job-pid');
    proc_terminate($server,SIGTERM); until(fn()=>!posix_kill($pid,0),'shutdown child survived'); fclose($socket);
    proc_close($server);
    $server=proc_open(['/usr/bin/php8.4','-d','extension=tidy','/repo/scripts/test/news/extraction-service-bootstrap.php','real'],[0=>['file','/dev/null','r'],1=>['file','/dev/null','w'],2=>['file','/work/server-error','w']],$pipes);
    until(fn()=>httpRequest('/ready')['status']===200,'real service not ready');
    $real=httpRequest('/extract',$request('http://127.0.0.1/private'));
    $reply=json_decode($real['body'],true);
    check($real['status']===200&&$reply['decision']==='rejected'&&$reply['reason']==='destination_rejected','production bounded PHP job did not execute');
    check(trim(file_get_contents('/sys/fs/cgroup/memory.max'))==='536870912','kernel did not enforce the shared worker/child memory bound');
    echo "responsive service admission/cancellation/limits passed\n";
} finally { proc_terminate($server,9); proc_close($server); }
