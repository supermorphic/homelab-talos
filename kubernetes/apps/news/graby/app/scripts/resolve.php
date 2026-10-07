<?php
declare(strict_types=1);
// Isolated so a stalled system DNS resolver can be killed by the caller.
ini_set('display_errors', '0');
$host = trim(stream_get_contents(STDIN, 256));
$records = @dns_get_record($host, DNS_A | DNS_AAAA);
$addresses = [];
foreach ($records ?: [] as $record) {
    if (isset($record['ip'])) { $addresses[] = $record['ip']; }
    if (isset($record['ipv6'])) { $addresses[] = $record['ipv6']; }
}
if (count($addresses) > 64) { exit(1); }
echo json_encode(array_values(array_unique($addresses)), JSON_THROW_ON_ERROR);
