<?php
declare(strict_types=1);
require __DIR__.'/runtime.php';
try {
    $root=dirname(__DIR__); $release=NewsExtraction\verifyRuntime('/work/current',$root);
    require '/work/current/vendor/autoload.php'; require $root.'/src/Server.php';
    $limits=json_decode(file_get_contents($root.'/limits.json'),true,32,JSON_THROW_ON_ERROR);
    (new NewsExtraction\Server($release,$limits))->listen();
    React\EventLoop\Loop::run();
} catch (Throwable $e) { fwrite(STDERR,"service_unready\n"); exit(1); }
