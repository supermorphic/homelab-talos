<?php
declare(strict_types=1);
check(is_file(APP . '/src/Fetcher.php'), 'bounded public fetcher is missing');
require APP . '/src/Fetcher.php';
// Resolve the IANA example domain at test time; never publish a live IP fixture.
$public = gethostbynamel('example.com');
check(is_array($public) && count($public) > 0, 'public test DNS unavailable');
$limits = json_decode(file_get_contents(APP . '/limits.json'), true, 32, JSON_THROW_ON_ERROR);
$calls = [];
$reply = ['status' => 200, 'headers' => ['content-type' => 'text/html'], 'html' => '<html><body>synthetic</body></html>'];
$transport = function ($url, $addresses, $headers, $deadline) use (&$calls, &$reply): array {
    $calls[] = [$url, $addresses, $headers, $deadline]; return $reply;
};
foreach (['127.0.0.1', '10.0.0.1', '169.254.169.254', '100.64.0.1', '192.0.2.1', '198.51.100.1', '203.0.113.1', '0.0.0.0', '224.0.0.1', '::1', 'fe80::1', 'fc00::1', '2001:db8::1', '::ffff:127.0.0.1'] as $address) {
    $fetcher = new NewsExtraction\Fetcher($limits, fn() => [$address], $transport);
    $result = $fetcher->fetch('https://synthetic.example/article', [], hrtime(true)/1e9 + 5);
    check($result['reason'] === 'destination_rejected', 'non-public destination accepted');
}
check(count($calls) === 0, 'unsafe destination reached transport');
$mixed = new NewsExtraction\Fetcher($limits, fn() => [...$public, '10.0.0.1'], $transport);
check($mixed->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'destination_rejected', 'mixed DNS set accepted');
foreach (['http://2130706433/a', 'http://0177.0.0.1/a', 'http://0x7f000001/a', 'https://user:password@example.com/', 'ftp://example.com/', 'https://example.com:8443/', "https://example.com/\r\nx", 'http://[::ffff:127.0.0.1]/'] as $url) {
    $fetcher = new NewsExtraction\Fetcher($limits, fn() => $public, $transport);
    check(!$fetcher->fetch($url, [], hrtime(true)/1e9 + 5)['ok'], 'unsafe URL accepted');
}
check(count($calls) === 0, 'unsafe URL reached transport');
$fetcher = new NewsExtraction\Fetcher($limits, fn() => $public, $transport);
$result = $fetcher->fetch('https://synthetic.example/a', ['etag' => '"known"'], hrtime(true)/1e9 + 5);
check($result['ok'] && $result['html'] === '<html><body>synthetic</body></html>', 'public HTML lost');
check($calls[0][1] === $public && $calls[0][2]['If-None-Match'] === '"known"', 'approved addresses or validator lost');
$fetcher->fetch('HTTPS://SYNTHETIC.EXAMPLE/a', [], hrtime(true)/1e9 + 5);
check($calls[count($calls)-1][0] === 'https://synthetic.example/a', 'URL spelling differed between resolution and connection');
$reply = ['status' => 302, 'headers' => ['location' => 'http://synthetic.example/insecure'], 'html' => ''];
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'destination_rejected', 'HTTPS downgrade accepted');
$reply['headers']['location'] = 'https://private.example/a';
$fetcher = new NewsExtraction\Fetcher($limits, fn($host) => $host === 'private.example' ? ['10.0.0.1'] : $public, $transport);
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'destination_rejected', 'private redirect accepted');
$reply['headers']['location'] = '/loop';
$fetcher = new NewsExtraction\Fetcher($limits, fn() => $public, $transport);
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'redirect_limit', 'redirect loop escaped limit');
$step=0;
$upgraded=new NewsExtraction\Fetcher($limits, fn()=>$public, function () use (&$step) { return ['status'=>302,'headers'=>['location'=>++$step===1?'https://synthetic.example/a':'http://synthetic.example/a'],'html'=>'']; });
check($upgraded->fetch('http://synthetic.example/a',[],hrtime(true)/1e9+5)['reason']==='destination_rejected','redirect downgraded after HTTPS upgrade');
$step=0;
$queryRedirect=new NewsExtraction\Fetcher($limits,fn()=>$public,function($url) use (&$step) { return ++$step===1?['status'=>302,'headers'=>['location'=>'?edition=2'],'html'=>'']:['status'=>200,'headers'=>['content-type'=>'text/html'],'html'=>$url]; });
check($queryRedirect->fetch('https://synthetic.example/a',[],hrtime(true)/1e9+5)['html']==='https://synthetic.example/a?edition=2','query-only redirect changed article path');
$reply = ['status' => 304, 'headers' => [], 'html' => 'untrusted body'];
$result = $fetcher->fetch('https://synthetic.example/a', ['etag' => '"known"'], hrtime(true)/1e9 + 5);
check($result['ok'] && $result['status'] === 304 && $result['html'] === '', '304 supplied body');
$reply = ['status' => 429, 'headers' => ['retry-after' => '999999'], 'html' => ''];
$result = $fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5);
check($result['reason'] === 'rate_limited' && $result['retry_after'] === 86400, 'rate limit not bounded');
$reply = ['status' => 403, 'headers' => ['content-type' => 'text/html'], 'html' => 'denied'];
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'http_denied', 'denial accepted');
$reply = ['status' => 200, 'headers' => ['content-type' => 'application/json'], 'html' => '{}'];
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'non_html', 'non-HTML accepted');
$reply = ['status' => 200, 'headers' => ['content-type' => 'text/html'], 'html' => str_repeat('x', 5242880)];
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['ok'], 'exact body size rejected');
$reply['html'] .= 'x';
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'body_limit', 'oversized body retained');
check($fetcher->fetch('https://synthetic.example/a', [], hrtime(true)/1e9)['reason'] === 'timeout', 'expired deadline fetched');
check($fetcher->fetch('https://synthetic.example/a', ['etag' => "a\r\nb"], hrtime(true)/1e9 + 5)['reason'] === 'request_invalid', 'validator injected headers');
echo "deterministic fetch guards passed\n";
$slow = new NewsExtraction\Fetcher($limits, function () use ($public) { usleep(1100000); return $public; }, $transport);
check($slow->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'timeout', 'DNS deadline reset by resolver');
$rebindCount = 0;
$reply = ['status'=>302, 'headers'=>['location'=>'/next'], 'html'=>''];
$rebind = new NewsExtraction\Fetcher($limits, function () use (&$rebindCount,$public) { return ++$rebindCount === 1 ? $public : ['127.0.0.1']; }, $transport);
$before = count($calls);
check($rebind->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 5)['reason'] === 'destination_rejected' && count($calls) === $before+1, 'redirect rebinding reached second connection');
$reply = ['status'=>302, 'headers'=>['location'=>'/next'], 'html'=>''];
$remaining = [];
$timed = new NewsExtraction\Fetcher($limits, fn()=>$public, function ($url,$addresses,$headers,$deadline) use (&$remaining) {
    $remaining[] = $deadline; usleep(20000); return ['status'=>302,'headers'=>['location'=>'/next'],'html'=>''];
});
check($timed->fetch('https://synthetic.example/a', [], hrtime(true)/1e9 + 0.05)['reason'] === 'timeout', 'redirect reset aggregate deadline');
check(count(array_unique($remaining)) === 1, 'hops used different deadlines');
require __DIR__.'/extraction-wire-tests.php';
