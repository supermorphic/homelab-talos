<?php
declare(strict_types=1);
namespace CommunityExtraction;

final class Client {
    private string $release='';
    private bool $checked=false;
    private bool $ready=false;
    private float $used=0;
    private \Closure $clock;
    private float $deadline;
    private const REASONS=['community_rule','not_modified','destination_rejected','request_invalid','timeout','body_limit','header_limit','encoding_rejected','fetch_failed','rate_limited','http_denied','non_html','redirect_limit','origin_cooldown','malformed','restricted','no_rule','no_body_rule','secondary_request_required','secondary_request_denied','extraction_failed','generic_rejected','selector_miss','insufficient_content','reply_invalid','job_timeout','job_failed'];
    public function __construct(string $manifest='/opt/news-extraction/release.json',private ?\Closure $transport=null,?\Closure $clock=null) {
        $this->clock=$clock??fn()=>hrtime(true)/1e9;
        $this->deadline=($this->clock)()+max(0,min(300,(int)(getenv('NEWS_REFRESH_DEADLINE')?:time()+300)-time()));
        try {
            $m=json_decode(file_get_contents($manifest),true,32,JSON_THROW_ON_ERROR); $id=$m['id']; unset($m['id']);
            $sort=function (array $a) use (&$sort): array { if (!array_is_list($a)) { ksort($a,SORT_STRING); } foreach ($a as &$v) { if (is_array($v)) { $v=$sort($v); } } return $a; };
            if (!is_string($id)||!preg_match('/^[a-f0-9]{64}$/D',$id)||!hash_equals($id,hash('sha256',json_encode($sort($m),JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR)))||empty($m['extension_files'])) { return; }
            foreach ($m['extension_files'] as $name=>$hash) {
                if (!preg_match('/^[A-Za-z0-9.-]+$/D',$name)||!is_string($hash)||!is_file(__DIR__.'/'.$name)||!hash_equals($hash,hash_file('sha256',__DIR__.'/'.$name))) { return; }
            }
            $this->release=$id;
        } catch (\Throwable $error) { /* Invalid mounted release fails closed, preserving hooks. */ }
    }
    public function resetContext(): void { $this->checked=false; $this->ready=false; $this->used=0; }
    public function releaseId(): string { return $this->release; }
    private function request(string $method,string $path,array $body,float $seconds): array {
        if ($this->transport!==null) { return ($this->transport)($method,$path,$body,$seconds); }
        $ch=curl_init('http://news-graby.news.svc.cluster.local:8080'.$path); $reply='';
        curl_setopt_array($ch,[CURLOPT_PROXY=>'',CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT_MS=>min(1000,(int)($seconds*1000)),CURLOPT_TIMEOUT_MS=>max(1,(int)($seconds*1000)),CURLOPT_WRITEFUNCTION=>function ($ch,$data) use (&$reply): int { if (strlen($reply)+strlen($data)>8388608) { return 0; } $reply.=$data; return strlen($data); },CURLOPT_HTTPHEADER=>['Content-Type: application/json','Connection: close']]);
        if ($method==='POST') { curl_setopt_array($ch,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>json_encode($body,JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR)]); }
        try { if (curl_exec($ch)===false) { return [0,[]]; } return [(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE),json_decode($reply,true,32)]; } finally { curl_close($ch); }
    }
    private function circuit(bool $open=false,string $reason=''): bool {
        $handle=@fopen('/run/news/extraction-circuit.json','c+');
        if ($handle===false) { return true; }
        try {
            if (!flock($handle,LOCK_EX|LOCK_NB)) { return true; }
            $raw=stream_get_contents($handle,8193); $state=strlen($raw)>8192?[]:(json_decode($raw,true)?:[]);
            $until=(int)($state['open_until']??0); $blocked=$until>time()&&$until<=time()+60;
            if ($open) { $state['open_until']=time()+60; }
            if ($reason!=='') { $state[$reason]=min(2147483647,(int)($state[$reason]??0)+1); }
            if ($open||$reason!=='') { ftruncate($handle,0); rewind($handle); fwrite($handle,json_encode($state,JSON_THROW_ON_ERROR)); fflush($handle); }
            return $blocked;
        } finally { fclose($handle); }
    }
    public function extract(string $url,array $validators,float $remainingSeconds=10): array {
        $fallback=fn($reason)=>['decision'=>'rejected','reason'=>$reason];
        $remaining=min($remainingSeconds,60-$this->used,$this->deadline-($this->clock)());
        if ($this->release===''||$remaining<=0) { $this->circuit(false,'budget_exhausted'); return $fallback('budget_exhausted'); }
        if ($this->circuit()) { return $fallback('worker_unavailable'); }
        if (!$this->checked) {
            $this->checked=true; $start=($this->clock)();
            try { [$status,$reply]=$this->request('GET','/ready',[],min(1,$remaining)); $this->ready=$status===200&&is_array($reply)&&($reply['release_id']??'')===$this->release; } catch (\Throwable $error) { $this->ready=false; }
            $this->used+=max(0,($this->clock)()-$start);
            if (!$this->ready) { $this->circuit(true,'worker_unavailable'); }
        }
        if (!$this->ready) { return $fallback('worker_unavailable'); }
        $remaining=min(10,$remainingSeconds,60-$this->used,$this->deadline-($this->clock)());
        if ($remaining<=0) { return $fallback('budget_exhausted'); }
        $request=['url'=>$url,'expected_release'=>$this->release,'validators'=>$validators];
        if (strlen(json_encode($request))>8192) { return $fallback('reply_invalid'); }
        $start=($this->clock)();
        try { [$status,$reply]=$this->request('POST','/extract',$request,$remaining); } catch (\Throwable $error) { $status=0; $reply=[]; }
        $elapsed=max(0,($this->clock)()-$start); $this->used+=$elapsed;
        if ($status!==200) { $this->ready=false; $this->circuit(true,'worker_unavailable'); return $fallback('worker_unavailable'); }
        if ($elapsed>$remaining+0.01||!$this->valid($reply)) { return $fallback('reply_invalid'); }
        $this->circuit(false,$reply['decision']==='accepted'?'accepted':'fallback'); return $reply;
    }
    private function valid($r): bool {
        if (!is_array($r)||($r['release_id']??'')!==$this->release||!in_array($r['reason']??'',self::REASONS,true)||!in_array($r['decision']??'', ['accepted','rejected','not_modified'],true)) { return false; }
        if ($r['decision']!=='accepted') { return !isset($r['html']); }
        if ($r['reason']!=='community_rule'||!is_string($r['html']??null)||strlen($r['html'])<1||strlen($r['html'])>2097152||!mb_check_encoding($r['html'],'UTF-8')||!is_string($r['final_url']??null)||strlen($r['final_url'])>4096||!preg_match('~^https?://~D',$r['final_url'])||!is_array($r['rules']??null)||!$r['rules']||count($r['rules'])>32||!is_array($r['validators']??null)||strlen(json_encode($r['validators']))>2048) { return false; }
        foreach ($r['rules'] as $name=>$hash) { if (!preg_match('/^[a-z0-9.-]+\.txt$/D',(string)$name)||!is_string($hash)||!preg_match('/^[a-f0-9]{64}$/D',$hash)) { return false; } }
        foreach ($r['validators'] as $key=>$value) { if (!in_array($key,['etag','last_modified'],true)||!is_string($value)||strlen($value)>1024||preg_match('/[\x00-\x1f\x7f]/',$value)) { return false; } }
        if (preg_match('~<(?:script|iframe|object|embed|form|input|style|svg)\b|\son\w+\s*=|(?:javascript|data):~i',$r['html'])||!preg_match('~<(?:p|figure|table|ul|ol|h[1-6])\b~i',$r['html'])) { return false; }
        return true;
    }
}
