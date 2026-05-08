# Syncing Data Between Local and Production Wikibase

This guide covers strategies for moving Wikibase content between `localhost:8080` (local development) and `https://dev-climatekg.semanticclimate.org` (production on Hetzner).

## Overview of Approaches

| Approach | Direction | Destructive? | Granularity | Complexity |
|----------|-----------|--------------|-------------|------------|
| Full DB dump/restore | Either | Yes — replaces everything | Entire database | Low |
| MediaWiki XML export/import | Either | No — merges or skips | Per-namespace or per-page | Medium |
| Wikibase API scripting | Either | No — granular control | Per-item/property/claim | High |
| QuickStatements / CSV | Either | No — additive | Structured data only | Medium |

---

## Approach 1: Full Database Dump/Restore

A `mysqldump` from one environment imported into the other. This is a complete replacement of all wiki content, user accounts, settings, and Wikibase items.

### When to use

- Starting a local dev session with the latest production data
- Disaster recovery
- When one environment is the single source of truth

### Limitations

- **Overwrites everything** on the target — there is no merge
- Site URLs in the database will point to the source environment (must be fixed after import)
- Admin passwords will be those from the source

### Pull production → local

```bash
# 1. Export from production
ssh root@178.104.156.88 "docker exec wikibase-mariadb mysqldump -u wikibase -p'DB_PASSWORD' my_wiki" > backup.sql

# 2. Import into local
docker exec -i wikibase-mariadb mysql -u wikibase -pwikibase my_wiki < backup.sql

# 3. Fix sitelinks (re-register localhost URLs)
docker compose restart wikibase-sitelinks-init

# 4. Restart wikibase to clear caches
docker compose restart wikibase

# 5. (Optional) Reset admin password to local default
docker exec wikibase php /var/www/html/maintenance/run.php changePassword \
  --conf /config/LocalSettings.php --user admin --password "adminpass123!"
```

### Push local → production (full replacement)

> **Warning**: This overwrites all production data. Only use if production has no unique edits.

```bash
# 1. Export from local
docker exec wikibase-mariadb mysqldump -u wikibase -pwikibase my_wiki > local-dump.sql

# 2. Copy to server
scp local-dump.sql root@178.104.156.88:/tmp/

# 3. Import on production
ssh root@178.104.156.88 "docker exec -i wikibase-mariadb mysql -u wikibase -p'DB_PASSWORD' my_wiki < /tmp/local-dump.sql"

# 4. Re-register production sitelinks
ssh root@178.104.156.88 "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase-sitelinks-init"

# 5. Restart wikibase
ssh root@178.104.156.88 "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase"
```

---

## Approach 2: MediaWiki XML Export/Import (Recommended for Selective Sync)

Export specific namespaces or pages as XML, then import on the other side. This does not delete existing content — it adds or updates pages based on title matching.

### Key Wikibase Namespaces

| NS ID | Name | Content |
|-------|------|---------|
| 0 | Main | Regular wiki pages |
| 120 | Item | Wikibase items (Q1, Q2, ...) |
| 122 | Property | Wikibase properties (P1, P2, ...) |

### Export from local

```bash
# Export all Wikibase items and properties
docker exec wikibase php /var/www/html/maintenance/run.php dumpBackup \
  --conf /config/LocalSettings.php \
  --full \
  --namespaces=120,122 \
  > wikibase-items-export.xml

# Or export everything (all namespaces)
docker exec wikibase php /var/www/html/maintenance/run.php dumpBackup \
  --conf /config/LocalSettings.php \
  --full \
  > full-export.xml

# Or export specific pages only
docker exec wikibase php /var/www/html/maintenance/run.php dumpBackup \
  --conf /config/LocalSettings.php \
  --full \
  --pagelist=/tmp/pages.txt \
  > selected-pages.xml
```

To use `--pagelist`, first create a text file with one page title per line:
```
Item:Q1
Item:Q2
Property:P1
Main_Page
```

### Import into production

```bash
# Copy the export file to the server
scp wikibase-items-export.xml root@178.104.156.88:/tmp/

# Import on production
ssh root@178.104.156.88 "cat /tmp/wikibase-items-export.xml | docker exec -i wikibase php /var/www/html/maintenance/run.php importDump --conf /config/LocalSettings.php"

# Rebuild search index for imported content
ssh root@178.104.156.88 "docker exec wikibase php /var/www/html/maintenance/run.php rebuildrecentchanges --conf /config/LocalSettings.php"
```

### Export from production → import locally

