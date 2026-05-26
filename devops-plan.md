# Plan: 4-Tier Docker DevOps Workflow (LOCAL / DEV / TEST / PROD)

> **Documentation hierarchy**
> | Doc | Role |
> |---|---|
> | [`docs/multi-env-workflow.md`](docs/multi-env-workflow.md) | **Master reference** — how to operate all environments, run scripts, promote content |
> | **`devops-plan.md`** (this file) | Planning log — itemised task list, design decisions, build rationale |
> | `docs/deployment-protocol.md` | Historical deployment log; server registry |
> | `docs/hetzner-deploy-guide.md` | One-time server provisioning on Hetzner |
> | `docs/sync-guide.md` | Background reference — sync strategy options (context only) |
> | Sync scripts | [`sync-local-to-test.ps1`](scripts/sync/sync-local-to-test.ps1) · [`sync-dev-to-test.ps1`](scripts/sync/sync-dev-to-test.ps1) · [`sync-dev-to-prod.ps1`](scripts/sync/sync-dev-to-prod.ps1) · [`pull-from-dev.ps1`](scripts/sync/pull-from-dev.ps1) |
> | Deploy scripts | [`deploy.sh`](scripts/deploy/deploy.sh) · [`deploy-dev.sh`](scripts/deploy/deploy-dev.sh) · [`deploy-test.sh`](scripts/deploy/deploy-test.sh) · [`deploy-prod.sh`](scripts/deploy/deploy-prod.sh) |

## Environment Map

| Env   | Server IP        | Domain                                   | Compose override file         | Status                                  |
|-------|-----------------|------------------------------------------|-------------------------------|-----------------------------------------|
| LOCAL | workstation     | localhost:8080                           | docker-compose.override.yml   | Unchanged                               |
| DEV   | 178.104.156.88  | dev-climatekg.semanticclimate.org        | docker-compose.dev.yml (new)  | Existing server — reassigned from PROD  |
| TEST  | 46.224.66.24    | test-climatekg.semanticclimate.org       | docker-compose.test.yml (new) | Re-provisioned fresh Ubuntu OS — full build from scratch |
| PROD  | 178.105.222.174 | prod-climatekg.semanticclimate.org       | docker-compose.prod.yml (upd) | New server, full build from scratch     |

---

## Phase 1 — Docker Compose & Config Files (LOCAL repo changes)

### New files to create

1. `docker-compose.dev.yml` — copy of current `docker-compose.prod.yml` logic; domain already correct (`dev-climatekg`); references new `sites.dev.xml` and `wdqs-custom-config.dev.json`
2. `docker-compose.test.yml` — same structure, domain = `test-climatekg.semanticclimate.org`; references `sites.test.xml` and `wdqs-custom-config.test.json`
3. `sites.dev.xml` — copy of current `sites.prod.xml` (domain already correct)
4. `sites.test.xml` — same structure, domain = `test-climatekg.semanticclimate.org`
5. `wdqs-custom-config.dev.json` — copy of current `wdqs-custom-config.prod.json` (domain already correct)
6. `wdqs-custom-config.test.json` — same structure, domain = `test-climatekg.semanticclimate.org`
7. `.env.dev.template` — copy of `.env.production`, `WIKIBASE_DOMAIN=dev-climatekg.semanticclimate.org`
8. `.env.test.template` — same, `WIKIBASE_DOMAIN=test-climatekg.semanticclimate.org`

### Files to modify

9.  `docker-compose.prod.yml` — update all domain env vars to `prod-climatekg.semanticclimate.org`
10. `sites.prod.xml` — change domain to `prod-climatekg.semanticclimate.org` (currently points to dev domain)
11. `wdqs-custom-config.prod.json` — update wikibase URI to `prod-climatekg.semanticclimate.org`
12. `.env.production` — set `WIKIBASE_DOMAIN=prod-climatekg.semanticclimate.org`

---

## Phase 2 — Deploy Scripts

13. **Refactor** `scripts/deploy/deploy.sh` — replace all hardcoded domain/compose-file/env-template values with variables (`WIKIBASE_DOMAIN`, `WIKIBASE_ENV`, `COMPOSE_FILE`, `ENV_TEMPLATE`); Nginx heredoc, Docker Compose command, and `.env` template selection all driven by those vars
14. **Create** `scripts/deploy/deploy-dev.sh` — thin wrapper: sets DEV vars, calls `deploy.sh`
15. **Create** `scripts/deploy/deploy-test.sh` — thin wrapper: TEST vars
16. **Create** `scripts/deploy/deploy-prod.sh` — thin wrapper: PROD vars

