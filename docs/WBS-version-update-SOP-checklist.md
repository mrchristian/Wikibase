# WBS Post-Upgrade User Test Checklist

October 2026, SW

 - Test Localhhost first

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
- [ ] Homepage loads at http://localhost:8080
- [ ] HTTP response is successful
- [ ] no startup errors are visible in Docker logs
- [ ] the site is reachable through the expected local URL

### 2. Site identity and branding
- [ ] site title is correct
- [ ] logo loads correctly
- [ ] skin/style is rendered as expected: Vector 2022 $wgVectorResponsive set to true (to be confirmed as only possible by inspecting local config)
- [ ] Check mobile browsing is working. Switch to Developer Tools in Chrome, etc.
- [ ] no default branding is showing where custom branding should appear

### 3. Wikibase configuration
- [ ] custom namespaces are present: e.g., IPCC, Project.
- [ ] namespace IDs still match the expected values
- [ ] special pages and local configuration still resolve correctly
- [ ] custom LocalSettings files are still being loaded

### 4. Functional checks
- [ ] search works (OpenSearch)
- [ ] item pages load
- [ ] entity editing or form access works if applicable. Try a QID, PID, and normal page
- [ ] SPARQL endpoint is reachable if used in this environment
- [ ] Query UI loads correctly if required

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

