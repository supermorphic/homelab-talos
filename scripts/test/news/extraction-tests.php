<?php
declare(strict_types=1);
set_error_handler(function (int $severity, string $message): bool {
    if (error_reporting() & $severity) { throw new ErrorException($message, 0, $severity); }
    return false;
});

function check(bool $condition, string $message): void {
    if (!$condition) { throw new RuntimeException($message); }
}
function rejects(callable $call, string $message): void {
    try { $call(); } catch (Throwable $e) { return; }
    throw new RuntimeException($message);
}
const APP = '/repo/kubernetes/apps/news/graby/app';
$phase = $argv[1] ?? 'all';
if ($phase === 'initialization' || $phase === 'all') {
    check(is_file(APP . '/src/Release.php'), 'release verification is missing');
    require APP . '/src/Release.php';
    $root = '/work/test-release';
    mkdir($root);
    file_put_contents($root . '/code.php', 'synthetic');
    // Use a Python-produced canonical vector supplied below for valid input.
    $metadata = json_decode(file_get_contents('/repo/tests/fixtures/news/extraction/release-vector.json'), true, 32, JSON_THROW_ON_ERROR);
    file_put_contents($root . '/release.json', json_encode($metadata));
    $release = NewsExtraction\Release::load($root . '/release.json', $root);
    check($release->id() === $metadata['id'], 'valid release failed');
    file_put_contents($root . '/code.php', 'changed');
    rejects(fn() => NewsExtraction\Release::load($root . '/release.json', $root), 'changed code accepted');
    file_put_contents($root . '/code.php', 'synthetic');
    $metadata['rules']['commit'] = str_repeat('e',40);
    file_put_contents($root . '/release.json', json_encode($metadata));
    rejects(fn() => NewsExtraction\Release::load($root . '/release.json', $root), 'changed rule pin accepted');
    $metadata['files']['../escape'] = str_repeat('a',64);
    file_put_contents($root . '/release.json', json_encode($metadata));
    rejects(fn() => NewsExtraction\Release::load($root . '/release.json', $root), 'unsafe release path accepted');
    require APP . '/scripts/runtime.php';
    rejects(fn() => NewsExtraction\verifyRuntime('/work/absent', APP), 'partial installation became ready');
    require APP . '/scripts/archive.php';
    $tar = new PharData('/work/valid.tar');
    $tar->addFromString('ftr-site-config-' . str_repeat('b',40) . '/example.com.txt', 'body: //article');
    unset($tar);
    NewsExtraction\extractRules('/work/valid.tar', '/work/rules', str_repeat('b',40));
    check(file_get_contents('/work/rules/example.com.txt') === 'body: //article', 'valid archive lost rule');
    $tar = new PharData('/work/wrong.tar');
    $tar->addFromString('wrong/example.com.txt', 'body: //article'); unset($tar);
    rejects(fn() => NewsExtraction\extractRules('/work/wrong.tar', '/work/wrong-rules', str_repeat('b',40)), 'wrong rule directory accepted');
    echo "initialization release checks passed on " . PHP_VERSION . ' ' . php_uname('m') . "\n";
}
if ($phase === 'fetch' || $phase === 'all') { require __DIR__ . '/extraction-fetch-tests.php'; }
if (!in_array($phase, ['initialization', 'fetch', 'all'], true)) {
    throw new RuntimeException('phase not implemented: ' . $phase);
}
