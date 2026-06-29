#Requires -Version 5.1
<#
.SYNOPSIS
    Promote the TEST database (and optionally images) to the PRODUCTION server.

.DESCRIPTION
    1. Dumps the TEST MariaDB database inside the TEST container using --result-file
       (bypasses SSH/PowerShell stream encoding corruption).
    2. Copies the dump from container to TEST host, SCP's it to this Windows machine.
    3. Size-verifies the dump (must be > 1 MB).
    4. SCP's the dump to PROD host, imports it via drop/recreate + docker cp +
       mysql source inside the PROD container (no PowerShell streams involved).
    5. Clears objectcache and l10n_cache on PROD so MediaWiki generates fresh
       URLs for the PROD domain.
    6. Runs MediaWiki update + recentchanges rebuild.
    7. Re-registers PROD sitelinks by restarting wikibase-sitelinks-init.
    8. Restarts the wikibase container on PROD.

    With -IncludeImages:
    9. Tars /var/www/html/images (excluding thumb/) from the TEST wikibase
       container, SCP's it via this Windows machine to PROD, copies it into
       the PROD wikibase container and extracts it, then fixes ownership and
       clears stale thumbnails.

.PARAMETER IncludeImages
    Also promote uploaded images from TEST to PROD.

.NOTES
    TEST DB password is read from TEST_DB_PASS in C:\Wikibase\.env (gitignored).
    PROD DB password is read from PROD_DB_PASS in C:\Wikibase\.env (gitignored).

    Add both lines to that file before running:
        TEST_DB_PASS=<test-password>
        PROD_DB_PASS=<prod-password>

    WARNING: This operation overwrites the PRODUCTION database. Confirm with the
    team before running this script.

    SSH key: C:\Users\<user>\.ssh\id_wikibase_sync
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
Write-Host "WARNING: This will overwrite the PRODUCTION database with TEST data." -ForegroundColor Red
if ($IncludeImages) {
    Write-Host "WARNING: This will ALSO overwrite PRODUCTION images/uploads with TEST data." -ForegroundColor Red
}
Write-Host "Production: prod-climatekg.semanticclimate.org (178.105.222.174)" -ForegroundColor Red
Write-Host ""
$confirm = Read-Host "Type PROMOTE to confirm"
if ($confirm -ne "PROMOTE") {
    Write-Host "Aborted - no changes made." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$TEST_HOST       = "46.224.66.24"
$TEST_USER       = "root"
$TEST_DB_USER    = "wikibase"
$TEST_DB_NAME    = "my_wiki"
$TEST_CONTAINER  = "wikibase-mariadb"

$PROD_HOST       = "178.105.222.174"
$PROD_USER       = "root"
$PROD_DB_USER    = "wikibase"
$PROD_DB_NAME    = "my_wiki"
$PROD_CONTAINER  = "wikibase-mariadb"

$TEST_SSH_KEY    = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"  # authorized on TEST
$PROD_SSH_KEY    = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"  # authorized on PROD
$BACKUP_DIR      = "C:\Wikibase\backups"
$TIMESTAMP       = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME   = "test_to_prod_$TIMESTAMP.sql"

$TEST_WB_CONTAINER = "wikibase"           # wikibase (Apache/PHP) container on TEST
$PROD_WB_CONTAINER = "wikibase"           # wikibase (Apache/PHP) container on PROD

$IMAGES_ARCHIVE          = "test_to_prod_images_$TIMESTAMP.tar.gz"
$TEST_IMAGES_ARCHIVE     = "/tmp/$IMAGES_ARCHIVE"   # inside TEST wikibase container
$TEST_HOST_IMAGES_TEMP   = "/tmp/$IMAGES_ARCHIVE"   # on TEST host after docker cp
$LOCAL_IMAGES_FILE       = Join-Path $BACKUP_DIR $IMAGES_ARCHIVE
$PROD_HOST_IMAGES_TEMP   = "/tmp/$IMAGES_ARCHIVE"   # on PROD host before docker cp
$PROD_IMAGES_TEMP        = "/tmp/images_restore.tar.gz"  # inside PROD wikibase container

$CONTAINER_TEMP        = "/tmp/$DUMP_FILENAME"
$TEST_HOST_TEMP        = "/tmp/$DUMP_FILENAME"
$LOCAL_FILE            = Join-Path $BACKUP_DIR $DUMP_FILENAME
$PROD_HOST_TEMP        = "/tmp/$DUMP_FILENAME"
$TARGET_CONTAINER_TEMP = "/tmp/restore.sql"

# ---------------------------------------------------------------------------
# Resolve passwords from .env
# ---------------------------------------------------------------------------
$envFile      = "C:\Wikibase\.env"
$TEST_DB_PASS = $null
$PROD_DB_PASS = $null

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^TEST_DB_PASS\s*=")  { $TEST_DB_PASS  = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^PROD_DB_PASS\s*=")  { $PROD_DB_PASS  = ($_ -split "=", 2)[1].Trim() }
    }
}

