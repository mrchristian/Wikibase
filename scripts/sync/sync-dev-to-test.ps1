#Requires -Version 5.1
<#
.SYNOPSIS
    Promote the DEV database to the TEST server.

.DESCRIPTION
    1. Dumps the DEV MariaDB database inside the DEV container using --result-file
       (bypasses SSH/PowerShell stream encoding corruption).
    2. Copies the dump from container to DEV host, SCP's it to this Windows machine.
    3. Size-verifies the dump (must be > 1 MB).
    4. SCP's the dump to TEST host, imports it via docker cp + mysql source inside
       the TEST container (no PowerShell stream involved).
    5. Truncates objectcache and l10n_cache on TEST so MediaWiki generates fresh
       URLs for the TEST domain.
    6. Runs MediaWiki update + recentchanges rebuild.
    7. Re-registers TEST sitelinks by restarting wikibase-sitelinks-init.
    8. Restarts the wikibase container on TEST.

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

$TEST_HOST       = "178.105.195.111"
$TEST_USER       = "root"
$TEST_DB_USER    = "wikibase"
$TEST_DB_NAME    = "my_wiki"
$TEST_CONTAINER  = "wikibase-mariadb"

$SSH_KEY         = "C:\Users\$env:USERNAME\.ssh\id_rsa"
$BACKUP_DIR      = "C:\Wikibase\backups"
$TIMESTAMP       = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME   = "dev_to_test_$TIMESTAMP.sql"

$CONTAINER_TEMP      = "/tmp/$DUMP_FILENAME"
$DEV_HOST_TEMP       = "/tmp/$DUMP_FILENAME"
$LOCAL_FILE          = Join-Path $BACKUP_DIR $DUMP_FILENAME
$TEST_HOST_TEMP      = "/tmp/$DUMP_FILENAME"
$TARGET_CONTAINER_TEMP = "/tmp/restore.sql"

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
ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 "${DEV_USER}@${DEV_HOST}" "echo OK" | Out-Null
if ($LASTEXITCODE -ne 0) { Die "Cannot SSH to DEV. Ensure public key is in authorized_keys." }

Write-Host "Testing SSH to TEST ($TEST_HOST)..." -ForegroundColor Yellow
ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 "${TEST_USER}@${TEST_HOST}" "echo OK" | Out-Null
if ($LASTEXITCODE -ne 0) { Die "Cannot SSH to TEST. Ensure public key is in authorized_keys." }

OK "Pre-flight passed"

# ---------------------------------------------------------------------------
# Step 1 — Dump DEV database inside the container
# ---------------------------------------------------------------------------
Step "1/8  Dumping DEV database (inside container)"

$dumpCmd = "docker exec $DEV_CONTAINER mysqldump " +
    "-u $DEV_DB_USER -p'$DEV_DB_PASS' " +
    "--default-character-set=utf8mb4 " +
    "--single-transaction --quick --max_allowed_packet=512M " +
    "--result-file=$CONTAINER_TEMP $DEV_DB_NAME"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" $dumpCmd
OK "Dump written to $CONTAINER_TEMP inside $DEV_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 — Copy dump from container to DEV host filesystem
# ---------------------------------------------------------------------------
Step "2/8  Copying dump to DEV host filesystem"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker cp ${DEV_CONTAINER}:${CONTAINER_TEMP} ${DEV_HOST_TEMP}"
OK "Dump at $DEV_HOST_TEMP on DEV host"

# ---------------------------------------------------------------------------
# Step 3 — SCP dump to LOCAL machine and verify size
# ---------------------------------------------------------------------------
Step "3/8  Downloading dump to LOCAL machine"

scp -i $SSH_KEY "${DEV_USER}@${DEV_HOST}:${DEV_HOST_TEMP}" $LOCAL_FILE
$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) { Die "Dump is too small ($fileSize bytes) — mysqldump likely failed." }
OK "Dump: $([math]::Round($fileSize/1MB, 1)) MB — $LOCAL_FILE"

# Clean up DEV temp files
ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_CONTAINER} rm -f ${CONTAINER_TEMP}; rm -f ${DEV_HOST_TEMP}"
OK "Cleaned up DEV temp files"

# ---------------------------------------------------------------------------
# Step 4 — SCP dump to TEST host
# ---------------------------------------------------------------------------
Step "4/8  Uploading dump to TEST host"

scp -i $SSH_KEY $LOCAL_FILE "${TEST_USER}@${TEST_HOST}:${TEST_HOST_TEMP}"
OK "Dump at $TEST_HOST_TEMP on TEST host"

# ---------------------------------------------------------------------------
# Step 5 — Copy dump into TEST container and import
# ---------------------------------------------------------------------------
Step "5/8  Importing dump into TEST database"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" @"
docker cp ${TEST_HOST_TEMP} ${TEST_CONTAINER}:${TARGET_CONTAINER_TEMP}
docker exec ${TEST_CONTAINER} mysql -u ${TEST_DB_USER} -p'${TEST_DB_PASS}' \
  --default-character-set=utf8mb4 ${TEST_DB_NAME} \
  -e 'source ${TARGET_CONTAINER_TEMP}'
docker exec ${TEST_CONTAINER} rm -f ${TARGET_CONTAINER_TEMP}
rm -f ${TEST_HOST_TEMP}
"@
OK "Database import complete on TEST"

# ---------------------------------------------------------------------------
# Step 6 — Clear stale cache tables on TEST
# ---------------------------------------------------------------------------
Step "6/8  Clearing stale cache tables on TEST"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" @"
docker exec ${TEST_CONTAINER} mysql -u ${TEST_DB_USER} -p'${TEST_DB_PASS}' ${TEST_DB_NAME} \
  -e 'TRUNCATE TABLE objectcache; TRUNCATE TABLE l10n_cache;'
docker exec wikibase php /var/www/html/maintenance/run.php update \
  --conf /config/LocalSettings.php --quick
docker exec wikibase php /var/www/html/maintenance/run.php rebuildrecentchanges \
  --conf /config/LocalSettings.php
"@
OK "Caches cleared and MediaWiki updated on TEST"

# ---------------------------------------------------------------------------
# Step 7 — Re-register TEST sitelinks
# ---------------------------------------------------------------------------
Step "7/8  Re-registering TEST sitelinks"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" @"
cd /opt/wikibase
docker compose -f docker-compose.yml -f docker-compose.test.yml restart wikibase-sitelinks-init
sleep 15
"@
OK "Sitelinks init restarted on TEST"

# ---------------------------------------------------------------------------
# Step 8 — Restart wikibase on TEST
# ---------------------------------------------------------------------------
Step "8/8  Restarting wikibase container on TEST"

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
Write-Host ""
Write-Host "Verify at https://test-climatekg.semanticclimate.org" -ForegroundColor Yellow
Write-Host ""
