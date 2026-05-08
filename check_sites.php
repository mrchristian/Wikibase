<?php
require '/config/LocalSettings.php';
$sites = MediaWiki\MediaWikiServices::getInstance()->getSiteLookup()->getSites();
echo 'Sites found: ' . count($sites) . PHP_EOL;
foreach ($sites as $site) {
    echo 'ID: ' . $site->getGlobalId() . ' | Group: ' . $site->getGroup() . ' | Type: ' . $site->getType() . PHP_EOL;
}
echo PHP_EOL . 'siteLinkGroups: ' . json_encode($GLOBALS['wgWBRepoSettings']['siteLinkGroups'] ?? 'NOT SET') . PHP_EOL;
