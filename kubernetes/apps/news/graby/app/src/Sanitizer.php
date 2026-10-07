<?php
declare(strict_types=1);
namespace NewsExtraction;

final class Sanitizer {
    private const ELEMENTS = ['a','abbr','b','blockquote','br','caption','cite','code','col','colgroup','dd','del','div','dl','dt','em','figcaption','figure','h1','h2','h3','h4','h5','h6','hr','i','img','li','ol','p','pre','q','s','small','span','strong','sub','sup','table','tbody','td','tfoot','th','thead','tr','u','ul'];
    public static function document(string $html): \DOMDocument {
        $d=new \DOMDocument(); $old=libxml_use_internal_errors(true);
        try { $d->loadHTML('<?xml encoding="UTF-8">'.$html,LIBXML_NONET|LIBXML_NOERROR|LIBXML_NOWARNING); }
        finally { libxml_clear_errors(); libxml_use_internal_errors($old); }
        return $d;
    }
    private static function url(string $value,string $base,bool $link): ?string {
        $value=trim(html_entity_decode($value,ENT_QUOTES|ENT_HTML5,'UTF-8'));
        if ($value==='' || preg_match('/[\x00-\x20\x7f\\\\]/',$value)) { return null; }
        try { $uri=\GuzzleHttp\Psr7\UriResolver::resolve(new \GuzzleHttp\Psr7\Uri($base),new \GuzzleHttp\Psr7\Uri($value)); }
        catch (\Throwable $e) { return null; }
        if (!in_array(strtolower($uri->getScheme()),$link?['http','https','mailto']:['http','https'],true) || $uri->getUserInfo()!=='') { return null; }
        if ($uri->getScheme()!=='mailto' && ($uri->getHost()==='' || ($uri->getPort()!==null && !in_array($uri->getPort(),[80,443],true)))) { return null; }
        return (string)$uri;
    }
    public static function clean(string $html,string $baseUrl): string {
        $d=self::document($html); $body=$d->getElementsByTagName('body')->item(0);
        if ($body===null) { return ''; }
        $walk=function (\DOMNode $parent) use (&$walk,$baseUrl): void {
            foreach (iterator_to_array($parent->childNodes) as $node) {
                if ($node instanceof \DOMComment || $node instanceof \DOMProcessingInstruction) { $parent->removeChild($node); continue; }
                if (!$node instanceof \DOMElement) { continue; }
                $tag=strtolower($node->tagName);
                if (in_array($tag,['script','style','form','iframe','object','embed','svg','math','input','button','select','textarea','template','noscript'],true)) { $parent->removeChild($node); continue; }
                $walk($node);
                if (!in_array($tag,self::ELEMENTS,true)) {
                    while ($node->firstChild) { $parent->insertBefore($node->firstChild,$node); }
                    $parent->removeChild($node); continue;
                }
                foreach (iterator_to_array($node->attributes) as $attribute) {
                    $name=strtolower($attribute->name); $value=$attribute->value; $keep=false;
                    if ($name==='href' && $tag==='a' || $name==='src' && $tag==='img') {
                        $safe=self::url($value,$baseUrl,$name==='href');
                        if ($safe!==null) { $node->setAttribute($name,$safe); $keep=true; }
                    } elseif ($name==='srcset' && $tag==='img') {
                        $items=[];
                        foreach (explode(',',$value) as $part) {
                            $tokens=preg_split('/\s+/',trim($part)); $safe=self::url($tokens[0]??'',$baseUrl,false);
                            if ($safe===null || count($tokens)>2 || (isset($tokens[1])&&!preg_match('/^(?:[1-9][0-9]*w|[0-9]+(?:\.[0-9]+)?x)$/D',$tokens[1]))) { continue; }
                            $items[]=$safe.(isset($tokens[1])?' '.$tokens[1]:'');
                        }
                        if ($items) { $node->setAttribute($name,implode(', ',$items)); $keep=true; }
                    } elseif (in_array($name,['title','alt'],true) && strlen($value)<=1024) { $keep=true; }
                    elseif (in_array($name,['colspan','rowspan','width','height'],true) && preg_match('/^[1-9][0-9]{0,3}$/D',$value)) { $keep=true; }
                    elseif ($name==='scope' && in_array($value,['row','col','rowgroup','colgroup'],true)) { $keep=true; }
                    if (!$keep) { $node->removeAttribute($attribute->name); }
                }
                if ($tag==='img' && !$node->hasAttribute('src') && !$node->hasAttribute('srcset')) { $parent->removeChild($node); }
            }
        };
        $walk($body); $output='';
        foreach ($body->childNodes as $node) { $output.=$d->saveHTML($node); }
        return trim($output);
    }
}
