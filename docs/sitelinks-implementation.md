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

// Register this database as a local client that can receive sitelinks
// This allows the repo to create sitelinks to pages in this same wiki
$wgWBRepoSettings['localClientDatabases'] = [ $wgDBname ];

// Label for the sitelink group heading (avoids raw ⧼message-key⧽ display)
// Load custom sitelink messages directly via hook
$wgHooks['LocalisationCacheRecache'][] = function ( $cache, $code, &$cachedData ) {
    if ( $code === 'en' ) {
        $cachedData['messages']['wikibase-sitelinks-climatekg-wiki'] = 'Climate KG Wiki';
        $cachedData['messages']['wikibase-group-climatekg-wiki'] = 'climatekg-wiki';
    }
};

// Set the local wiki's global site ID (must match sites table entry)
$wgWBClientSettings['siteGlobalID'] = 'climatekg-wiki';

// Client-repo connection (same wiki serves as both)
$wgWBClientSettings['repoUrl'] = $wgServer;
$wgWBClientSettings['repoScriptPath'] = '/w';
$wgWBClientSettings['repoArticlePath'] = '/wiki/$1';
```

This file is bind-mounted into the wikibase container in `docker-compose.yml` (base) and is therefore shared across all environments — only the sites XML file changes per environment.

---

## Step 3: Localize Sitelink Group Names (Legacy - Now Handled by Hook)

**Note:** Message localization is now handled directly in `LocalSettings.sitelinks.php` via the `LocalisationCacheRecache` hook. The `WikibaseSitelinksMessages.php` file still exists for reference but is no longer loaded.

**File: `WikibaseSitelinksMessages.php`** (for reference only)
```php
<?php
$messages = [];
$messages['en'] = [
    'wikibase-sitelinks-climatekg-wiki' => 'Climate KG Wiki',
    'wikibase-group-climatekg-wiki' => 'climatekg-wiki',
];
```

The hook-based approach in `LocalSettings.sitelinks.php` is preferred as it ensures messages are available immediately without requiring file loading or cache rebuilds.

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

This script runs automatically when the `wikibase-sitelinks-init` container starts. It performs:

1. **Legacy cleanup** — Removes old `mywiki` site entries
2. **Data migration** — Updates existing sitelinks from `mywiki` to `climatekg-wiki`
3. **Site import** — Imports the environment-specific sites XML file
4. **Language configuration** — Sets site language to English
5. **Domain/protocol fix** — Corrects any corruption from importSites bug
6. **Interwiki setup** — Adds required interwiki entry for page validation

```bash
#!/bin/bash
set -e

echo "=== Wikibase Sitelinks Initialization ==="

# Remove any legacy 'mywiki' entries (renamed to 'climatekg-wiki')
echo "Removing legacy 'mywiki' site entries (if present)..."
cd /var/www/html
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "DELETE si FROM site_identifiers si INNER JOIN sites s ON si.si_site = s.site_id WHERE s.site_global_key = 'mywiki';" || true
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "DELETE FROM sites WHERE site_global_key = 'mywiki';" || true

# Migrate existing sitelink data
echo "Migrating existing sitelinks from 'mywiki' to 'climatekg-wiki'..."
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "UPDATE wb_items_per_site SET ips_site_id = 'climatekg-wiki' WHERE ips_site_id = 'mywiki';" || true

# Import sites from XML
echo "Importing sites from sites.xml..."
/usr/local/bin/php maintenance/run.php importSites --conf /config/LocalSettings.php /extra-config/sites.xml

# Set language
echo "Setting site language for climatekg-wiki..."
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "UPDATE sites SET site_language = 'en' WHERE site_global_key = 'climatekg-wiki' AND (site_language IS NULL OR site_language = '');"

# Fix site_domain and site_protocol (importSites can corrupt these)
# Extract correct values from site_data paths which are imported correctly
# Note: site_domain must be reachable from inside the container for API validation
# For LOCAL, use 'localhost' (not 'localhost:8080') since port 8080 is only on host
echo "Fixing site_domain and site_protocol..."
SITE_FIX_SQL="
UPDATE sites
SET
    site_protocol = CASE
        WHEN site_data LIKE '%https://%' THEN 'https'
        WHEN site_data LIKE '%http://%' THEN 'http'
        ELSE site_protocol
    END,
    site_domain = CASE
        WHEN site_data LIKE '%localhost:8080%' THEN 'localhost'
        WHEN site_data LIKE '%dev-climatekg.semanticclimate.org%' THEN 'dev-climatekg.semanticclimate.org'
        WHEN site_data LIKE '%test-climatekg.semanticclimate.org%' THEN 'test-climatekg.semanticclimate.org'
        WHEN site_data LIKE '%prod-climatekg.semanticclimate.org%' THEN 'prod-climatekg.semanticclimate.org'
        ELSE site_domain
    END
WHERE site_global_key = 'climatekg-wiki';
"
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query "$SITE_FIX_SQL" || true

