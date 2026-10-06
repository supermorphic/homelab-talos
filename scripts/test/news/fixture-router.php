<?php
// Synthetic feed transport failures. Served only on the isolated test network.
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
file_put_contents('/tmp/request-count', $path . "\n", FILE_APPEND);
switch ($path) {
    case '/redirect-private':
        header('Location: http://news-postgresql:5432/');
        exit;
    case '/redirect-loop':
        header('Location: /redirect-loop');
        exit;
    case '/oversized':
        header('Content-Type: application/rss+xml');
        // No Content-Length: prove the transfer limit applies to streamed responses.
        for ($i = 0; $i < 100; $i++) {
            echo str_repeat('x', 65536);
            flush();
        }
        exit;
    case '/slow':
        sleep(20);
        echo 'too late';
        exit;
    case '/malformed':
        header('Content-Type: application/rss+xml');
        echo '<rss><channel><item';
        exit;
    case '/rate-limit':
        http_response_code(429);
        header('Retry-After: 3600');
        exit;
}
return false;
