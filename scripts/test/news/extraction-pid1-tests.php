<?php
declare(strict_types=1);
function checkPid1(bool $condition,string $message): void { if (!$condition) { throw new RuntimeException($message); } }
function waitFor(callable $test,string $message,float $seconds=2): void { $end=hrtime(true)/1e9+$seconds; do { if ($test()) return; usleep(10000); } while (hrtime(true)/1e9<$end); throw new RuntimeException($message); }
waitFor(function () { $socket=@stream_socket_client('tcp://127.0.0.1:18082',$code,$message,0.1); if ($socket===false) return false; fclose($socket); return true; },'PID1 server not ready',310);
checkPid1(str_contains(file_get_contents('/proc/1/cmdline'),'extraction-service-bootstrap.php'),'service is not PID1');
$release=json_decode(file_get_contents('/app/release.json'),true)['id'];
$body=json_encode(['url'=>'https://fixture.example/delayed-orphan','expected_release'=>$release]);
$ch=curl_init('http://127.0.0.1:18082/extract'); curl_setopt_array($ch,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>$body,CURLOPT_RETURNTRANSFER=>true,CURLOPT_TIMEOUT=>5]);
$reply=curl_exec($ch); curl_close($ch); checkPid1(json_decode($reply,true)['decision']==='accepted','completed job reply lost');
$orphan=(int)file_get_contents('/work/descendant-pid');
waitFor(fn()=>!posix_kill($orphan,0),'PID1 retained late-exiting adopted descendant');
for ($attempt=0;$attempt<60;$attempt++) {
 @unlink('/work/job-started');
 $socket=stream_socket_client('tcp://127.0.0.1:18082');
 $body=json_encode(['url'=>'https://fixture.example/hang','expected_release'=>$release]);
 fwrite($socket,"POST /extract HTTP/1.1\r\nHost: fixture\r\nContent-Length: ".strlen($body)."\r\n\r\n".$body);
 waitFor(fn()=>is_file('/work/job-started'),'job did not start');
 $parent=(int)file_get_contents('/work/job-pid'); $descendant=(int)file_get_contents('/work/descendant-pid');
 fclose($socket);
 waitFor(fn()=>!posix_kill($parent,0),'direct child was not reaped');
 waitFor(fn()=>!posix_kill($descendant,0),'PID1 retained killed descendant');
}
echo "PID1 sixty cancellation groups reaped\n";
