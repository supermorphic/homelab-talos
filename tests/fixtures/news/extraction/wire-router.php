<?php
header('Content-Type: text/html');
$path=trim(parse_url($_SERVER['REQUEST_URI'],PHP_URL_PATH),'/');
if ($path==='slow-headers') { usleep(300000); }
if ($path==='slow-body') { echo 'start'; flush(); usleep(300000); }
if ($path==='gzip' || $path==='compressed-overflow') {
    header('Content-Encoding: gzip');
    echo gzencode($path==='gzip'?'synthetic body':str_repeat('x',5242881));
} elseif ($path==='exact' || $path==='overflow') { echo str_repeat('x',$path==='exact'?5242880:5242881); }
else { echo 'synthetic body'; }
