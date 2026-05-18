#Requires -Version 5.1
<#
.SYNOPSIS
    Pull the production MariaDB database and overwrite the local Wikibase instance,
    then re-register localhost sitelinks.

.DESCRIPTION
    1. Dumps the production database inside the production MariaDB container using
       --result-file (bypasses SSH/PowerShell stream encoding — see
       backups/mariadb-backup-powershell-encoding-notes.md).
    2. Copies the dump from the container to the production host, then SCP's it
       to this Windows machine.
    3. Copies the SQL file into the local MariaDB container and imports it from
       inside (no PowerShell stream involved — avoids UTF-16LE corruption).
    4. Re-registers localhost sitelinks by restarting wikibase-sitelinks-init.
    5. Restarts the wikibase container to clear PHP/object caches.

.NOTES
    Production DB password is read from PROD_DB_PASS in a local .env file
    (C:\Wikibase\.env), which is gitignored.  Add the following line to that
    file before running:

        PROD_DB_PASS=<actual-password>

    If the variable is absent the script will prompt securely.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$PROD_HOST        = "178.104.156.88"
$PROD_USER        = "root"
$PROD_DB_USER     = "wikibase"
$PROD_DB_NAME     = "my_wiki"
$PROD_CONTAINER   = "wikibase-mariadb"

$LOCAL_DB_USER    = "wikibase"
$LOCAL_DB_PASS    = "wikibase"
$LOCAL_DB_NAME    = "my_wiki"
$LOCAL_CONTAINER  = "wikibase-mariadb"

$BACKUP_DIR       = "C:\Wikibase\backups"
$TIMESTAMP        = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME    = "prod_pull_$TIMESTAMP.sql"

$CONTAINER_TEMP   = "/tmp/$DUMP_FILENAME"      # path inside production container
$PROD_HOST_TEMP   = "/tmp/$DUMP_FILENAME"      # path on production host after docker cp
$LOCAL_FILE       = Join-Path $BACKUP_DIR $DUMP_FILENAME
$LOCAL_CONTAINER_TEMP = "/tmp/restore.sql"      # path inside local container

# ---------------------------------------------------------------------------
# Resolve production DB password
# ---------------------------------------------------------------------------
$envFile = "C:\Wikibase\.env"
$PROD_DB_PASS = $null

if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match "^PROD_DB_PASS\s*=" } | ForEach-Object {
        $PROD_DB_PASS = ($_ -split "=", 2)[1].Trim()
    }
}

