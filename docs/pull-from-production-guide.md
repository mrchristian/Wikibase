# Pull Database from Production to Local

This guide covers using `scripts/sync/pull-from-production.ps1` to overwrite the local Wikibase database with a fresh dump from the production server.

---

## When to use this

- Starting a local development session with the latest production data
- Verifying a production issue locally before fixing it on the server
- After a production content sprint — pulling the latest items/properties down for local work
- Disaster recovery / local reset to a known-good production state

> **Warning**: This script completely overwrites your local database. Any local-only edits, items, or properties not on production will be lost.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker Desktop running | All containers must be up (`docker compose up -d`) |
| OpenSSH | `ssh` and `scp` must be on PATH (standard on Windows 10/11) |
| SSH key | `C:\Users\<you>\.ssh\id_wikibase_sync` — passphrase-free sync key |
| `PROD_DB_PASS` in `.env` | See below — the script reads the production DB password from `C:\Wikibase\.env` |

### SSH key setup (one-time)

See [sync-guide.md](sync-guide.md) for full setup. The key must exist at `C:\Users\<you>\.ssh\id_wikibase_sync`, be authorised in `~/.ssh/authorized_keys` on the production server, and not require a passphrase (or be loaded in ssh-agent).

### Production DB password

Add the following line to `C:\Wikibase\.env` (the file is gitignored — never commit it):

```
PROD_DB_PASS=<actual-password>
```

If the variable is absent, the script will prompt for the password interactively.

The production DB password is stored in `/opt/wikibase/.env` on the Hetzner server. See the repo memory or [deployment-protocol.md](deployment-protocol.md) for the current value.

---

## Running the script

```powershell
.\scripts\sync\pull-from-production.ps1
```

No arguments required. Expected runtime: **3–5 minutes** (dominated by the ~350 MB SCP download).

---

## What the script does — step by step

### Pre-flight checks

Before doing any work the script verifies:

- `C:\Wikibase\backups\` exists (creates it if not)
- `docker`, `ssh`, and `scp` are on PATH
- The SSH sync key exists at the expected path
- SSH connectivity to `178.104.156.88` succeeds without a passphrase

### Step 1 — Dump production database (inside container)

```
mysqldump --result-file=/tmp/<dump>.sql
```

`mysqldump` writes the SQL file **directly to disk inside the production MariaDB container** using `--result-file`. This bypasses all shell redirection — no SSH pipe, no PowerShell stream — so the file is written as clean UTF-8 with no BOM.

> **Why not just redirect with `>`?** PowerShell 5.1 writes redirected output as UTF-16LE (with BOM). MariaDB expects UTF-8, so the import would fail with character set errors. See [backups/mariadb-backup-powershell-encoding-notes.md](../backups/mariadb-backup-powershell-encoding-notes.md) for full details.

Flags used:

| Flag | Purpose |
|---|---|
| `--default-character-set=utf8mb4` | Declares utf8mb4 in the dump header |
| `--single-transaction` | Consistent InnoDB snapshot without table locks |
| `--quick` | Retrieves rows one at a time to avoid buffering large tables in memory |
| `--max_allowed_packet=512M` | Handles large wikitext blobs |
| `--result-file=<path>` | Writes directly to disk — no shell stream |

### Step 2 — Copy dump from container to production host

```
docker cp wikibase-mariadb:/tmp/<dump>.sql /tmp/<dump>.sql
```

The SQL file is copied from the MariaDB container filesystem to the production host's `/tmp/`.

### Step 3 — Download dump to local machine

```
scp root@178.104.156.88:/tmp/<dump>.sql C:\Wikibase\backups\<dump>.sql
```

SCP transfers bytes unchanged — no encoding transformation. The script then:

1. Verifies the downloaded file is at least 1 MB (a 0-byte file means the dump silently failed)
2. Cleans up the temp files on the production host and inside the production container

### Step 4 — Copy dump into the local MariaDB container

```
docker cp C:\Wikibase\backups\<dump>.sql wikibase-mariadb:/tmp/restore.sql
```

`docker cp` copies the file byte-for-byte into the local container. No PowerShell output stream is involved, so no UTF-16LE corruption can occur.

### Step 5 — Import from inside the local container

```
mysql -e "source /tmp/restore.sql"
```

MySQL reads the SQL file from the container's own filesystem — no Windows streams involved. The dump file is deleted from inside the container after the import.

### Step 6 — Clear stale cache tables

The production dump contains `objectcache` and `l10n_cache` rows generated with the production URL (`https://dev-climatekg.semanticclimate.org`). If not cleared, MediaWiki will serve pages with broken production URLs on localhost.

