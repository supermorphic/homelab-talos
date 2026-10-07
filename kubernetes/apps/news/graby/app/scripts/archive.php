<?php
declare(strict_types=1);
namespace NewsExtraction;

function extractRules(string $file, string $destination, string $commit): void {
    $archive = new \PharData($file);
    $prefix = 'ftr-site-config-' . $commit . '/';
    mkdir($destination, 0700);
    $count = 0;
    foreach (new \RecursiveIteratorIterator($archive) as $key => $entry) {
        $path = substr($key, strlen('phar://' . $file . '/'));
        if ($entry->isLink() || str_contains($path, '..') || !str_starts_with($path, $prefix)) { throw new \RuntimeException('unsafe_archive'); }
        $name = substr($path, strlen($prefix));
        if (!str_contains($name, '/') && preg_match('/^[a-zA-Z0-9_.-]+\.txt$/D', $name)) {
            if (++$count > 10000 || $entry->getSize() > 1048576) { throw new \RuntimeException('archive_limit'); }
            file_put_contents($destination . '/' . $name, file_get_contents($key));
        }
    }
    if ($count === 0) { throw new \RuntimeException('rules_missing'); }
}
