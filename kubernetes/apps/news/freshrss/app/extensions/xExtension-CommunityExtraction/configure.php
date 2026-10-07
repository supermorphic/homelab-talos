<?php
declare(strict_types=1);
if (PHP_SAPI!=='cli') { http_response_code(404); exit(1); }
$options=getopt('',['user:','feed-id:','mode:']);
if (!is_array($options)||!is_string($options['user']??null)||!preg_match('/^[A-Za-z][A-Za-z0-9_]{0,31}$/D',$options['user'])||!ctype_digit($options['feed-id']??'')||(int)$options['feed-id']<1||!in_array($options['mode']??'', ['rss','community'],true)) { fwrite(STDERR,"Use --user NAME --feed-id ID --mode rss|community\n"); exit(2); }
$service=fopen('/run/news/service.lock','c'); $refresh=fopen('/run/news/refresh.lock','c');
try {
    if ($service===false||$refresh===false||!flock($service,LOCK_SH|LOCK_NB)||is_file('/run/news/maintenance-request')||!flock($refresh,LOCK_EX|LOCK_NB)) { throw new RuntimeException(); }
    require '/var/www/FreshRSS/cli/_cli.php'; cliInitUser($options['user']);
    $dao=FreshRSS_Factory::createFeedDao(); $feed=$dao->searchById((int)$options['feed-id']);
    if ($feed===null) { throw new RuntimeException(); }
    if ($options['mode']==='community'&&($feed->httpAuth()!==''||!preg_match('~^https?://~i',$feed->url(false))||parse_url($feed->url(false),PHP_URL_USER)!==null||!empty($feed->attributeArray('curl_options')))) { throw new RuntimeException(); }
    $attributes=$feed->attributes(); $attributes['community_extraction_mode']=$options['mode'];
    $values=['attributes'=>$attributes];
    if ($options['mode']==='community') { $values['pathEntries']=''; }
    if (!$dao->updateFeed($feed->id(),$values)) { throw new RuntimeException(); }
    echo "Feed extraction mode saved\n";
} catch (Throwable $error) { fwrite(STDERR,"Feed configuration refused; check existing feed and maintenance state\n"); exit(1); }
