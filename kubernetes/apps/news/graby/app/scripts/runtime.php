<?php
declare(strict_types=1);
namespace NewsExtraction;
require_once __DIR__ . '/../src/Release.php';

function verifyRuntime(string $current, string $root): Release {
    $release = Release::load($root . '/release.json', $root);
    foreach (['curl', 'dom', 'mbstring', 'tidy', 'xml'] as $extension) {
        if (!extension_loaded($extension)) { throw new \RuntimeException('platform_missing'); }
    }
    if (!is_file($current . '/verified.json')) { throw new \RuntimeException('runtime_mismatch'); }
    $marker = json_decode(file_get_contents($current . '/verified.json'), true, 16, JSON_THROW_ON_ERROR);
    if (($marker['release_id'] ?? '') !== $release->id() ||
        !is_file($current . '/vendor/autoload.php') ||
        !hash_equals(hash_file('sha256', $root . '/composer.lock'), hash_file('sha256', $current . '/composer.lock')) ||
        realpath($current . '/rules') !== realpath($current) . '/rules') {
        throw new \RuntimeException('runtime_mismatch');
    }
    $actual = [];
    foreach (glob($current . '/rules/*.txt') as $file) { $actual[basename($file)] = hash_file('sha256', $file); }
    ksort($actual);
    if (empty($actual) || ($marker['rules'] ?? null) !== $actual) { throw new \RuntimeException('rules_mismatch'); }
    $installed = json_decode(file_get_contents($current . '/vendor/composer/installed.json'), true, 64, JSON_THROW_ON_ERROR);
    $lock = json_decode(file_get_contents($root . '/composer.lock'), true, 64, JSON_THROW_ON_ERROR);
    $packages = [];
    foreach ($installed['packages'] as $p) { $packages[$p['name']] = [$p['version'], $p['source']['reference'] ?? $p['dist']['reference'] ?? null]; }
    $expected = [];
    foreach ($lock['packages'] as $p) { $expected[$p['name']] = [$p['version'], $p['source']['reference'] ?? $p['dist']['reference'] ?? null]; }
    ksort($packages); ksort($expected);
    if ($packages !== $expected) { throw new \RuntimeException('installed_lock_mismatch'); }
    return $release;
}