if ([string]::IsNullOrEmpty($PROD_DB_PASS)) {
    Write-Host ""
    Write-Host "PROD_DB_PASS not found in $envFile."
    Write-Host "Add  PROD_DB_PASS=<password>  to that file (it is gitignored), or enter it now."
    $securePwd = Read-Host "Production DB password" -AsSecureString
    $PROD_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
    )
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Step([string]$msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function OK([string]$msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

function Die([string]$msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Step "Pre-flight checks"

if (-not (Test-Path $BACKUP_DIR)) {
    New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
    OK "Created backup directory $BACKUP_DIR"
}

$null = Get-Command docker -ErrorAction SilentlyContinue
if (-not $?) { Die "docker command not found. Ensure Docker Desktop is running." }

$null = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $?) { Die "ssh command not found. Ensure OpenSSH is installed." }

$null = Get-Command scp -ErrorAction SilentlyContinue
if (-not $?) { Die "scp command not found. Ensure OpenSSH is installed." }

OK "All required commands found"

# Ensure the SSH agent is running so SSH/SCP calls don't block on passphrase.
$agentStatus = (Get-Service ssh-agent -ErrorAction SilentlyContinue).Status
if ($agentStatus -ne "Running") {
    Write-Host ""
    Write-Host "WARNING: The Windows SSH Agent (ssh-agent) is not running." -ForegroundColor Yellow
    Write-Host "SSH commands will block waiting for your key passphrase and the" -ForegroundColor Yellow
    Write-Host "dump may silently produce a 0-byte file." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Fix (run once in an Administrator PowerShell):" -ForegroundColor Yellow
    Write-Host "  Set-Service -Name ssh-agent -StartupType Automatic" -ForegroundColor White
    Write-Host "  Start-Service ssh-agent" -ForegroundColor White
    Write-Host "  ssh-add C:\Users\$env:USERNAME\.ssh\id_rsa" -ForegroundColor White
    Write-Host ""
    $confirm = Read-Host "Continue anyway? Your terminal must be interactive for passphrase input. [y/N]"
    if ($confirm -ne "y" -and $confirm -ne "Y") { exit 1 }
} else {
    # Agent is running — make sure the key is loaded
    $loadedKeys = & ssh-add -l 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "SSH agent is running but no keys are loaded. Loading key..." -ForegroundColor Yellow
        ssh-add "C:\Users\$env:USERNAME\.ssh\id_rsa"
    }
    OK "SSH agent running with key(s) loaded"
}

# Verify we can actually reach the production server before doing any work
Write-Host "Testing SSH connectivity to $PROD_HOST ..." -ForegroundColor Yellow
if ($agentStatus -eq "Running") {
    # Agent running — test non-interactively
    $sshTest = ssh -o ConnectTimeout=10 -o BatchMode=yes "${PROD_USER}@${PROD_HOST}" "echo OK" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Die "Cannot SSH to ${PROD_USER}@${PROD_HOST}. Ensure your SSH key is loaded in the agent (ssh-add) and the server is reachable.`nSSH output: $sshTest"
    }
} else {
    # No agent — do a quick interactive test; user will be prompted for passphrase
    Write-Host "No SSH agent — you will be prompted for your key passphrase on each SSH/SCP command." -ForegroundColor Yellow
    ssh -o ConnectTimeout=10 "${PROD_USER}@${PROD_HOST}" "echo 'SSH OK'"
    if ($LASTEXITCODE -ne 0) {
        Die "Cannot SSH to ${PROD_USER}@${PROD_HOST}. Check your key and that the server is reachable."
    }
}
OK "SSH connectivity confirmed"

# ---------------------------------------------------------------------------
# Step 1 — Dump production DB inside the container using --result-file
#           This writes UTF-8 directly to disk inside the container; it never
#           passes through any shell redirection that could corrupt encoding.
# ---------------------------------------------------------------------------
Step "1/7  Dumping production database (inside container)"

$dumpCmd = "docker exec $PROD_CONTAINER mysqldump " +
    "-u $PROD_DB_USER -p'$PROD_DB_PASS' " +
    "--default-character-set=utf8mb4 " +
    "--single-transaction " +
    "--quick " +
    "--max_allowed_packet=512M " +
    "--result-file=$CONTAINER_TEMP " +
    "$PROD_DB_NAME"

ssh "${PROD_USER}@${PROD_HOST}" $dumpCmd
OK "Dump written to $CONTAINER_TEMP inside $PROD_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 — Copy dump from container to production host filesystem
# ---------------------------------------------------------------------------
Step "2/7  Copying dump from container to production host"

ssh "${PROD_USER}@${PROD_HOST}" "docker cp ${PROD_CONTAINER}:${CONTAINER_TEMP} ${PROD_HOST_TEMP}"
OK "Dump now at ${PROD_HOST_TEMP} on production host"

# ---------------------------------------------------------------------------
# Step 3 — SCP dump to local Windows machine
#           SCP transfers bytes unchanged — no encoding transformation.
# ---------------------------------------------------------------------------
Step "3/7  Downloading dump to local machine"

scp "${PROD_USER}@${PROD_HOST}:${PROD_HOST_TEMP}" $LOCAL_FILE
OK "Dump saved as $LOCAL_FILE"

# Verify the downloaded file is not empty
$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) {
    Die "Downloaded dump is suspiciously small ($fileSize bytes). The production mysqldump likely failed. Check SSH connectivity and DB credentials."
}
OK "Dump size: $([math]::Round($fileSize/1MB, 1)) MB — looks valid"

# Tidy up remote files now they are no longer needed
ssh "${PROD_USER}@${PROD_HOST}" "docker exec $PROD_CONTAINER rm -f $CONTAINER_TEMP ; rm -f $PROD_HOST_TEMP"
OK "Cleaned up temp files on production server"

