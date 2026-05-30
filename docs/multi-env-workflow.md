# Multi-Environment Workflow — ClimateKG Wikibase

> **Documentation hierarchy**
> | Doc | Role |
> |---|---|
> | **`docs/multi-env-workflow.md`** (this file) | **Master reference** — how to operate all environments, run scripts, promote content |
> | `devops-plan.md` | Planning log — itemised task list, design decisions, build rationale |
> | `docs/deployment-protocol.md` | Historical deployment log; server registry |
> | `docs/hetzner-deploy-guide.md` | One-time server provisioning on Hetzner |
> | `docs/server-admin.md` | Server resource management — disk, Docker logs, maintenance |
> | `docs/sync-guide.md` | Background reference — sync strategy options (context only) |
> | Sync scripts — see §4 | [`sync-local-to-dev.ps1`](../scripts/sync/sync-local-to-dev.ps1) · [`sync-local-to-test.ps1`](../scripts/sync/sync-local-to-test.ps1) · [`sync-dev-to-test.ps1`](../scripts/sync/sync-dev-to-test.ps1) · [`sync-dev-to-prod.ps1`](../scripts/sync/sync-dev-to-prod.ps1) · [`sync-test-to-prod.ps1`](../scripts/sync/sync-test-to-prod.ps1) · [`pull-from-dev.ps1`](../scripts/sync/pull-from-dev.ps1) |
> | Experimental workflow — see §11 | [`experimental-import-workflow.ps1`](../scripts/experimental-import-workflow.ps1) |
> | Backup scripts — see §12 | [`backup-local-db.ps1`](../scripts/backup/backup-local-db.ps1) |
> | Deploy scripts — see §6 | [`deploy.sh`](../scripts/deploy/deploy.sh) · [`deploy-dev.sh`](../scripts/deploy/deploy-dev.sh) · [`deploy-test.sh`](../scripts/deploy/deploy-test.sh) · [`deploy-prod.sh`](../scripts/deploy/deploy-prod.sh) |

This document is the master reference for the 4-tier Docker DevOps workflow.

---

## Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CLIMATEKG DEVOPS WORKFLOW                          │
└─────────────────────────────────────────────────────────────────────────────┘

CODE/CONFIG FLOW (via GitHub):
┌──────────────┐
│   LOCAL      │  1. Fork repo, make changes
│ (workstation)│  2. Create PR to master
└──────┬───────┘
       │ PR
       ↓
┌──────────────┐
│   GitHub     │  Master branch = source of truth
│   master     │
└──┬───┬───┬───┘
   │   │   │ git pull (manual on each server)
   ↓   ↓   ↓
┌──────┐ ┌──────┐ ┌──────┐
│ DEV  │ │ TEST │ │ PROD │  Redeploy with docker compose up -d --build
└──────┘ └──────┘ └──────┘

DATABASE/CONTENT FLOW (via sync scripts):
┌──────────────┐                    ┌──────────────┐
│   LOCAL      │◄───pull-from-dev───│     DEV      │  DEV = DB source of truth
│ (workstation)│                    │ (178...88)   │  Content edited here
└──────┬───────┘                    └──────┬───────┘
       │                                   │
       │ sync-local-to-test                │ sync-dev-to-test
       │ (staging from local)              │ (standard promotion)
       │                                   │
       ↓                                   ↓
   ┌──────────────┐                  ┌──────────────┐
   │    TEST      │──────────────────│    TEST      │
   │ (46...24)    │  (same target)   │ (46...24)    │
   └──────────────┘                  └──────┬───────┘
                                            │
                                            │ sync-dev-to-prod  (or sync-test-to-prod)
                                            │
                                            ↓
                                       ┌──────────────┐
                                       │    PROD      │  Public instance
                                       │ (178...174)  │
                                       └──────────────┘

EXPERIMENTAL WORKFLOW (LOCAL only):
┌─────────────────────────────────────────────────────┐
│  LOCAL DATABASE STATES                              │
│                                                     │
│  ┌─────────────┐          start (snapshot)          │
│  │   CLEAN     │─────────────────────────┐          │
│  │ (DEV sync)  │                         │          │
│  └─────┬───────┘                         ↓          │
│        ↑                          ┌──────────────┐  │
│        │                          │EXPERIMENTAL  │  │
│        │                          │ (+ imports)  │  │
│        │                          └──────┬───────┘  │
│        │                                 │          │
│        │ rollback                        │ approve  │
│        └─────────────────────────────────┘          │
│                                                     │
│  sync (pull-from-dev) only allowed when CLEAN       │
└─────────────────────────────────────────────────────┘

