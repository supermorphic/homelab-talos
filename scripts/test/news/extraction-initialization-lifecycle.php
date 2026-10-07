<?php
declare(strict_types=1);
function invariant(bool $condition,string $message): void { if (!$condition) { throw new RuntimeException($message); } }
function initialize(string $root): bool {
 $process=proc_open(['/bin/sh',$root.'/scripts/initialize.sh'],[0=>['file','/dev/null','r'],1=>['file','/work/lifecycle.log','a'],2=>['file','/work/lifecycle.log','a']],$pipes);
 return is_resource($process)&&proc_close($process)===0;
}
mkdir('/tmp/foreign-tree'); file_put_contents('/tmp/foreign-tree/keep','outside stage ownership');
mkdir('/work/staging-keep-me'); file_put_contents('/work/staging-keep-me/keep','unknown stage ownership');
symlink('/tmp/foreign-tree','/work/staging-bbbbbbbbbbbbbbbb');
for ($attempt=0;$attempt<3;$attempt++) { $path='/work/staging-'.str_pad((string)$attempt,16,'a'); mkdir($path); file_put_contents($path.'/interrupted',str_repeat('x',1048576)); }
invariant(initialize('/app'),'valid initialization failed');
invariant(count(glob('/work/staging-*'))===1,'abandoned stage was retained');
invariant(is_file('/tmp/foreign-tree/keep')&&is_file('/work/staging-keep-me/keep'),'cleanup crossed its ownership boundary');
invariant(rename('/work/current','/work/reference-runtime'),'cannot isolate baseline runtime');
exec('cp -a /app /tmp/bad-app',$unused,$status); invariant($status===0,'cannot copy candidate');
$m=json_decode(file_get_contents('/tmp/bad-app/release.json'),true); unset($m['id']); $m['rules']['sha256']=str_repeat('0',64);
$sort=function (array $a) use (&$sort): array { if (!array_is_list($a)) ksort($a,SORT_STRING); foreach ($a as &$v) if (is_array($v)) $v=$sort($v); return $a; };
$m['id']=hash('sha256',json_encode($sort($m),JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR));
file_put_contents('/tmp/bad-app/release.json',json_encode($m,JSON_THROW_ON_ERROR));
for ($attempt=0;$attempt<3;$attempt++) {
 invariant(!initialize('/tmp/bad-app'),'bad rule checksum became ready');
 invariant(count(glob('/work/staging-*'))===1&&!is_dir('/work/current'),'failed dependency tree was retained');
}
invariant(initialize('/app'),'recovery after repeated initialization failures did not become ready');
invariant(count(glob('/work/staging-*'))===1,'recovery retained stages');
echo "Repeated rule failures, owned-stage cleanup and recovery passed\n";
