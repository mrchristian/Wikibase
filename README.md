# ClimateKG Deployment Repository (TIB-first)

This is a DevOps deployment repository for ClimateKG Wikibase.

```text
		     CLIMATEKG TIB INFRA (PRIMARY)

  Workstation/CI
	  |
	  v
  git.tib.eu (origin)
	  |
	  v
  DEV --------> TEST --------> PROD
   |             |              |
   v             v              v
 dev-climatekg  test-climatekg  climatekg
 .tibwiki.io    .tibwiki.io     .tibwiki.io

  IMPORT (disconnected clean sandbox)
     import-climatekg.tibwiki.io

  LOCAL experiment loop (workstation)
     CLEAN -> start -> EXPERIMENTAL -> approve/rollback -> CLEAN
```

This repository is the deployment and operations source for the Climate Knowledge Graph Wikibase stack, with the TIB infrastructure as the primary target.

Primary remote repository:
- https://git.tib.eu/OSL/climate-knowledge-graph/climatekg-deploy

Project governance files:
- License: [LICENSE](LICENSE)  
- Change history: [CHANGELOG.md](CHANGELOG.md)

This workspace can still keep GitHub as a backup mirror, but active deployment flow should be centered on the TIB repository.

## What this repository manages

- Docker Compose stack for Wikibase, MariaDB, WDQS, and WDQS frontend
- Environment-specific compose overlays and configuration
- Environment sync and migration scripts (PowerShell)
- Deployment scripts for server bootstrap and updates
- Validation and maintenance scripts

## Current operating model

The project currently runs with a parallel model:

- Legacy environments continue to run while new TIB environments are validated
- New TIB environments are the deployment focus and cutover target

New TIB domains:
- IMPORT: https://import-climatekg.tibwiki.io
- DEV: https://dev-climatekg.tibwiki.io
- TEST: https://test-climatekg.tibwiki.io
- PROD: https://climatekg.tibwiki.io

Full operational reference:
- docs/multi-env-workflow.md

## Repository structure (key files)

- docker-compose.yml
- docker-compose.override.yml
- docker-compose.dev.yml
- docker-compose.test.yml
- docker-compose.prod.yml
- docker-compose.import.yml
- scripts/deploy/deploy.sh
- scripts/deploy/deploy-dev-new.sh
- scripts/deploy/deploy-test-new.sh
- scripts/deploy/deploy-prod-new.sh
- scripts/deploy/deploy-import.sh
- scripts/sync/migrate-olddev-to-newdev.ps1
- scripts/sync/migrate-newdev-to-newtest.ps1
- scripts/sync/migrate-newtest-to-newprod.ps1
- scripts/verify-env-sync.ps1

## Quick start (local workstation)

Prerequisites:
- Docker Desktop for Windows
- PowerShell 5.1 or PowerShell 7+
- SSH access to TIB servers (for remote ops)

Start local stack:

```powershell
docker compose up -d
docker compose ps
```

Local endpoints:
- Wiki: http://localhost:8080
- Query UI: http://localhost:8081
- SPARQL: http://localhost:9999

Stop local stack:

```powershell
docker compose down
```

## TIB deployment workflow

### 1) Deploy or update a TIB environment

Run from the target host after repository update:

```bash
cd /opt/wikibase
bash scripts/deploy/deploy-dev-new.sh
bash scripts/deploy/deploy-test-new.sh
bash scripts/deploy/deploy-prod-new.sh
```

Use the script matching the target machine role.

IMPORT is intentionally separate from the main promotion chain and should be used as a clean sandbox for import testing:

```bash
cd /opt/wikibase
bash scripts/deploy/deploy-import.sh
```

### 2) Promote data through the new chain

```powershell
.\scripts\sync\migrate-olddev-to-newdev.ps1
.\scripts\sync\migrate-newdev-to-newtest.ps1
.\scripts\sync\migrate-newtest-to-newprod.ps1
```

### 3) Verify environment parity and health

```powershell
.\scripts\verify-env-sync.ps1
```

External checks:

```powershell
curl -I https://dev-climatekg.tibwiki.io/wiki/Main_Page
curl -I https://test-climatekg.tibwiki.io/wiki/Main_Page
curl -I https://climatekg.tibwiki.io/wiki/Main_Page
```

Separate IMPORT sandbox check:

```powershell
curl -I https://import-climatekg.tibwiki.io/wiki/Main_Page
```

### 4) Local experiment loop (import test cycle)

Use local workflow state tracking to test imports safely, then keep or discard changes:

```powershell
.\scripts\experimental-import-workflow.ps1 status
.\scripts\experimental-import-workflow.ps1 start
# run import scripts here
.\scripts\experimental-import-workflow.ps1 approve
# or rollback instead of approve:
.\scripts\experimental-import-workflow.ps1 rollback
```

## Git remotes (recommended)

Use TIB as origin and keep GitHub as backup mirror:

```bash
git remote -v
# origin  git@git.tib.eu:OSL/climate-knowledge-graph/climatekg-deploy.git
# github  https://github.com/mrchristian/Wikibase.git
```

If needed, set them explicitly:

```bash
git remote rename origin github
git remote add origin git@git.tib.eu:OSL/climate-knowledge-graph/climatekg-deploy.git
```

Push local main to remote master (current branch strategy):

```bash
git push -u origin main:master
```

## Environment sync scripts (legacy and parallel support)

These scripts remain available and documented because they are still used during the transition window:

- scripts/sync/sync-local-to-dev.ps1
- scripts/sync/sync-local-to-test.ps1
- scripts/sync/sync-dev-to-test.ps1
- scripts/sync/sync-dev-to-prod.ps1
- scripts/sync/sync-test-to-prod.ps1
- scripts/sync/pull-from-dev.ps1

Canonical details and guardrails:
- docs/multi-env-workflow.md

## Troubleshooting

### SSH works but git fetch/push fails

- Verify access to the project path:

```bash
git ls-remote git@git.tib.eu:OSL/climate-knowledge-graph/climatekg-deploy.git
```

- If prompted repeatedly, ensure your key is loaded and has project access.

### SPARQL data appears stale

Use reindex workflow:

```powershell
.\scripts\wdqs-reindex-prod.ps1
```

### Container health issues

```powershell
docker compose ps
docker compose logs --tail 100 wikibase
docker compose logs --tail 100 wdqs
docker compose logs --tail 100 wdqs-updater
```

## Security and secrets

- Do not commit .env files or private keys
- Keep environment passwords in a secure password manager
- Keep SQL backups in controlled storage

## Documentation map

- Master operations guide: docs/multi-env-workflow.md
- Deployment history and registry: docs/deployment-protocol.md
- New TIB rollout plan: docs/new-tib-machines-provisioning-plan.md
- Server administration: docs/server-admin.md
- Temporary access protection: docs/temporary-web-password-protection.md

## Status note

This README intentionally prioritizes TIB deployment and migration operations. For deeper command-level details and edge-case procedures, use docs/multi-env-workflow.md as the authoritative runbook.