```sql
TRUNCATE TABLE objectcache;
TRUNCATE TABLE l10n_cache;
```

After truncation the script runs two MediaWiki maintenance tasks:

- `run.php update --quick` — checks schema consistency and flushes internal caches
- `run.php rebuildrecentchanges` — rebuilds `Special:RecentChanges` to reflect the imported revision history

### Step 6b — Re-register localhost sitelinks

The imported production database contains sitelink registrations pointing to `https://dev-climatekg.semanticclimate.org`. These must be replaced with localhost URLs so Wikibase item sitelinks work locally.

The `wikibase-sitelinks-init` container is restarted; it runs `init-sitelinks.sh` which imports `sites.xml` (containing `localhost:8080` paths). The script waits 15 seconds for the init container to finish.

### Step 7 — Restart wikibase container

```
docker compose restart wikibase
```

Flushes the PHP opcode cache and APCu object cache, which may still hold production-URL data from before the import.

### Step 8 — Reset local admin password

The imported database carries the production admin password. The script resets it to the standard localhost default:

```
admin / adminpass123!
```

This uses `run.php changePassword` from inside the wikibase container.

---

## Output

On success:

```
============================================================
 Pull from production complete!
============================================================

  Local dump file : C:\Wikibase\backups\prod_pull_20260519_110102.sql
  Timestamp       : 20260519_110102

Verify at http://localhost:8080

  Local admin login: admin / adminpass123!

Note: Sitelinks should now be registered for mywiki (localhost).
Verify at http://localhost:8080/wiki/Special:Sites
```

The SQL dump is kept in `C:\Wikibase\backups\` as a local record. It can be deleted once you are satisfied the restore was successful.

---

## After running the script

1. Hard-refresh your browser: `Ctrl+Shift+R` at http://localhost:8080
2. Log in with `admin` / `adminpass123!`
3. Check `Special:RecentChanges` — should show the latest production edits
4. Check `Special:Sites` — `mywiki` should be registered pointing to `localhost:8080`

If images are missing (files uploaded to production are not visible locally), run:

```powershell
.\scripts\sync\pull-images-from-production.ps1
```

See [pull-images-guide.md](pull-images-guide.md) for details.

---

## Troubleshooting

### "Downloaded dump is suspiciously small"

The production `mysqldump` failed silently. Common causes:

- Wrong `PROD_DB_PASS` in `.env`
- Production MariaDB container is not running
- SSH connection dropped mid-transfer

Re-check credentials and container health on production:

```bash
ssh root@178.104.156.88 "docker ps | grep wikibase-mariadb"
```

### Pages show production URLs after import

The cache truncation may not have taken effect. Run manually:

```powershell
docker exec wikibase-mariadb mysql -u wikibase -pwikibase my_wiki -e "TRUNCATE TABLE objectcache; TRUNCATE TABLE l10n_cache;"
docker compose restart wikibase
```

### Sitelinks not registered (Special:Sites is empty)

The sitelinks init container may have finished before the wikibase container was ready. Re-run it:

```powershell
docker compose restart wikibase-sitelinks-init
Start-Sleep -Seconds 20
docker compose restart wikibase
```

### "Cannot SSH to root@178.104.156.88"

The SSH agent may not have the sync key loaded, or the key's public half is not in `authorized_keys` on the server. See [sync-guide.md](sync-guide.md) for the full SSH setup procedure.

---

## Relationship to other sync scripts

| Script | What it syncs |
|---|---|
| `scripts/sync/pull-from-production.ps1` | Full MariaDB database (all wiki content, items, properties, user accounts) |
| `scripts/sync/pull-images-from-production.ps1` | MediaWiki image files (the `wikibase_images` Docker volume) |

For a fully up-to-date local environment matching production, run both scripts in order:

```powershell
.\scripts\sync\pull-from-production.ps1
.\scripts\sync\pull-images-from-production.ps1
```
