# Deploying Wikibase to Hetzner VM with a Custom Domain

When moving from a local environment (`localhost`) to a production server on a Hetzner VM with a custom domain (e.g., `https://wiki.example.com`), you must update several Sitelinks-related configurations to ensure MediaWiki pages and Wikibase items remain correctly linked.

## 1. Update the Sites Table (XML)
The `sites.xml` file currently points to `localhost:8080`. These MUST be updated to your production domain. If you do not update this, clicking Sitelinks in the sidebar will attempt to redirect users to their own local computer.

**File: `sites.xml`**
```xml
<sites version="1.0">
  <site type="mediawiki">
    <globalid>mywiki</globalid>
    <group>mywiki</group>
    <path type="link">https://wiki.example.com/wiki/$1</path>
    <path type="page_path">https://wiki.example.com/wiki/$1</path>
    <path type="file_path">https://wiki.example.com/w/$1</path>
  </site>
</sites>
```
*   **Action**: Re-run the `init-sitelinks.sh` script inside the container after updating this file.

## 2. Update MediaWiki Global Settings
Your `docker-compose.yml` and `LocalSettings.php` likely define `MW_WG_SERVER` or `$wgServer`. Ensure these reflect the new protocol (`https`) and domain.

**File: `docker-compose.yml`**
```yaml
environment:
  MW_WG_SERVER: "https://wiki.example.com"
```

## 3. Sitelink Repo Connection
In [LocalSettings.sitelinks.php](LocalSettings.sitelinks.php), the connection settings use `$wgServer`. While this is dynamic, you must ensure that if you are using a reverse proxy (like Nginx on the Hetzner VM), MediaWiki is aware of the `https` termination.

If `repoUrl` is explicitly set to `localhost` anywhere, it must be changed:
```php
$wgWBClientSettings['repoUrl'] = 'https://wiki.example.com';
```

## 4. Query Service (WDQS) Integration
The Query Service updater needs to know where the Wikibase instance is located to pull changes.

**File: `docker-compose.yml` (wdqs-updater section)**
```yaml
environment:
  WIKIBASE_HOST: "wiki.example.com"
  WIKIBASE_CONCEPT_URI: "https://wiki.example.com"
```

## 5. Reverse Proxy Configuration
On a Hetzner VM, you will likely use Nginx or Traefik to handle SSL (HTTPS). Ensure the following headers are passed to the Wikibase container:
- `X-Forwarded-Proto: https`
- `X-Forwarded-Host: wiki.example.com`

Without these, MediaWiki might generate `http://` links internally, causing Sitelinks to break due to Mixed Content errors in the browser.

---
**Summary Checklist**:
1. [ ] Update `sites.xml` with the domain name and `https`.
2. [ ] Re-run `init-sitelinks.sh`.
3. [ ] Update `docker-compose.yml` environment variables.
4. [ ] Configure SSL certificates (e.g., Let's Encrypt).
5. [ ] Restart all containers (`docker compose up -d`).
