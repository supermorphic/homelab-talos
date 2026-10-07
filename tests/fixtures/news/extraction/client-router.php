<?php
header('Content-Type: application/json');
$release=json_decode(file_get_contents('/release.json'),true)['id'];
$path=parse_url($_SERVER['REQUEST_URI'],PHP_URL_PATH);
if ($path==='/ready') { echo json_encode(['release_id'=>$release]); exit; }
$request=json_decode(file_get_contents('php://input'),true);
if (str_ends_with($request['url'],'/slow')) { sleep(3); }
if (str_ends_with($request['url'],'/oversized')) { echo str_repeat('x',8388609); exit; }
echo json_encode(['decision'=>'accepted','reason'=>'community_rule','release_id'=>$release,'html'=>'<p>Wire-selected article body.</p>','rules'=>['fixture.txt'=>str_repeat('a',64)],'final_url'=>$request['url'],'validators'=>[]]);
