<?php
/**
 * Sitelinks configuration for Wikibase
 *
 * Enables linking MediaWiki pages to Wikibase items via sitelinks.
 * The site group 'mywiki' and global ID must match the entry registered
 * in the sites table (see sites.xml).
 */

// Define the site link group for the local wiki
$wgWBRepoSettings['siteLinkGroups'] = [ 'mywiki' ];

// Label for the sitelink group heading (avoids raw ⧼message-key⧽ display)
$wgExtensionMessagesFiles['WikibaseSitelinks'] = __DIR__ . '/WikibaseSitelinksMessages.php';

// Set the local wiki's global site ID (must match sites table entry)
$wgWBClientSettings['siteGlobalID'] = 'mywiki';

// Client-repo connection (same wiki serves as both)
$wgWBClientSettings['repoUrl'] = $wgServer;
$wgWBClientSettings['repoScriptPath'] = '/w';
$wgWBClientSettings['repoArticlePath'] = '/wiki/$1';
