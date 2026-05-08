# Deployment Protocol — dev-climatekg.semanticclimate.org

**Date**: 9 April 2026  
**Server**: Hetzner Cloud VM (CX22, Ubuntu 24.04, Nuremberg)  
**IP**: 178.104.156.88  
**Domain**: dev-climatekg.semanticclimate.org

---

## 1. Production Configuration Files Created

The following files were created locally to support a production deployment separate from the local `docker-compose.yml` (which remains for localhost development):

| File | Purpose |
|------|---------|
| `.env.production` | Template with domain (`dev-climatekg.semanticclimate.org`) and placeholder passwords |
| `docker-compose.prod.yml` | Production overrides: binds ports to `127.0.0.1`, sets env vars via `$WIKIBASE_DOMAIN` |
| `docker-compose.override.yml` | Local dev port bindings (auto-loaded by `docker compose up`) |
| `sites.prod.xml` | Sitelinks XML with `https://dev-climatekg.semanticclimate.org` paths |
| `wdqs-custom-config.prod.json` | Query service config pointing to production SPARQL proxy at `/query/proxy/sparql` |
| `deploy.sh` | Automated server setup script (Docker, Nginx, firewall, credentials, stack start) |
| `.gitignore` | Excludes `.env` (real credentials) and `.venv/` from version control |

### Key design decision: ports moved out of `docker-compose.yml`

Ports were removed from `docker-compose.yml` and placed in:
- `docker-compose.override.yml` — for local dev (auto-loaded)
- `docker-compose.prod.yml` — for production (`127.0.0.1` bindings)

**Reason**: Docker Compose merges port lists additively across files. Having `8080:80` in `docker-compose.yml` and `127.0.0.1:8080:80` in the prod override caused "address already in use" because both bindings were applied simultaneously.

## 2. Git Push

All files committed and pushed to `mrchristian/Wikibase` on `master`:
- Commit `6963a18`: Initial production config files
- Commit `14c073b`: Fix port conflict (move ports to override files)
- Commit `5689211`: Fix wdqs-frontend `:ro` mount issue

## 3. Hetzner VM Provisioned

- Server created in Hetzner Cloud Console (CX22, Ubuntu 24.04, Nuremberg)
- SSH key added; root access confirmed
- Public IPv4: `178.104.156.88`

## 4. DNS Configured

A record created in DNS for `semanticclimate.org`:
- `dev-climatekg` → `178.104.156.88`

## 5. Deploy Script Executed

Ran `deploy.sh` on the server via:
```
Get-Content deploy.sh -Raw | ssh root@178.104.156.88 'bash -s'
```

The script performed:
1. System update (`apt-get update && upgrade`)
2. Docker installation via `get.docker.com`
3. Nginx + Certbot installation
4. Repository cloned to `/opt/wikibase`
5. `.env` created from `.env.production` with auto-generated passwords:
   - `DB_PASS`: `AOti5qI4vQ55t7RtOggSOhICh20NbO2`
   - `MW_ADMIN_PASS`: `B7diYv1qlz4VdsqQ6rBNF3bPPS2XEq2R`
6. Nginx reverse proxy configured (port 80 → 8080, /query/ → 8081, /query/proxy/sparql → 9999)
7. UFW firewall enabled (ports 22, 80, 443 only)
8. Docker stack started

## 6. Issues Encountered and Fixed

### 6a. Port 8080 "address already in use"

**Symptom**: `docker compose up` failed with `failed to bind host port 127.0.0.1:8080/tcp: address already in use`.

**Cause**: Docker Compose merges port lists from multiple files additively. Both `docker-compose.yml` (`8080:80`) and `docker-compose.prod.yml` (`127.0.0.1:8080:80`) were applied, creating two conflicting bindings.

**Fix**: Removed ports from `docker-compose.yml`. Created `docker-compose.override.yml` for local dev ports. Production ports remain only in `docker-compose.prod.yml`.

### 6b. wdqs-frontend restart loop

**Symptom**: `wdqs-frontend` container kept restarting with `cp: cannot create regular file '/usr/share/nginx/html/custom-config.json': Read-only file system`.

