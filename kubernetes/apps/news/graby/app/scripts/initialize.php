<?php
declare(strict_types=1);
require __DIR__ . '/runtime.php';
require __DIR__ . '/archive.php';

function command(array $args, string $directory): void {
    $process = proc_open($args, [0 => ['file', '/dev/null', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes, $directory,
        ['PATH' => '/usr/local/bin:/usr/bin:/bin', 'COMPOSER_HOME' => '/tmp/composer', 'COMPOSER_CACHE_DIR' => '/tmp/composer-cache', 'COMPOSER_PROCESS_TIMEOUT' => '120']);
    if (!is_resource($process) || proc_close($process) !== 0) { throw new RuntimeException('installation_failed'); }
}

function removeStage(string $path): void {
    if (is_link($path) || is_file($path)) { if (!unlink($path)) { throw new RuntimeException('staging_cleanup_failed'); } return; }
    if (!is_dir($path)) { return; }
    foreach (new FilesystemIterator($path, FilesystemIterator::SKIP_DOTS) as $entry) { removeStage($entry->getPathname()); }
    if (!rmdir($path)) { throw new RuntimeException('staging_cleanup_failed'); }
}
$stage = null;

try {
    $root = dirname(__DIR__);
    $release = NewsExtraction\Release::load($root . '/release.json', $root);
    $lock = fopen('/work/.initialize.lock', 'c');
    if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) { throw new RuntimeException('initializer_busy'); }
    chmod('/work/.initialize.lock', 0600);
    // This volume belongs only to this initializer. Never follow stage symlinks.
    foreach (glob('/work/staging-*') as $abandoned) {
        if (preg_match('/^staging-[a-f0-9]{16}$/D', basename($abandoned))) { removeStage($abandoned); }
    }
    // A warm reuse must pass all checks, never just a marker-file check.
    if (is_dir('/work/current')) {
        NewsExtraction\verifyRuntime('/work/current', $root);
        exit(0);
    }
    $stage = '/work/staging-' . bin2hex(random_bytes(8));
    mkdir($stage, 0700);
    copy($root . '/composer.json', $stage . '/composer.json');
    copy($root . '/composer.lock', $stage . '/composer.lock');
    $php = ['/usr/bin/php8.4', '-d', 'extension=tidy', '/usr/local/bin/composer'];
    $installed = false;
    for ($attempt = 0; $attempt < 2; $attempt++) {
        echo "installation_attempt\n";
        try {
            command([...$php, 'install', '--no-dev', '--no-scripts', '--no-plugins', '--prefer-dist', '--no-interaction'], $stage);
            $installed = true; break;
        } catch (Throwable $e) { /* bounded second attempt inside outer deadline */ }
    }
    if (!$installed) { throw new RuntimeException('installation_failed'); }
    command([...$php, 'check-platform-reqs', '--no-dev', '--no-scripts', '--no-plugins'], $stage);
    $rules = $release->metadata()['rules'];
    command(['/usr/bin/curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '60', '--max-filesize', '8388608', '--proto', '=https', '--proto-redir', '=https', '--output', $stage . '/rules.tar.gz',
        'https://codeload.github.com/fivefilters/ftr-site-config/tar.gz/' . $rules['commit']], $stage);
    if (!hash_equals($rules['sha256'], hash_file('sha256', $stage . '/rules.tar.gz'))) { throw new RuntimeException('rule_archive_mismatch'); }
    NewsExtraction\extractRules($stage . '/rules.tar.gz', $stage . '/rules', $rules['commit']);
    $hashes = [];
    foreach (glob($stage . '/rules/*.txt') as $file) { $hashes[basename($file)] = hash_file('sha256', $file); }
    ksort($hashes);
    file_put_contents($stage . '/verified.json', json_encode(['release_id' => $release->id(), 'rules' => $hashes], JSON_THROW_ON_ERROR));
    NewsExtraction\verifyRuntime($stage, $root);
    require __DIR__ . '/smoke.php';
    smoke($stage);
    if (!rename($stage, '/work/current')) { throw new RuntimeException('selection_failed'); }
    echo "initialization_ready\n";
} catch (Throwable $e) {
    if ($stage !== null) { try { removeStage($stage); } catch (Throwable $cleanup) { /* Retry cleanup under the next initializer lock. */ } }
    $known = ['initializer_busy', 'staging_cleanup_failed', 'installation_failed', 'rule_archive_mismatch', 'unsafe_archive', 'archive_limit', 'rules_missing', 'runtime_mismatch', 'rules_mismatch', 'installed_lock_mismatch', 'platform_missing', 'rule_policy_failed'];
    $reason = in_array($e->getMessage(), $known, true) ? $e->getMessage() : 'initialization_failed';
    fwrite(STDERR, $reason . "\n"); exit(1);
}
