<?php
declare(strict_types=1);
header('Content-Type: text/plain; version=0.0.4; charset=utf-8');
header('Cache-Control: no-store');
// Fixed names and aggregate values only: never expose account/feed/article identity.
function metric(string $name, int $value, string $help, string $type = 'gauge'): void {
    echo "# HELP $name $help\n# TYPE $name $type\n$name $value\n";
}
function timestamp(string $path): int {
    $value = @file_get_contents($path);
    $value = is_string($value) ? trim($value) : '';
    return ctype_digit($value) && (int)$value <= time() ? (int)$value : 0;
}
metric('news_refresh_last_completed_timestamp_seconds', timestamp('/run/news/last-refresh'),
    'Last completed scheduler invocation; does not imply successful feed fetching.');
metric('news_backup_last_success_timestamp_seconds', timestamp('/run/news/last-backup'),
    'Capture time of the newest validated local paired set; not off-cluster confirmation.');
metric('news_extraction_requests_enabled', getenv('NEWS_EXTRACTION_REQUESTS_ENABLED') === 'true' ? 1 : 0,
    'Whether new article extraction requests are enabled; preservation remains enabled.');
$circuit = @file_get_contents('/run/news/extraction-circuit.json', false, null, 0, 8193);
$counters = is_string($circuit) && strlen($circuit) <= 8192 ? json_decode($circuit, true) : [];
foreach (['accepted', 'fallback', 'budget_exhausted', 'worker_unavailable'] as $kind) {
    $value = $counters[$kind] ?? 0;
    metric('news_extraction_' . $kind . '_total', is_int($value) && $value >= 0 ? min(2147483647, $value) : 0,
        'Aggregate article extraction ' . $kind . ' observations in the current temporary runtime.', 'counter');
}
try {
    $config = require getenv('DATA_PATH') . '/config.php';
    $user = $config['default_user'];
    if (!is_string($user) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/D', $user)) {
        throw new RuntimeException();
    }
    $userConfig = require getenv('DATA_PATH') . '/users/' . $user . '/config.php';
    $defaultTtl = max(1, (int)($userConfig['ttl_default'] ?? 3600));
    $db = new PDO('pgsql:host=' . $config['db']['host'] . ';dbname=freshrss;connect_timeout=3',
        $config['db']['user'], $config['db']['password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec('SET statement_timeout = 1500');
    $db->exec('BEGIN READ ONLY');
    $query = $db->prepare('SELECT count(*) AS active,
        count(*) FILTER (WHERE error <> 0) AS failed,
        COALESCE(min("lastUpdate"), 0) AS oldest,
        count(*) FILTER (WHERE "lastUpdate" <= 0 OR
            :now - "lastUpdate" > GREATEST(7200, 2 * CASE WHEN ttl = 0 THEN :ttl ELSE ttl END)) AS stale
        FROM "' . $user . '_feed" WHERE ttl >= 0');
    $query->execute(['now' => time(), 'ttl' => $defaultTtl]);
    $row = $query->fetch(PDO::FETCH_ASSOC);
    $db->exec('COMMIT');
    metric('news_database_up', 1, 'The application database and feed table are readable.');
    metric('news_feeds_active', (int)$row['active'], 'Subscribed feeds excluding muted feeds.');
    metric('news_feeds_failed', (int)$row['failed'], 'Active feeds whose latest fetch failed.');
    metric('news_feeds_stale', (int)$row['stale'], 'Active feeds overdue by two polling intervals or two hours, whichever is longer.');
    metric('news_feed_oldest_success_timestamp_seconds', (int)$row['oldest'], 'Oldest successful active-feed refresh; zero if no success.');
} catch (Throwable $error) {
    // Leave feed observations absent on failure rather than reporting healthy zeroes.
    metric('news_database_up', 0, 'The application database and feed table are readable.');
}
