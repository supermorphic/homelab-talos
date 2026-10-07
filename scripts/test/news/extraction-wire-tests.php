<?php
declare(strict_types=1);
// Call only the private transport below the address guard. No production switch
// permits local targets. These tests isolate cURL byte/timer/proxy behavior.
$server = proc_open(['/usr/bin/php8.4','-S','127.0.0.1:18080','/repo/tests/fixtures/news/extraction/wire-router.php'], [0=>['file','/dev/null','r'],1=>['file','/dev/null','w'],2=>['file','/dev/null','w']], $pipes);
check(is_resource($server),'fixture server unavailable');
try {
    $ready=false;
    for ($i=0;$i<100;$i++) {
        $socket=@fsockopen('127.0.0.1',18080,$errno,$error,0.02);
        if ($socket!==false) { fclose($socket); $ready=true; break; }
        usleep(10000);
    }
    check($ready,'fixture server did not start');
    $transport = new ReflectionMethod(NewsExtraction\Fetcher::class,'curl');
    $real = new NewsExtraction\Fetcher($limits);
    putenv('http_proxy=http://127.0.0.1:1'); putenv('HTTP_PROXY=http://127.0.0.1:1'); putenv('https_proxy=http://127.0.0.1:1'); putenv('ALL_PROXY=http://127.0.0.1:1');
    $wire = fn($path,$seconds=2) => $transport->invoke($real,'http://fixture.invalid:18080/'.$path,['127.0.0.1'],['Accept-Encoding'=>'gzip, deflate'],hrtime(true)/1e9+$seconds);
    check($wire('identity')['html'] === 'synthetic body','wire response or proxy suppression failed');
    check($wire('gzip')['html'] === 'synthetic body','gzip decode failed');
    check(strlen($wire('exact')['html'])===5242880,'exact wire body limit rejected');
    foreach (['overflow','compressed-overflow'] as $path) {
        try { $wire($path); throw new RuntimeException('overflow accepted'); }
        catch (RuntimeException $e) { check($e->getMessage()==='body_limit','wire overflow gave wrong rejection'); }
    }
    foreach (['slow-headers','slow-body'] as $path) {
        usleep(350000); // The single fixture worker has finished the prior request.
        try { $wire($path,0.1); throw new RuntimeException('slow response accepted'); }
        catch (RuntimeException $e) { check($e->getMessage()==='timeout','wire timer gave wrong rejection'); }
    }
    echo "production cURL wire limits passed\n";
} finally { proc_terminate($server,9); proc_close($server); }
