# Pull Images from Production to Local

This guide covers using `scripts/sync/pull-images-from-production.ps1` to sync MediaWiki image files from the production Hetzner server to your local Docker stack.

---

## When to use this

- New images have been uploaded to production and are missing locally
- You have just run `scripts/sync/pull-from-production.ps1` (full DB restore) and want to match the image files too
- Local image display is broken after a DB sync (files referenced in the DB but not present in the volume)

This script is **additive and replacing** — it overwrites the entire local images volume with the production set. It does not delete files that exist locally but not on production; the tar extraction will overwrite matching filenames and add new ones.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker Desktop running | Local wikibase container must be up (`docker compose up -d`) |
| OpenSSH | `ssh` and `scp` must be on PATH (standard on Windows 10/11) |
| SSH key | `C:\Users\<you>\.ssh\id_wikibase_sync` — passphrase-free sync key |
| Python 3 | Used for a temporary HTTP file server during the transfer |
| Port 9876 free | Used briefly during the container transfer step |

### SSH key setup (one-time)

If the `id_wikibase_sync` key does not exist yet, see [sync-guide.md](sync-guide.md) for setup. The key must be in `authorized_keys` on the production server and must not require a passphrase (or must be loaded in ssh-agent).

---

## How it works

The script follows a 6-step workflow designed to avoid two known Windows Docker pitfalls:

1. **PowerShell `>` redirection** corrupts files with UTF-16LE encoding (not relevant here for images, but the same principle applies — no shell redirection is used).
2. **`docker cp` of large files crashes Docker Desktop on Windows** via the named-pipe backend. Files > ~100 MB frequently cause `io: read/write on closed pipe`. The script works around this by:
   - Serving the archive from a temporary Python HTTP server on the Windows host
   - Using `curl` from inside the local container to download it via `host.docker.internal`

### Step-by-step

| Step | What happens |
|---|---|
| 1 | Count production image files (pre-flight baseline) |
| 2 | `tar -czf` inside the production container — excludes `thumb/` (~287 MB of regeneratable thumbnails) |
| 3 | `docker cp` from production container → production host → `scp` to `C:\Wikibase\backups\` |
| 4 | Python HTTP server started on port 9876; container `curl`s the archive from `host.docker.internal:9876` |
| 5 | `tar -xzf` into `/var/www/html/images`; `chown -R www-data`; stale thumbnails deleted |
| 6 | File count verified; temp files cleaned up everywhere |

---

## Running the script

```powershell
.\scripts\sync\pull-images-from-production.ps1
```

No arguments required. The script is self-contained and reads the SSH key path from the configuration block at the top.

Expected runtime: **3–5 minutes** for a ~750 MB image set on a typical broadband connection (the SCP download at ~6 MB/s is the longest step).

---

## Output

On success the script prints:

```
============================================================
 Pull images from production complete!
============================================================

  Archive saved  : C:\Wikibase\backups\wiki_images_20260519_110102.tar.gz
  Production imgs: 2147
  Local imgs now : 2148

Verify images at http://localhost:8080/wiki/Special:ListFiles
```

The archive is kept in `C:\Wikibase\backups\` as a local record. It can be deleted once you are satisfied the restore was successful.

---

## What is excluded

| Excluded | Reason |
|---|---|
| `images/thumb/` | Regenerated automatically by MediaWiki on first page view — no need to transfer ~287 MB |

All other contents of the images volume are transferred, including:

- `images/<hash>/<hash>/` — original uploaded files
- `images/archive/` — previous versions of overwritten files
- `images/deleted/` — soft-deleted files (if present)
- `.htaccess` and other root-level config files

---

## Troubleshooting

### "docker cp failed" / pipe error on large files

This is why the script uses an HTTP server instead of `docker cp` for the local container step. If you see this error during Step 3 (SCP, not docker cp), it means the SCP itself failed — check SSH connectivity and disk space on the production host.

### "curl inside container failed"

Verify `curl` is present in the container:

```powershell
docker exec wikibase curl --version
```

If missing, the container image predates the curl installation. Contact the project maintainer to update the Dockerfile.

### Image count mismatch after restore

A lower count than production may mean:
- The SCP was interrupted — check the archive size: `(Get-Item C:\Wikibase\backups\wiki_images_*.tar.gz | Sort LastWriteTime | Select -Last 1).Length`
- Some production images were in `thumb/` only (no original) — this is unusual and indicates a data integrity issue on production

### Port 9876 already in use

Edit the `$HTTP_PORT` variable near the top of `scripts/sync/pull-images-from-production.ps1` to any free port, e.g. `9877`.

### Thumbnails not regenerating

MediaWiki generates thumbnails lazily on first view. If a thumbnail is missing after several days of use, run:

```powershell
docker exec wikibase php /var/www/html/maintenance/run.php refreshImageMetadata --conf /config/LocalSettings.php --force
```

---

## Relationship to pull-from-production.ps1

| Script | What it syncs |
|---|---|
| `scripts/sync/pull-from-production.ps1` | Full MariaDB database (all wiki content, items, properties, user accounts) |
| `scripts/sync/pull-images-from-production.ps1` | MediaWiki image files (the `wikibase_images` Docker volume) |

Run `scripts/sync/pull-from-production.ps1` first, then `scripts/sync/pull-images-from-production.ps1` to get a fully up-to-date local environment matching production.
