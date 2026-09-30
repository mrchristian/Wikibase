#Requires -Version 5.1
<#
.SYNOPSIS
    Promote new-TEST's database (and optionally images) to new-PROD.

.PARAMETER IncludeImages
    Also promote uploaded images from new-TEST to new-PROD.

.DESCRIPTION
    Part of the new-TIB-machines rollout (see docs/new-tib-machines-provisioning-plan.md,
    Phase 4 step 14). Promotes new-TEST's content (previously promoted from new-DEV via
    migrate-newdev-to-newtest.ps1) forward to new-PROD (climatekg21.service.tib.eu),
    following the same DEV->TEST->PROD staged pattern used historically by
    sync-dev-to-test.ps1 / sync-test-to-prod.ps1, but adapted for the new boxes: both
    source and target use `worthingtons` + passwordless sudo (no root SSH), and credentials
    are resolved LIVE via SSH grep rather than a local plaintext .env copy.

    Steps mirror migrate-newdev-to-newtest.ps1 exactly (dump -> copy -> drop/recreate +
    import via stdin -> clear caches -> MediaWiki update -> reset PROD's OWN admin password
    -> re-register sitelinks -> restart wikibase -> optional images).

.NOTES
    WARNING: This operation overwrites new-PROD's database (and optionally images).
    Requires typing PROMOTE to confirm. This is PRODUCTION.

    SSH key: id_rsa (passphrase-protected) for both new-TEST and new-PROD -- expect a
    passphrase prompt for every ssh/scp call, there is no agent caching.
#>

