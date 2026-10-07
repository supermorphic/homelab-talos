<?php
declare(strict_types=1);
ini_set('display_errors', '0');

function check(bool $valid): void {
    if (!$valid) { throw new RuntimeException('failed invariant', debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 1)[0]['line']); }
}

function api(string $path, ?array $data = null, string $auth = ''): string {
    $headers = "Connection: close\r\n";
    if ($auth !== '') { $headers .= 'Authorization: GoogleLogin auth=' . $auth . "\r\n"; }
    $options = ['method' => $data === null ? 'GET' : 'POST', 'timeout' => 15,
        'header' => $headers, 'follow_location' => 0, 'max_redirects' => 0, 'ignore_errors' => true];
    if ($data !== null) {
        $options['content'] = http_build_query($data);
        $options['header'] .= "Content-Type: application/x-www-form-urlencoded\r\n";
    }
    $result = @file_get_contents('http://127.0.0.1:8080/api/greader.php' . $path,
        false, stream_context_create(['http' => $options]), 0, 1048577);
    check(is_string($result) && strlen($result) <= 1048576);
    check(isset($http_response_header[0]) && preg_match('/^HTTP\/\S+ 200\b/', $http_response_header[0]) === 1);
    return $result;
}

function state(string $auth): array {
    $items = json_decode(api('/reader/api/0/stream/contents/reading-list?output=json&n=100', null, $auth), true, 32, JSON_THROW_ON_ERROR)['items'];
    $subscriptions = json_decode(api('/reader/api/0/subscription/list?output=json', null, $auth), true, 32, JSON_THROW_ON_ERROR)['subscriptions'];
    check(count($items) === 3 && count($subscriptions) === 2);
    $full = array_values(array_filter($items, fn($i) => str_contains($i['summary']['content'], 'community garden')));
    check(count($full) === 1);
    $body = $full[0]['summary']['content'];
    check(str_contains($body, '<img') && str_contains($body, 'figcaption') && !str_contains($body, '<script'));
    check(in_array('user/-/state/com.google/read', $full[0]['categories'], true));
    check(in_array('user/-/state/com.google/starred', $full[0]['categories'], true));
    check(count(array_filter($subscriptions, fn($s) => count(array_filter($s['categories'], fn($c) => $c['label'] === 'News')) > 0)) === 1);
    return ['items_sha256' => hash('sha256', json_encode($items, JSON_THROW_ON_ERROR)),
        'subscriptions_sha256' => hash('sha256', json_encode($subscriptions, JSON_THROW_ON_ERROR)),
        'articles' => count($items), 'subscriptions' => count($subscriptions)];
}

try {
    check(count($argv) === 2 && in_array($argv[1], ['source', 'unavailable', 'reattached', 'restored'], true));
    if ($argv[1] === 'unavailable') {
        $connection = @stream_socket_client('tcp://127.0.0.1:5432', $errno, $error, 1);
        check($connection === false);
        $output = [];
        exec(escapeshellarg(PHP_BINARY) . ' /opt/news/ready.php 2>/dev/null', $output, $status);
        check($status !== 0);
        echo "News database outage confirmed; application readiness is unavailable\n";
        exit(0);
    }
    $login = api('/accounts/ClientLogin', ['Email' => 'reader', 'Passwd' => getenv('NEWS_API_PASSWORD')]);
    check(preg_match('/^Auth=(.+)$/m', $login, $matched) === 1);
    $auth = trim($matched[1]);
    if ($argv[1] === 'source') {
        foreach (['full-feed.xml', 'truncated-feed.xml'] as $feed) {
            $added = json_decode(api('/reader/api/0/subscription/quickadd', ['quickadd' => 'http://127.0.0.1:8080/' . $feed], $auth), true, 32, JSON_THROW_ON_ERROR);
            check($added['numResults'] === 1);
        }
        $subscriptions = json_decode(api('/reader/api/0/subscription/list?output=json', null, $auth), true, 32, JSON_THROW_ON_ERROR)['subscriptions'];
        api('/reader/api/0/subscription/edit', ['s' => $subscriptions[0]['id'], 'ac' => 'edit', 'a' => 'user/-/label/News'], $auth);
        $items = json_decode(api('/reader/api/0/stream/contents/reading-list?output=json&n=100', null, $auth), true, 32, JSON_THROW_ON_ERROR)['items'];
        $full = array_values(array_filter($items, fn($i) => str_contains($i['summary']['content'], 'community garden')));
        check(count($full) === 1);
        $token = trim(api('/reader/api/0/token', null, $auth));
        foreach (['read', 'starred'] as $tag) {
            api('/reader/api/0/edit-tag', ['T' => $token, 'i' => $full[0]['id'], 'a' => 'user/-/state/com.google/' . $tag], $auth);
        }
        $expected = state($auth);
        echo json_encode($expected, JSON_THROW_ON_ERROR) . "\n";
    } else {
        $expected = json_decode(stream_get_contents(STDIN, 4097), true, 32, JSON_THROW_ON_ERROR);
        check(is_array($expected) && state($auth) === array_diff_key($expected, ['set' => true]));
        check(!is_file('/run/news/last-refresh'));
        echo $argv[1] === 'reattached'
            ? "News source claim reuse passed; article and reading state preserved\n"
            : "News isolated paired recovery passed; polling remains disabled\n";
    }
} catch (Throwable $error) {
    fwrite(STDERR, "News recovery phase failed at fixture line " . ($error->getCode() ?: $error->getLine()) . "\n");
    exit(1);
}
