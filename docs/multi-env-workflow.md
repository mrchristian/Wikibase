# Multi-Environment Workflow — ClimateKG Wikibase

This document is the master reference for the 4-tier Docker DevOps workflow.

---

## 1. Environment Overview

| Env   | Server IP        | Domain                                   | Purpose                                      |
|-------|-----------------|------------------------------------------|----------------------------------------------|
| LOCAL | workstation     | localhost:8080                           | Configuration development using GitHub forks |
| DEV   | 178.104.156.88  | dev-climatekg.semanticclimate.org        | Live content editing; source of truth for DB |
| TEST  | 46.224.66.24    | test-climatekg.semanticclimate.org       | Staging; validating DB + code before PROD    |
| PROD  | 178.105.222.174 | prod-climatekg.semanticclimate.org       | Public production instance                   |

---

## 2. Source of Truth

| What          | Where                        | Notes                                                      |
|---------------|------------------------------|------------------------------------------------------------|
| Code / config | GitHub `master` branch       | Fed by fork PRs from LOCAL; servers `git pull` on demand   |
| Database      | DEV server                   | Content is edited on DEV, then promoted upward             |

---

## 3. Git Workflow (Code Changes)

```
LOCAL fork  →  PR to master  →  manual git pull on each server  →  redeploy
```

1. **LOCAL**: Create a GitHub fork. Make configuration changes (compose files, LocalSettings, etc.).
2. Open a **Pull Request** against `mrchristian/Wikibase` on `master`.
3. After merge, SSH to each server and `git pull`:
   ```sh
   ssh root@<server-ip>
   cd /opt/wikibase
   git pull --ff-only
   docker compose -f docker-compose.yml -f docker-compose.<env>.yml up -d --build
   ```

---

## 4. DB Promotion Flow (Content Changes)

Content is edited on DEV and flows upward:

```
DEV  →  (validate)  →  TEST  →  (approve)  →  PROD
```

### DEV → TEST

```powershell
.\scripts\sync\sync-dev-to-test.ps1
```

### DEV → PROD

```powershell
.\scripts\sync\sync-dev-to-prod.ps1
```

> **Note**: `sync-dev-to-prod.ps1` requires typing `PROMOTE` at the confirmation prompt to prevent accidental overwrites.

### LOCAL ← DEV  (pull DEV content to LOCAL for testing)

```powershell
.\scripts\sync\pull-from-dev.ps1
```

---

## 5. Compose Commands Quick Reference

### LOCAL

```powershell
# Auto-loads docker-compose.override.yml — exposes ports 8080, 9999, 8081
docker compose up -d
```

### DEV  (on 178.104.156.88)

```sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

### TEST  (on 46.224.66.24)

```sh
docker compose -f docker-compose.yml -f docker-compose.test.yml up -d
```

### PROD  (on 178.105.222.174)

```sh
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

---

## 6. Full Server Build (fresh Ubuntu OS)

Run once from LOCAL to bootstrap a brand-new server:

```sh
# DEV (already built — use only to rebuild)
cat scripts/deploy/deploy-dev.sh scripts/deploy/deploy.sh | ssh root@178.104.156.88 'bash -s'

# TEST (new server)
cat scripts/deploy/deploy-test.sh scripts/deploy/deploy.sh | ssh root@46.224.66.24 'bash -s'

# PROD (new server)
cat scripts/deploy/deploy-prod.sh scripts/deploy/deploy.sh | ssh root@178.105.222.174 'bash -s'
```

> **Why `cat ... | ssh 'bash -s'` and not `ssh 'bash -s' < wrapper.sh`?**
> When a single script is piped to `bash -s`, `BASH_SOURCE[0]` is empty so the wrapper cannot locate `deploy.sh` on the remote server (it hasn't been cloned yet). Concatenating both files into the pipe means `deploy.sh` content flows inline immediately after the wrapper sets its variables.

Each deploy script:
1. Updates the OS and installs Docker, Nginx, Certbot
2. Clones the repo to `/opt/wikibase`
3. Creates `/opt/wikibase/.env` from the matching env template with auto-generated passwords
4. Configures Nginx reverse proxy for that domain
5. Configures UFW firewall (ports 22, 80, 443)
6. Starts the Docker stack
7. Prints the Certbot command to obtain SSL

### After deploy: obtain SSL

```sh
certbot --nginx -d <domain> --non-interactive --agree-tos -m simon.worthington@tib.eu
```

---

## 7. Compose & Config Files per Environment

| File                           | Used by      |
|-------------------------------|--------------|
| `docker-compose.yml`           | All envs (base) |
| `docker-compose.override.yml`  | LOCAL (auto) |
| `docker-compose.dev.yml`       | DEV          |
| `docker-compose.test.yml`      | TEST         |
| `docker-compose.prod.yml`      | PROD         |
| `sites.xml`                    | LOCAL sitelinks |
| `sites.dev.xml`                | DEV sitelinks |
| `sites.test.xml`               | TEST sitelinks |
| `sites.prod.xml`               | PROD sitelinks |
| `wdqs-custom-config.json`      | LOCAL query UI |
| `wdqs-custom-config.dev.json`  | DEV query UI |
| `wdqs-custom-config.test.json` | TEST query UI |
| `wdqs-custom-config.prod.json` | PROD query UI |
| `.env.dev.template`            | DEV .env seed |
| `.env.test.template`           | TEST .env seed |
| `.env.production`              | PROD .env seed |

---

## 8. SSH Key Setup (Windows — one-time)

All sync and deploy scripts use a dedicated passphrase-free key `id_wikibase_sync`. Set it up once:

```powershell
# Generate key (if not already done)
ssh-keygen -t ed25519 -f C:\Users\<user>\.ssh\id_wikibase_sync -N ""

# Copy public key to each server
type C:\Users\<user>\.ssh\id_wikibase_sync.pub | ssh root@178.104.156.88 "cat >> ~/.ssh/authorized_keys"
type C:\Users\<user>\.ssh\id_wikibase_sync.pub | ssh root@46.224.66.24 "cat >> ~/.ssh/authorized_keys"
type C:\Users\<user>\.ssh\id_wikibase_sync.pub | ssh root@178.105.222.174 "cat >> ~/.ssh/authorized_keys"

# Enable SSH agent (Administrator PowerShell — one-time)
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service ssh-agent
ssh-add C:\Users\<user>\.ssh\id_wikibase_sync
```

---

## 9. .env Password Variables

Add these to `C:\Wikibase\.env` (gitignored) so sync scripts can read them non-interactively:

```
DEV_DB_PASS=<dev-mariadb-password>
TEST_DB_PASS=<test-mariadb-password>
PROD_DB_PASS=<prod-mariadb-password>
```

The actual passwords are stored in `/opt/wikibase/.env` on each server (printed once during initial deploy).

---

## 10. Verification Checklist

After deploying or syncing an environment, verify:

- [ ] Wiki responds at `https://<domain>/wiki/Main_Page` (200 OK)
- [ ] Query UI responds at `https://<domain>/query/` (200 OK)
- [ ] SPARQL endpoint responds at `https://<domain>/query/proxy/sparql` (200 OK)
- [ ] All 5 containers healthy: `docker compose ps` → all `healthy` or `running`
- [ ] Sitelinks: visit `Special:Sites` — `mywiki` registered with correct domain URLs
- [ ] SSL certificate valid (green padlock in browser)
