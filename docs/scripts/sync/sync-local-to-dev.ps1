#Requires -Version 5.1
<#
.SYNOPSIS
    Push the LOCAL Wikibase database (and optionally uploads/files) and LocalSettings to DEV.

.PARAMETER DbOnly
    Skip the uploads/images sync (step 8). Useful when only the database has changed.
    Usage:  .\scripts\sync\sync-local-to-dev.ps1 -DbOnly

.DESCRIPTION
    1. Dumps the LOCAL MariaDB database inside the LOCAL container using --result-file
       (bypasses PowerShell stream encoding -- avoids UTF-16LE/character-map corruption,
       see backups/mariadb-backup-powershell-encoding-notes.md).
    2. Verifies dump size > 1 MB.
    3. SCPs the dump to the DEV host, imports it via docker cp + mysql source inside
       the DEV container (no PowerShell stream involved).
    4. Truncates objectcache and l10n_cache on DEV so MediaWiki generates fresh URLs
       for the DEV domain (https://dev-climatekg.semanticclimate.org).
    5. Resets the MediaWiki Admin password on DEV to the value from DEV_MW_ADMIN_PASS
       in C:\Wikibase\.env using the changePassword maintenance script.
    6. Runs MediaWiki update + recentchanges rebuild on DEV.
    7. Syncs uploads/images: creates tar.gz inside LOCAL container, docker cp to LOCAL
       host, SCP to DEV, extracts into DEV Docker volume.
    8. Updates LocalSettings files on DEV via git pull (files are bind-mounted from
       /opt/wikibase repo on the DEV server).
    9. Re-registers DEV sitelinks by restarting wikibase-sitelinks-init.
   10. Restarts the wikibase container on DEV.

.NOTES
    Required entries in C:\Wikibase\.env (gitignored):
        DEV_DB_PASS=<dev-mariadb-password>
        DEV_MW_ADMIN_PASS=<mediawiki-admin-password-for-dev>

    LOCAL DB credentials come from docker-compose.yml defaults (user: wikibase / pass: wikibase).

    WARNING: This overwrites the DEV database. DEV is the DB source of truth.
    Only push LOCAL → DEV when you have intentional content to promote (e.g. a
    bulk data import that was tested locally and approved via experimental workflow).

    IMPORTANT -- PowerShell character-map safety rules:
      * NEVER use  >  or  |  to redirect mysqldump output from PowerShell.
      * ALWAYS use  --result-file  inside the container.
      * ALWAYS import via  mysql -e 'source /tmp/file.sql'  inside the container.
      * NEVER use  docker exec ... mysql < file  from PowerShell.
#>

param(
    [switch]$DbOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$LOCAL_CONTAINER    = "wikibase-mariadb"
$LOCAL_WB_CONTAINER = "wikibase"
$LOCAL_DB_USER      = "wikibase"
$LOCAL_DB_PASS      = "wikibase"          # docker-compose.yml default for LOCAL
$LOCAL_DB_NAME      = "my_wiki"

$DEV_HOST           = "178.104.156.88"
$DEV_USER           = "root"
$DEV_DB_USER        = "wikibase"
$DEV_DB_NAME        = "my_wiki"
$DEV_CONTAINER      = "wikibase-mariadb"
$DEV_WB_CONTAINER   = "wikibase"

$SSH_KEY            = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"
$BACKUP_DIR         = "C:\Wikibase\backups"
$TIMESTAMP          = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME      = "local_to_dev_$TIMESTAMP.sql"
$IMAGES_ARCHIVE     = "local_to_dev_images_$TIMESTAMP.tar.gz"

$LOCAL_CONTAINER_DUMP = "/tmp/$DUMP_FILENAME"    # inside LOCAL mariadb container
$LOCAL_FILE           = Join-Path $BACKUP_DIR $DUMP_FILENAME
$LOCAL_IMAGES_ARCHIVE = "/tmp/$IMAGES_ARCHIVE"   # inside LOCAL wikibase container
$LOCAL_IMAGES_FILE    = Join-Path $BACKUP_DIR $IMAGES_ARCHIVE

$DEV_HOST_TEMP        = "/tmp/$DUMP_FILENAME"
$DEV_IMAGES_TEMP      = "/tmp/$IMAGES_ARCHIVE"
$TARGET_CONTAINER_TEMP = "/tmp/restore.sql"

# ---------------------------------------------------------------------------
# Resolve DEV passwords from .env
# ---------------------------------------------------------------------------
$envFile           = "C:\Wikibase\.env"
$DEV_DB_PASS       = $null
$DEV_MW_ADMIN_PASS = $null

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^DEV_DB_PASS\s*=")       { $DEV_DB_PASS       = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^DEV_MW_ADMIN_PASS\s*=") { $DEV_MW_ADMIN_PASS = ($_ -split "=", 2)[1].Trim() }
    }
}

