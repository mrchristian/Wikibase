#Requires -Version 5.1
<#
.SYNOPSIS
    Promote the DEV database (and optionally uploads/images) to the TEST server.

.PARAMETER DbOnly
    Skip the uploads/images sync (step 6). Use when only the database has changed.
    Usage:  .\scripts\sync\sync-dev-to-test.ps1 -DbOnly

.DESCRIPTION
    1.  Dumps the DEV MariaDB database inside the DEV container using --result-file
        (bypasses SSH/PowerShell stream encoding corruption).
    2.  Copies the dump from container to DEV host, SCP's it to this Windows machine.
    3.  Size-verifies the dump (must be > 1 MB).
    4.  SCP's the dump to TEST host, imports it via docker cp + mysql source (-f) inside
        the TEST container (no PowerShell stream involved; -f continues past schema errors).
    5.  Imports the dump into TEST.
    6.  Syncs uploads/images: tar inside DEV wikibase container → SCP via LOCAL → extract
        into TEST wikibase container.  Skipped when -DbOnly is set.
    7.  Truncates objectcache/l10n_cache (IF EXISTS) and runs MediaWiki update.
    8.  Runs git pull on TEST to update LocalSettings files from master.
    9.  Re-registers TEST sitelinks by restarting wikibase-sitelinks-init.
    10. Restarts the wikibase container on TEST.

.NOTES
    DEV DB password is read from DEV_DB_PASS in C:\Wikibase\.env (gitignored).
    TEST DB password is read from TEST_DB_PASS in C:\Wikibase\.env (gitignored).

    Add both lines to that file before running:
        DEV_DB_PASS=<dev-password>
        TEST_DB_PASS=<test-password>

    SSH key setup (one-time, as Administrator):
        Set-Service -Name ssh-agent -StartupType Automatic
        Start-Service ssh-agent
        ssh-add C:\Users\<user>\.ssh\id_wikibase_sync
#>

param(
    [switch]$DbOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$DEV_HOST        = "178.104.156.88"
$DEV_USER        = "root"
$DEV_DB_USER     = "wikibase"
$DEV_DB_NAME     = "my_wiki"
$DEV_CONTAINER   = "wikibase-mariadb"
$DEV_WB_CONTAINER = "wikibase"

$TEST_HOST        = "46.224.66.24"
$TEST_USER        = "root"
$TEST_DB_USER     = "wikibase"
$TEST_DB_NAME     = "my_wiki"
$TEST_CONTAINER   = "wikibase-mariadb"
$TEST_WB_CONTAINER = "wikibase"

$SSH_KEY         = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"
$BACKUP_DIR      = "C:\Wikibase\backups"
$TIMESTAMP       = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME   = "dev_to_test_$TIMESTAMP.sql"
$IMAGES_ARCHIVE  = "dev_to_test_images_$TIMESTAMP.tar.gz"

$CONTAINER_TEMP        = "/tmp/$DUMP_FILENAME"
$DEV_HOST_TEMP         = "/tmp/$DUMP_FILENAME"
$LOCAL_FILE            = Join-Path $BACKUP_DIR $DUMP_FILENAME
$TEST_HOST_TEMP        = "/tmp/$DUMP_FILENAME"
$TARGET_CONTAINER_TEMP = "/tmp/restore.sql"

$DEV_IMAGES_CONTAINER  = "/tmp/$IMAGES_ARCHIVE"   # inside DEV wikibase container
$DEV_IMAGES_HOST_TEMP  = "/tmp/$IMAGES_ARCHIVE"   # on DEV host filesystem
$LOCAL_IMAGES_FILE     = Join-Path $BACKUP_DIR $IMAGES_ARCHIVE
$TEST_IMAGES_TEMP      = "/tmp/$IMAGES_ARCHIVE"   # on TEST host filesystem

# ---------------------------------------------------------------------------
# Resolve passwords from .env
# ---------------------------------------------------------------------------
$envFile = "C:\Wikibase\.env"
$DEV_DB_PASS  = $null
$TEST_DB_PASS = $null

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^DEV_DB_PASS\s*=")  { $DEV_DB_PASS  = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^TEST_DB_PASS\s*=") { $TEST_DB_PASS = ($_ -split "=", 2)[1].Trim() }
    }
}

if ([string]::IsNullOrEmpty($DEV_DB_PASS)) {
    $securePwd = Read-Host "DEV DB password" -AsSecureString
    $DEV_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
}

if ([string]::IsNullOrEmpty($TEST_DB_PASS)) {
    $securePwd = Read-Host "TEST DB password" -AsSecureString
    $TEST_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
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
foreach ($cmd in @("docker","ssh","scp")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Die "$cmd not found." }
}
if (-not (Test-Path $SSH_KEY)) { Die "Sync key not found at $SSH_KEY." }