# ---------------------------------------------------------------------------
# Step 4 — Copy dump into the local MariaDB container
#           Using docker cp avoids any PowerShell output pipe, so no UTF-16LE
#           encoding corruption can occur.
# ---------------------------------------------------------------------------
Step "4/7  Copying dump into local MariaDB container"

docker cp $LOCAL_FILE "${LOCAL_CONTAINER}:${LOCAL_CONTAINER_TEMP}"
OK "Dump available at $LOCAL_CONTAINER_TEMP inside $LOCAL_CONTAINER"

# ---------------------------------------------------------------------------
# Step 5 — Import from inside the local container
#           Running mysql from inside the container means the SQL file is read
#           from the container's local filesystem — no Windows streams involved.
# ---------------------------------------------------------------------------
Step "5/7  Importing dump into local database"

docker exec $LOCAL_CONTAINER mysql `
    -u $LOCAL_DB_USER -p"$LOCAL_DB_PASS" `
    --default-character-set=utf8mb4 `
    $LOCAL_DB_NAME `
    -e "source $LOCAL_CONTAINER_TEMP"

OK "Database import complete"

# Remove the temp file from the local container
docker exec $LOCAL_CONTAINER rm -f $LOCAL_CONTAINER_TEMP
OK "Cleaned up temp file inside local container"

# ---------------------------------------------------------------------------
# Step 6 — Clear stale production cache entries from the imported database
#           The production dump contains objectcache and l10n_cache rows that
#           were generated with the production URL. Truncating them forces
#           MediaWiki to regenerate them with localhost:8080 URLs.
# ---------------------------------------------------------------------------
Step "6/7  Clearing stale cache tables"

docker exec $LOCAL_CONTAINER mysql `
    -u $LOCAL_DB_USER -p"$LOCAL_DB_PASS" `
    $LOCAL_DB_NAME `
    -e "TRUNCATE TABLE objectcache; TRUNCATE TABLE l10n_cache;"

OK "objectcache and l10n_cache cleared"

# Run the MediaWiki database update script to ensure schema consistency and
# flush any internal caches it manages.
docker exec wikibase php /var/www/html/maintenance/run.php update `
    --conf /config/LocalSettings.php --quick

OK "MediaWiki update/purge complete"

# Rebuild the recentchanges table so Special:RecentChanges reflects the
# imported content rather than the old local revision history.
docker exec wikibase php /var/www/html/maintenance/run.php rebuildrecentchanges `
    --conf /config/LocalSettings.php

OK "recentchanges rebuilt"

# ---------------------------------------------------------------------------
# Step 6b — Re-register localhost sitelinks
#           The imported production DB will contain production URL sitelinks.
#           Restarting wikibase-sitelinks-init re-runs init-sitelinks.sh which
#           imports sites.xml (localhost:8080 paths) and sets site_language.
# ---------------------------------------------------------------------------
Step "6b/7  Re-registering localhost sitelinks (mywiki)"

docker compose --project-directory "C:\Wikibase" restart wikibase-sitelinks-init

# Give the init container time to complete
Write-Host "Waiting 15 seconds for sitelinks-init to complete..." -ForegroundColor Yellow
Start-Sleep -Seconds 15
OK "Sitelinks init restarted"

# ---------------------------------------------------------------------------
# Step 7 — Restart wikibase to clear PHP/object caches
# ---------------------------------------------------------------------------
Step "7/7  Restarting wikibase container"

docker compose --project-directory "C:\Wikibase" restart wikibase
OK "Wikibase container restarted"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Pull from production complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local dump file : $LOCAL_FILE"
Write-Host "  Timestamp       : $TIMESTAMP"
Write-Host ""
Write-Host "Verify at http://localhost:8080" -ForegroundColor Yellow
Write-Host ""
Write-Host "Note: Admin password is now the production admin password." -ForegroundColor Yellow
Write-Host "To reset it to the local default run:" -ForegroundColor Yellow
Write-Host '  docker exec wikibase php /var/www/html/maintenance/run.php changePassword \'
Write-Host '    --conf /config/LocalSettings.php --user admin --password "adminpass123!"'
Write-Host ""
Write-Host "Note: Sitelinks should now be registered for mywiki (localhost)."
Write-Host "Verify at http://localhost:8080/wiki/Special:Sites"