```bash
# Export from production
ssh root@178.104.156.88 "docker exec wikibase php /var/www/html/maintenance/run.php dumpBackup --conf /config/LocalSettings.php --full --namespaces=120,122" > prod-items.xml

# Import locally
cat prod-items.xml | docker exec -i wikibase php /var/www/html/maintenance/run.php importDump --conf /config/LocalSettings.php
```

### Important notes on XML import

- If an item (e.g., Q1) exists on both sides, the import will **add the imported revision as a new revision** — the latest revision wins
- Item/property IDs (Q1, P1, etc.) are preserved in the export — they will match on import only if the target doesn't already have a different item at that ID
- **Properties should be imported first** (NS 122) before items (NS 120), since items reference properties

---

## Approach 3: Wikibase API Scripting

Use the Wikibase REST or Action API to read entities from one instance and write them to another. This gives the most control but requires scripting.

### Tools

- **[WikibaseIntegrator](https://github.com/LeMiworking/WikibaseIntegrator)** (Python) — high-level library for reading/writing Wikibase entities
- **Direct API calls** — `wbeditentity`, `wbgetentities` via `curl` or scripts

### Example: Copy Q1 from local to production via API

```bash
# Read Q1 from local
curl -s "http://localhost:8080/w/api.php?action=wbgetentities&ids=Q1&format=json" > q1.json

# Write to production (requires login token first)
# This is simplified — in practice you need to authenticate and handle edit tokens
curl -X POST "https://dev-climatekg.semanticclimate.org/w/api.php" \
  -d "action=wbeditentity&id=Q1&data=...&format=json&token=..."
```

### When to use

- You need to merge specific claims/statements without overwriting others
- You're building an automated pipeline
- ID mapping is needed (e.g., Q1 on local maps to Q5 on production)

---

## Approach 4: QuickStatements / CSV

Export structured Wikibase data as QuickStatements v1 format or CSV, review it, then import on the other side.

### When to use

- Bulk import of tabular data (e.g., from spreadsheets)
- You want a human-readable review step before importing
- Mainly for structured data (labels, descriptions, claims) — not wiki page content

### Requires

- QuickStatements extension installed (not included in the current docker setup)
- Or a script that converts CSV to API calls

---

## Recommended Workflow

**Treat production as the source of truth.** Edit there whenever possible. Use local for development and testing of new schemas or bulk operations.

```
Production (source of truth)
    │
    ├── Full DB dump ──────────► Local (start of work session)
    │                               │
    │                               ├── Create/test new properties
    │                               ├── Create/test new items
    │                               ├── Develop wiki pages
    │                               │
    │   ◄── XML export (selective) ─┘   (push tested content up)
    │
    ├── Direct edits by users
    │
    └── Ongoing production use
```

### Session workflow

1. **Start of session**: Pull full DB dump from production → local
2. **Develop locally**: Create items, properties, pages, test sitelinks
3. **When ready**: XML export the new/changed namespaces from local
4. **Review**: Inspect the XML to confirm what will be imported
5. **Push to production**: Import the XML on production
6. **Verify**: Check the imported content on the production site

### Conflict avoidance tips

- **Reserve ID ranges**: If multiple people work locally, agree on who uses which Q/P ID ranges to avoid collisions
- **Properties first**: Always define and import properties before items that use them
- **Don't edit the same item in both places**: If you pulled Q1 from production, don't also edit Q1 on production until you've pushed your changes back

---

## Comparison Table

| Scenario | Recommended approach |
|----------|---------------------|
| Start local dev with latest prod data | Full DB dump (prod → local) |
| Push 5 new items to production | XML export (NS 120, local → prod) |
| Push new properties to production | XML export (NS 122, local → prod) |
| Full reset of production from local | Full DB dump (local → prod) — **destructive** |
| Ongoing multi-user editing | Edit on production only; pull dumps for local analysis |
| Automated data pipeline | Wikibase API scripting |
| Bulk import from spreadsheet | QuickStatements or API scripting |

---

## Environment Reference

| | Local | Production |
|-|-------|------------|
| URL | `http://localhost:8080` | `https://dev-climatekg.semanticclimate.org` |
| Server | Docker Desktop | Hetzner VM `178.104.156.88` |
| DB user | `wikibase` | `wikibase` |
| DB password | `wikibase` | (see `/opt/wikibase/.env` on server) |
| Admin user | `admin` | `admin` |
| Admin password | `adminpass123!` | (see `/opt/wikibase/.env` on server) |
| Compose command | `docker compose up -d` | `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d` |
