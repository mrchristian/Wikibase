# XML Import Troubleshooting

## Symptom
Special:Import writes only the SHA1 hash as page content: `n5onrvg31b61r9nu9kftng4t1ee6y3c`
Happens with both the original export and the anchored version — confirmed wiki config issue.

## Options to try (in order)

### 1. Use the maintenance script (most reliable)
Bypasses HTTP/PHP upload limits entirely.
```powershell
docker cp api/xml/ClimateKG-20260602204800-anchored.xml wikibase-wikibase-1:/tmp/import.xml
docker exec wikibase-wikibase-1 php /var/www/html/maintenance/importDump.php /tmp/import.xml
```

### 2. Increase PHP memory_limit
Add to `php/uploads.ini`, then restart:
```ini
memory_limit = 256M
```
```powershell
docker compose restart wikibase
```

### 3. Add explicit import permissions to LocalSettings.general.php
These are sysop defaults but worth making explicit:
```php
$wgGroupPermissions['sysop']['import'] = true;
$wgGroupPermissions['sysop']['importupload'] = true;
```

### 4. Check container logs during import
```powershell
docker logs wikibase-wikibase-1 --tail 100
```

## Files
- Original export: `ClimateKG-20260602204800.xml`
- Anchored version (ready to import): `ClimateKG-20260602204800-anchored.xml`
  - 1061/1061 citation anchors matched and inserted
  - All spot-checks passed including multi-variant cases (IEA--2019a/b/c/e)