SERVICES & PORTS:
LOCAL:     8080 (wiki) | 8081 (query UI) | 9999 (SPARQL)
REMOTE:    443/HTTPS for all services (wiki at /, query at /query/)
```

---

## 1. Environment Overview

| Env   | Server IP        | Domain                                   | Purpose                                      |
|-------|-----------------|------------------------------------------|----------------------------------------------|
| LOCAL | workstation     | localhost:8080                           | Config development; experimental data imports (with snapshot/rollback) |
| DEV   | 178.104.156.88  | dev-climatekg.semanticclimate.org        | Live content editing; source of truth for DB |
| TEST  | 46.224.66.24    | test-climatekg.semanticclimate.org       | Staging; validating DB + code before PROD    |
| PROD  | 178.105.222.174 | prod-climatekg.semanticclimate.org       | Public production instance                   |

### Port Configuration

| Service       | LOCAL Port | Remote (DEV/TEST/PROD) |
|---------------|------------|------------------------|
| Wiki          | 8080       | 443 (HTTPS)            |
| Query UI      | 8081       | 443 (HTTPS at /query/) |
| WDQS/SPARQL   | 9999       | 443 (HTTPS at /query/proxy/sparql) |

**LOCAL URLs:**
- Wiki: http://localhost:8080
- Query UI: http://localhost:8081
- SPARQL: http://localhost:9999

**Remote URLs (example for DEV):**
- Wiki: https://dev-climatekg.semanticclimate.org
- Query UI: https://dev-climatekg.semanticclimate.org/query/
- SPARQL: https://dev-climatekg.semanticclimate.org/query/proxy/sparql

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
   git pull 
   --ff-only
   docker compose -f docker-compose.yml -f docker-compose.<env>.yml up -d --build
   ```

---

## 4. DB Promotion Flow (Content Changes)

Content is edited on DEV and flows upward, or LOCAL can push directly to TEST for staging:

```
LOCAL  →  TEST  (immediate staging from local)
DEV    →  TEST  →  PROD  (standard promotion path)
```

### LOCAL → DEV  (push local DB + files + LocalSettings to DEV)

> **Use case**: promoting content created or bulk-imported locally (e.g. a data import tested via the experimental workflow) back to DEV as the new source of truth.

```powershell
# Full sync (DB + images + git pull + container restart):
.\scripts\sync\sync-local-to-dev.ps1

# DB + git pull + restart only (skip images — faster when only data changed):
.\scripts\sync\sync-local-to-dev.ps1 -DbOnly
```
> Script: [scripts/sync/sync-local-to-dev.ps1](../scripts/sync/sync-local-to-dev.ps1)
> **Note**: requires typing `PROMOTE` at the confirmation prompt — DEV is the DB source of truth.

Required entries in `C:\Wikibase\.env`:
```
DEV_DB_PASS=<dev-mariadb-password>
DEV_MW_ADMIN_PASS=<dev-mediawiki-admin-password>
```

### LOCAL → TEST  (push local DB + files + LocalSettings to TEST)

```powershell
# Full sync (DB + images + git pull + container restart):
.\scripts\sync\sync-local-to-test.ps1

# DB + git pull + restart only (skip images):
.\scripts\sync\sync-local-to-test.ps1 -DbOnly
```
> Script: [scripts/sync/sync-local-to-test.ps1](../scripts/sync/sync-local-to-test.ps1)

Covers: database dump (395 MB, `--result-file` pattern), uploads/images (unless `-DbOnly`), `git pull` of LocalSettings on TEST, Admin password reset to `TEST_MW_ADMIN_PASS`, cache flush, `run.php update`, container restart.

Required entries in `C:\Wikibase\.env`:
```
TEST_DB_PASS=<test-mariadb-password>
TEST_MW_ADMIN_PASS=<test-mediawiki-admin-password>
```

### DEV → TEST

```powershell
.\scripts\sync\sync-dev-to-test.ps1
```
> Script: [scripts/sync/sync-dev-to-test.ps1](../scripts/sync/sync-dev-to-test.ps1)

### DEV → PROD  (DB)

```powershell
.\scripts\sync\sync-dev-to-prod.ps1
```
> Script: [scripts/sync/sync-dev-to-prod.ps1](../scripts/sync/sync-dev-to-prod.ps1)
> **Note**: requires typing `PROMOTE` at the confirmation prompt to prevent accidental overwrites.

### TEST → PROD  (DB)

> **Use case**: promoting staged content directly from TEST to PROD when TEST is the validated source (e.g. after a bulk import was reviewed on TEST).

```powershell
.\scripts\sync\sync-test-to-prod.ps1
```
> Script: [scripts/sync/sync-test-to-prod.ps1](../scripts/sync/sync-test-to-prod.ps1)
> **Note**: requires typing `PROMOTE` at the confirmation prompt to prevent accidental overwrites.

Required entries in `C:\Wikibase\.env`:
```
TEST_DB_PASS=<test-mariadb-password>
PROD_DB_PASS=<prod-mariadb-password>
PROD_MW_ADMIN_PASS=<prod-mediawiki-admin-password>
```