param(
    [switch]$IncludeImages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Safety confirmation
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "WARNING: This will overwrite new-PROD's database with new-TEST data." -ForegroundColor Red
if ($IncludeImages) {
    Write-Host "WARNING: This will ALSO overwrite new-PROD's images/uploads with new-TEST data." -ForegroundColor Red
}
Write-Host "Target: new-PROD (climatekg21.service.tib.eu / climatekg.tibwiki.io) -- PRODUCTION" -ForegroundColor Red
Write-Host ""
$confirm = Read-Host "Type PROMOTE to confirm"
if ($confirm -ne "PROMOTE") {
    Write-Host "Aborted - no changes made." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$SRC_HOST         = "climatekg11.test.service.tib.eu"
$SRC_USER         = "worthingtons"
$SRC_DB_USER      = "wikibase"
$SRC_DB_NAME      = "my_wiki"
$SRC_CONTAINER    = "wikibase-mariadb"
$SRC_WB_CONTAINER = "wikibase"
$SRC_REMOTE_DIR   = "/opt/wikibase"

$DST_HOST         = "climatekg21.service.tib.eu"
$DST_USER         = "worthingtons"
$DST_DB_USER      = "wikibase"
$DST_DB_NAME      = "my_wiki"
$DST_CONTAINER    = "wikibase-mariadb"
$DST_WB_CONTAINER = "wikibase"
$DST_REMOTE_DIR   = "/opt/wikibase"
$DST_COMPOSE      = "docker compose -f docker-compose.yml -f docker-compose.prod.yml"

$SSH_KEY = "C:\Users\$env:USERNAME\.ssh\id_rsa"

$BACKUP_DIR      = "C:\Wikibase\backups"
$TIMESTAMP       = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME   = "newtest_to_newprod_$TIMESTAMP.sql"
$IMAGES_ARCHIVE  = "newtest_to_newprod_images_$TIMESTAMP.tar.gz"

$CONTAINER_TEMP     = "/tmp/$DUMP_FILENAME"
$SRC_HOST_TEMP      = "/tmp/$DUMP_FILENAME"
$LOCAL_FILE         = Join-Path $BACKUP_DIR $DUMP_FILENAME
$DST_HOST_TEMP      = "/tmp/$DUMP_FILENAME"

$SRC_IMAGES_CONTAINER = "/tmp/$IMAGES_ARCHIVE"
$SRC_IMAGES_HOST_TEMP = "/tmp/$IMAGES_ARCHIVE"
$LOCAL_IMAGES_FILE    = Join-Path $BACKUP_DIR $IMAGES_ARCHIVE
$DST_IMAGES_HOST_TEMP = "/tmp/$IMAGES_ARCHIVE"

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
if (-not (Test-Path $SSH_KEY)) { Die "SSH key not found at $SSH_KEY." }

Write-Host "Testing SSH to new-TEST ($SRC_HOST)..." -ForegroundColor Yellow
if (-not (Test-NetConnection -ComputerName $SRC_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) { Die "Cannot reach new-TEST port 22." }
OK "SSH port reachable"

Write-Host "Testing SSH to new-PROD ($DST_HOST)..." -ForegroundColor Yellow
if (-not (Test-NetConnection -ComputerName $DST_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) { Die "Cannot reach new-PROD port 22." }
OK "SSH port reachable"

# ---------------------------------------------------------------------------
# Resolve DB + admin passwords LIVE from each server's .env
# ---------------------------------------------------------------------------
Step "Resolving credentials live from each server"

$SRC_DB_PASS = (ssh -i $SSH_KEY "${SRC_USER}@${SRC_HOST}" "sudo grep -E '^DB_PASS=' ${SRC_REMOTE_DIR}/.env | cut -d= -f2").Trim()
if ([string]::IsNullOrEmpty($SRC_DB_PASS)) { Die "Could not read new-TEST DB_PASS." }
OK "new-TEST DB_PASS resolved"

$DST_DB_PASS = (ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo grep -E '^DB_PASS=' ${DST_REMOTE_DIR}/.env | cut -d= -f2").Trim()
if ([string]::IsNullOrEmpty($DST_DB_PASS)) { Die "Could not read new-PROD DB_PASS." }
OK "new-PROD DB_PASS resolved"

$DST_MW_ADMIN_PASS = (ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo grep -E '^MW_ADMIN_PASS=' ${DST_REMOTE_DIR}/.env | cut -d= -f2").Trim()
if ([string]::IsNullOrEmpty($DST_MW_ADMIN_PASS)) { Die "Could not read new-PROD MW_ADMIN_PASS." }
OK "new-PROD MW_ADMIN_PASS resolved (will be re-applied after migration)"

# ---------------------------------------------------------------------------
# Step 1 -- Dump new-TEST database inside the container
# ---------------------------------------------------------------------------
Step "1/8  Dumping new-TEST database (inside container)"

$dumpCmd = "sudo docker exec $SRC_CONTAINER mysqldump " +
    "-u $SRC_DB_USER -p'$SRC_DB_PASS' " +
    "--default-character-set=utf8mb4 " +
    "--single-transaction --quick --max_allowed_packet=512M " +
    "--result-file=$CONTAINER_TEMP $SRC_DB_NAME"

ssh -i $SSH_KEY "${SRC_USER}@${SRC_HOST}" $dumpCmd
if ($LASTEXITCODE -ne 0) { Die "mysqldump on new-TEST failed." }
OK "Dump written to $CONTAINER_TEMP inside $SRC_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 -- Copy dump from container to new-TEST host, then to LOCAL
# ---------------------------------------------------------------------------
Step "2/8  Copying dump to LOCAL machine"

ssh -i $SSH_KEY "${SRC_USER}@${SRC_HOST}" "sudo docker cp ${SRC_CONTAINER}:${CONTAINER_TEMP} ${SRC_HOST_TEMP} && sudo chmod 644 ${SRC_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "docker cp on new-TEST failed." }

scp -i $SSH_KEY "${SRC_USER}@${SRC_HOST}:${SRC_HOST_TEMP}" $LOCAL_FILE
if ($LASTEXITCODE -ne 0) { Die "SCP of dump from new-TEST failed." }

$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) { Die "Dump is too small ($fileSize bytes) -- mysqldump likely failed." }
OK "Dump: $([math]::Round($fileSize/1MB, 1)) MB -- $LOCAL_FILE"

ssh -i $SSH_KEY "${SRC_USER}@${SRC_HOST}" "sudo docker exec ${SRC_CONTAINER} rm -f ${CONTAINER_TEMP}; rm -f ${SRC_HOST_TEMP}"
OK "Cleaned up new-TEST temp files"

# ---------------------------------------------------------------------------
# Step 3 -- SCP dump to new-PROD host and import (drop/recreate for a clean import)
# ---------------------------------------------------------------------------
Step "3/8  Uploading and importing dump into new-PROD database"

scp -i $SSH_KEY $LOCAL_FILE "${DST_USER}@${DST_HOST}:${DST_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "SCP of dump to new-PROD failed." }
OK "Dump at $DST_HOST_TEMP on new-PROD host"

Write-Host "  Dropping and recreating new-PROD database for a clean import..." -ForegroundColor Yellow
ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker exec ${DST_CONTAINER} mysql -u ${DST_DB_USER} -p'${DST_DB_PASS}' -e 'DROP DATABASE IF EXISTS ${DST_DB_NAME}; CREATE DATABASE ${DST_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
if ($LASTEXITCODE -ne 0) { Die "Failed to drop/recreate new-PROD database." }

ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker exec -i ${DST_CONTAINER} mysql -u ${DST_DB_USER} -p'${DST_DB_PASS}' --default-character-set=utf8mb4 ${DST_DB_NAME} < ${DST_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "Database import on new-PROD failed." }

ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "rm -f ${DST_HOST_TEMP}"
OK "Database import complete on new-PROD"

# ---------------------------------------------------------------------------
# Step 4 -- Clear stale cache tables on new-PROD
# ---------------------------------------------------------------------------
Step "4/8  Clearing stale cache tables on new-PROD"

ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker exec ${DST_CONTAINER} mysql -u ${DST_DB_USER} -p'${DST_DB_PASS}' ${DST_DB_NAME} -e 'DELETE FROM objectcache; DELETE FROM l10n_cache;'"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Cache clear on new-PROD had errors (non-fatal)." -ForegroundColor Yellow
} else {
    OK "Cache tables cleared on new-PROD"
}

# ---------------------------------------------------------------------------
# Step 5 -- MediaWiki update + recentchanges rebuild
# ---------------------------------------------------------------------------
Step "5/8  Running MediaWiki update on new-PROD"

ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker exec ${DST_WB_CONTAINER} php /var/www/html/maintenance/run.php update --conf /config/LocalSettings.php --quick"
if ($LASTEXITCODE -ne 0) { Die "MediaWiki update on new-PROD failed." }
OK "MediaWiki update complete"

ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker exec ${DST_WB_CONTAINER} php /var/www/html/maintenance/run.php rebuildrecentchanges --conf /config/LocalSettings.php"
OK "recentchanges rebuilt on new-PROD"

# ---------------------------------------------------------------------------
# Step 6 -- Reset new-PROD's admin password back to its OWN .env value
# ---------------------------------------------------------------------------
Step "6/8  Resetting new-PROD admin password to its own .env value"

ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker exec ${DST_WB_CONTAINER} php /var/www/html/maintenance/run.php changePassword --conf /config/LocalSettings.php --user=admin --password='${DST_MW_ADMIN_PASS}'"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] changePassword on new-PROD failed (non-fatal -- check manually)." -ForegroundColor Yellow
} else {
    OK "new-PROD admin password reset -- admin / (new-PROD's .env MW_ADMIN_PASS)"
}

# ---------------------------------------------------------------------------
# Step 7 -- Re-register new-PROD sitelinks then restart wikibase
# ---------------------------------------------------------------------------
Step "7/8  Re-registering new-PROD sitelinks and restarting wikibase"

ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" (@"
cd ${DST_REMOTE_DIR}
sudo $DST_COMPOSE restart wikibase-sitelinks-init
sleep 20
sudo $DST_COMPOSE restart wikibase
"@ -replace "`r`n", "`n")
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Sitelinks init or wikibase restart failed (non-fatal -- check manually)." -ForegroundColor Yellow
} else {
    OK "Sitelinks init complete and wikibase restarted on new-PROD"
}

# ---------------------------------------------------------------------------
# Optional: Promote images from new-TEST to new-PROD
# ---------------------------------------------------------------------------
if ($IncludeImages) {
    Step "Images 1/4  Archiving new-TEST wikibase images (excluding thumbnails)"

    ssh -i $SSH_KEY "${SRC_USER}@${SRC_HOST}" "sudo docker exec ${SRC_WB_CONTAINER} tar --exclude=thumb -czf ${SRC_IMAGES_CONTAINER} /var/www/html/images"
    if ($LASTEXITCODE -ne 0) { Die "tar archive of new-TEST images failed." }

    ssh -i $SSH_KEY "${SRC_USER}@${SRC_HOST}" "sudo docker cp ${SRC_WB_CONTAINER}:${SRC_IMAGES_CONTAINER} ${SRC_IMAGES_HOST_TEMP} && sudo chmod 644 ${SRC_IMAGES_HOST_TEMP} && sudo docker exec ${SRC_WB_CONTAINER} rm -f ${SRC_IMAGES_CONTAINER}"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive from new-TEST container failed." }

    Step "Images 2/4  Transferring archive: new-TEST -> local -> new-PROD"

    scp -i $SSH_KEY "${SRC_USER}@${SRC_HOST}:${SRC_IMAGES_HOST_TEMP}" $LOCAL_IMAGES_FILE
    if ($LASTEXITCODE -ne 0) { Die "SCP of images archive from new-TEST failed." }
    ssh -i $SSH_KEY "${SRC_USER}@${SRC_HOST}" "rm -f ${SRC_IMAGES_HOST_TEMP}"

    $archiveSize = (Get-Item $LOCAL_IMAGES_FILE).Length
    OK "Images archive: $([math]::Round($archiveSize/1MB, 1)) MB -- $LOCAL_IMAGES_FILE"

    scp -i $SSH_KEY $LOCAL_IMAGES_FILE "${DST_USER}@${DST_HOST}:${DST_IMAGES_HOST_TEMP}"
    if ($LASTEXITCODE -ne 0) { Die "SCP of images archive to new-PROD failed." }

    Step "Images 3/4  Extracting images on new-PROD"

    ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker cp ${DST_IMAGES_HOST_TEMP} ${DST_WB_CONTAINER}:/tmp/images_restore.tar.gz"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive to new-PROD container failed." }

    ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "sudo docker exec ${DST_WB_CONTAINER} sh -c 'find /var/www/html/images -mindepth 1 -not -name ckglogo1.png -not -name ckglogo1.svg -delete 2>/dev/null; tar -xzf /tmp/images_restore.tar.gz --strip-components=3 -C /var/www/html --exclude=var/www/html/images/ckglogo1.png --exclude=var/www/html/images/ckglogo1.svg && chown -R www-data:www-data /var/www/html/images 2>/dev/null; rm -f /tmp/images_restore.tar.gz'"
    if ($LASTEXITCODE -ne 0) { Die "Images extraction on new-PROD failed." }

    ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" "rm -f ${DST_IMAGES_HOST_TEMP}"
    Step "Images 4/4  Done"
    OK "Images synced to new-PROD"
}

# ---------------------------------------------------------------------------
# Step 8 -- Verify
# ---------------------------------------------------------------------------
Step "8/8  Verifying new-PROD after migration"

Start-Sleep -Seconds 10
ssh -i $SSH_KEY "${DST_USER}@${DST_HOST}" 'curl -s -o /dev/null -w "wiki:%{http_code}\n" http://127.0.0.1:8080/wiki/Main_Page'
curl.exe -s -o NUL -w "external-wiki:%{http_code}`n" https://climatekg.tibwiki.io/wiki/Main_Page

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " new-TEST -> new-PROD promotion complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local dump file : $LOCAL_FILE"
Write-Host "  Timestamp       : $TIMESTAMP"
if ($IncludeImages) {
    Write-Host "  Images archive  : $LOCAL_IMAGES_FILE"
} else {
    Write-Host "  Images archive  : (skipped, use -IncludeImages to sync images)"
}
Write-Host ""
Write-Host "Verify at https://climatekg.tibwiki.io/wiki/Main_Page" -ForegroundColor Yellow
Write-Host "Admin login: admin / (new-PROD's own .env MW_ADMIN_PASS, unchanged by this migration)" -ForegroundColor Yellow
Write-Host ""
