<?php
declare(strict_types=1);
try {
    $config = require getenv('DATA_PATH') . '/config.php';
    $db = new PDO('pgsql:host=' . $config['db']['host'] . ';dbname=freshrss;connect_timeout=3',
        $config['db']['user'], $config['db']['password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $user = $config['default_user'];
    if (!is_string($user) || !preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/D', $user)) {
        exit(1);
    }
    // A reachable database alone does not prove that account bootstrap finished.
    $tables = array_map(static fn(string $table): string => '"' . $user . '_' . $table . '"',
        ['category', 'feed', 'entry', 'entrytmp', 'tag', 'entrytag']);
    $db->query('SELECT 1 FROM ' . implode(', ', $tables) . ' LIMIT 0');
    $request = curl_init('http://127.0.0.1:8080/api/');
    curl_setopt_array($request, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 2, CURLOPT_TIMEOUT => 3]);
    $body = curl_exec($request);
    if (curl_getinfo($request, CURLINFO_RESPONSE_CODE) !== 200 || !is_string($body) || !str_contains($body, '/scripts/api.js')) {
        exit(1);
    }
} catch (Throwable $error) {
    exit(1);
}
