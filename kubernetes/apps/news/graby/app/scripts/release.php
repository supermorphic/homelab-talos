<?php
declare(strict_types=1);
require __DIR__ . '/../src/Release.php';
try {
    $release = NewsExtraction\Release::load(__DIR__ . '/../release.json', dirname(__DIR__));
    if (!in_array($argv[1] ?? '', ['verify', 'id'], true)) { throw new RuntimeException('invalid_command'); }
    echo $release->id(), "\n";
} catch (Throwable $e) { fwrite(STDERR, "release_verification_failed\n"); exit(1); }
