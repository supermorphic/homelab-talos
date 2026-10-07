<?php
require '/work/current/vendor/autoload.php';
require '/repo/kubernetes/apps/news/graby/app/src/Release.php';
require '/repo/kubernetes/apps/news/graby/app/src/Server.php';
$root='/repo/kubernetes/apps/news/graby/app';
$release=NewsExtraction\Release::load($root.'/release.json',$root);
$limits=json_decode(file_get_contents($root.'/limits.json'),true);
$factory=($argv[1]??'')==='real'?null:fn()=>new React\ChildProcess\Process('exec /usr/bin/php8.4 /repo/tests/fixtures/news/extraction/service-job.php');
$service=new NewsExtraction\Server($release,$limits,$factory);
$service->listen('127.0.0.1:18082','127.0.0.1:18083');
React\EventLoop\Loop::run();