### DEV → PROD  (uploads/images only)

```powershell
.\scripts\sync\sync-dev-to-prod-files.ps1
```
> Script: [scripts/sync/sync-dev-to-prod-files.ps1](../scripts/sync/sync-dev-to-prod-files.ps1)
> **Note**: also requires `PROMOTE` confirmation.

### DEV → LOCAL  (pull DEV DB to LOCAL for testing)

```powershell
.\scripts\sync\pull-from-dev.ps1
```
> Script: [scripts/sync/pull-from-dev.ps1](../scripts/sync/pull-from-dev.ps1)
> **Note**: DB only — no `-DbOnly` flag needed. Uploads/images are not copied.

---

## 5. Compose Commands Quick Reference

### LOCAL

```powershell
# Auto-loads docker-compose.override.yml
# Exposes: 8080 (wiki), 9999 (SPARQL), 8081 (query UI)
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

Scripts: [deploy.sh](../scripts/deploy/deploy.sh) · [deploy-dev.sh](../scripts/deploy/deploy-dev.sh) · [deploy-test.sh](../scripts/deploy/deploy-test.sh) · [deploy-prod.sh](../scripts/deploy/deploy-prod.sh)

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

| File                           | Used by         |
|--------------------------------|-----------------|
| `docker-compose.yml`           | All envs (base) |
| `docker-compose.override.yml`  | LOCAL (auto)    |
| `docker-compose.dev.yml`       | DEV             |
| `docker-compose.test.yml`      | TEST            |
| `docker-compose.prod.yml`      | PROD            |
| `sites.xml`                    | LOCAL sitelinks |
| `sites.dev.xml`                | DEV sitelinks   |
| `sites.test.xml`               | TEST sitelinks  |
| `sites.prod.xml`               | PROD sitelinks  |
| `wdqs-custom-config.json`      | LOCAL query UI  |
| `wdqs-custom-config.dev.json`  | DEV query UI    |
| `wdqs-custom-config.test.json` | TEST query UI   |
| `wdqs-custom-config.prod.json` | PROD query UI   |
| `.env.dev.template`            | DEV .env seed   |
| `.env.test.template`           | TEST .env seed  |
| `.env.production`              | PROD .env seed  |

---

## 8. SSH Key Setup (Windows — one-time)

SSH key setup instructions are stored in `.ssh-setup.md` (gitignored for security).

Quick summary:
1. Generate key: `ssh-keygen -t ed25519 -f C:\Users\<user>\.ssh\id_wikibase_sync -N ""`
2. Copy public key to all servers
3. Enable SSH agent and add key

See `.ssh-setup.md` in the repository root for complete instructions.

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

**For LOCAL (localhost):**
- [ ] Wiki responds at http://localhost:8080/wiki/Main_Page (200 OK)
- [ ] Query UI responds at http://localhost:8081 (200 OK)
- [ ] SPARQL endpoint responds at http://localhost:9999/bigdata/namespace/wdq/sparql (200 OK)
- [ ] All 5 containers healthy: `docker compose ps` → all `healthy` or `running`
- [ ] Sitelinks: visit http://localhost:8080/wiki/Special:Sites — `climatekg-wiki` registered

**For remote environments (DEV/TEST/PROD):**
- [ ] Wiki responds at `https://<domain>/wiki/Main_Page` (200 OK)
- [ ] Query UI responds at `https://<domain>/query/` (200 OK)
- [ ] SPARQL endpoint responds at `https://<domain>/query/proxy/sparql` (200 OK)
- [ ] All 5 containers healthy: `docker compose ps` → all `healthy` or `running`
- [ ] Sitelinks: visit `Special:Sites` — `climatekg-wiki` registered with correct domain URLs
- [ ] SSL certificate valid (green padlock in browser)

---

## 11. Experimental Import Workflow (LOCAL)

When testing new data imports or reviewing Wikibase items before committing to production, use the experimental workflow to safely test changes without affecting your clean LOCAL database.

### Workflow States

Your LOCAL database can be in one of two states:

| State | Description | Actions Available |
|-------|-------------|-------------------|
| **CLEAN** | Pure DEV data or approved experiments | Start new experiment, sync from DEV |
| **EXPERIMENTAL** | Has unapproved experimental changes | Review → approve or rollback |

### Basic Workflow

**1. Check current state:**
```powershell
.\scripts\experimental-import-workflow.ps1 status
```

**2. Start an experiment:**
```powershell
# Creates snapshot of current CLEAN state
.\scripts\experimental-import-workflow.ps1 start
```

**3. Run your experimental imports:**
```powershell
# Your import scripts here
.\scripts\import\your-import-script.ps1
```

**4. Review at http://localhost:8080**

**5. Decide:**

