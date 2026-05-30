#Requires -Version 5.1
<#
.SYNOPSIS
    Promote the TEST database to the PRODUCTION server.

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

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Safety confirmation
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "WARNING: This will overwrite the PRODUCTION database with TEST data." -ForegroundColor Red
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
# Step 6 — Reset PROD admin password + run MediaWiki update
# ---------------------------------------------------------------------------
Step "6/8  Resetting PROD admin password and running MediaWiki update"

$PROD_WB_CONTAINER = "wikibase"

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
# Step 7 — Re-register PROD sitelinks
# ---------------------------------------------------------------------------
Step "7/8  Re-registering PROD sitelinks"

ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase-sitelinks-init"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Sitelinks init restart failed (non-fatal - check manually)." -ForegroundColor Yellow
} else {
    OK "Sitelinks init restarted on PROD"
}

# ---------------------------------------------------------------------------
# Step 8 — Restart wikibase container on PROD
# ---------------------------------------------------------------------------
Step "8/8  Restarting wikibase container on PROD"

ssh -i $PROD_SSH_KEY "${PROD_USER}@${PROD_HOST}" "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase"
if ($LASTEXITCODE -ne 0) { Die "Failed to restart wikibase on PROD." }
OK "Wikibase restarted on PROD"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " TEST → PROD sync complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local dump file : $LOCAL_FILE"
Write-Host "  Timestamp       : $TIMESTAMP"
Write-Host ""
Write-Host "Verify at https://prod-climatekg.semanticclimate.org" -ForegroundColor Yellow
Write-Host ""