Invocation pattern (same as today):
```sh
ssh root@<ip> 'bash -s' < scripts/deploy/deploy-test.sh
```

---

## Phase 3 — Sync Scripts (DB promotion: DEV → TEST → PROD)

All run from LOCAL Windows workstation. Follow the proven `mysqldump --result-file` + `docker cp` + `mysql source` pattern (avoids PowerShell UTF-16LE corruption).

17. **Create** `scripts/sync/sync-dev-to-test.ps1` ✅ (DB promotion from DEV)
    - SSH → DEV: `mysqldump --result-file` inside container, `docker cp` to host
    - `scp` to LOCAL `backups/`, size-verify (>100 MB)
    - `scp` to TEST host, SSH → TEST: `docker cp`, `mysql source`, `TRUNCATE objectcache; TRUNCATE l10n_cache;`, `run.php update --quick`, restart containers

17a. **Create** `scripts/sync/sync-local-to-test.ps1` ✅ (DB + files + LocalSettings from LOCAL)
    - Dumps LOCAL MariaDB using `docker exec ... mysqldump --result-file` inside container (avoids PowerShell UTF-16LE character-map corruption)
    - `docker cp` to LOCAL Windows host, size-verify, `scp` to TEST host
    - Import on TEST via `docker cp` + `mysql source` inside container (no PS stream)
    - `TRUNCATE objectcache; TRUNCATE l10n_cache;` (clears LOCAL domain URLs)
    - Resets MediaWiki Admin password to `TEST_MW_ADMIN_PASS` from `C:\Wikibase\.env` using `run.php changePassword`
    - `run.php update --quick` + `rebuildrecentchanges`
    - Syncs uploads/images: `tar --exclude=thumb` inside LOCAL container → `docker cp` → `scp` → extract inside TEST container via `--strip-components=3`
    - `git pull origin master` on TEST to update LocalSettings bind-mount files
    - Restarts `wikibase-sitelinks-init` (15 s) then `wikibase`
    - Required `.env` keys: `TEST_DB_PASS`, `TEST_MW_ADMIN_PASS`
18. **Create** `scripts/sync/sync-dev-to-prod.ps1` — same pattern targeting PROD server
19. **Rename** `scripts/sync/pull-from-production.ps1` → `pull-from-dev.ps1` — update header comments; no logic changes (server IP is unchanged at 178.104.156.88)

---

## Phase 4 — Documentation

20. **Create** `docs/multi-env-workflow.md` — master reference:
    - Environment table (all 4 tiers, IPs, domains, compose commands)
    - Git workflow: fork → PR → master → manual `git pull` + redeploy on each server
    - DB promotion flow: DEV edits → `sync-dev-to-test.ps1` → validate → `sync-dev-to-prod.ps1`
    - Quick-reference compose commands per environment
21. **Update** `docs/deployment-protocol.md` — add new server table; note existing server reassignment from PROD → DEV

---

## Verification Plan

1. **DEV** — push Phase 1 changes → SSH to 178.104.156.88: `git pull` then `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d` → confirm wiki at `https://dev-climatekg.semanticclimate.org`
2. **TEST** — `cat scripts/deploy/deploy-test.sh scripts/deploy/deploy.sh | ssh root@46.224.66.24 'bash -s'` → all 5 containers healthy; SSL via Certbot; wiki at `https://test-climatekg.semanticclimate.org`
3. **PROD** — `cat scripts/deploy/deploy-prod.sh scripts/deploy/deploy.sh | ssh root@178.105.222.174 'bash -s'` → same verification at `https://prod-climatekg.semanticclimate.org`
4. **Sync** — run `scripts/sync/sync-dev-to-test.ps1` → confirm TEST wiki shows DEV content
5. **Git workflow** — create LOCAL fork PR → merge to master → `git pull` on DEV → redeploy → confirms code promotion path

---

## Key Design Decisions

- **No CI/CD** — all promotion is manual one-command scripts
- **Code source of truth**: GitHub `master` (fed by fork PRs); servers `git pull` on demand
- **Content source of truth**: DEV database; promoted upward via sync scripts (`DEV → TEST → PROD`)
- Current `docker-compose.prod.yml` is being *split*: its existing DEV-domain logic moves to `docker-compose.dev.yml`; `prod.yml` is updated for the new PROD server
- Existing Docker volumes on DEV are untouched — all current content preserved
- `pull-from-dev.ps1` (renamed from `pull-from-production.ps1`) remains valid for `LOCAL ← DEV` sync; no logic changes as the server IP is unchanged