**If approved:**
```powershell
.\scripts\experimental-import-workflow.ps1 approve
# Experimental changes become the new clean base
```

**If rejected:**
```powershell
.\scripts\experimental-import-workflow.ps1 rollback
# Discards all experimental changes, restores clean base
```

### Syncing from DEV

**Pull fresh DEV data (only when CLEAN):**
```powershell
.\scripts\experimental-import-workflow.ps1 sync
# Wrapper around pull-from-dev.ps1 with state tracking
```

> **Important**: Cannot sync from DEV while in EXPERIMENTAL state. Must approve or rollback first.

### Common Scenarios

**Scenario 1: Simple experiment**
```powershell
.\scripts\experimental-import-workflow.ps1 start
.\scripts\import\my-import.ps1
# Review in browser
.\scripts\experimental-import-workflow.ps1 approve
```

**Scenario 2: Failed experiment, try again**
```powershell
.\scripts\experimental-import-workflow.ps1 start
.\scripts\import\my-import.ps1
# Data looks wrong
.\scripts\experimental-import-workflow.ps1 rollback
# Fix your import script
.\scripts\experimental-import-workflow.ps1 start
.\scripts\import\my-import.ps1
# Now it looks good
.\scripts\experimental-import-workflow.ps1 approve
```

**Scenario 3: Need fresh DEV data mid-experiment**
```powershell
.\scripts\experimental-import-workflow.ps1 start
.\scripts\import\my-import.ps1
# Wait, DEV was updated with new content I need
.\scripts\experimental-import-workflow.ps1 rollback
.\scripts\experimental-import-workflow.ps1 sync
# Now re-run experiment on fresh DEV base
.\scripts\experimental-import-workflow.ps1 start
.\scripts\import\my-import.ps1
.\scripts\experimental-import-workflow.ps1 approve
```

### Key Rules

1. **Only sync from DEV when CLEAN** — Never pull DEV updates while mid-experiment
2. **Always snapshot before experiments** — Use `start` to create a rollback point
3. **Approve or rollback before syncing** — Finish one experiment before starting another
4. **Track your state** — Use `status` to see where you are

### State Management

State is tracked in `C:\Wikibase\backups\.workflow_state.json`:
- Current workflow state (CLEAN or EXPERIMENTAL)
- Last DEV sync timestamp
- Last state change timestamp

Snapshots are stored in `C:\Wikibase\backups\`:
- `experimental_snapshot.sql` — Active rollback point
- `approved_experiment_YYYYMMDD_HHMMSS.sql` — Archived approved snapshots

---

## 12. Backup Strategy

### Taking a local backup

Run [`backup-local-db.ps1`](../scripts/backup/backup-local-db.ps1) from `C:\Wikibase` to dump the local MariaDB database to a timestamped `.sql` file in `C:\Wikibase\backups\`:

```powershell
.\scripts\backup\backup-local-db.ps1
```

Outputs `mw_db_YYYYMMDD_HHMMSS.sql`. See [`backups/README.md`](../backups/README.md) for full backup guide (DB + filesystem + config files).

### What is already covered

| Asset | How it is backed up |
|-------|---------------------|
| Config / scripts / docs | GitHub (`mrchristian/Wikibase` `master`) — push after every change |
| Database (authoritative) | DEV server — Hetzner infrastructure; supplemented by SQL dumps in `C:\Wikibase\backups\` |
| Database (point-in-time) | [`backup-local-db.ps1`](../scripts/backup/backup-local-db.ps1) and `pull-from-dev.ps1` write timestamped `.sql` files to `C:\Wikibase\backups\` |
| Experimental snapshots | `C:\Wikibase\backups\approved_experiment_*.sql` (created by experimental workflow) |

### Gitignored items that need separate backup

The following are excluded from the GitHub repo and must be backed up independently:

| Item | Why gitignored | Recommended backup |
|------|---------------|--------------------|
| `C:\Wikibase\.env` | Contains passwords | Store key/value pairs in a password manager (Bitwarden, KeePass, etc.) |
| `C:\Wikibase\backups\*.sql` | Large binary files | Enable cloud sync on `C:\Wikibase\backups\` (e.g. OneDrive) |
| Uploads / images | Large binaries | DEV server is authoritative; `sync-local-to-dev.ps1` keeps DEV current |
| `data-import/` | Large data files | Keep source files in their own repo or cloud storage |
| `.ssh-setup.md` | Security | Copy to password manager or encrypted notes |

### Minimum backup checklist

- [ ] All config changes pushed to GitHub (`git push` / PR merged)
- [ ] `C:\Wikibase\.env` passwords recorded in password manager
- [ ] `C:\Wikibase\backups\` folder synced to cloud storage (OneDrive or equivalent)
- [ ] SSH key `C:\Users\<user>\.ssh\id_wikibase_sync` backed up securely (or regeneratable — pub key is on servers)
