# Wikibase Data Migration and Push to Production

This document covers how Wikibase entity data is migrated between instances in the ClimateKG project: from an external source into localhost, and from localhost up to the production server.

---

## Overview

The project uses two Python scripts to manage Wikibase data across three environments:

| Environment | URL |
|---|---|
| Source (external) | `https://wikibase.runstop.uk` |
| Local dev | `http://localhost:8080` |
| Production | `https://dev-climatekg.semanticclimate.org` |

**Script 1 — `migrate_wikibase.py`**: Pulls data from the external source into localhost (one-time migration).

**Script 2 — `push_to_production.py`**: Pushes data from localhost to production (repeatable sync).

---

## Prerequisites

- Python virtual environment activated: `& .venv\Scripts\Activate.ps1`
- Local Docker stack running: `docker compose up -d`
- SSH access to production server (for other maintenance tasks)

---

## Script 1: Migrate from External Source to Localhost

**File**: `migrate_wikibase.py`

Migrates P1–P12 (Properties) and Q1–Q192 (Items) from `wikibase.runstop.uk` into the local Wikibase.

### What it does

1. **Creates Properties (P1–P12)** — fetches each property from the source and creates it on localhost in order, preserving labels, descriptions, aliases, and datatype.
2. **Creates Item stubs (Q1–Q192)** — creates each item with labels/descriptions/aliases only, with no statements. This ensures all IDs exist before any cross-references are written.
3. **Adds statements** — in a second pass, writes all claims (statements, qualifiers, references) to each item. The two-pass approach prevents "entity not found" errors when a statement references an item that hasn't been created yet.

### Run

```powershell
& .venv\Scripts\Activate.ps1
python migrate_wikibase.py
```

### Notes

- The script creates new entities sequentially; it does **not** check for existing ones. Run it only on a clean or empty Wikibase instance.
- If the localhost already has entities, skip this script and go directly to `push_to_production.py`.
- Credentials are hardcoded in the script (`admin` / `adminpass123!` for localhost).

---

## Script 2: Push from Localhost to Production

**File**: `push_to_production.py`

Syncs the current state of localhost (P1–P12, Q1–Q192) up to the production Wikibase. Safe to re-run at any time — it upserts rather than blindly creating, so it handles both first-time pushes and subsequent updates.

### What it does

1. **Upserts Properties (P1–P12)** — checks which properties already exist on production; updates them if present, creates them if not.
2. **Upserts Item stubs (Q1–Q192)** — same upsert logic for labels/descriptions/aliases only.
3. **Replaces statements on all items** — uses `clear=1` combined with the full entity data (labels + descriptions + claims) in a single atomic API call. This ensures:
   - No duplicate statements accumulate across re-runs.
   - Labels and descriptions are never lost during the clear.

### Run

```powershell
& .venv\Scripts\Activate.ps1
python push_to_production.py
```

### Example output

```
Logged in to production as admin

=== Upserting properties P1-P12 on production ===
  0 of 12 already exist on production
  P1 -> P1  (Instance of) [created]
  ...

=== Upserting item stubs Q1-Q192 on production ===
  0 of 192 already exist on production
  Q1 -> Q1  (Publication type) [created]
  ...

=== Replacing statements on items ===
  Q3 (Publication) - statements updated
  Q7 (IPCC Sixth Assessment Report) - statements updated
  ...

=== Push to production complete ===
```

---

## Entity Ranges

| Type | IDs | Count |
|---|---|---|
| Properties | P1–P12 | 12 |
| Items | Q1–Q192 | 192 |

To extend the sync to new entities, update `PROP_IDS` and `ITEM_IDS` at the top of `push_to_production.py`.

---

## Key Design Decisions

### Two-pass import (stubs then statements)
Wikibase statements can reference other items (e.g. "P1 = Q3"). If items are created with their statements in a single pass, any statement referencing an item not yet created will fail. Creating all stubs first, then adding statements in a second pass, avoids this.

### `clear=1` with full entity data in step 3
The `wbeditentity` API with `clear=1` wipes the entire entity before applying the new data. Including labels, descriptions, aliases, and claims together in one call ensures nothing is lost. Without this, re-running the sync would add duplicate statements.

### Upsert pattern (no blind creates)
`push_to_production.py` first fetches all IDs from production to find which already exist, then either edits (`id=Qn`) or creates (`new=item`) accordingly. This makes the script idempotent and safe to run repeatedly.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Login failed` | Wrong credentials or production unreachable | Check `USERNAME`/`PASSWORD` in script; verify `https://dev-climatekg.semanticclimate.org` is up |
| Duplicate statements on production | Step 3 ran without `clear=1` | Re-run `push_to_production.py` — the current version uses `clear=1` and will deduplicate |
| Missing labels/descriptions on production | Old version of script used `clear=1` without including labels | Re-run current `push_to_production.py` |
| `entity not found` errors during migration | Items referenced in statements didn't exist yet | The two-pass approach in both scripts prevents this; if you see it, ensure step 2 completed fully before step 3 |
| Property/item count mismatch | Source has more entities than the script's range | Extend `PROP_IDS`/`ITEM_IDS` in the script to cover the new range |
