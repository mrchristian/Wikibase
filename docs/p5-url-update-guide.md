# P5 Wiki URL Update Guide — Chapter Items

This guide documents the workflow for updating the **P5 (Wiki URL)** property on all Chapter items (P1=Q6) in ClimateKG Wikibase to use the canonical URL derived from each item's `climatekg-wiki` sitelink.

---

## Background

### What is P5?

`P5` is the **Wiki URL** property — it stores the MediaWiki page URL for a Wikibase item. For Chapter items this should point to the corresponding IPCC page on the ClimateKG wiki (e.g. `https://dev-climatekg.semanticclimate.org/wiki/IPCC:AR6/WGII/Chapter-1`).

### Why run this update?

When the ClimateKG stack was first deployed, P5 values pointed to an older domain (`wikibase.runstop.uk`). After the sitelinks feature was implemented (linking items to MediaWiki pages via the `climatekg-wiki` site group), the P5 values must be regenerated from the sitelink titles to match the correct domain for each environment (DEV / TEST / PROD each have different base URLs).

### Scope

The update affects all items where:
- `P1 = Q6` (i.e. the item is a Chapter)
- The item has a `climatekg-wiki` sitelink

There are **88 Chapter items** (Q6), all of which have a `climatekg-wiki` sitelink.

---

## Script

**Location:** `scripts/update-chapter-wiki-urls.py`

**What it does:**
1. Queries the SPARQL endpoint for all items with `P1 = Q6`
2. For each item, fetches the `climatekg-wiki` sitelink title via the MediaWiki API
3. Constructs the canonical URL: `{wiki_base}/wiki/{sitelink_title}`
4. If P5 already has the correct value — skips (idempotent)
5. If P5 has a different value — updates it via `wbsetclaimvalue`
6. If P5 has no value yet — creates a new claim via `wbcreateclaim`

**Flags:**
```
--env   local | dev | test | prod    (default: local)
--dry-run                            List planned changes without writing anything
```

**Credentials** are read from (in priority order):
1. Environment variable (`WB_PASSWORD` for local; `DEV_MW_ADMIN_PASS`, `TEST_MW_ADMIN_PASS`, `PROD_MW_ADMIN_PASS` for remotes)
2. `C:\Wikibase\.env` file
3. Interactive prompt (last resort)

**The script is idempotent** — safe to re-run at any time. Items already at the correct URL are skipped.

---

## Initial Deployment Workflow (LOCAL → all environments)

This is the one-time workflow to apply the update to all four environments. After this, the script only needs to be run again if domain names change or if new Chapter items are added.

### Prerequisites

- Docker containers running on LOCAL (`docker compose up -d`)
- `.env` contains `WB_PASSWORD`, `DEV_MW_ADMIN_PASS`, `TEST_MW_ADMIN_PASS`, `PROD_MW_ADMIN_PASS`
- SSH key set up for DEV, TEST, PROD servers

---

### Step 1 — Pull fresh DEV data to LOCAL

```powershell
.\scripts\sync\pull-from-dev.ps1
```

> Takes 30–45 minutes (DB is 800 MB+). No progress output during the dump/transfer steps — just wait.

---

### Step 2 — Snapshot LOCAL (experimental workflow)

```powershell
.\scripts\experimental-import-workflow.ps1 start
```

This creates a rollback point before making any changes.

---

### Step 3 — Dry-run (optional sanity check)

```powershell
python scripts/update-chapter-wiki-urls.py --env local --dry-run
```

Expected output: 88 items to update, 0 to skip.

---

### Step 4 — Apply P5 updates on LOCAL

```powershell
python scripts/update-chapter-wiki-urls.py --env local
```

Expected output:
```
Updated: 88   Errors: 0   Skipped: 0
```

---

### Step 5 — Verify on LOCAL

Browse to http://localhost:8080 and check a Chapter item (e.g. Q1). The P5 value should now be `http://localhost:8080/wiki/IPCC:AR6/...`.

Alternatively, open `chapter-urls-verification.csv` (generated during initial setup) to compare expected vs actual values.

---

### Step 6 — Approve the experiment

```powershell
.\scripts\experimental-import-workflow.ps1 approve
```

LOCAL is now CLEAN with the P5 updates committed as the new base.

---

### Step 7 — Push LOCAL → DEV

```powershell
.\scripts\sync\sync-local-to-dev.ps1 -DbOnly
```

Type `PROMOTE` at the confirmation prompt.

> `-DbOnly` skips images since only data (P5 claims) changed.

---

### Step 8 — Apply P5 updates on DEV

Run locally, pointing at the DEV API:

```powershell
python scripts/update-chapter-wiki-urls.py --env dev
```

This rewrites the P5 URLs using the DEV base domain (`https://dev-climatekg.semanticclimate.org`).

---

### Step 9 — Promote DEV → TEST

```powershell
.\scripts\sync\sync-dev-to-test.ps1
```

Then apply P5 updates for the TEST domain:

```powershell
python scripts/update-chapter-wiki-urls.py --env test
```

---

### Step 10 — Promote TEST → PROD

```powershell
.\scripts\sync\sync-dev-to-prod.ps1
```

Then apply P5 updates for the PROD domain:

```powershell
python scripts/update-chapter-wiki-urls.py --env prod
```

---

## Re-running After a Domain Change

If any environment's domain name changes, re-run the script for that environment:

```powershell
python scripts/update-chapter-wiki-urls.py --env <env>
```

The script will detect that the existing P5 value doesn't match the new domain and update it. Items with no P5 at all will have one created.

---

## Re-running for a New Chapter Item

If a new Chapter item is added (P1=Q6) with a `climatekg-wiki` sitelink, re-run the script for the relevant environment(s). Existing items are skipped (idempotent), so there is no risk of overwriting correct values.

---

## Known Issues

No known issues. All 88 Chapter items have `climatekg-wiki` sitelinks and correct P5 values.

> **Previously:** Q125 ("Poverty, Livelihoods and Sustainable Development" — WGII Chapter 8) was missing its sitelink. Fixed by adding sitelink `IPCC:AR6/WGII/Chapter-8` to the item and re-running the script.

---

## Verification

A verification CSV was generated during the initial run:

**File:** `chapter-urls-verification.csv`  
**Columns:** `QID`, `Label`, `MediaWiki_Page_Title`, `P5_URL`  
**Rows:** 88 (all with updated URLs)

To regenerate the CSV at any time (e.g. to verify DEV or PROD):

```powershell
python scripts/_gen_verification_csv.py
```

---

## Environment → Password Variable Mapping

| Environment | Password variable    | API endpoint                                           |
|-------------|---------------------|--------------------------------------------------------|
| LOCAL       | `WB_PASSWORD`        | `http://localhost:8080/w/api.php`                      |
| DEV         | `DEV_MW_ADMIN_PASS`  | `https://dev-climatekg.semanticclimate.org/w/api.php`  |
| TEST        | `TEST_MW_ADMIN_PASS` | `https://test-climatekg.semanticclimate.org/w/api.php` |
| PROD        | `PROD_MW_ADMIN_PASS` | `https://prod-climatekg.semanticclimate.org/w/api.php` |

All variables are read from `C:\Wikibase\.env`.

---

## Related

- Script: [`scripts/update-chapter-wiki-urls.py`](../scripts/update-chapter-wiki-urls.py)
- Sitelinks setup: [`docs/sitelinks-implementation.md`](sitelinks-implementation.md)
- Sync workflow: [`docs/multi-env-workflow.md`](multi-env-workflow.md) §4
- Experimental workflow: [`docs/multi-env-workflow.md`](multi-env-workflow.md) §11
