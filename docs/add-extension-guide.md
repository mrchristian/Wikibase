# How to Add a MediaWiki Extension

This guide covers adding extensions to the ClimateKG Wikibase instance, both locally and on production.

## Overview

Extensions are enabled via individual `LocalSettings.*.php` files mounted into the container's `/var/www/html/LocalSettings.d/` directory. This keeps configuration modular and avoids editing the auto-generated `LocalSettings.php`.

---

## Step 1 — Check if the extension is already bundled

Many common extensions ship with MediaWiki and require no download. Check the extension page on [mediawiki.org](https://www.mediawiki.org/wiki/Category:Extensions_bundled_with_MediaWiki) or look inside the running container:

```bash
docker exec wikibase ls /var/www/html/extensions/
```

If the folder is present, skip to Step 2. If not, the extension must be installed via Composer or added to the `Dockerfile.wikibase` — see [Step 1b](#step-1b--install-via-composer-if-not-bundled) below.

### Step 1b — Install via Composer (if not bundled)

Add a `composer require` line to `Dockerfile.wikibase`, following the pattern already used for the SPARQL extension:

```dockerfile
RUN COMPOSER_ALLOW_SUPERUSER=1 composer require --working-dir /var/www/html \
    vendor/extension-package --no-interaction --no-progress
```

Then rebuild the image:

```bash
docker compose build wikibase
docker compose up -d
```

---

## Step 2 — Create a LocalSettings file

Create a new file `LocalSettings.<extensionname>.php` in `c:\Wikibase\`:

```php
<?php
# Extension:<Name>
# https://www.mediawiki.org/wiki/Extension:<Name>

wfLoadExtension( '<ExtensionName>' );

# Add any configuration variables here, e.g.:
# $wgSomeExtensionOption = true;
```

**Example** — `LocalSettings.parserfunctions.php`:

```php
<?php
wfLoadExtension( 'ParserFunctions' );
$wgPFEnableStringFunctions = true;
```

---

## Step 3 — Mount the file (local)

Add a volume entry to the `wikibase` service in `docker-compose.yml`:

```yaml
volumes:
  - ./LocalSettings.<extensionname>.php:/var/www/html/LocalSettings.d/LocalSettings.<extensionname>.php:ro
```

Then restart the container:

```bash
docker compose up -d
```

Docker will recreate the container automatically if the compose config has changed.

### Verify locally

```bash
docker exec wikibase curl -s "http://localhost/w/api.php?action=query&meta=siteinfo&siprop=extensions&format=json" \
  | python3 -c "import sys,json; exts=[e['name'] for e in json.load(sys.stdin)['query']['extensions']]; print('Loaded:', '<ExtensionName>' in exts)"
```

Or browse to [http://localhost:8080/wiki/Special:Version](http://localhost:8080/wiki/Special:Version).

---

## Step 4 — Mount the file (production)

Add the same volume entry to the `wikibase` service in `docker-compose.prod.yml`:

```yaml
volumes:
  - ./LocalSettings.<extensionname>.php:/var/www/html/LocalSettings.d/LocalSettings.<extensionname>.php:ro
```

### Upload files to the server

```bash
scp LocalSettings.<extensionname>.php docker-compose.prod.yml root@178.104.156.88:/opt/wikibase/
```

> **Note:** Windows PowerShell's `scp` will prompt for your SSH key passphrase each time unless the SSH agent is running. Wait for the transfer to complete before closing the terminal — a timed-out SCP will silently produce no file on the server.

### Force-recreate the container

A plain `up -d` will not always recreate the container when only volume mounts change. Use `--force-recreate`:

```bash
ssh root@178.104.156.88 "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --force-recreate --no-deps wikibase"
```

`--no-deps` ensures MariaDB and WDQS are not restarted unnecessarily.

### Verify on production

```bash
python3 -c "
import urllib.request, json
r = urllib.request.urlopen('https://dev-climatekg.semanticclimate.org/w/api.php?action=query&meta=siteinfo&siprop=extensions&format=json', timeout=15)
exts = [e['name'] for e in json.load(r)['query']['extensions']]
print('Loaded:', '<ExtensionName>' in exts)
"
```

Or browse to [https://dev-climatekg.semanticclimate.org/wiki/Special:Version](https://dev-climatekg.semanticclimate.org/wiki/Special:Version).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Extension not in Special:Version after `up -d` | Docker didn't recreate the container | Run with `--force-recreate` |
| File missing on server after SCP | SCP timed out at passphrase prompt | Re-run the `scp` command and enter passphrase promptly |
| PHP fatal error in container logs | Bad syntax in LocalSettings file | Check the file with `php -l LocalSettings.<name>.php` |
| Extension folder missing in container | Not bundled; needs Composer install | Add to `Dockerfile.wikibase` and rebuild |

### Check container logs

```bash
docker logs wikibase --tail 50
```

### Check the file is actually mounted

```bash
docker exec wikibase ls /var/www/html/LocalSettings.d/
```

---

## Extensions already installed

| Extension | LocalSettings file | Notes |
|---|---|---|
| ParserFunctions | `LocalSettings.parserfunctions.php` | Bundled; string functions enabled |
| SPARQL | via Composer in `Dockerfile.wikibase` | professional-wiki/sparql |
| Sitelinks | `LocalSettings.sitelinks.php` | Custom WikibaseSitelinks setup |