Write-Host "Testing SSH to DEV ($DEV_HOST)..." -ForegroundColor Yellow
$tcpTest = Test-NetConnection -ComputerName $DEV_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcpTest) { Die "Cannot reach DEV port 22. Server may be down or firewall blocking." }
OK "SSH port reachable"

Write-Host "Testing SSH to TEST ($TEST_HOST)..." -ForegroundColor Yellow
$tcpTest = Test-NetConnection -ComputerName $TEST_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcpTest) { Die "Cannot reach TEST port 22. Server may be down or firewall blocking." }
OK "SSH port reachable"

OK "Pre-flight passed"

# ---------------------------------------------------------------------------
# Step 1 -- Dump DEV database inside the container
# ---------------------------------------------------------------------------
Step "1/10  Dumping DEV database (inside container)"

$dumpCmd = "docker exec $DEV_CONTAINER mysqldump " +
    "-u $DEV_DB_USER -p'$DEV_DB_PASS' " +
    "--default-character-set=utf8mb4 " +
    "--single-transaction --quick --max_allowed_packet=512M " +
    "--result-file=$CONTAINER_TEMP $DEV_DB_NAME"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" $dumpCmd
OK "Dump written to $CONTAINER_TEMP inside $DEV_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 -- Copy dump from container to DEV host filesystem
# ---------------------------------------------------------------------------
Step "2/10  Copying dump to DEV host filesystem"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker cp ${DEV_CONTAINER}:${CONTAINER_TEMP} ${DEV_HOST_TEMP}"
OK "Dump at $DEV_HOST_TEMP on DEV host"

# ---------------------------------------------------------------------------
# Step 3 -- SCP dump to LOCAL machine and verify size
# ---------------------------------------------------------------------------
Step "3/10  Downloading dump to LOCAL machine"

scp -i $SSH_KEY "${DEV_USER}@${DEV_HOST}:${DEV_HOST_TEMP}" $LOCAL_FILE
$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) { Die "Dump is too small ($fileSize bytes) -- mysqldump likely failed." }
OK "Dump: $([math]::Round($fileSize/1MB, 1)) MB -- $LOCAL_FILE"

# Clean up DEV temp files
ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_CONTAINER} rm -f ${CONTAINER_TEMP}; rm -f ${DEV_HOST_TEMP}"
OK "Cleaned up DEV temp files"

# ---------------------------------------------------------------------------
# Step 4 -- SCP dump to TEST host
# ---------------------------------------------------------------------------
Step "4/10  Uploading dump to TEST host"

scp -i $SSH_KEY $LOCAL_FILE "${TEST_USER}@${TEST_HOST}:${TEST_HOST_TEMP}"
OK "Dump at $TEST_HOST_TEMP on TEST host"

# ---------------------------------------------------------------------------
# Step 5 -- Copy dump into TEST container and import
# ---------------------------------------------------------------------------
Step "5/10  Importing dump into TEST database"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" @"
docker cp ${TEST_HOST_TEMP} ${TEST_CONTAINER}:${TARGET_CONTAINER_TEMP}
docker exec ${TEST_CONTAINER} mysql -f -u ${TEST_DB_USER} -p'${TEST_DB_PASS}' \
  --default-character-set=utf8mb4 ${TEST_DB_NAME} \
  -e 'source ${TARGET_CONTAINER_TEMP}'
docker exec ${TEST_CONTAINER} rm -f ${TARGET_CONTAINER_TEMP}
rm -f ${TEST_HOST_TEMP}
"@
OK "Database import complete on TEST"

