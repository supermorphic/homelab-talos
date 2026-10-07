<?php
declare(strict_types=1);
namespace NewsExtraction;

final class RuleFiles implements \Graby\SiteConfig\ConfigLinesProvider {
    public array $loaded=[];
    public function __construct(private string $directory) {}
    public function supportsHost(string $host): bool { return preg_match('/^[a-z0-9.-]+$/D',$host) && !str_contains($host,'..') && is_file($this->directory.'/'.$host.'.txt'); }
    public function getLinesForHost(string $host): array {
        if (!$this->supportsHost($host)) { return []; }
        $this->loaded[$host.'.txt']=hash_file('sha256',$this->directory.'/'.$host.'.txt');
        return file($this->directory.'/'.$host.'.txt',FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES);
    }
    public function reload(): void { $this->loaded=[]; }
}
final class RuleTrace extends \Psr\Log\AbstractLogger {
    public bool $matched=false;
    public bool $generic=false;
    public function log($level,string|\Stringable $message,array $context=[]): void {
        if (str_starts_with((string)$message,'XPath: found ')) { $this->matched=true; }
        if ((string)$message==='Detecting body') { $this->generic=true; }
        // No context, URL, headers or article text is retained or logged.
    }
}
final class SecondaryRequestDenied extends \RuntimeException implements \Psr\Http\Client\ClientExceptionInterface {}
final class RefusingClient implements \Psr\Http\Client\ClientInterface {
    public int $attempts=0;
    public function sendRequest(\Psr\Http\Message\RequestInterface $request): \Psr\Http\Message\ResponseInterface {
        $this->attempts++; throw new SecondaryRequestDenied('secondary_request_denied');
    }
}
final class Extractor {
    public function __construct(private string $rules,private array $limits) {}
    private static function reject(string $reason): array { return ['decision'=>'rejected','reason'=>$reason]; }
    public static function restricted(string $html): bool {
        $d=Sanitizer::document($html);
        $marked=function ($value) use (&$marked): bool {
            if (!is_array($value)) { return false; }
            if (array_key_exists('isAccessibleForFree',$value) && strtolower((string)$value['isAccessibleForFree'])==='false') { return true; }
            // JSON boolean false casts to empty string.
            if (($value['isAccessibleForFree']??null)===false) { return true; }
            foreach ($value as $v) { if ($marked($v)) { return true; } }
            return false;
        };
        foreach ($d->getElementsByTagName('script') as $script) {
            if (strtolower($script->getAttribute('type'))==='application/ld+json') {
                if ($marked(json_decode($script->textContent,true,32))) { return true; }
            }
        }
        $all=0; $gate=0;
        foreach ($d->getElementsByTagName('p') as $p) {
            $text=trim($p->textContent); $all+=mb_strlen($text);
            if (preg_match('/\b(subscribe|sign\s+in|log\s+in)\b.{0,60}\b(read|continue|access)\b/iu',$text)) { $gate+=mb_strlen($text); }
        }
        if ($all>0 && $gate>$all/2) { return true; }
        foreach (['h1','h2','h3'] as $tag) {
            foreach ($d->getElementsByTagName($tag) as $h) {
                if (preg_match('/^(?:(?:this|the) (?:post|article|story|content) is (?:available )?(?:only )?for (?:paid |premium |registered )?(?:members|subscribers)(?: only)?|sign up for (?:free )?access to (?:this|the) (?:post|article|story))\b/iu',trim($h->textContent))) { return true; }
            }
        }
        return false;
    }
    public function extract(string $url,string $html): array {
        if ($html==='' || strlen($html)>$this->limits['publisher_bytes'] || !str_contains($html,'<')) { return self::reject('malformed'); }
        if (self::restricted($html)) { return self::reject('restricted'); }
        $files=new RuleFiles($this->rules); $trace=new RuleTrace();
        $builder=new \Graby\SiteConfig\ConfigBuilder([], $trace,$files);
        $host=strtolower((string)parse_url($url,PHP_URL_HOST));
        $own=$builder->loadSiteConfig($host);
        $hostRules=array_values(array_filter(array_keys($files->loaded),fn($name)=>$name!=='global.txt'));
        if ($own===false || !$hostRules) { return self::reject('no_rule'); }
        $hostConfig=$builder->parseLines($files->getLinesForHost(substr($hostRules[0],0,-4)));
        if (!$hostConfig->body) { return self::reject('no_body_rule'); }
        $config=$builder->buildForHost($host);
        $config->body=$hostConfig->body;
        if ($config->requires_login) { return self::reject('restricted'); }
        if ($config->single_page_link || $config->next_page_link) { return self::reject('secondary_request_required'); }
        $config->autodetect_on_failure=false;
        $cacheHost=str_starts_with($host,'www.')?substr($host,4):$host;
        $builder->addToCache($cacheHost.'.merged',$config);
        $client=new RefusingClient();
        $graby=new \Graby\Graby(['singlepage'=>false,'multipage'=>false,'extractor'=>['fingerprints'=>[]]],$client,$builder);
        $graby->setLogger($trace); $graby->setContentAsPrefetched($html);
        try { $result=$graby->fetchContent($url); }
        catch (\Throwable $e) { return self::reject($client->attempts?'secondary_request_denied':'extraction_failed'); }
        if ($client->attempts) { return self::reject('secondary_request_denied'); }
        if ($trace->generic) { return self::reject('generic_rejected'); }
        if (!$trace->matched) { return self::reject('selector_miss'); }
        if (($result['status']??0)!==200 || empty($result['html']) || str_contains($result['html'],'[unable to retrieve full-text content]')) { return self::reject('extraction_failed'); }
        if (self::restricted($result['html'])) { return self::reject('restricted'); }
        $clean=Sanitizer::clean($result['html'],$url); $doc=Sanitizer::document($clean);
        $text=trim($doc->textContent); $structured=($doc->getElementsByTagName('img')->length>=2 && $doc->getElementsByTagName('figcaption')->length>0) || ($doc->getElementsByTagName('table')->length>0 && $doc->getElementsByTagName('tr')->length>=2);
        if ($text==='' || (mb_strlen($text)<200 && !$structured) || strlen($clean)>$this->limits['accepted_html_bytes']) { return self::reject('insufficient_content'); }
        return ['decision'=>'accepted','reason'=>'community_rule','html'=>$clean,'rules'=>$files->loaded];
    }
}