if ([string]::IsNullOrEmpty($TEST_DB_PASS)) {
    $securePwd = Read-Host "TEST DB password" -AsSecureString
    $TEST_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
}

if ([string]::IsNullOrEmpty($PROD_DB_PASS)) {
    $securePwd = Read-Host "PROD DB password" -AsSecureString
    $PROD_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
}

$PROD_MW_ADMIN_PASS = $null
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^PROD_MW_ADMIN_PASS\s*=") { $PROD_MW_ADMIN_PASS = ($_ -split "=", 2)[1].Trim() }
    }
}

if ([string]::IsNullOrEmpty($PROD_MW_ADMIN_PASS)) {
    Write-Host ""
    Write-Host "PROD_MW_ADMIN_PASS not found in $envFile." -ForegroundColor Yellow
    Write-Host "Add  PROD_MW_ADMIN_PASS=<password>  to that file, or enter it now."
    $securePwd          = Read-Host "PROD MediaWiki Admin password" -AsSecureString
    $PROD_MW_ADMIN_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                              [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
}

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
if (-not (Test-Path $TEST_SSH_KEY)) { Die "SSH key not found at $TEST_SSH_KEY." }
if (-not (Test-Path $PROD_SSH_KEY)) { Die "SSH key not found at $PROD_SSH_KEY." }

Write-Host "Testing SSH to TEST ($TEST_HOST)..." -ForegroundColor Yellow
$tcpTest = Test-NetConnection -ComputerName $TEST_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcpTest) { Die "Cannot reach TEST port 22. Server may be down or firewall blocking." }
OK "SSH port reachable"

Write-Host "Testing SSH to PROD ($PROD_HOST)..." -ForegroundColor Yellow
$tcpTest = Test-NetConnection -ComputerName $PROD_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcpTest) { Die "Cannot reach PROD port 22. Server may be down or firewall blocking." }
OK "SSH port reachable"

OK "Pre-flight passed"

# ---------------------------------------------------------------------------
# Step 1 — Dump TEST database inside the container
# ---------------------------------------------------------------------------
Step "1/8  Dumping TEST database (inside container)"

$dumpCmd = "docker exec $TEST_CONTAINER mysqldump " +
    "-u $TEST_DB_USER -p'$TEST_DB_PASS' " +
    "--default-character-set=utf8mb4 " +
    "--single-transaction --quick --max_allowed_packet=512M " +
    "--result-file=$CONTAINER_TEMP $TEST_DB_NAME"

ssh -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}" $dumpCmd
if ($LASTEXITCODE -ne 0) { Die "mysqldump on TEST failed." }
OK "Dump written to $CONTAINER_TEMP inside $TEST_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 — Copy dump from container to TEST host filesystem
# ---------------------------------------------------------------------------
Step "2/8  Copying dump to TEST host filesystem"

ssh -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker cp ${TEST_CONTAINER}:${CONTAINER_TEMP} ${TEST_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "docker cp from TEST container to host failed." }
OK "Dump at $TEST_HOST_TEMP on TEST host"

# ---------------------------------------------------------------------------
# Step 3 — SCP dump to LOCAL machine and verify size
# ---------------------------------------------------------------------------
Step "3/8  Downloading dump to LOCAL machine"

scp -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}:${TEST_HOST_TEMP}" $LOCAL_FILE
$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) { Die "Dump is too small ($fileSize bytes) - mysqldump likely failed." }
OK "Dump: $([math]::Round($fileSize/1MB, 1)) MB : $LOCAL_FILE"

# Clean up TEST temp files
ssh -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_CONTAINER} rm -f ${CONTAINER_TEMP}; rm -f ${TEST_HOST_TEMP}"
OK "Cleaned up TEST temp files"

# ---------------------------------------------------------------------------
# Step 4 — SCP dump to PROD host and import
# ---------------------------------------------------------------------------
Step "4/8  Uploading dump to PROD and importing"

scp -i $PROD_SSH_KEY $LOCAL_FILE "${PROD_USER}@${PROD_HOST}:${PROD_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "SCP to PROD failed." }
OK "Dump uploaded to PROD"