# ---------------------------------------------------------------------------
# Step 6 -- Sync uploads/images from DEV to TEST
#           tar inside DEV wikibase container → DEV host → LOCAL → TEST → extract
# ---------------------------------------------------------------------------
if ($DbOnly) {
    Step "6/10  Skipping uploads/images sync (-DbOnly)"
    OK "Images sync skipped"
} else {
    Step "6/10  Syncing uploads/images from DEV to TEST"

    Write-Host "  Creating images archive inside DEV wikibase container (excluding thumbnails)..." -ForegroundColor Yellow
    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_WB_CONTAINER} tar --exclude=thumb -czf ${DEV_IMAGES_CONTAINER} /var/www/html/images"
    if ($LASTEXITCODE -ne 0) { Die "tar archive of DEV images failed." }

    Write-Host "  Copying archive from DEV container to DEV host..." -ForegroundColor Yellow
    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker cp ${DEV_WB_CONTAINER}:${DEV_IMAGES_CONTAINER} ${DEV_IMAGES_HOST_TEMP} && docker exec ${DEV_WB_CONTAINER} rm -f ${DEV_IMAGES_CONTAINER}"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive from DEV container failed." }

    Write-Host "  Downloading archive to LOCAL machine..." -ForegroundColor Yellow
    scp -i $SSH_KEY "${DEV_USER}@${DEV_HOST}:${DEV_IMAGES_HOST_TEMP}" $LOCAL_IMAGES_FILE
    if ($LASTEXITCODE -ne 0) { Die "SCP of images archive from DEV failed." }
    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "rm -f ${DEV_IMAGES_HOST_TEMP}"

    $archiveSize = (Get-Item $LOCAL_IMAGES_FILE).Length
    OK "Images archive: $([math]::Round($archiveSize/1MB, 1)) MB -- $LOCAL_IMAGES_FILE"

    Write-Host "  Uploading archive to TEST host..." -ForegroundColor Yellow
    scp -i $SSH_KEY $LOCAL_IMAGES_FILE "${TEST_USER}@${TEST_HOST}:${TEST_IMAGES_TEMP}"
    if ($LASTEXITCODE -ne 0) { Die "SCP of images archive to TEST failed." }

    Write-Host "  Extracting archive into TEST container (wikibase_images volume)..." -ForegroundColor Yellow
    ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker cp ${TEST_IMAGES_TEMP} ${TEST_WB_CONTAINER}:/tmp/images_restore.tar.gz"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive to TEST container failed." }

    ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_WB_CONTAINER} sh -c 'find /var/www/html/images -mindepth 1 -not -name ckglogo1.png -not -name ckglogo1.svg -delete 2>/dev/null; tar -xzf /tmp/images_restore.tar.gz --strip-components=3 -C /var/www/html --exclude=var/www/html/images/ckglogo1.png --exclude=var/www/html/images/ckglogo1.svg && rm /tmp/images_restore.tar.gz'"
    if ($LASTEXITCODE -ne 0) { Die "Images extraction on TEST failed." }

    ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "rm -f ${TEST_IMAGES_TEMP}"
    OK "Images synced to TEST"
}

# ---------------------------------------------------------------------------
# Step 7 -- Clear stale cache tables on TEST (non-fatal -- table may not exist)
# ---------------------------------------------------------------------------
Step "7/10  Clearing stale cache tables on TEST"

$cacheResult = ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" @"
docker exec ${TEST_CONTAINER} mysql -u ${TEST_DB_USER} -p'${TEST_DB_PASS}' ${TEST_DB_NAME} \
  -e 'TRUNCATE TABLE IF EXISTS objectcache; TRUNCATE TABLE IF EXISTS l10n_cache;'
docker exec wikibase php /var/www/html/maintenance/run.php update \
  --conf /config/LocalSettings.php --quick
docker exec wikibase php /var/www/html/maintenance/run.php rebuildrecentchanges \
  --conf /config/LocalSettings.php
"@
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Cache truncation or MediaWiki update had errors (non-fatal)." -ForegroundColor Yellow
} else {
    OK "Caches cleared and MediaWiki updated on TEST"
}

# ---------------------------------------------------------------------------
# Step 8 -- Update LocalSettings files on TEST via git pull
#           LocalSettings.*.php files are bind-mounted from /opt/wikibase/ on TEST.
# ---------------------------------------------------------------------------
Step "8/10  Updating LocalSettings files on TEST via git pull"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "cd /opt/wikibase && git fetch origin && git pull origin master"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] git pull on TEST failed or repo not configured. LocalSettings files may be stale." -ForegroundColor Yellow
    Write-Host "       Manually run: ssh root@${TEST_HOST} 'cd /opt/wikibase && git pull origin master'" -ForegroundColor Yellow
} else {
    OK "git pull complete on TEST -- LocalSettings files updated"
}

# ---------------------------------------------------------------------------
# Step 9 -- Re-register TEST sitelinks
# ---------------------------------------------------------------------------
Step "9/10  Re-registering TEST sitelinks"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" @"
cd /opt/wikibase
docker compose -f docker-compose.yml -f docker-compose.test.yml restart wikibase-sitelinks-init
sleep 15
"@
OK "Sitelinks init restarted on TEST"

# ---------------------------------------------------------------------------
# Step 10 -- Restart wikibase on TEST
# ---------------------------------------------------------------------------
Step "10/10  Restarting wikibase container on TEST"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" @"
cd /opt/wikibase
docker compose -f docker-compose.yml -f docker-compose.test.yml restart wikibase
"@
OK "Wikibase restarted on TEST"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " DEV → TEST sync complete!" -ForegroundColor Green
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
Write-Host "Verify at https://test-climatekg.semanticclimate.org" -ForegroundColor Yellow
Write-Host ""
