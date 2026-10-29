# WBS Post-Upgrade and for Other Significant Chnages - User Test Checklist and Admin Tests

October 2026, SW

 1. Test Localhhost first
 2. Test on DEV

## Purpose
This checklist is used after a WBS version update has already been completed. It is for user validation and acceptance testing, not for performing the upgrade itself.

## Scope
Use this checklist after a deployment or rebuild to confirm the site still works and that local custom configuration is intact.

## Key validation areas
- website loads successfully
- site identity and branding are correct
- custom namespaces are present
- key functionality still works
- database and service health remain sound

## User validation checklist

### 1. Site access
- [ ] Homepage loads  and site browsable at http://localhost:8080
- [ ] HTTP response is successful
- [ ] no startup errors are visible in Docker logs

### 2. Site identity and branding
- [ ] site title is correct
- [ ] logo loads correctly
- [ ] skin/style is rendered as expected
- [ ] Check mobile browsing is working. See links in footer. Switch to Developer Tools in Chrome, etc.
- [ ] no default branding is showing where custom branding should appear

### 2a. Key areas load
- [ ] Login pw works
- [ ] Wiki: http://localhost:8080
- [ ] Query UI: http://localhost:8081
- [ ] SPARQL endpoint: http://localhost:9999/bigdata/namespace/wdq/sparql (root http://localhost:9999/ returns 404 by design)
- [ ] Blazegraph workbench: http://localhost:9999/bigdata/#status
- [ ] Special Pages - http://localhost:8080/wiki/Special:SpecialPages
- [ ] IPCC Pages entry point - http://localhost:8080/wiki/IPCC:AR6
- [ ] Sitelinks - bi-directional check and pageinfo check - http://localhost:8080/wiki/Item:Q14 to http://localhost:8080/wiki/IPCC:AR6/SR15/SPM 

### 3. Wikibase configuration
- [ ] custom namespaces are present: e.g., IPCC, Project, Item, Property, EntitySchema. http://localhost:8080/wiki/Special:NamespaceInfo 
- [ ] namespace IDs still match the expected values
- [ ] special pages and local configuration still resolve correctly
- [ ] custom LocalSettings files are still being loaded (add more detail about what this means) 

### 4. Functional checks
- [ ] Search - run from several pages, use predictive and list view. See data stats for search index count. 
- [ ] item pages load
- [ ] entity editing or form access works if applicable. Try a QID, PID, and normal page
- [ ] SPARQL endpoint is reachable if used in this environment
- [ ] Query UI loads correctly if required, run a query

```sparql
#defaultView:Graph
SELECT ?item ?itemLabel ?linkTo ?linkToLabel
WHERE {
  ?item <http://localhost:8080/prop/direct/P12> ?linkTo .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
LIMIT 200
```
NB: Full tests for SPARQL and APIs are her: [text](docs/sparql-api-tests-and-graph-queries.md)

### 5. Data and integration checks
- [ ] database connection is healthy
- [ ] no data loss or content drift is visible
- [ ] item links and sitelinks still resolve correctly
- [ ] custom extensions remain active

### 6. Health and stability checks
- [ ] all relevant Docker containers are healthy
- [ ] MariaDB version is expected and supported 
- [ ] no repeat restarts or crash loops are occurring
- [ ] there are no critical log errors after the update

## Quick verification commands
```powershell
cd C:\Wikibase
docker compose ps
docker exec wikibase-mariadb mariadb --version
```

```powershell
curl.exe -I http://localhost:8080/
```

```powershell
curl.exe "http://localhost:8080/w/api.php?action=query&meta=siteinfo&siprop=general&format=json"
curl.exe "http://localhost:8080/w/api.php?action=query&meta=siteinfo&siprop=general%7Cnamespaces&format=json"
```

## Acceptance rule
The update is accepted only when all required user validation items pass and the custom project configuration is still present after deployment.

## Notes
This checklist is intended for the testing stage after an update has already been applied. It is not a deployment procedure or upgrade playbook.

