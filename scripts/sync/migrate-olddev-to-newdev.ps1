#Requires -Version 5.1
<#
.SYNOPSIS
    One-off migration: copy the old DEV database (and optionally uploads/images) into the
    brand-new new-DEV TIB machine (climatekg01.develop.service.tib.eu).

.PARAMETER DbOnly
    Skip the uploads/images sync. Use when only the database needs migrating.
    Usage:  .\scripts\sync\migrate-olddev-to-newdev.ps1 -DbOnly

.DESCRIPTION
    Part of the new-TIB-machines rollout (see docs/new-tib-machines-provisioning-plan.md,
    Phase 4). Migrates content from the old DEV server (178.104.156.88, root access) into
    new-DEV (climatekg01.develop.service.tib.eu, worthingtons + passwordless sudo, fresh/empty
    Wikibase stack from Phase 3 provisioning).

    1.  Dumps the OLD DEV MariaDB database inside its container using --result-file
        (avoids SSH/PowerShell stream encoding corruption).
    2.  Copies the dump from container to OLD DEV host, SCP's it to this Windows machine.
    3.  Size-verifies the dump (must be > 1 MB).
    4.  SCP's the dump to new-DEV host, imports it via docker cp + mysql source (-f) inside
        the new-DEV container (all docker commands via sudo, since new-DEV's .env/docker
        state is root-owned).
    5.  Syncs uploads/images: tar inside OLD DEV wikibase container -> SCP via LOCAL ->
        extract into new-DEV wikibase container. Skipped when -DbOnly is set.
    6.  Truncates objectcache/l10n_cache (IF EXISTS) and runs MediaWiki update on new-DEV.
    7.  Re-registers new-DEV sitelinks by restarting wikibase-sitelinks-init.
    8.  Restarts the wikibase container on new-DEV.

.NOTES
    DB passwords are read LIVE from each server's /opt/wikibase/.env over SSH (no local
    plaintext copies needed) -- OLD DEV is root so no sudo needed there; new-DEV requires
    `sudo grep` since deploy.sh creates .env as root:root 0600.

    OLD DEV SSH key: id_wikibase_sync if present (passphrase-free, added May 2026), else
    falls back to id_rsa (passphrase-protected, prompts each use).
    new-DEV SSH key: id_rsa (passphrase-protected; new TIB boxes only trust this key) --
    expect a passphrase prompt for EVERY ssh/scp call to new-DEV, there is no agent caching.
#>

param(
    [switch]$DbOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$OLD_HOST         = "178.104.156.88"
$OLD_USER         = "root"
$OLD_DB_USER      = "wikibase"
$OLD_DB_NAME      = "my_wiki"
$OLD_CONTAINER    = "wikibase-mariadb"
$OLD_WB_CONTAINER = "wikibase"

$NEW_HOST         = "climatekg01.develop.service.tib.eu"
$NEW_USER         = "worthingtons"
$NEW_DB_USER      = "wikibase"
$NEW_DB_NAME      = "my_wiki"
$NEW_CONTAINER    = "wikibase-mariadb"
$NEW_WB_CONTAINER = "wikibase"
$NEW_REMOTE_DIR   = "/opt/wikibase"
$NEW_COMPOSE      = "docker compose -f docker-compose.yml -f docker-compose.dev.yml"

$syncKey = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"
$OLD_KEY = if (Test-Path $syncKey) { $syncKey } else { "C:\Users\$env:USERNAME\.ssh\id_rsa" }
$NEW_KEY = "C:\Users\$env:USERNAME\.ssh\id_rsa"

$BACKUP_DIR      = "C:\Wikibase\backups"
$TIMESTAMP       = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME   = "olddev_to_newdev_$TIMESTAMP.sql"
$IMAGES_ARCHIVE  = "olddev_to_newdev_images_$TIMESTAMP.tar.gz"

$CONTAINER_TEMP        = "/tmp/$DUMP_FILENAME"
$OLD_HOST_TEMP         = "/tmp/$DUMP_FILENAME"
$LOCAL_FILE            = Join-Path $BACKUP_DIR $DUMP_FILENAME
$NEW_HOST_TEMP         = "/tmp/$DUMP_FILENAME"
$TARGET_CONTAINER_TEMP = "/tmp/restore.sql"

$OLD_IMAGES_CONTAINER  = "/tmp/$IMAGES_ARCHIVE"
$OLD_IMAGES_HOST_TEMP  = "/tmp/$IMAGES_ARCHIVE"
$LOCAL_IMAGES_FILE     = Join-Path $BACKUP_DIR $IMAGES_ARCHIVE
$NEW_IMAGES_TEMP       = "/tmp/$IMAGES_ARCHIVE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Step([string]$msg) { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Die([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Step "Pre-flight checks"

if (-not (Test-Path $BACKUP_DIR)) { New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null }
foreach ($cmd in @("ssh","scp")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Die "$cmd not found." }
}
if (-not (Test-Path $OLD_KEY)) { Die "OLD DEV key not found at $OLD_KEY." }
if (-not (Test-Path $NEW_KEY)) { Die "new-DEV key not found at $NEW_KEY." }

