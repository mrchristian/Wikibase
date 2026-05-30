# Scripts

All operational scripts for the Wikibase / ClimateKG project are organised here into four subdirectories.

---

## `sync/` — Production ↔ Local data workflows

| Script | Language | Purpose |
|---|---|---|
| [`pull-from-production.ps1`](sync/pull-from-production.ps1) | PowerShell | Dump the production MariaDB, SCP it locally, import it into the local container, clear caches, re-register sitelinks, reset admin password. Full guide: [`docs/pull-from-production-guide.md`](../docs/pull-from-production-guide.md) |
| [`pull-images-from-production.ps1`](sync/pull-images-from-production.ps1) | PowerShell | Pull the production `images/` volume to local via SCP + HTTP transfer. Full guide: [`docs/pull-images-guide.md`](../docs/pull-images-guide.md) |
| [`push_to_production.py`](sync/push_to_production.py) | Python | Upsert local items and properties (P1–P12, Q1–Q192) up to the production Wikibase. Idempotent — safe to re-run. |
| [`sync-to-production.sh`](sync/sync-to-production.sh) | Bash | Shell helper for syncing files to the production server. |
| [`migrate_wikibase.py`](sync/migrate_wikibase.py) | Python | One-time migration: pull P1–P12 and Q1–Q192 from an external Wikibase source into localhost. Run only on a clean instance. |

### Running the sync scripts (from repo root)

```powershell
# Pull production DB to local
.\scripts\sync\pull-from-production.ps1

# Pull production images to local (run after pull-from-production)
.\scripts\sync\pull-images-from-production.ps1

# Push local items/properties up to production (activate venv first)
& .venv\Scripts\Activate.ps1
python scripts/sync/push_to_production.py
```

---

## `deploy/` — Server setup and sitelinks

| Script | Language | Purpose |
|---|---|---|
| [`deploy.sh`](deploy/deploy.sh) | Bash | Automated server setup: installs Docker, clones repo, configures Nginx + Certbot SSL, starts the stack. |
| [`init-sitelinks.sh`](deploy/init-sitelinks.sh) | Bash | Runs inside the `wikibase-sitelinks-init` container on startup. Imports `sites.xml` to register the `mywiki` site and sets the site language. **Mounted by `docker-compose.yml` and `docker-compose.prod.yml`** — do not move this file without updating those compose files. |

---

## `images/` — Image management

| Script | Language | Purpose |
|---|---|---|
| [`upload_images.py`](images/upload_images.py) | Python | Batch-upload image files to the local Wikibase via the MediaWiki API. |
| [`upload_failed_images.py`](images/upload_failed_images.py) | Python | Retry failed image uploads from `upload_log.txt`. |
| [`register_images.py`](images/register_images.py) | Python | Register uploaded images as Wikibase media items. |
| [`restore_images.py`](images/restore_images.py) | Python | Restore images to the local instance from a backup archive. |
| [`restore_images_prod.py`](images/restore_images_prod.py) | Python | Restore images to the production instance. |
| [`extract_images.py`](images/extract_images.py) | Python | Extract image files from a source (preserving subdirectory structure). |
| [`extract_images_flat.py`](images/extract_images_flat.py) | Python | Extract image files into a flat directory (no subdirs). |
| [`fix_thumb.py`](images/fix_thumb.py) | Python | Fix broken thumbnail paths after an image restore. |
| [`delete_uploads.py`](images/delete_uploads.py) | Python | Delete uploaded files from the wiki (used during cleanup/reset). |
| [`generate_image_sql.sh`](images/generate_image_sql.sh) | Bash | Generate SQL INSERT statements for bulk image registration in the `image` table. |

---

## `content/` — Content analysis utilities

| Script | Language | Purpose |
|---|---|---|
| [`find_anchors.py`](content/find_anchors.py) | Python | Find all anchor links in wiki page XML exports. |
| [`find_section_links.py`](content/find_section_links.py) | Python | Find internal section links across wiki pages. |
| [`inspect_xml.py`](content/inspect_xml.py) | Python | Inspect and summarise MediaWiki XML export files. |
| [`generate_test_docx.py`](content/generate_test_docx.py) | Python | Generate a test `.docx` file for upload/conversion testing. |

---

## `sparql/` — SPARQL utilities

| Script | Language | Purpose |
|---|---|---|
| [`query-sparql.ps1`](sparql/query-sparql.ps1) | PowerShell | Run a SPARQL query against the local or production WDQS endpoint. |

---

## Notes

- Python scripts require the project virtual environment: `& .venv\Scripts\Activate.ps1` (Windows) before running.
- PowerShell scripts (`.ps1`) should be run from the **repo root** (`C:\Wikibase`) so relative paths resolve correctly:  `.\scripts\sync\pull-from-production.ps1`
- `init-sitelinks.sh` is bind-mounted by Docker Compose at `./scripts/deploy/init-sitelinks.sh` — update `docker-compose.yml` and `docker-compose.prod.yml` if this path ever changes.
