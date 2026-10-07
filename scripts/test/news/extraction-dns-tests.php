<?php
declare(strict_types=1);
require '/repo/kubernetes/apps/news/graby/app/src/Fetcher.php';
$process=proc_open(['/usr/bin/php8.4','/repo/tests/fixtures/news/extraction/slow-dns.php'],[0=>['file','/dev/null','r'],1=>['file','/dev/null','w'],2=>['file','/dev/null','w']],$pipes);
try {
    for ($i=0;$i<100&&!is_file('/work/dns-listening');$i++) { usleep(10000); }
    if (!is_file('/work/dns-listening')) { throw new RuntimeException('DNS fixture did not start'); }
    $limits=json_decode(file_get_contents('/repo/kubernetes/apps/news/graby/app/limits.json'),true);
    $fetcher=new NewsExtraction\Fetcher($limits);
    $start=hrtime(true)/1e9;
    $result=$fetcher->fetch('https://synthetic.example/article',[],$start+5);
    $elapsed=hrtime(true)/1e9-$start;
    if (($result['reason']??'')!=='timeout'||$elapsed>1.3) { throw new RuntimeException('production resolver did not meet one-second deadline'); }
    echo "production DNS deadline passed\n";
} finally { proc_terminate($process,9); proc_close($process); }
