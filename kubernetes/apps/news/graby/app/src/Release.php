<?php
declare(strict_types=1);
namespace NewsExtraction;

final class Release {
    private function __construct(private array $metadata) {}

    public static function canonical(array $value): string {
        $sort = function (array $a) use (&$sort): array {
            if (!array_is_list($a)) { ksort($a, SORT_STRING); }
            foreach ($a as &$v) { if (is_array($v)) { $v = $sort($v); } }
            return $a;
        };
        return json_encode($sort($value), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    }

    public static function load(string $manifest, string $root): self {
        $m = json_decode(file_get_contents($manifest), true, 32, JSON_THROW_ON_ERROR);
        $id = $m['id'] ?? '';
        unset($m['id']);
        if (($m['schema'] ?? null) !== 1 || !preg_match('/^[a-f0-9]{64}$/D', $id) ||
            !hash_equals($id, hash('sha256', self::canonical($m))) || empty($m['files']) ||
            !preg_match('/@sha256:[a-f0-9]{64}$/D', $m['image'] ?? '') ||
            !preg_match('/@sha256:[a-f0-9]{64}$/D', $m['freshrss_image'] ?? '') ||
            !preg_match('/^[a-f0-9]{40}$/D', $m['rules']['commit'] ?? '') ||
            !preg_match('/^[a-f0-9]{64}$/D', $m['rules']['sha256'] ?? '')) {
            throw new \RuntimeException('release_invalid');
        }
        $base = realpath($root);
        if ($base === false) { throw new \RuntimeException('release_root_missing'); }
        foreach ($m['files'] as $path => $hash) {
            if (!is_string($path) || !preg_match('~^[a-zA-Z0-9_./-]+$~D', $path) ||
                str_starts_with($path, '/') || in_array('..', explode('/', $path), true)) {
                throw new \RuntimeException('release_path_invalid');
            }
            $actual = realpath($base . '/' . $path);
            if ($actual === false || !str_starts_with($actual, $base . '/') ||
                !is_file($actual) || !is_string($hash) || !hash_equals($hash, hash_file('sha256', $actual))) {
                throw new \RuntimeException('release_file_mismatch');
            }
        }
        $m['id'] = $id;
        return new self($m);
    }

    public function id(): string { return $this->metadata['id']; }
    public function metadata(): array { return $this->metadata; }
}