Write-Host "  Dropping and recreating PROD database for a clean import..." -ForegroundColor Yellow
ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "docker exec ${PROD_CONTAINER} mysql -u ${PROD_DB_USER} -p'${PROD_DB_PASS}' -e 'DROP DATABASE IF EXISTS ${PROD_DB_NAME}; CREATE DATABASE ${PROD_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
if ($LASTEXITCODE -ne 0) { Die "Failed to drop/recreate PROD database." }

# Pipe directly from PROD host /tmp into the container via stdin (no docker cp needed).
# This avoids writing the dump into the container overlay layer on /, which can fail
# when the root filesystem is nearly full. The file stays in /tmp (tmpfs).
ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "docker exec -i ${PROD_CONTAINER} mysql -u ${PROD_DB_USER} -p'${PROD_DB_PASS}' --default-character-set=utf8mb4 ${PROD_DB_NAME} < ${PROD_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "Database import on PROD failed." }

ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "rm -f ${PROD_HOST_TEMP}"
OK "Database import complete on PROD"

# ---------------------------------------------------------------------------
# Step 5 — Clear stale cache tables on PROD
# ---------------------------------------------------------------------------
Step "5/8  Clearing stale cache tables on PROD"

ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "docker exec ${PROD_CONTAINER} mysql -u ${PROD_DB_USER} -p'${PROD_DB_PASS}' ${PROD_DB_NAME} -e 'DELETE FROM objectcache; DELETE FROM l10n_cache;'"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Cache clear on PROD had errors (non-fatal)." -ForegroundColor Yellow
} else {
    OK "Cache tables cleared on PROD"
}

# ---------------------------------------------------------------------------
# Step 6 -- Reset PROD admin password + run MediaWiki update
# ---------------------------------------------------------------------------
Step "6/8  Resetting PROD admin password and running MediaWiki update"

ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "docker exec ${PROD_WB_CONTAINER} php /var/www/html/maintenance/run.php update --conf /config/LocalSettings.php --quick"
if ($LASTEXITCODE -ne 0) { Die "MediaWiki update on PROD failed." }
OK "MediaWiki update complete"

ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "docker exec ${PROD_WB_CONTAINER} php /var/www/html/maintenance/run.php changePassword --conf /config/LocalSettings.php --user=admin --password='${PROD_MW_ADMIN_PASS}'"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] changePassword on PROD failed (non-fatal - check manually)." -ForegroundColor Yellow
} else {
    OK "PROD admin password reset"
}

ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "docker exec ${PROD_WB_CONTAINER} php /var/www/html/maintenance/run.php rebuildrecentchanges --conf /config/LocalSettings.php"
OK "recentchanges rebuilt on PROD"

# ---------------------------------------------------------------------------
# Step 7 — Re-register PROD sitelinks then restart wikibase
# ---------------------------------------------------------------------------
Step "7/8  Re-registering PROD sitelinks"

# sleep 20 gives wikibase-sitelinks-init time to finish init-sitelinks.sh before
# wikibase restarts and reads the sites table (same pattern as sync-local-to-test.ps1).
ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase-sitelinks-init && sleep 20 && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Sitelinks init or wikibase restart failed (non-fatal - check manually)." -ForegroundColor Yellow
} else {
    OK "Sitelinks init complete and wikibase restarted on PROD"
}

# ---------------------------------------------------------------------------
# Step 8 — (no-op — wikibase already restarted in step 7)
# ---------------------------------------------------------------------------
Step "8/8  Wikibase restart"
OK "Wikibase was restarted as part of step 7"