**Cause**: The volume mount in `docker-compose.prod.yml` used `:ro` (read-only), but the container's entrypoint script copies the config file to that location at startup.

**Fix**: Removed `:ro` flag from the `wdqs-custom-config.prod.json` mount.

### 6c. Certbot "Timeout during connect"

**Symptom**: `certbot --nginx` failed with `Timeout during connect (likely firewall problem)`.

**Cause**: Hetzner Cloud Firewall (separate from the VM's UFW) was blocking inbound ports 80 and 443.

**Fix**: Opened TCP ports 22, 80, and 443 in the Hetzner Cloud Console firewall settings.

## 7. SSL Certificate Obtained

```
certbot --nginx -d dev-climatekg.semanticclimate.org --non-interactive --agree-tos -m simon.worthington@tib.eu
```

- Certificate saved at `/etc/letsencrypt/live/dev-climatekg.semanticclimate.org/`
- Expires: 8 July 2026
- Auto-renewal configured via systemd timer

## 8. Sitelinks Configuration for Production

All steps from `deployment-guide.md` were completed:

| Step | Status | Detail |
|------|--------|--------|
| Update `sites.xml` with domain + HTTPS | Done | `sites.prod.xml` uses `https://dev-climatekg.semanticclimate.org` |
| Re-run `init-sitelinks.sh` | Done | Init container exited (0); `mywiki` registered in sites table with `site_language=en`, `site_group=mywiki` |
| Update `docker-compose.yml` env vars | Done | `docker-compose.prod.yml` sets `MW_WG_SERVER`, `WIKIBASE_CONCEPT_URI`, `WDQS_PUBLIC_URL` etc. |
| Configure SSL certificates | Done | Let's Encrypt via Certbot |
| Restart all containers | Done | All 5 containers healthy |

### Sitelinks configuration files:

- **`sites.prod.xml`**: Defines the `mywiki` site with production URLs
- **`LocalSettings.sitelinks.php`**: Sets `siteLinkGroups` to `['mywiki']`, `siteGlobalID` to `'mywiki'`, and `repoUrl` to `$wgServer` (dynamic)
- **`WikibaseSitelinksMessages.php`**: i18n label "Local wiki" for the sitelink group heading

### Outstanding sitelinks issue:

When using `Special:SetSiteLink` on the live site, entering `mywiki` as the Site value returns:
> *The site ID "mywiki" is unknown. Please use an existing site ID, such as "enwiki".*

The sites table confirms `mywiki` is in the database. Investigation is ongoing — likely requires a container restart or cache clear for Wikibase to pick up the newly imported site.

## 9. Final Deployment State

### Container Status (all healthy)

| Container | Status |
|-----------|--------|
| wikibase | Up (healthy) |
| wikibase-mariadb | Up (healthy) |
| wikibase-wdqs | Up (healthy) |
| wikibase-wdqs-frontend | Up (healthy) |
| wikibase-wdqs-updater | Up |

### URLs

| Service | URL | Status |
|---------|-----|--------|
| Wiki | https://dev-climatekg.semanticclimate.org/wiki/Main_Page | 200 OK |
| Query UI | https://dev-climatekg.semanticclimate.org/query/ | 200 OK |
| SPARQL endpoint | https://dev-climatekg.semanticclimate.org/query/proxy/sparql | 200 OK |
| Admin login | https://dev-climatekg.semanticclimate.org/wiki/Special:UserLogin | — |

### Architecture

```
Browser → Nginx (443/SSL) → 127.0.0.1:8080  (Wikibase/MediaWiki)
                           → 127.0.0.1:8081  (WDQS Frontend at /query/)
                           → 127.0.0.1:9999  (Blazegraph SPARQL at /query/proxy/sparql)
```

### Credentials (stored in `/opt/wikibase/.env` on server)

- **Admin user**: `admin`
- **Admin password**: `B7diYv1qlz4VdsqQ6rBNF3bPPS2XEq2R`
- **DB password**: `AOti5qI4vQ55t7RtOggSOhICh20NbO2`

### Production compose command

```bash
cd /opt/wikibase
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```
