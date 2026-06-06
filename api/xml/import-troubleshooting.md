# XML Import Troubleshooting

## Symptom
Special:Import writes only the SHA1 hash as page content: `n5onrvg31b61r9nu9kftng4t1ee6y3c`
Happens with both the original export and the anchored version — confirmed wiki config issue.

---

## Preferred method: API edit ✅ CONFIRMED WORKING

Use `api_edit_page.py` (project root). It reads the wikitext from the XML export and
submits it via the MediaWiki Action API, creating a fresh revision every time.

```powershell
# Default: uses ClimateKG-20260602204800-anchored.xml and IPCC:AR6/WGIII/Chapter-9
python api_edit_page.py

# Custom XML file or page title
python api_edit_page.py --xml api/xml/MyExport.xml --page "IPCC:AR6/WGIII/Chapter-10"
```

Credentials are read from `.env` (`WB_PASSWORD` / `WB_ADMIN_USER`); local docker default
(`adminpass123!`) is used as fallback.

**Why not `importDump.php`?**
`importDump.php` checks the revision ID from `<id>` in the XML. If that revision ID already
exists in the database (e.g. from a prior import of the same export file), the revision is
silently skipped — even if the content has changed. The API edit has no such restriction.

---

## Alternative: importDump.php maintenance script

Only use this for a **first-time** import of pages that do not yet exist in the database.
Container name is `wikibase` (not `wikibase-wikibase-1`).

```powershell
docker cp api/xml/ClimateKG-20260602204800-anchored.xml wikibase:/tmp/import.xml
docker exec wikibase php /var/www/html/maintenance/importDump.php /tmp/import.xml
```

**Known limitation:** If the revision ID in the XML already exists in the DB, the import is
skipped silently ("Done!" with no new revision created). Use the API edit method instead.

---

## Other notes

### PHP memory_limit
Already set to 256 M in `php/uploads.ini` — no action needed.

### Check container logs during import
```powershell
docker logs wikibase --tail 100
```

---

## Files
- Original export: `ClimateKG-20260602204800.xml`
- Anchored version: `ClimateKG-20260602204800-anchored.xml`
  - 1061/1061 citation anchors matched and inserted by `api/fix_xml_anchors.py`
  - All spot-checks passed including multi-variant cases (IEA--2019a/b/c/e)
- Import script: `api_edit_page.py` (project root)