# Add interwiki entry (needed for sitelink page validation)
echo "Adding interwiki entry for climatekg-wiki..."
INTERWIKI_SQL="
INSERT IGNORE INTO interwiki (iw_prefix, iw_url, iw_api, iw_wikiid, iw_local)
VALUES ('climatekg-wiki', 'http://localhost/wiki/\$1', 'http://localhost/w/api.php', '', 1);
"
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query "$INTERWIKI_SQL" || true

echo ""
echo "=== Sitelinks initialization complete ==="
```

**Note about interwiki URLs:** The script uses `http://localhost/` for all environments. This works because:
- In LOCAL: Container uses internal localhost
- In DEV/TEST/PROD: Containers communicate internally via Docker network using container names (resolved to localhost within each container)

If external API calls are needed in production, the interwiki entry should be updated to use the public domain after deployment.

This script runs once at container startup and does not need to be manually executed unless the sites table is reset.

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

---

## Step 8: Adding Sitelinks to Items

### Via the Web UI

1. Navigate to an item page (e.g., `http://localhost:8080/wiki/Item:Q1`)
2. Scroll to the **"Climate KG Wiki"** section at the bottom
3. Click **"edit"** next to the section heading
4. You'll be redirected to `Special:SetSiteLink/<ItemID>`
5. Fill in the form:
   - **Site ID:** `climatekg-wiki`
   - **Sitelink:** The page title (e.g., `Main_Page` or `Main Page`)
6. Click **"Set the sitelink"**
7. The sitelink appears in the item's "Climate KG Wiki" section

**Note:** The inline JavaScript editor may not work correctly in some cases. If clicking "edit" doesn't open a form, navigate directly to:
```
http://localhost:8080/wiki/Special:SetSiteLink/<ItemID>
```

### Via the API

```bash
curl -X POST 'http://localhost:8080/w/api.php' \
  -d 'action=wbsetsitelink' \
  -d 'id=Q1' \
  -d 'linksite=climatekg-wiki' \
  -d 'linktitle=Main_Page' \
  -d 'token=YOUR_CSRF_TOKEN' \
  -d 'format=json'
```

---

## Architecture & Technical Details

### Site Registration Tables

Wikibase uses three database structures for sitelinks:

1. **`sites` table**: Stores site metadata (domain, protocol, language, paths)
2. **`site_identifiers` table**: Maps site prefixes to site IDs (for interwiki resolution)
3. **`interwiki` table**: Required for page validation when adding sitelinks
4. **`wb_items_per_site` table**: Denormalized table for fast sitelink lookups

### Container-Internal vs External URLs

**Critical distinction for LOCAL environment:**

- **External URLs** (for browser links): `http://localhost:8080/wiki/$1`
  - Used in XML `<path>` elements
  - Accessible from the host machine
  
- **Internal URLs** (for API validation): `http://localhost/wiki/$1`
  - Used in `site_domain` field
  - Used in `interwiki` table entries
  - Accessible from inside the container
  - Port 8080 is NOT accessible from within the container

The `init-sitelinks.sh` script automatically:
- Detects `localhost:8080` in XML paths
- Sets `site_domain = 'localhost'` (without port) for container-internal API calls
- Adds interwiki entry with `http://localhost/` URLs

For DEV/TEST/PROD environments, both internal and external URLs are identical since the domains are accessible from both inside and outside the containers.

### Interwiki Requirement

Wikibase validates sitelink pages by making API calls to the target wiki. This requires:

1. **Site registration** in the `sites` table (via `importSites`)
2. **Interwiki entry** in the `interwiki` table with:
   - `iw_prefix = 'climatekg-wiki'`
   - `iw_url` pointing to internal page path
   - `iw_api` pointing to internal API endpoint
   - `iw_local = 1` flag set

Without the interwiki entry, you'll see this error when adding sitelinks:
```
A page "PageName" could not be found on "climatekg-wiki".
```

The `init-sitelinks.sh` script creates this entry automatically.

---

## Troubleshooting

### Issue: "Climate KG Wiki" heading shows raw message key

**Symptom:** `⧼wikibase-sitelinks-climatekg-wiki⧽` instead of "Climate KG Wiki"

**Cause:** Message file not loaded correctly

**Fix:**
1. Verify `WikibaseSitelinksMessages.php` is mounted in `docker-compose.yml`
2. Check that `LocalSettings.sitelinks.php` uses the `LocalisationCacheRecache` hook
3. Clear caches and restart:
   ```bash
   docker exec wikibase-mariadb mariadb -uwikibase -pwikibase my_wiki -e "TRUNCATE objectcache; TRUNCATE l10n_cache;"
   docker compose restart wikibase
   ```

### Issue: Page input field missing on edit form

**Symptom:** Only see a "wiki" label with trash icon, no page name input

**Cause:** Orphaned data in `wb_items_per_site` table that doesn't match item JSON blob

