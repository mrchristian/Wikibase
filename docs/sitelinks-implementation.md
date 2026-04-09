# Wikibase Sitelinks Implementation Guide

This document details the successful implementation of Sitelinks within a Wikibase environment. Sitelinks allow MediaWiki pages to be linked to Wikibase items, facilitating data interconnection within the wiki structure.

## AI Attribution
- **Model**: Gemini 1.5 Flash (Preview)
- **Role**: AI Programming Assistant via GitHub Copilot

## Software & Programming Languages
- **MediaWiki / Wikibase**: Open-source knowledge base software.
- **PHP**: Core server-side language for MediaWiki configurations.
- **Bash**: Shell scripting for initialization and environment setup.
- **XML**: Site definition format for the MediaWiki sites table.
- **Docker / Docker Compose**: Containerization and orchestration.

---

## Step 1: Define the Site Configuration
The site must be registered in the MediaWiki `sites` table. An XML file is used to provide these definitions.

**File: `sites.xml`**
```xml
<?xml version="1.0"?>
<sites version="1.0">
  <site type="mediawiki">
    <globalid>mywiki</globalid>
    <group>mywiki</group>
    <localid type="interwiki">mywiki</localid>
    <path type="link">http://localhost:8080/wiki/$1</path>
    <path type="page_path">http://localhost:8080/wiki/$1</path>
    <path type="file_path">http://localhost:8080/w/$1</path>
  </site>
</sites>
```

## Step 2: Configure MediaWiki Settings
The `LocalSettings.php` (or a dedicated include file) must be updated to enable sitelink groups and point to the correct global ID.

**File: `LocalSettings.sitelinks.php`**
```php
<?php
// Define the site link group for the local wiki
$wgWBRepoSettings['siteLinkGroups'] = [ 'mywiki' ];

// Label for the sitelink group heading
$wgExtensionMessagesFiles['WikibaseSitelinks'] = __DIR__ . '/WikibaseSitelinksMessages.php';

// Set the local wiki's global site ID
$wgWBClientSettings['siteGlobalID'] = 'mywiki';

// Client-repo connection
$wgWBClientSettings['repoUrl'] = $wgServer;
$wgWBClientSettings['repoScriptPath'] = '/w';
$wgWBClientSettings['repoArticlePath'] = '/wiki/$1';
```

## Step 3: Localize Sitelink Group Names
To avoid raw message keys like `⧼wikibase-sitelinks-mywiki⧽` appearing in the UI, translation messages must be provided.

**File: `WikibaseSitelinksMessages.php`**
```php
<?php
$messages = [];
$messages['en'] = [
    'wikibase-sitelinks-mywiki' => 'Local wiki',
    'wikibase-group-mywiki' => 'mywiki',
];
```

## Step 4: Automate Initialization
A shell script is used to import the sites into the database and ensure the language settings are correctly applied. Using the absolute path `/usr/local/bin/php` ensures compatibility within the Docker container.

**File: `init-sitelinks.sh`**
```bash
#!/bin/bash
set -e

# Import sites from the XML definition
/usr/local/bin/php maintenance/run.php importSites --conf /config/LocalSettings.php /extra-config/sites.xml

# Set the site language (required for proper rendering)
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "UPDATE sites SET site_language = 'en' WHERE site_global_key = 'mywiki' AND (site_language IS NULL OR site_language = '');"
```

## Step 5: Finalize and Restart
After the files are in place and the initialization script has run, the containers must be restarted to apply the PHP configuration changes.

```bash
docker compose restart wikibase
```
