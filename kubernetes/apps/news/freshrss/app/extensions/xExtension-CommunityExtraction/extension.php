<?php
declare(strict_types=1);
require_once __DIR__.'/Client.php'; require_once __DIR__.'/Preservation.php';
final class CommunityExtractionExtension extends Minz_Extension {
    public function init(): void {
        $preservation=new \CommunityExtraction\Preservation(new \CommunityExtraction\Client(),getenv('NEWS_EXTRACTION_REQUESTS_ENABLED')==='true');
        $this->registerHook(Minz_HookType::EntryBeforeInsert,[$preservation,'beforeInsert']);
        $this->registerHook(Minz_HookType::EntryBeforeUpdate,[$preservation,'beforeUpdate']);
    }
}