**Fix:**
```sql
# Check for inconsistent data
SELECT ips_item_id, ips_site_id, ips_site_page FROM wb_items_per_site WHERE ips_item_id = 1;

# Compare with item JSON (should match)
SELECT old_text FROM text 
INNER JOIN slots ON slot_content_id = old_id 
INNER JOIN page ON page_latest = slot_revision_id 
WHERE page_title = 'Q1' AND page_namespace = 120;

# If mismatch, delete the orphaned row
DELETE FROM wb_items_per_site WHERE ips_item_id = 1;
```

Then clear browser cache (Ctrl+Shift+R).

### Issue: "A page 'PageName' could not be found on 'climatekg-wiki'"

**Symptom:** Error when trying to add a sitelink to an existing page

**Causes and Fixes:**

1. **Missing interwiki entry**
   ```sql
   # Check if entry exists
   SELECT * FROM interwiki WHERE iw_prefix = 'climatekg-wiki';
   
   # If missing, add it
   INSERT INTO interwiki (iw_prefix, iw_url, iw_api, iw_wikiid, iw_local) 
   VALUES ('climatekg-wiki', 'http://localhost/wiki/$1', 'http://localhost/w/api.php', '', 1);
   ```

2. **Wrong site_domain (LOCAL environment)**
   ```sql
   # Check current value
   SELECT site_domain FROM sites WHERE site_global_key = 'climatekg-wiki';
   
   # Should be 'localhost' (not 'localhost:8080') for LOCAL
   UPDATE sites SET site_domain = 'localhost' WHERE site_global_key = 'climatekg-wiki';
   ```

3. **Page doesn't actually exist**
   - Verify the page exists: `http://localhost:8080/wiki/PageName`
   - Use correct page title format (spaces or underscores as stored in database)

### Issue: Stale browser cache shows old broken UI

**Symptom:** Form still shows old state after fixes

**Fix:**
1. Hard refresh: Ctrl+Shift+R (or Ctrl+F5)
2. Clear browser cache completely for localhost:8080
3. Try in incognito/private window
4. Navigate directly to `Special:SetSiteLink/<ItemID>` URL instead of using "edit" link

### Issue: Site domain corruption ("tsohlacol." backwards localhost)

**Symptom:** `site_domain` field contains garbled text

**Cause:** Known bug in MediaWiki's `importSites` command

**Fix:** The `init-sitelinks.sh` script automatically detects and corrects this using SQL CASE statement to extract domain from `site_data` paths.

---

## Migration from "mywiki" to "climatekg-wiki"

The init script automatically handles migration of legacy `mywiki` data:

1. **Removes legacy site entries:**
   ```sql
   DELETE FROM site_identifiers WHERE si_site IN (SELECT site_id FROM sites WHERE site_global_key = 'mywiki');
   DELETE FROM sites WHERE site_global_key = 'mywiki';
   ```

2. **Migrates existing sitelink data:**
   ```sql
   UPDATE wb_items_per_site SET ips_site_id = 'climatekg-wiki' WHERE ips_site_id = 'mywiki';
   ```

This runs automatically on every `wikibase-sitelinks-init` container startup, so database syncs between environments will automatically migrate any legacy data.

---

## Files Modified in This Implementation

- `sites.xml` — LOCAL site registration with localhost:8080 URLs
- `sites.dev.xml` — DEV site registration
- `sites.test.xml` — TEST site registration  
- `sites.prod.xml` — PROD site registration
- `LocalSettings.sitelinks.php` — Wikibase sitelinks configuration
- `WikibaseSitelinksMessages.php` — Localization messages for "Climate KG Wiki"
- `scripts/deploy/init-sitelinks.sh` — Automated initialization and migration script
- `sites-internal.xml` — Internal-only site definition (for container path validation)
- `interwiki.sql` — SQL to create interwiki entry (reference)
- `docker-compose.yml` — Base configuration with LOCAL sites.xml mount
- `docker-compose.dev.yml` — DEV override with sites.dev.xml
- `docker-compose.test.yml` — TEST override with sites.test.xml
- `docker-compose.prod.yml` — PROD override with sites.prod.xml

---

## Maintenance

### After Database Restore/Sync

The sync scripts automatically restart `wikibase-sitelinks-init`, which runs the migration. No manual intervention needed.

### Adding New Environments

1. Create `sites.<newenv>.xml` with appropriate domain
2. Create `docker-compose.<newenv>.yml` override:
   ```yaml
   wikibase-sitelinks-init:
     volumes:
       - ./sites.<newenv>.xml:/extra-config/sites.xml:ro
   ```
3. Update `init-sitelinks.sh` if the domain requires special handling in the site_domain fix logic

### Changing Sitelink Group Name

1. Update all XML files with new `<globalid>`, `<group>`, `<localid>`
2. Update `LocalSettings.sitelinks.php` with new group name
3. Update `WikibaseSitelinksMessages.php` with new message keys
4. Add deletion logic to `init-sitelinks.sh` for old group name
5. Test on LOCAL before rolling out to other environments

