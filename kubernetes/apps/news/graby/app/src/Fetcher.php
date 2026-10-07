<?php
declare(strict_types=1);
namespace NewsExtraction;

final class Fetcher {
    public function __construct(private array $limits, private ?\Closure $resolver = null, private ?\Closure $transport = null) {}
    private static function now(): float { return hrtime(true) / 1e9; }
    private static function reject(string $reason, array $extra = []): array { return ['ok' => false, 'reason' => $reason] + $extra; }

    private static function inNetwork(string $address, string $network, int $bits): bool {
        $a = inet_pton($address); $n = inet_pton($network);
        if ($a === false || $n === false || strlen($a) !== strlen($n)) { return false; }
        $bytes = intdiv($bits, 8); $remaining = $bits % 8;
        return substr($a, 0, $bytes) === substr($n, 0, $bytes) &&
            ($remaining === 0 || (ord($a[$bytes]) >> (8-$remaining)) === (ord($n[$bytes]) >> (8-$remaining)));
    }

    private static function publicAddress(string $address): bool {
        if (filter_var($address, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
            foreach ([['0.0.0.0',8],['10.0.0.0',8],['100.64.0.0',10],['127.0.0.0',8],['169.254.0.0',16],['172.16.0.0',12],['192.0.0.0',24],['192.0.2.0',24],['192.88.99.0',24],['192.168.0.0',16],['198.18.0.0',15],['198.51.100.0',24],['203.0.113.0',24],['224.0.0.0',4],['240.0.0.0',4]] as [$net,$bits]) {
                if (self::inNetwork($address,$net,$bits)) { return false; }
            }
            return true;
        }
        // IPv6 global unicast only; exclude special and transition allocations.
        return self::inNetwork($address, '2000::',3) &&
            !self::inNetwork($address,'2001::',23) && !self::inNetwork($address,'2001:db8::',32) &&
            !self::inNetwork($address,'2002::',16) && !self::inNetwork($address,'3fff::',20);
    }

    private static function urlParts(string $url): ?array {
        if (strlen($url) > 4096 || preg_match('/[\x00-\x20\x7f\\\\]/', $url)) { return null; }
        $p = @parse_url($url);
        if (!is_array($p) || !in_array(strtolower($p['scheme'] ?? ''), ['http','https'], true) || isset($p['user']) || isset($p['pass'])) { return null; }
        $scheme = strtolower($p['scheme']);
        $host = strtolower($p['host'] ?? '');
        $bare = trim($host, '[]');
        $port = $p['port'] ?? ($scheme === 'https' ? 443 : 80);
        if ($port !== ($scheme === 'https' ? 443 : 80)) { return null; }
        if (filter_var($bare, FILTER_VALIDATE_IP)) {
            if (!self::publicAddress($bare)) { return null; }
        } elseif (!preg_match('/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/D', $host)) { return null; }
        return ['host'=>$bare, 'port'=>$port, 'scheme'=>$scheme, 'path'=>$p['path'] ?? '/', 'query'=>$p['query'] ?? null];
    }

    private function resolve(string $host, float $deadline): array {
        if (filter_var($host, FILTER_VALIDATE_IP)) { return [$host]; }
        $end = min($deadline, self::now() + $this->limits['dns_seconds']);
        if ($this->resolver !== null) {
            $result = ($this->resolver)($host, $end);
            if (self::now() >= $end) { throw new \RuntimeException('timeout'); }
            return $result;
        }
        $proc = proc_open(['/usr/bin/php8.4', '-d', 'memory_limit=32M', __DIR__.'/../scripts/resolve.php'], [0=>['pipe','r'],1=>['pipe','w'],2=>['file','/dev/null','w']], $pipes);
        if (!is_resource($proc)) { throw new \RuntimeException('dns_failed'); }
        fwrite($pipes[0], $host); fclose($pipes[0]); stream_set_blocking($pipes[1],false);
        $out = ''; $done = false;
        try {
            while (self::now() < $end) {
                $out .= stream_get_contents($pipes[1]);
                if (strlen($out) > 16384) { throw new \RuntimeException('dns_failed'); }
                if (!proc_get_status($proc)['running']) { $out .= stream_get_contents($pipes[1]); $done = true; break; }
                usleep(1000);
            }
            if (!$done) { throw new \RuntimeException('timeout'); }
        } finally {
            if (!$done) { proc_terminate($proc,9); }
            fclose($pipes[1]); proc_close($proc);
        }
        $result = json_decode($out,true,8,JSON_THROW_ON_ERROR);
        if (!is_array($result) || count($result)>64) { throw new \RuntimeException('dns_failed'); }
        return $result;
    }

    public function fetch(string $url, array $validators, float $deadline): array {
        $start = self::now(); $deadline = min($deadline, $start + $this->limits['fetch_seconds']);
        $headers = ['Accept'=>'text/html, application/xhtml+xml', 'Accept-Encoding'=>'gzip, deflate', 'User-Agent'=>'CommunityNewsExtraction/1.0'];
        foreach ($validators as $key=>$value) {
            if (!in_array($key,['etag','last_modified'],true) || !is_string($value) || strlen($value)>1024 || preg_match('/[\x00-\x1f\x7f]/',$value)) { return self::reject('request_invalid'); }
            $headers[$key==='etag' ? 'If-None-Match' : 'If-Modified-Since'] = $value;
        }
        $secure = (self::urlParts($url)['scheme'] ?? null) === 'https';
        for ($hop=0; $hop <= $this->limits['redirects']; $hop++) {
            if (self::now() >= $deadline) { return self::reject('timeout'); }
            $parts = self::urlParts($url);
            if ($parts === null || ($secure && $parts['scheme']!=='https')) { return self::reject('destination_rejected'); }
            $secure = $secure || $parts['scheme']==='https';
            $url = $parts['scheme'].'://'.(str_contains($parts['host'],':')?'['.$parts['host'].']':$parts['host']).$parts['path'].($parts['query']!==null?'?'.$parts['query']:'');
            try {
                $addresses = $this->resolve($parts['host'], $deadline);
                if (!$addresses || count($addresses)>64) { return self::reject('destination_rejected'); }
                foreach ($addresses as $address) { if (!is_string($address) || !self::publicAddress($address)) { return self::reject('destination_rejected'); } }
                if (self::now() >= $deadline) { return self::reject('timeout'); }
                $response = $this->transport !== null ? ($this->transport)($url,$addresses,$headers,$deadline) : $this->curl($url,$addresses,$headers,$deadline);
            } catch (\Throwable $e) {
                $reason = in_array($e->getMessage(),['timeout','body_limit','header_limit','encoding_rejected'],true) ? $e->getMessage() : 'fetch_failed';
                return self::reject($reason);
            }
            if (self::now() >= $deadline) { return self::reject('timeout'); }
            $status = $response['status']; $h = $response['headers'];
            if (in_array($status,[301,302,303,307,308],true)) {
                if ($hop === $this->limits['redirects'] || empty($h['location'])) { return self::reject('redirect_limit'); }
                $location = $h['location'];
                if (str_starts_with($location,'//')) { $location = $parts['scheme'].':'.$location; }
                elseif (!preg_match('/^[a-z][a-z0-9+.-]*:/i',$location)) {
                    $prefix = $parts['scheme'].'://'.parse_url($url,PHP_URL_HOST);
                    $location = $prefix . (str_starts_with($location,'/') ? $location : (str_starts_with($location,'?') || str_starts_with($location,'#') ? $parts['path'] : substr($parts['path'],0,strrpos($parts['path'],'/')+1)).$location);
                }
                $url = $location;
                // Validators belong to the original article request only.
                unset($headers['If-None-Match'], $headers['If-Modified-Since']);
                continue;
            }
            $outValidators = [];
            foreach (['etag'=>'etag','last-modified'=>'last_modified'] as $key=>$target) {
                if (isset($h[$key]) && strlen($h[$key])<=1024 && !preg_match('/[\x00-\x1f\x7f]/',$h[$key])) { $outValidators[$target]=$h[$key]; }
            }
            if ($status===304) { return ['ok'=>true,'status'=>304,'html'=>'','final_url'=>$url,'validators'=>$outValidators,'seconds'=>self::now()-$start]; }
            if ($status===429) {
                $retry = $h['retry-after'] ?? '';
                $seconds = ctype_digit($retry) ? (float)$retry : (($date=strtotime($retry)) !== false ? $date-time() : $this->limits['origin_cooldown_seconds']);
                return self::reject('rate_limited',['retry_after'=>(int)max(1,min($this->limits['max_retry_after_seconds'],$seconds)), 'final_url'=>$url]);
            }
            if ($status!==200) { return self::reject('http_denied'); }
            $media = strtolower(trim(explode(';',$h['content-type'] ?? '')[0]));
            if (!in_array($media,['text/html','application/xhtml+xml'],true)) { return self::reject('non_html'); }
            if (strlen($response['html']) > $this->limits['publisher_bytes']) { return self::reject('body_limit'); }
            return ['ok'=>true,'status'=>200,'html'=>$response['html'],'media_type'=>$media,'final_url'=>$url,'validators'=>$outValidators,'seconds'=>self::now()-$start];
        }
        return self::reject('redirect_limit');
    }

    private function curl(string $url, array $addresses, array $headers, float $deadline): array {
        $handle = curl_init($url); $body=''; $responseHeaders=[]; $headerBytes=0; $failure=null;
        $host = trim((string)parse_url($url,PHP_URL_HOST),'[]');
        $port = parse_url($url,PHP_URL_PORT) ?? (parse_url($url,PHP_URL_SCHEME)==='https'?443:80);
        $address = $addresses[0]; $pinned = str_contains($address,':')?'['.$address.']':$address;
        curl_setopt_array($handle,[
            CURLOPT_RESOLVE=>[$host.':'.$port.':'.$pinned], CURLOPT_PROXY=>'', CURLOPT_NOPROXY=>'*',
            CURLOPT_FOLLOWLOCATION=>false, CURLOPT_PROTOCOLS=>CURLPROTO_HTTP|CURLPROTO_HTTPS,
            CURLOPT_SSL_VERIFYPEER=>true, CURLOPT_SSL_VERIFYHOST=>2,
            CURLOPT_CONNECTTIMEOUT_MS=>(int)(1000*min($this->limits['connect_seconds'],max(0.001,$deadline-self::now()))),
            CURLOPT_TIMEOUT_MS=>(int)(1000*max(0.001,$deadline-self::now())), CURLOPT_NOSIGNAL=>true,
            CURLOPT_HTTP_CONTENT_DECODING=>false, CURLOPT_HTTPHEADER=>array_map(fn($k,$v)=>$k.': '.$v,array_keys($headers),$headers),
            CURLOPT_HEADERFUNCTION=>function ($ch,string $line) use (&$responseHeaders,&$headerBytes,&$failure): int {
                $headerBytes += strlen($line);
                if ($headerBytes>32768) { $failure='header_limit'; return 0; }
                if (str_starts_with($line,'HTTP/')) { $responseHeaders=[]; }
                elseif (str_contains($line,':')) { [$k,$v]=explode(':',$line,2); $responseHeaders[strtolower(trim($k))]=trim($v); }
                return strlen($line);
            },
            CURLOPT_WRITEFUNCTION=>function ($ch,string $chunk) use (&$body,&$failure): int {
                if (strlen($body)+strlen($chunk)>$this->limits['publisher_bytes']) { $failure='body_limit'; return 0; }
                $body.=$chunk; return strlen($chunk);
            },
        ]);
        try {
            $ok=curl_exec($handle); $status=(int)curl_getinfo($handle,CURLINFO_RESPONSE_CODE); $error=curl_errno($handle);
            if ($ok===false) { throw new \RuntimeException($failure ?? ($error===CURLE_OPERATION_TIMEDOUT?'timeout':'fetch_failed')); }
        } finally { curl_close($handle); }
        $encoding = strtolower($responseHeaders['content-encoding'] ?? 'identity');
        if ($encoding!=='identity' && $body!=='') {
            if (!in_array($encoding,['gzip','deflate'],true)) { throw new \RuntimeException('encoding_rejected'); }
            // Streaming file decoding bounds retained and transient decoded bytes.
            $file = tmpfile(); fwrite($file,$body); rewind($file);
            $filter = stream_filter_append($file,'zlib.inflate',STREAM_FILTER_READ,['window'=>$encoding==='gzip'?31:15]);
            if ($filter===false) { fclose($file); throw new \RuntimeException('encoding_rejected'); }
            $body='';
            try {
                while (!feof($file)) {
                    if (self::now()>=$deadline) { throw new \RuntimeException('timeout'); }
                    $chunk=fread($file,65536);
                    if ($chunk===false) { throw new \RuntimeException('encoding_rejected'); }
                    if (strlen($body)+strlen($chunk)>$this->limits['publisher_bytes']) { throw new \RuntimeException('body_limit'); }
                    $body.=$chunk;
                }
            } finally { fclose($file); }
        }
        return ['status'=>$status,'headers'=>$responseHeaders,'html'=>$body];
    }
}
