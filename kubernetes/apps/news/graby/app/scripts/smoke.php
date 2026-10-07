<?php
declare(strict_types=1);
function smoke(string $current): void {
    require $current . '/vendor/autoload.php';
    $builder = new Graby\SiteConfig\ConfigBuilder(['site_config' => [$current . '/rules']]);
    $config = $builder->buildForHost('arstechnica.com');
    if (empty($config->body) || $builder->buildForHost('unsupported.invalid')->body !== []) {
        throw new RuntimeException('rule_policy_failed');
    }
    $config->autodetect_on_failure = false;
    $extractor = new Graby\Extractor\ContentExtractor(['fingerprints' => []], null, $builder);
    $html = '<html><head><title>Initialization test</title></head><body><article><p>Independent synthetic editorial paragraph for verification.</p></article><nav>Excluded navigation</nav></body></html>';
    if (!$extractor->process($html, 'https://arstechnica.com/synthetic', $config) ||
        !str_contains($extractor->getContent()->textContent, 'Independent synthetic editorial') ||
        str_contains($extractor->getContent()->textContent, 'Excluded navigation')) {
        throw new RuntimeException('rule_policy_failed');
    }
    $extractor->reset();
    if ($extractor->process('<html><body><p>Selector must miss.</p></body></html>', 'https://arstechnica.com/synthetic', $config)) {
        throw new RuntimeException('rule_policy_failed');
    }
}
