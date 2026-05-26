# Wikibase Sitelinks Implementation Guide

This document details the implementation of Sitelinks within the ClimateKG Wikibase environment. Sitelinks allow MediaWiki pages to be linked to Wikibase items, facilitating data interconnection within the wiki structure.

The sitelink group is named **`climatekg-wiki`** across all environments. Each environment has its own `sites.<env>.xml` file with the correct domain URL; Docker Compose mounts the appropriate file at runtime.

## Deployment Strategy

All changes in this guide live on branch **`feature-dev-sitelinks`**. The rollout is gated on a LOCAL validation step before any remote environment is touched.

```
feature-dev-sitelinks  →  LOCAL test  →  merge to master  →  git pull on DEV / TEST / PROD
```

### Phase 1 — LOCAL validation (current phase)
1. Ensure you are on the branch: `git checkout feature-dev-sitelinks`
2. Bring up (or restart) the local stack: `docker compose up -d`
3. The `wikibase-sitelinks-init` container runs `init-sitelinks.sh` automatically, which:
   - Deletes legacy `mywiki` rows from `site_identifiers` and `sites`
   - Imports `sites.xml` (localhost URLs, `climatekg-wiki` globalid)
   - Sets `site_language = 'en'`
4. **Verify** — see [Step 7](#step-7-verifying-sitelinks). A "Climate KG Wiki" section should appear on item pages.
5. If verification passes, commit and push the branch, then open a PR to `master`.

### Phase 2 — Rollout to DEV / TEST / PROD (after merge)
Once `feature-dev-sitelinks` is merged to `master`, SSH to each server and pull:
```sh
cd /opt/wikibase
git pull --ff-only
docker compose -f docker-compose.yml -f docker-compose.<env>.yml up -d
```
The `wikibase-sitelinks-init` restart triggered by `up -d` runs the migration automatically on each server. No manual SQL needed.

---

## Software & Programming Languages
- **MediaWiki / Wikibase**: Open-source knowledge base software.
- **PHP**: Core server-side language for MediaWiki configurations.
- **Bash**: Shell scripting for initialization and environment setup.
- **XML**: Site definition format for the MediaWiki sites table.
- **Docker / Docker Compose**: Containerization and orchestration.

---

## Environment Overview

| Env   | Domain                                   | Sites XML file       | Compose override            |
|-------|------------------------------------------|---------------------|-----------------------------|
| LOCAL | localhost:8080                           | `sites.xml`          | `docker-compose.override.yml` |
| DEV   | dev-climatekg.semanticclimate.org        | `sites.dev.xml`      | `docker-compose.dev.yml`    |
| TEST  | test-climatekg.semanticclimate.org       | `sites.test.xml`     | `docker-compose.test.yml`   |
| PROD  | prod-climatekg.semanticclimate.org       | `sites.prod.xml`     | `docker-compose.prod.yml`   |

---

## Step 1: Define the Site Configuration (per environment)

Each environment has a `sites.<env>.xml` file. The `globalid`, `group`, and `localid` are always `climatekg-wiki`; only the `path` URLs differ.

**`sites.xml`** (LOCAL)
```xml
<?xml version="1.0"?>
<sites version="1.0">
  <site type="mediawiki">
    <globalid>climatekg-wiki</globalid>
    <group>climatekg-wiki</group>
    <localid type="interwiki">climatekg-wiki</localid>
    <path type="link">http://localhost:8080/wiki/$1</path>
    <path type="page_path">http://localhost:8080/wiki/$1</path>
    <path type="file_path">http://localhost:8080/w/$1</path>
  </site>
</sites>
```

**`sites.dev.xml`** (DEV)
```xml
<?xml version="1.0"?>
<sites version="1.0">
  <site type="mediawiki">
    <globalid>climatekg-wiki</globalid>
    <group>climatekg-wiki</group>
    <localid type="interwiki">climatekg-wiki</localid>
    <path type="link">https://dev-climatekg.semanticclimate.org/wiki/$1</path>
    <path type="page_path">https://dev-climatekg.semanticclimate.org/wiki/$1</path>
    <path type="file_path">https://dev-climatekg.semanticclimate.org/w/$1</path>
  </site>
</sites>
```

**`sites.test.xml`** and **`sites.prod.xml`** follow the same pattern with their respective domains.

---

## Step 2: Configure MediaWiki Settings

**File: `LocalSettings.sitelinks.php`**
```php
<?php
// Define the site link group for the local wiki
$wgWBRepoSettings['siteLinkGroups'] = [ 'climatekg-wiki' ];

// Label for the sitelink group heading
$wgExtensionMessagesFiles['WikibaseSitelinks'] = __DIR__ . '/WikibaseSitelinksMessages.php';

// Set the local wiki's global site ID
$wgWBClientSettings['siteGlobalID'] = 'climatekg-wiki';

// Client-repo connection
$wgWBClientSettings['repoUrl'] = $wgServer;
$wgWBClientSettings['repoScriptPath'] = '/w';
$wgWBClientSettings['repoArticlePath'] = '/wiki/$1';
```

This file is bind-mounted into the wikibase container in `docker-compose.yml` (base) and is therefore shared across all environments — only the sites XML file changes per environment.

---

## Step 3: Localize Sitelink Group Names

**File: `WikibaseSitelinksMessages.php`**
```php
<?php
$messages = [];
$messages['en'] = [
    'wikibase-sitelinks-climatekg-wiki' => 'Climate KG Wiki',
    'wikibase-group-climatekg-wiki' => 'climatekg-wiki',
];
```

---

## Step 4: Docker Compose Wiring

The `wikibase-sitelinks-init` service in `docker-compose.yml` (base) mounts `sites.xml` by default. Each environment override replaces it with the environment-specific file:

**`docker-compose.yml`** (base — LOCAL)
```yaml
wikibase-sitelinks-init:
  volumes:
    - ./sites.xml:/extra-config/sites.xml:ro
    - ./scripts/deploy/init-sitelinks.sh:/init-sitelinks.sh:ro
  entrypoint: ["bash", "/init-sitelinks.sh"]
```

**`docker-compose.dev.yml`** (DEV override)
```yaml
wikibase-sitelinks-init:
  volumes:
    - ./sites.dev.xml:/extra-config/sites.xml:ro
```

**`docker-compose.test.yml`** / **`docker-compose.prod.yml`** follow the same pattern with `sites.test.xml` / `sites.prod.xml`.

---

## Step 5: Automate Initialization

**File: `scripts/deploy/init-sitelinks.sh`**
```bash
#!/bin/bash
set -e

echo "=== Wikibase Sitelinks Initialization ==="

cd /var/www/html
/usr/local/bin/php maintenance/run.php importSites \
    --conf /config/LocalSettings.php /extra-config/sites.xml

/usr/local/bin/php maintenance/run.php sql \
    --conf /config/LocalSettings.php --query \
    "UPDATE sites SET site_language = 'en'
     WHERE site_global_key = 'climatekg-wiki'
     AND (site_language IS NULL OR site_language = '');"

echo "=== Sitelinks initialization complete ==="
```

This script runs once at container startup via the `wikibase-sitelinks-init` service and does not need to be re-run unless the sites table is reset (e.g. after a fresh DB restore).

---

## Step 6: Applying Changes

### Fresh deployment (new server or after DB reset)
The `wikibase-sitelinks-init` service runs automatically on `docker compose up`. No manual steps needed.

### After a DB sync (e.g. `sync-local-to-test.ps1`)
The sync scripts restart `wikibase-sitelinks-init` automatically:
```powershell
docker compose -f docker-compose.yml -f docker-compose.test.yml restart wikibase-sitelinks-init
Start-Sleep 15
docker compose -f docker-compose.yml -f docker-compose.test.yml restart wikibase
```

### Renaming the sitelink group
If the `globalid` is changed, `init-sitelinks.sh` handles the migration automatically: it deletes any rows where `site_global_key = 'mywiki'` from both `site_identifiers` and `sites` before running the import. This runs on every `wikibase-sitelinks-init` restart, so the sync scripts (`sync-local-to-test.ps1`, `sync-dev-to-test.ps1`, `sync-dev-to-prod.ps1`) and `pull-from-dev.ps1` all perform the migration as part of their existing container-restart step — no manual SQL is needed.

---

## Step 7: Verifying Sitelinks

1. Open any Wikibase item (e.g. `/wiki/Item:Q1`).
2. At the bottom of the item page, a **"Climate KG Wiki"** sitelinks section should appear.
3. Add a sitelink pointing to a wiki page (e.g. `Main_Page`) and confirm the link resolves correctly.

If the sitelinks heading shows a raw message key (e.g. `⧼wikibase-sitelinks-climatekg-wiki⧽`), the `WikibaseSitelinksMessages.php` file is not being loaded — check the bind-mount in `docker-compose.yml` is correct and restart the wikibase container.