Write-Host "Testing SSH to OLD DEV ($OLD_HOST)..." -ForegroundColor Yellow
if (-not (Test-NetConnection -ComputerName $OLD_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Die "Cannot reach OLD DEV port 22."
}
OK "SSH port reachable"

Write-Host "Testing SSH to new-DEV ($NEW_HOST)..." -ForegroundColor Yellow
if (-not (Test-NetConnection -ComputerName $NEW_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Die "Cannot reach new-DEV port 22."
}
OK "SSH port reachable"

# ---------------------------------------------------------------------------
# Resolve DB passwords LIVE from each server's .env (never stored locally)
# ---------------------------------------------------------------------------
Step "Resolving DB credentials live from each server"

$OLD_DB_PASS = (ssh -i $OLD_KEY "${OLD_USER}@${OLD_HOST}" "grep -E '^DB_PASS=' /opt/wikibase/.env | cut -d= -f2").Trim()
if ([string]::IsNullOrEmpty($OLD_DB_PASS)) { Die "Could not read OLD DEV DB_PASS." }
OK "OLD DEV DB_PASS resolved"

$NEW_DB_PASS = (ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" "sudo grep -E '^DB_PASS=' ${NEW_REMOTE_DIR}/.env | cut -d= -f2").Trim()
if ([string]::IsNullOrEmpty($NEW_DB_PASS)) { Die "Could not read new-DEV DB_PASS." }
OK "new-DEV DB_PASS resolved"

# ---------------------------------------------------------------------------
# Step 1 -- Dump OLD DEV database inside the container
# ---------------------------------------------------------------------------
Step "1/8  Dumping OLD DEV database (inside container)"

$dumpCmd = "docker exec $OLD_CONTAINER mysqldump " +
    "-u $OLD_DB_USER -p'$OLD_DB_PASS' " +
    "--default-character-set=utf8mb4 " +
    "--single-transaction --quick --max_allowed_packet=512M " +
    "--result-file=$CONTAINER_TEMP $OLD_DB_NAME"

ssh -i $OLD_KEY "${OLD_USER}@${OLD_HOST}" $dumpCmd
if ($LASTEXITCODE -ne 0) { Die "mysqldump on OLD DEV failed." }
OK "Dump written to $CONTAINER_TEMP inside $OLD_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 -- Copy dump from container to OLD DEV host, then to LOCAL
# ---------------------------------------------------------------------------
Step "2/8  Copying dump to LOCAL machine"

ssh -i $OLD_KEY "${OLD_USER}@${OLD_HOST}" "docker cp ${OLD_CONTAINER}:${CONTAINER_TEMP} ${OLD_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "docker cp on OLD DEV failed." }

scp -i $OLD_KEY "${OLD_USER}@${OLD_HOST}:${OLD_HOST_TEMP}" $LOCAL_FILE
if ($LASTEXITCODE -ne 0) { Die "SCP of dump from OLD DEV failed." }

$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) { Die "Dump is too small ($fileSize bytes) -- mysqldump likely failed." }
OK "Dump: $([math]::Round($fileSize/1MB, 1)) MB -- $LOCAL_FILE"

ssh -i $OLD_KEY "${OLD_USER}@${OLD_HOST}" "docker exec ${OLD_CONTAINER} rm -f ${CONTAINER_TEMP}; rm -f ${OLD_HOST_TEMP}"
OK "Cleaned up OLD DEV temp files"

# ---------------------------------------------------------------------------
# Step 3 -- SCP dump to new-DEV host and import (sudo docker cp/exec throughout)
# ---------------------------------------------------------------------------
Step "3/8  Uploading and importing dump into new-DEV database"

scp -i $NEW_KEY $LOCAL_FILE "${NEW_USER}@${NEW_HOST}:${NEW_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "SCP of dump to new-DEV failed." }
OK "Dump at $NEW_HOST_TEMP on new-DEV host"

ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" (@"
sudo docker cp ${NEW_HOST_TEMP} ${NEW_CONTAINER}:${TARGET_CONTAINER_TEMP}
sudo docker exec ${NEW_CONTAINER} mysql -f -u ${NEW_DB_USER} -p'${NEW_DB_PASS}' --default-character-set=utf8mb4 ${NEW_DB_NAME} -e 'source ${TARGET_CONTAINER_TEMP}'
sudo docker exec ${NEW_CONTAINER} rm -f ${TARGET_CONTAINER_TEMP}
rm -f ${NEW_HOST_TEMP}
"@ -replace "`r`n", "`n")
if ($LASTEXITCODE -ne 0) { Die "Database import on new-DEV failed." }
OK "Database import complete on new-DEV"

# ---------------------------------------------------------------------------
# Step 4 -- Sync uploads/images from OLD DEV to new-DEV
# ---------------------------------------------------------------------------
if ($DbOnly) {
    Step "4/8  Skipping uploads/images sync (-DbOnly)"
    OK "Images sync skipped"
} else {
    Step "4/8  Syncing uploads/images from OLD DEV to new-DEV"

    Write-Host "  Creating images archive inside OLD DEV wikibase container (excluding thumbnails)..." -ForegroundColor Yellow
    ssh -i $OLD_KEY "${OLD_USER}@${OLD_HOST}" "docker exec ${OLD_WB_CONTAINER} tar --exclude=thumb -czf ${OLD_IMAGES_CONTAINER} /var/www/html/images"
    if ($LASTEXITCODE -ne 0) { Die "tar archive of OLD DEV images failed." }

    Write-Host "  Copying archive from OLD DEV container to OLD DEV host..." -ForegroundColor Yellow
    ssh -i $OLD_KEY "${OLD_USER}@${OLD_HOST}" "docker cp ${OLD_WB_CONTAINER}:${OLD_IMAGES_CONTAINER} ${OLD_IMAGES_HOST_TEMP} && docker exec ${OLD_WB_CONTAINER} rm -f ${OLD_IMAGES_CONTAINER}"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive from OLD DEV container failed." }

    Write-Host "  Downloading archive to LOCAL machine..." -ForegroundColor Yellow
    scp -i $OLD_KEY "${OLD_USER}@${OLD_HOST}:${OLD_IMAGES_HOST_TEMP}" $LOCAL_IMAGES_FILE
    if ($LASTEXITCODE -ne 0) { Die "SCP of images archive from OLD DEV failed." }
    ssh -i $OLD_KEY "${OLD_USER}@${OLD_HOST}" "rm -f ${OLD_IMAGES_HOST_TEMP}"

    $archiveSize = (Get-Item $LOCAL_IMAGES_FILE).Length
    OK "Images archive: $([math]::Round($archiveSize/1MB, 1)) MB -- $LOCAL_IMAGES_FILE"

    Write-Host "  Uploading archive to new-DEV host..." -ForegroundColor Yellow
    scp -i $NEW_KEY $LOCAL_IMAGES_FILE "${NEW_USER}@${NEW_HOST}:${NEW_IMAGES_TEMP}"
    if ($LASTEXITCODE -ne 0) { Die "SCP of images archive to new-DEV failed." }

    Write-Host "  Extracting archive into new-DEV container (wikibase_images volume)..." -ForegroundColor Yellow
    ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" "sudo docker cp ${NEW_IMAGES_TEMP} ${NEW_WB_CONTAINER}:/tmp/images_restore.tar.gz"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive to new-DEV container failed." }

    ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" "sudo docker exec ${NEW_WB_CONTAINER} sh -c 'find /var/www/html/images -mindepth 1 -not -name ckglogo1.png -not -name ckglogo1.svg -delete 2>/dev/null; tar -xzf /tmp/images_restore.tar.gz --strip-components=3 -C /var/www/html --exclude=var/www/html/images/ckglogo1.png --exclude=var/www/html/images/ckglogo1.svg && rm /tmp/images_restore.tar.gz'"
    if ($LASTEXITCODE -ne 0) { Die "Images extraction on new-DEV failed." }

    ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" "rm -f ${NEW_IMAGES_TEMP}"
    OK "Images synced to new-DEV"
}

# ---------------------------------------------------------------------------
# Step 5 -- Clear stale cache tables on new-DEV and run MediaWiki update
# ---------------------------------------------------------------------------
Step "5/8  Clearing stale cache tables on new-DEV and running MediaWiki update"

ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" (@"
sudo docker exec ${NEW_CONTAINER} mysql -u ${NEW_DB_USER} -p'${NEW_DB_PASS}' ${NEW_DB_NAME} -e 'TRUNCATE TABLE objectcache; TRUNCATE TABLE l10n_cache;'
sudo docker exec ${NEW_WB_CONTAINER} php /var/www/html/maintenance/run.php update --conf /config/LocalSettings.php --quick
sudo docker exec ${NEW_WB_CONTAINER} php /var/www/html/maintenance/run.php rebuildrecentchanges --conf /config/LocalSettings.php
"@ -replace "`r`n", "`n")
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Cache truncation or MediaWiki update had errors (non-fatal)." -ForegroundColor Yellow
} else {
    OK "Caches cleared and MediaWiki updated on new-DEV"
}

# ---------------------------------------------------------------------------
# Step 6 -- Re-register new-DEV sitelinks
# ---------------------------------------------------------------------------
Step "6/8  Re-registering new-DEV sitelinks"

ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" (@"
cd ${NEW_REMOTE_DIR}
sudo $NEW_COMPOSE restart wikibase-sitelinks-init
sleep 15
"@ -replace "`r`n", "`n")
OK "Sitelinks init restarted on new-DEV"

# ---------------------------------------------------------------------------
# Step 7 -- Restart wikibase on new-DEV
# ---------------------------------------------------------------------------
Step "7/8  Restarting wikibase container on new-DEV"

ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" (@"
cd ${NEW_REMOTE_DIR}
sudo $NEW_COMPOSE restart wikibase
"@ -replace "`r`n", "`n")
OK "Wikibase restarted on new-DEV"

# ---------------------------------------------------------------------------
# Step 8 -- Verify
# ---------------------------------------------------------------------------
Step "8/8  Verifying new-DEV after migration"

Start-Sleep -Seconds 10
ssh -i $NEW_KEY "${NEW_USER}@${NEW_HOST}" 'curl -s -o /dev/null -w "wiki:%{http_code}\n" http://127.0.0.1:8080/wiki/Main_Page'
curl.exe -s -o NUL -w "external-wiki:%{http_code}`n" https://dev-climatekg.tibwiki.io/wiki/Main_Page

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " OLD DEV -> new-DEV migration complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local dump file : $LOCAL_FILE"
Write-Host "  Timestamp       : $TIMESTAMP"
if ($DbOnly) {
    Write-Host "  Images archive  : (skipped, -DbOnly)"
} else {
    Write-Host "  Images archive  : $LOCAL_IMAGES_FILE"
}
Write-Host ""
Write-Host "Verify at https://dev-climatekg.tibwiki.io/wiki/Main_Page" -ForegroundColor Yellow
Write-Host ""
