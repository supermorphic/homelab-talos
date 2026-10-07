<?php
declare(strict_types=1);
namespace CommunityExtraction;

final class Preservation {
    private \WeakMap $selected;
    public function __construct(private ?Client $client,private bool $requestsEnabled=false) { $this->selected=new \WeakMap(); }
    public function beforeInsert(\FreshRSS_Entry $entry): \FreshRSS_Entry {
        if (isset($this->selected[$entry])) { return $this->beforeUpdate($entry); }
        $hash=$entry->hash(); $rss=$entry->originalContent(); $body=$entry->content(false); $provenance=null;
        try {
            $prior=\FreshRSS_Factory::createEntryDao()->searchByGuid($entry->feedId(),$entry->guid());
            $old=$prior?->attributeArray('community_extraction');
            if ($prior!==null&&is_array($old)&&($old['feed_id']??null)===$entry->feedId()&&($old['guid']??null)===$entry->guid()&&($old['body_sha256']??'')===hash('sha256',$prior->content(false))) { $body=$prior->content(false); $provenance=$old; }
            $feed=$entry->feed(); $url=htmlspecialchars_decode($entry->link(),ENT_QUOTES);
            if ($this->requestsEnabled&&$this->client!==null&&$feed!==null&&$feed->attributeString('community_extraction_mode')==='community'&&$feed->httpAuth()===''&&empty($feed->attributeArray('curl_options'))&&preg_match('~^https?://~i',$feed->url(false))&&parse_url($feed->url(false),PHP_URL_USER)===null) {
                $validators=$provenance!==null&&($provenance['publisher_url']??'')===$url?($provenance['validators']??[]):[];
                $reply=$this->client->extract($url,$validators,10);
                if (($reply['decision']??'')==='accepted') {
                    $body=$reply['html'];
                    $provenance=['schema'=>1,'feed_id'=>$entry->feedId(),'guid'=>$entry->guid(),'publisher_url'=>$url,'final_url'=>$reply['final_url'],'input_hash'=>$hash,'release_id'=>$reply['release_id'],'rules'=>$reply['rules'],'validators'=>$reply['validators'],'body_sha256'=>hash('sha256',$body)];
                }
            }
        } catch (\Throwable $error) { /* Return RSS or prior validated body on every failure. */ }
        if ($provenance!==null) { $entry->_content($body); $entry->_attribute('community_extraction',$provenance); }
        $entry->_attribute('community_original_rss',$rss); $entry->_hash($hash);
        $this->selected[$entry]=['hash'=>$hash,'body'=>$entry->content(false),'provenance'=>$provenance,'rss'=>$rss];
        return $entry;
    }
    public function beforeUpdate(\FreshRSS_Entry $entry): \FreshRSS_Entry {
        $selected=$this->selected[$entry]??null;
        if ($selected===null) {
            $enabled=$this->requestsEnabled; $this->requestsEnabled=false;
            try { return $this->beforeInsert($entry); } finally { $this->requestsEnabled=$enabled; }
        }
        $entry->_content($selected['body']); $entry->_attribute('community_extraction',$selected['provenance']); $entry->_attribute('community_original_rss',$selected['rss']); $entry->_hash($selected['hash']); return $entry;
    }
}
