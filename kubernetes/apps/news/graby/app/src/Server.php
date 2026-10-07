<?php
declare(strict_types=1);
namespace NewsExtraction;

use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Message\ResponseInterface;
use React\Http\Message\Response;
use React\Promise\Promise;
use React\Promise\PromiseInterface;
use React\EventLoop\Loop;
use React\Stream\ReadableStreamInterface;

final class Server {
    private bool $reserved=false;
    private bool $stopping=false;
    private ?\React\ChildProcess\Process $child=null;
    private array $connections=[];
    private array $origins=[];
    private array $counts=[];
    private float $seconds=0;
    private int $requests=0;
    private ?\React\Socket\SocketServer $socket=null;
    private ?\React\Socket\SocketServer $metricsSocket=null;
    private const REASONS=['community_rule','not_modified','destination_rejected','request_invalid','timeout','body_limit','header_limit','encoding_rejected','fetch_failed','rate_limited','http_denied','non_html','redirect_limit','origin_cooldown','malformed','restricted','no_rule','no_body_rule','secondary_request_required','secondary_request_denied','extraction_failed','generic_rejected','selector_miss','insufficient_content','reply_invalid','job_timeout','job_failed'];
    public function __construct(private Release $release,private array $limits,private ?\Closure $jobFactory=null) {}
    private static function now(): float { return hrtime(true)/1e9; }
    private static function response(int $status,array $reply): ResponseInterface {
        return new Response($status,['Content-Type'=>'application/json','Connection'=>'close'],json_encode($reply,JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR));
    }
    private function rejection(string $reason,int $status=200): ResponseInterface { return self::response($status,['decision'=>'rejected','reason'=>$reason,'release_id'=>$this->release->id()]); }
    private static function origin(string $url): string { $p=@parse_url($url); return strtolower(($p['scheme']??'').':'.($p['host']??'')); }
    private function kill(): void {
        if ($this->child===null) { return; }
        $pid=$this->child->getPid();
        if ($pid!==null && posix_getpgid($pid)===$pid) { posix_kill(-$pid,SIGKILL); }
        $this->child->terminate(SIGKILL);
    }
    private function reapGroup(int $group, \Closure $done): void {
        // React has reaped the leader. Kill survivors and retain only this
        // completed group until all adopted descendants have exited.
        posix_kill(-$group, SIGKILL);
        $timer=null;
        $reap=function () use ($group,$done,&$timer): bool {
            do { $result=pcntl_waitpid(-$group,$status,WNOHANG); } while ($result>0);
            if ($result===-1 && pcntl_get_last_error()===PCNTL_ECHILD) { if ($timer!==null) { Loop::cancelTimer($timer); } $done(); return true; }
            return false;
        };
        if (!$reap()) { $timer=Loop::addPeriodicTimer(0.01,$reap); }
    }
    public function handle(ServerRequestInterface $request): ResponseInterface|PromiseInterface {
        if ($request->getUri()->getPath()==='/ready' && $request->getMethod()==='GET') {
            return self::response($this->stopping?503:200,['release_id'=>$this->release->id()]);
        }
        if ($request->getUri()->getPath()!=='/extract' || $request->getMethod()!=='POST') { return $this->rejection('request_invalid',404); }
        if ($this->stopping) { return $this->rejection('job_failed',503); }
        if ($this->reserved) { return $this->rejection('job_failed',429); }
        $this->reserved=true;
        $params=$request->getServerParams(); $key=($params['REMOTE_ADDR']??'').':'.($params['REMOTE_PORT']??'');
        $end=$this->connections[$key]['deadline']??self::now()+$this->limits['client_seconds']-0.5;
        $body=$request->getBody();
        if (!$body instanceof ReadableStreamInterface) { return $this->admit((string)$body,$end); }
        $pending=null; $buffer=''; $timer=null; $complete=false;
        return new Promise(function ($resolve) use ($body,$end,&$pending,&$buffer,&$timer,&$complete) {
            $finish=function (ResponseInterface $response) use ($resolve,$body,&$complete,&$timer): void {
                if ($complete) { return; } $complete=true;
                if ($timer!==null) { Loop::cancelTimer($timer); }
                $resolve($response); $body->close();
            };
            $timer=Loop::addTimer(min($this->limits['body_seconds'],max(0.001,$end-self::now())),function () use ($finish) { $this->reserved=false; $finish($this->rejection('timeout',408)); });
            $body->on('data',function ($chunk) use (&$buffer,$finish): void {
                if (strlen($buffer)+strlen($chunk)>$this->limits['request_bytes']) { $this->reserved=false; $finish($this->rejection('request_invalid',413)); return; }
                $buffer.=$chunk;
            });
            $body->on('end',function () use (&$complete,&$timer,&$pending,&$buffer,$end,$resolve): void {
                if ($complete) { return; } $complete=true; Loop::cancelTimer($timer);
                $pending=$this->admit($buffer,$end);
                if ($pending instanceof PromiseInterface) { $pending->then($resolve); } else { $resolve($pending); }
            });
            $body->on('error',function () use ($finish,&$complete): void { if (!$complete) { $this->reserved=false; $finish($this->rejection('request_invalid',400)); } });
        },function () use (&$pending,&$timer,$body): void {
            if ($timer!==null) { Loop::cancelTimer($timer); }
            if ($pending instanceof PromiseInterface) { $pending->cancel(); } else { $this->reserved=false; }
            $body->close();
        });
    }
    private function admit(string $raw,float $end): ResponseInterface|PromiseInterface {
        if (strlen($raw)>$this->limits['request_bytes']) { $this->reserved=false; return $this->rejection('request_invalid',413); }
        $request=json_decode($raw,true,16);
        if (!is_array($request) || array_diff(array_keys($request),['url','expected_release','validators']) || !is_string($request['url']??null) || strlen($request['url'])>4096 || !is_array($request['validators']??[])) { $this->reserved=false; return $this->rejection('request_invalid',400); }
        if (($request['expected_release']??'')!==$this->release->id()) { $this->reserved=false; return $this->rejection('reply_invalid',503); }
        $origin=self::origin($request['url']);
        $this->origins=array_filter($this->origins,fn($until)=>$until>self::now());
        if (($this->origins[$origin]??0)>self::now()) { $this->reserved=false; return $this->rejection('origin_cooldown'); }
        $start=self::now(); $timer=null; $settled=false;
        return new Promise(function ($resolve) use ($raw,$end,$origin,$start,&$timer,&$settled): void {
            $out=''; $errBytes=0; $forced=null;
            $finish=function (array $reply) use ($resolve,$start,&$settled): void {
                if ($settled) { return; } $settled=true;
                $this->seconds+=self::now()-$start; $this->requests++;
                $reason=$reply['reason']??'reply_invalid'; $this->counts[$reason]=($this->counts[$reason]??0)+1;
                $resolve(self::response(200,$reply));
            };
            try {
                $child=$this->jobFactory!==null?($this->jobFactory)():new \React\ChildProcess\Process('exec /usr/bin/php8.4 -d extension=tidy -d memory_limit=512M '.escapeshellarg(__DIR__.'/../scripts/job.php'));
                $this->child=$child;
                $child->start(Loop::get(),0.02);
                $pid=$child->getPid();
                $timer=Loop::addTimer(max(0.001,min($this->limits['job_seconds'],$end-self::now())),function () use (&$forced): void { $forced='job_timeout'; $this->kill(); });
                $child->stdout->on('data',function ($data) use (&$out,&$forced): void {
                    if (strlen($out)+strlen($data)>$this->limits['reply_bytes']) { $forced='reply_invalid'; $this->kill(); return; }
                    $out.=$data;
                });
                $child->stderr->on('data',function ($data) use (&$errBytes,&$forced): void { $errBytes+=strlen($data); if ($errBytes>8192) { $forced='job_failed'; $this->kill(); } });
                $child->on('exit',function ($code) use (&$out,&$forced,&$timer,$origin,$finish,$pid): void {
                    Loop::cancelTimer($timer); $this->child=null;
                    $complete=function () use (&$out,$forced,$code,$origin,$finish): void {
                        $this->reserved=false;
                        $reply=json_decode($out,true,32);
                        if ($forced!==null || $code!==0 || !$this->validReply($reply)) { $reply=['decision'=>'rejected','reason'=>$forced??'reply_invalid','release_id'=>$this->release->id()]; }
                        if (($reply['reason']??'')==='rate_limited') {
                            if (count($this->origins)>=256) { array_shift($this->origins); }
                            $this->origins[$origin]=self::now()+max(1,min($this->limits['max_retry_after_seconds'],(int)($reply['retry_after']??$this->limits['origin_cooldown_seconds'])));
                            if (isset($reply['final_url'])) { $this->origins[self::origin($reply['final_url'])]=$this->origins[$origin]; }
                            while (count($this->origins)>256) { array_shift($this->origins); }
                            $temporary='/run/news-graby/origins-'.bin2hex(random_bytes(4));
                            file_put_contents($temporary,json_encode($this->origins,JSON_THROW_ON_ERROR),LOCK_EX); chmod($temporary,0600); rename($temporary,'/run/news-graby/origins.json');
                        }
                        $finish($reply);
                        if ($this->stopping) { Loop::stop(); }
                    };
                    if ($pid!==null) { $this->reapGroup($pid,$complete); } else { $complete(); }
                });
                $child->stdin->end($raw);
            } catch (\Throwable $e) {
                $this->kill(); $this->child=null; $this->reserved=false;
                $finish(['decision'=>'rejected','reason'=>'job_failed','release_id'=>$this->release->id()]);
            }
        },function () use (&$settled): void { $settled=true; $this->kill(); });
    }
    private function validReply($reply): bool {
        if (!is_array($reply) || ($reply['release_id']??'')!==$this->release->id() || !in_array($reply['decision']??'', ['accepted','rejected','not_modified'],true) || !in_array($reply['reason']??'',self::REASONS,true)) { return false; }
        if ($reply['decision']!=='accepted') { return !isset($reply['html']); }
        if (!is_string($reply['html']??null) || $reply['html']==='' || strlen($reply['html'])>$this->limits['accepted_html_bytes'] || !is_string($reply['final_url']??null) || !is_array($reply['rules']??null) || !$reply['rules'] || count($reply['rules'])>32 || !is_array($reply['validators']??null)) { return false; }
        foreach ($reply['rules'] as $name=>$hash) { if (!is_string($name) || !preg_match('/^[a-z0-9.-]+\.txt$/D',$name) || !is_string($hash) || !preg_match('/^[a-f0-9]{64}$/D',$hash)) { return false; } }
        return true;
    }
    public function listen(string $address='0.0.0.0:8080',string $metrics='0.0.0.0:9090'): void {
        $this->socket=new \React\Socket\SocketServer($address);
        $this->socket->on('connection',function ($connection): void {
            if (count($this->connections)>=$this->limits['connections']) { $connection->close(); return; }
            $p=parse_url($connection->getRemoteAddress()); $key=$p['host'].':'.$p['port'];
            $header=''; $timer=Loop::addTimer($this->limits['header_seconds'],fn()=>$connection->close());
            $deadline=self::now()+$this->limits['client_seconds']-0.5;
            $total=Loop::addTimer($this->limits['client_seconds'],fn()=>$connection->close());
            $this->connections[$key]=['deadline'=>$deadline];
            $reader=null; $reader=function ($data) use (&$reader,&$header,$connection,$timer): void {
                $header.=$data; $end=strpos($header,"\r\n\r\n");
                if ($end!==false) { Loop::cancelTimer($timer); $connection->removeListener('data',$reader); }
                elseif (strlen($header)>32768) { $connection->close(); }
            };
            $connection->on('data',$reader);
            $connection->on('close',function () use ($key,$timer,$total): void { unset($this->connections[$key]); Loop::cancelTimer($timer); Loop::cancelTimer($total); });
        });
        $http=new \React\Http\HttpServer(new \React\Http\Middleware\StreamingRequestMiddleware(),[$this,'handle']); $http->listen($this->socket);
        $this->metricsSocket=new \React\Socket\SocketServer($metrics);
        $this->metricsSocket->on('connection',function ($connection): void {
            $timer=Loop::addTimer($this->limits['header_seconds'],fn()=>$connection->close());
            $connection->on('close',fn()=>Loop::cancelTimer($timer));
        });
        $monitor=new \React\Http\HttpServer(new \React\Http\Middleware\StreamingRequestMiddleware(),fn()=>new Response(200,['Content-Type'=>'text/plain','Connection'=>'close'],$this->metrics())); $monitor->listen($this->metricsSocket);
        Loop::addSignal(SIGTERM,fn()=>$this->shutdown()); Loop::addSignal(SIGINT,fn()=>$this->shutdown());
    }
    private function metrics(): string {
        $out="news_extraction_ready 1\nnews_extraction_active_jobs ".($this->child!==null?1:0)."\nnews_extraction_request_seconds_count ".$this->requests."\nnews_extraction_request_seconds_sum ".$this->seconds."\n";
        foreach (self::REASONS as $reason) { $out.='news_extraction_decisions_total{reason="'.$reason.'"} '.($this->counts[$reason]??0)."\n"; }
        return $out;
    }
    private function shutdown(): void {
        $this->stopping=true; $this->socket?->close(); $this->metricsSocket?->close(); $this->kill();
        if ($this->child===null && !$this->reserved) { Loop::stop(); }
        else { Loop::addTimer(0.3,fn()=>Loop::stop()); }
    }
}