if ([string]::IsNullOrEmpty($DEV_DB_PASS)) {
    $securePwd   = Read-Host "DEV MariaDB password" -AsSecureString
    $DEV_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
}

if ([string]::IsNullOrEmpty($DEV_MW_ADMIN_PASS)) {
    Write-Host ""
    Write-Host "DEV_MW_ADMIN_PASS not found in $envFile." -ForegroundColor Yellow
    Write-Host "Add  DEV_MW_ADMIN_PASS=<password>  to that file, or enter it now."
    $securePwd         = Read-Host "DEV MediaWiki Admin password" -AsSecureString
    $DEV_MW_ADMIN_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                             [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Step([string]$msg) { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Die([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Confirmation prompt — DEV is the DB source of truth; require explicit intent
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Yellow
Write-Host "  WARNING: This will OVERWRITE the DEV database."        -ForegroundColor Yellow
Write-Host "  DEV is the DB source of truth for ClimateKG."          -ForegroundColor Yellow
Write-Host "  Only proceed if you have approved content to promote."  -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Type 'PROMOTE' to confirm"

if ($confirm -ne "PROMOTE") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Step "Pre-flight checks"

if (-not (Test-Path $BACKUP_DIR)) { New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null }

foreach ($cmd in @("docker","ssh","scp")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Die "$cmd not found." }
}
if (-not (Test-Path $SSH_KEY)) { Die "SSH key not found at $SSH_KEY." }

$runningContainers = docker ps --format "{{.Names}}"
if ($runningContainers -notcontains $LOCAL_CONTAINER) {
    Die "LOCAL container '$LOCAL_CONTAINER' is not running. Start Docker Desktop and run: docker compose up -d"
}
if ($runningContainers -notcontains $LOCAL_WB_CONTAINER) {
    Die "LOCAL container '$LOCAL_WB_CONTAINER' is not running. Start Docker Desktop and run: docker compose up -d"
}

Write-Host "Testing SSH to DEV ($DEV_HOST)..." -ForegroundColor Yellow
$tcpTest = Test-NetConnection -ComputerName $DEV_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcpTest) { Die "Cannot reach DEV port 22. Server may be down or firewall blocking." }
OK "SSH port reachable"

OK "Pre-flight passed"

# ---------------------------------------------------------------------------
# Step 1 -- Dump LOCAL database INSIDE the container using --result-file
# ---------------------------------------------------------------------------
Step "1/10  Dumping LOCAL database (inside container -- --result-file pattern)"

docker exec $LOCAL_CONTAINER mysqldump `
    -u $LOCAL_DB_USER -p"$LOCAL_DB_PASS" `
    --default-character-set=utf8mb4 `
    --single-transaction --quick --max_allowed_packet=512M `
    --result-file=$LOCAL_CONTAINER_DUMP `
    $LOCAL_DB_NAME

if ($LASTEXITCODE -ne 0) { Die "mysqldump failed. Check LOCAL container and credentials." }
OK "Dump written to $LOCAL_CONTAINER_DUMP inside $LOCAL_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 -- Copy dump from LOCAL container to LOCAL Windows filesystem
# ---------------------------------------------------------------------------
Step "2/10  Copying dump from LOCAL container to Windows host"

docker cp "${LOCAL_CONTAINER}:${LOCAL_CONTAINER_DUMP}" $LOCAL_FILE
docker exec $LOCAL_CONTAINER rm -f $LOCAL_CONTAINER_DUMP

$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) { Die "Dump is too small ($fileSize bytes) -- mysqldump likely failed." }
OK "Dump: $([math]::Round($fileSize/1MB, 1)) MB -- $LOCAL_FILE"

# ---------------------------------------------------------------------------
# Step 3 -- SCP dump to DEV host
# ---------------------------------------------------------------------------
Step "3/10  Uploading dump to DEV host"

scp -i $SSH_KEY $LOCAL_FILE "${DEV_USER}@${DEV_HOST}:${DEV_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "SCP to DEV failed." }
OK "Dump at $DEV_HOST_TEMP on DEV host"

# ---------------------------------------------------------------------------
# Step 4 -- Import dump into DEV database
# ---------------------------------------------------------------------------
Step "4/10  Importing dump into DEV database"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker cp ${DEV_HOST_TEMP} ${DEV_CONTAINER}:${TARGET_CONTAINER_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "docker cp of dump to DEV container failed." }

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_CONTAINER} mysql -u ${DEV_DB_USER} -p'${DEV_DB_PASS}' --default-character-set=utf8mb4 ${DEV_DB_NAME} -e 'source ${TARGET_CONTAINER_TEMP}'"
if ($LASTEXITCODE -ne 0) { Die "Database import on DEV failed." }

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_CONTAINER} rm -f ${TARGET_CONTAINER_TEMP}; rm -f ${DEV_HOST_TEMP}"
OK "Database import complete on DEV"

# ---------------------------------------------------------------------------
# Step 5 -- Clear stale cache tables (objectcache contains LOCAL domain URLs)
# ---------------------------------------------------------------------------
Step "5/10  Clearing stale cache tables on DEV"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_CONTAINER} mysql -u ${DEV_DB_USER} -p'${DEV_DB_PASS}' ${DEV_DB_NAME} -e 'TRUNCATE TABLE objectcache; TRUNCATE TABLE l10n_cache;'"
if ($LASTEXITCODE -ne 0) { Die "Cache truncation on DEV failed." }
OK "objectcache and l10n_cache cleared on DEV"

# ---------------------------------------------------------------------------
# Step 6 -- Reset MediaWiki Admin password to DEV-specific value
# ---------------------------------------------------------------------------
Step "6/10  Resetting MediaWiki Admin password on DEV"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_WB_CONTAINER} php /var/www/html/maintenance/run.php changePassword --conf /config/LocalSettings.php --user=admin --password='${DEV_MW_ADMIN_PASS}'"
if ($LASTEXITCODE -ne 0) { Die "Admin password reset on DEV failed." }
OK "Admin password reset to DEV value"

# ---------------------------------------------------------------------------
# Step 7 -- Run MediaWiki maintenance update + rebuild recentchanges
# ---------------------------------------------------------------------------
Step "7/10  Running MediaWiki update on DEV"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_WB_CONTAINER} php /var/www/html/maintenance/run.php update --conf /config/LocalSettings.php --quick"
if ($LASTEXITCODE -ne 0) { Die "MediaWiki update on DEV failed." }

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_WB_CONTAINER} php /var/www/html/maintenance/run.php rebuildrecentchanges --conf /config/LocalSettings.php"
if ($LASTEXITCODE -ne 0) { Die "rebuildrecentchanges on DEV failed." }
OK "MediaWiki update and recentchanges rebuild complete"

# ---------------------------------------------------------------------------
# Step 8 -- Sync uploads/images: tar inside LOCAL container → SCP → extract on DEV
# ---------------------------------------------------------------------------
if ($DbOnly) {
    Step "8/10  Skipping uploads/images sync (-DbOnly)"
    OK "Images sync skipped"
} else {
    Step "8/10  Syncing uploads/images from LOCAL to DEV"

    Write-Host "  Creating images archive inside LOCAL container (excluding thumbnails)..." -ForegroundColor Yellow
    docker exec $LOCAL_WB_CONTAINER tar --exclude=thumb -czf $LOCAL_IMAGES_ARCHIVE /var/www/html/images
    if ($LASTEXITCODE -ne 0) { Die "tar archive of LOCAL images failed." }

    docker cp "${LOCAL_WB_CONTAINER}:${LOCAL_IMAGES_ARCHIVE}" $LOCAL_IMAGES_FILE
    docker exec $LOCAL_WB_CONTAINER rm -f $LOCAL_IMAGES_ARCHIVE

    $archiveSize = (Get-Item $LOCAL_IMAGES_FILE).Length
    OK "Images archive: $([math]::Round($archiveSize/1MB, 1)) MB -- $LOCAL_IMAGES_FILE"

    Write-Host "  Uploading archive to DEV host..." -ForegroundColor Yellow
    scp -i $SSH_KEY $LOCAL_IMAGES_FILE "${DEV_USER}@${DEV_HOST}:${DEV_IMAGES_TEMP}"
    if ($LASTEXITCODE -ne 0) { Die "SCP of images archive to DEV failed." }

    Write-Host "  Extracting archive into DEV container (wikibase_images volume)..." -ForegroundColor Yellow

    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker cp ${DEV_IMAGES_TEMP} ${DEV_WB_CONTAINER}:/tmp/images_restore.tar.gz"
    if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive to DEV container failed." }

    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_WB_CONTAINER} sh -c 'find /var/www/html/images -mindepth 1 -not -name ckglogo1.png -not -name ckglogo1.svg -delete 2>/dev/null; tar -xzf /tmp/images_restore.tar.gz --strip-components=3 -C /var/www/html --exclude=var/www/html/images/ckglogo1.png --exclude=var/www/html/images/ckglogo1.svg && rm /tmp/images_restore.tar.gz'"
    if ($LASTEXITCODE -ne 0) { Die "Images extraction on DEV failed." }

    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "rm -f ${DEV_IMAGES_TEMP}"
    OK "Images synced to DEV"
}

# ---------------------------------------------------------------------------
# Step 9 -- Update LocalSettings files on DEV via git pull
# ---------------------------------------------------------------------------
Step "9/10  Updating LocalSettings files on DEV via git pull"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "cd /opt/wikibase && git fetch origin && git pull origin master"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] git pull on DEV failed or repo not configured. LocalSettings files may be stale." -ForegroundColor Yellow
    Write-Host "       Manually run: ssh root@${DEV_HOST} 'cd /opt/wikibase && git pull origin master'" -ForegroundColor Yellow
} else {
    OK "git pull complete on DEV -- LocalSettings files updated"
}

# ---------------------------------------------------------------------------
# Step 10 -- Re-register sitelinks and restart wikibase on DEV
# ---------------------------------------------------------------------------
Step "10/10  Restarting DEV containers"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.dev.yml restart wikibase-sitelinks-init && sleep 15 && docker compose -f docker-compose.yml -f docker-compose.dev.yml restart wikibase"
if ($LASTEXITCODE -ne 0) { Die "Container restart on DEV failed." }
OK "Sitelinks re-registered and wikibase restarted on DEV"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " LOCAL -> DEV sync complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  DB dump file    : $LOCAL_FILE"
if ($DbOnly) {
    Write-Host "  Images archive  : (skipped, -DbOnly)"
} else {
    Write-Host "  Images archive  : $LOCAL_IMAGES_FILE"
}
Write-Host "  Timestamp       : $TIMESTAMP"
Write-Host ""
Write-Host "Verify at https://dev-climatekg.semanticclimate.org" -ForegroundColor Yellow
Write-Host ""
Write-Host "NOTE: Admin login on DEV uses the password from DEV_MW_ADMIN_PASS in C:\Wikibase\.env" -ForegroundColor Yellow
Write-Host ""