# ---------------------------------------------------------------------------
# Optional: Promote images from TEST to PROD
# ---------------------------------------------------------------------------
if ($IncludeImages) {
    # Count images on TEST before transfer for verification
    Step "Images 1/4  Checking TEST image count"
    $testCount = ssh -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}" `
        "docker exec $TEST_WB_CONTAINER bash -c `"find /var/www/html/images -type f -not -path '*/thumb/*' -not -name '.htaccess' -not -name 'README' | wc -l`""
    OK "TEST image files (excluding thumbnails): $($testCount.Trim())"

    # -------------------------------------------------------------------------
    # Archive images inside TEST wikibase container (exclude thumb/)
    # -------------------------------------------------------------------------
    Step "Images 2/4  Archiving TEST wikibase images (excluding thumbnails)"

    Write-Host "This may take a minute for large image sets..." -ForegroundColor Yellow
    ssh -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}" `
        "docker exec $TEST_WB_CONTAINER tar --exclude=thumb -czf $TEST_IMAGES_ARCHIVE /var/www/html/images && echo DONE"
    if ($LASTEXITCODE -ne 0) { Die "tar failed inside TEST wikibase container." }
    OK "Archive created at $TEST_IMAGES_ARCHIVE inside $TEST_WB_CONTAINER"

    ssh -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}" `
        "docker cp ${TEST_WB_CONTAINER}:${TEST_IMAGES_ARCHIVE} ${TEST_HOST_IMAGES_TEMP} && echo DONE"
    if ($LASTEXITCODE -ne 0) { Die "docker cp from TEST container to host failed." }

    # -------------------------------------------------------------------------
    # SCP archive via local machine to PROD
    # -------------------------------------------------------------------------
    Step "Images 3/4  Transferring archive: TEST -> local -> PROD"

    Write-Host "Downloading from TEST (may take several minutes)..." -ForegroundColor Yellow
    scp -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}:${TEST_HOST_IMAGES_TEMP}" $LOCAL_IMAGES_FILE
    if ($LASTEXITCODE -ne 0) { Die "SCP download of images archive from TEST failed." }

    $archiveSize = (Get-Item $LOCAL_IMAGES_FILE).Length
    if ($archiveSize -lt 100KB) { Die "Downloaded images archive is too small ($archiveSize bytes)." }
    OK "Images archive: $([math]::Round($archiveSize / 1MB, 1)) MB -- $LOCAL_IMAGES_FILE"

    # Clean up TEST temp files
    ssh -i $TEST_SSH_KEY "${TEST_USER}@${TEST_HOST}" `
        "docker exec ${TEST_WB_CONTAINER} rm -f ${TEST_IMAGES_ARCHIVE} ; rm -f ${TEST_HOST_IMAGES_TEMP}"
    OK "Cleaned up TEST temp files"

    Write-Host "Uploading to PROD..." -ForegroundColor Yellow
    scp -i $PROD_SSH_KEY $LOCAL_IMAGES_FILE "${PROD_USER}@${PROD_HOST}:${PROD_HOST_IMAGES_TEMP}"
    if ($LASTEXITCODE -ne 0) { Die "SCP upload of images archive to PROD failed." }
    OK "Images archive uploaded to PROD"

    # -------------------------------------------------------------------------
    # Extract inside PROD wikibase container, fix ownership, purge thumbnails
    # -------------------------------------------------------------------------
    Step "Images 4/4  Extracting images on PROD and fixing ownership"

    ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" `
        "docker cp ${PROD_HOST_IMAGES_TEMP} ${PROD_WB_CONTAINER}:${PROD_IMAGES_TEMP} && echo DONE"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive into PROD container failed." }

    ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" `
        "docker exec ${PROD_WB_CONTAINER} sh -c 'find /var/www/html/images -mindepth 1 -not -name ckglogo1.png -not -name ckglogo1.svg -delete 2>/dev/null; tar -xzf ${PROD_IMAGES_TEMP} --strip-components=3 -C /var/www/html --exclude=var/www/html/images/ckglogo1.png --exclude=var/www/html/images/ckglogo1.svg && chown -R www-data:www-data /var/www/html/images && find /var/www/html/images/thumb -mindepth 1 -delete 2>/dev/null && rm -f ${PROD_IMAGES_TEMP} && echo DONE'"
    if ($LASTEXITCODE -ne 0) { Die "Images extraction on PROD failed." }
    OK "Images extracted, ownership fixed, stale thumbnails cleared on PROD"

    ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "rm -f ${PROD_HOST_IMAGES_TEMP}"

    # Verify file count
    $prodCount = ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" `
        "docker exec ${PROD_WB_CONTAINER} bash -c `"find /var/www/html/images -type f -not -path '*/thumb/*' -not -name '.htaccess' -not -name 'README' | wc -l`""
    OK "PROD image files after restore: $($prodCount.Trim())"
    if ([int]$prodCount.Trim() -lt [int]$testCount.Trim()) {
        Write-Host "[WARN] PROD count ($($prodCount.Trim())) is less than TEST count ($($testCount.Trim())). Some files may be missing." -ForegroundColor Yellow
    } else {
        OK "Image counts match or exceed TEST ($($testCount.Trim()) TEST / $($prodCount.Trim()) PROD)"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " TEST → PROD sync complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local dump file : $LOCAL_FILE"
if ($IncludeImages) {
    Write-Host "  Images archive  : $LOCAL_IMAGES_FILE"
}
Write-Host "  Timestamp       : $TIMESTAMP"
Write-Host ""
Write-Host "Verify at https://prod-climatekg.semanticclimate.org" -ForegroundColor Yellow
if ($IncludeImages) {
    Write-Host "  Verify images at https://prod-climatekg.semanticclimate.org/wiki/Special:ListFiles" -ForegroundColor Yellow
}
Write-Host ""
