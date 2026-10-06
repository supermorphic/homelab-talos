<?php
declare(strict_types=1);

// Use upstream CLI entry points without shell evaluation or credential output.
function setting(string $name): string {
    $value = getenv($name);
    if (!is_string($value) || $value === '') {
        throw new RuntimeException('Missing runtime setting: ' . $name);
    }
    return $value;
}

function cli(string $script, array $args = []): void {
    $process = proc_open(array_merge(['php', '/var/www/FreshRSS/cli/' . $script], $args),
        [0 => ['file', '/dev/null', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
    if (!is_resource($process) || proc_close($process) !== 0) {
        throw new RuntimeException('FreshRSS initialization failed at ' . $script);
    }
}

function saveConfig(string $path, array $config): void {
    $temporary = $path . '.new';
    if (file_put_contents($temporary, "<?php\nreturn " . var_export($config, true) . ";\n") === false ||
        !rename($temporary, $path)) {
        throw new RuntimeException('Unable to persist FreshRSS configuration');
    }
}

try {
    umask(0077);
    $data = setting('DATA_PATH');
    $user = setting('NEWS_OPERATOR_NAME');
    if (!preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/D', $user)) {
        throw new RuntimeException('Invalid operator username');
    }
    $complete = $data . '/news-bootstrap.complete';
    if (is_file($complete) && trim(file_get_contents($complete)) !== $user) {
        throw new RuntimeException('Operator rename requires an explicit account migration');
    }
    $dbPassword = setting('NEWS_DB_PASSWORD');
    $loginPassword = setting('NEWS_OPERATOR_PASSWORD');
    $apiPassword = setting('NEWS_API_PASSWORD');
    if ($loginPassword === $apiPassword) {
        throw new RuntimeException('Web and API passwords must be separate');
    }
    $base = setting('NEWS_BASE_URL');
    if (!filter_var($base, FILTER_VALIDATE_URL) || !in_array(parse_url($base, PHP_URL_SCHEME), ['http', 'https'], true)) {
        throw new RuntimeException('Invalid base URL');
    }
    cli('prepare.php');
    $policy = [
        'environment' => 'silent', 'base_url' => $base, 'default_user' => $user,
        'auth_type' => 'form', 'api_enabled' => true, 'allow_anonymous' => false,
        'allow_anonymous_refresh' => false, 'allow_robots' => false, 'disable_update' => true,
        'pubsubhubbub_enabled' => false, 'simplepie_syslog_enabled' => false,
        'nb_parallel_refresh' => 1, 'internal_host_allowlist' => [],
        'limits' => ['timeout' => 15, 'max_feeds' => 100, 'max_registrations' => 1,
                     'cache_duration_min' => 300, 'retry_after_default' => 1800],
        'curl_options' => [CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_TIMEOUT => 15,
                           CURLOPT_MAXREDIRS => 4, CURLOPT_MAXFILESIZE_LARGE => 5242880],
    ];
    saveConfig($data . '/config.custom.php', $policy);
    saveConfig($data . '/config-user.custom.php', [
        'archiving' => ['keep_unreads' => true, 'keep_favourites' => true],
        'mark_updated_article_unread' => false, 'ttl_default' => 3600,
    ]);
    if (!is_file($data . '/applied_migrations.txt')) {
        cli('do-install.php', ['--default-user=' . $user, '--db-type=pgsql',
            '--db-host=' . setting('NEWS_DB_HOST'), '--db-user=freshrss',
            '--db-password=' . $dbPassword, '--db-base=freshrss', '--db-prefix=']);
    }
    $config = require $data . '/config.php';
    // Replace policy arrays as units: recursive merge would retain removed host exceptions.
    $config = array_replace($config, $policy);
    $config['db'] = ['type' => 'pgsql', 'host' => setting('NEWS_DB_HOST'), 'user' => 'freshrss',
                     'password' => $dbPassword, 'base' => 'freshrss', 'prefix' => ''];
    saveConfig($data . '/config.php', $config);
    $home = $data . '/users/' . $user;
    if (!is_file($complete)) {
        if (!is_file($home . '/config.php')) {
            // Upstream can stop after mkdir but before config creation. Remove
            // only an empty directory; preserve unexpected files for recovery.
            if (is_dir($home) && !rmdir($home)) {
                throw new RuntimeException('Incomplete account directory needs recovery');
            }
            cli('create-user.php', ['--user=' . $user, '--password=' . $loginPassword,
                '--api-password=' . $apiPassword, '--no-default-feeds']);
        }
        // User config precedes tables upstream. Its idempotent schema installer
        // completes an interrupted initial create without replacing saved rows.
        require '/var/www/FreshRSS/cli/_cli.php';
        if (!FreshRSS_Factory::createUserDao($user)->createUser()) {
            throw new RuntimeException('Incomplete account schema');
        }
        cli('update-user.php', ['--user=' . $user, '--password=' . $loginPassword,
            '--api-password=' . $apiPassword]);
        if (file_put_contents($complete . '.new', $user . "\n") === false ||
            !rename($complete . '.new', $complete)) {
            throw new RuntimeException('Unable to record completed bootstrap');
        }
    } elseif (!is_file($home . '/config.php')) {
        throw new RuntimeException('Completed account configuration needs recovery');
    }
    echo "FreshRSS bootstrap ready\n";
} catch (Throwable $error) {
    // Do not emit exception messages from the database or parser with credentials.
    fwrite(STDERR, "FreshRSS bootstrap failed; check runtime inputs and database readiness\n");
    exit(1);
}
