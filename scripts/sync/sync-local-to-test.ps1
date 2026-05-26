#Requires -Version 5.1
<#
.SYNOPSIS
    Push the LOCAL Wikibase database, uploads/files, and LocalSettings to TEST.

.DESCRIPTION
    1. Dumps the LOCAL MariaDB database inside the LOCAL container using --result-file
       (bypasses PowerShell stream encoding -- avoids UTF-16LE/character-map corruption,
       see backups/mariadb-backup-powershell-encoding-notes.md).
    2. Verifies dump size > 1 MB.
    3. SCPs the dump to the TEST host, imports it via docker cp + mysql source inside
       the TEST container (no PowerShell stream involved).
    4. Truncates objectcache and l10n_cache on TEST so MediaWiki generates fresh URLs
       for the TEST domain (https://test-climatekg.semanticclimate.org).
    5. Resets the MediaWiki Admin password on TEST to the value from TEST_MW_ADMIN_PASS
       in C:\Wikibase\.env using the changePassword maintenance script.
    6. Runs MediaWiki update + recentchanges rebuild on TEST.
    7. Syncs uploads/images: creates tar.gz inside LOCAL container, docker cp to LOCAL
       host, SCP to TEST, extracts into TEST Docker volume.
    8. Updates LocalSettings files on TEST via git pull (files are bind-mounted from
       /opt/wikibase repo on the TEST server).
    9. Re-registers TEST sitelinks by restarting wikibase-sitelinks-init.
   10. Restarts the wikibase container on TEST.

.NOTES
    Required entries in C:\Wikibase\.env (gitignored):
        TEST_DB_PASS=<test-mariadb-password>
        TEST_MW_ADMIN_PASS=<mediawiki-admin-password-for-test>

    LOCAL DB credentials come from docker-compose.yml defaults (user: wikibase / pass: wikibase).

    SSH key setup (one-time, as Administrator):
        Set-Service  -Name ssh-agent -StartupType Automatic
        Start-Service ssh-agent
        ssh-add C:\Users\<user>\.ssh\id_rsa

    IMPORTANT -- PowerShell character-map safety rules:
      * NEVER use  >  or  |  to redirect mysqldump output from PowerShell.
      * ALWAYS use  --result-file  inside the container.
      * ALWAYS import via  mysql -e 'source /tmp/file.sql'  inside the container.
      * NEVER use  docker exec ... mysql < file  from PowerShell.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$LOCAL_CONTAINER  = "wikibase-mariadb"
$LOCAL_WB_CONTAINER = "wikibase"
$LOCAL_DB_USER    = "wikibase"
$LOCAL_DB_PASS    = "wikibase"          # docker-compose.yml default for LOCAL
$LOCAL_DB_NAME    = "my_wiki"

$TEST_HOST        = "46.224.66.24"
$TEST_USER        = "root"
$TEST_DB_USER     = "wikibase"
$TEST_DB_NAME     = "my_wiki"
$TEST_CONTAINER   = "wikibase-mariadb"
$TEST_WB_CONTAINER = "wikibase"

$SSH_KEY          = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"
$BACKUP_DIR       = "C:\Wikibase\backups"
$TIMESTAMP        = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME    = "local_to_test_$TIMESTAMP.sql"
$IMAGES_ARCHIVE   = "local_to_test_images_$TIMESTAMP.tar.gz"

$LOCAL_CONTAINER_DUMP    = "/tmp/$DUMP_FILENAME"    # inside LOCAL mariadb container
$LOCAL_FILE              = Join-Path $BACKUP_DIR $DUMP_FILENAME
$LOCAL_IMAGES_ARCHIVE    = "/tmp/$IMAGES_ARCHIVE"  # inside LOCAL wikibase container
$LOCAL_IMAGES_FILE       = Join-Path $BACKUP_DIR $IMAGES_ARCHIVE

$TEST_HOST_TEMP          = "/tmp/$DUMP_FILENAME"
$TEST_IMAGES_TEMP        = "/tmp/$IMAGES_ARCHIVE"
$TARGET_CONTAINER_TEMP   = "/tmp/restore.sql"

# ---------------------------------------------------------------------------
# Resolve TEST passwords from .env
# ---------------------------------------------------------------------------
$envFile           = "C:\Wikibase\.env"
$TEST_DB_PASS      = $null
$TEST_MW_ADMIN_PASS = $null

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^TEST_DB_PASS\s*=")       { $TEST_DB_PASS       = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^TEST_MW_ADMIN_PASS\s*=") { $TEST_MW_ADMIN_PASS = ($_ -split "=", 2)[1].Trim() }
    }
}

if ([string]::IsNullOrEmpty($TEST_DB_PASS)) {
    $securePwd    = Read-Host "TEST MariaDB password" -AsSecureString
    $TEST_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd))
}

if ([string]::IsNullOrEmpty($TEST_MW_ADMIN_PASS)) {
    Write-Host ""
    Write-Host "TEST_MW_ADMIN_PASS not found in $envFile." -ForegroundColor Yellow
    Write-Host "Add  TEST_MW_ADMIN_PASS=<password>  to that file, or enter it now."
    $securePwd        = Read-Host "TEST MediaWiki Admin password" -AsSecureString
    $TEST_MW_ADMIN_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
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
if (-not (Test-Path $SSH_KEY)) { Die "SSH key not found at $SSH_KEY." }

# Verify LOCAL containers are running
$runningContainers = docker ps --format "{{.Names}}"
if ($runningContainers -notcontains $LOCAL_CONTAINER) {
    Die "LOCAL container '$LOCAL_CONTAINER' is not running. Start Docker Desktop and run: docker compose up -d"
}
if ($runningContainers -notcontains $LOCAL_WB_CONTAINER) {
    Die "LOCAL container '$LOCAL_WB_CONTAINER' is not running. Start Docker Desktop and run: docker compose up -d"
}

Write-Host "Testing SSH to TEST ($TEST_HOST)..." -ForegroundColor Yellow
ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 "${TEST_USER}@${TEST_HOST}" "echo OK" | Out-Null
if ($LASTEXITCODE -ne 0) { Die "Cannot SSH to TEST. Ensure public key is in authorized_keys." }

OK "Pre-flight passed"

# ---------------------------------------------------------------------------
# Step 1 -- Dump LOCAL database INSIDE the container using --result-file
#           SAFE: writes UTF-8 directly to container disk; no PS redirection involved.
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
#           SAFE: docker cp preserves bytes unchanged.
# ---------------------------------------------------------------------------
Step "2/10  Copying dump from LOCAL container to Windows host"

docker cp "${LOCAL_CONTAINER}:${LOCAL_CONTAINER_DUMP}" $LOCAL_FILE
docker exec $LOCAL_CONTAINER rm -f $LOCAL_CONTAINER_DUMP

$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) { Die "Dump is too small ($fileSize bytes) -- mysqldump likely failed." }
OK "Dump: $([math]::Round($fileSize/1MB, 1)) MB -- $LOCAL_FILE"

# ---------------------------------------------------------------------------
# Step 3 -- SCP dump to TEST host
# ---------------------------------------------------------------------------
Step "3/10  Uploading dump to TEST host"

scp -i $SSH_KEY $LOCAL_FILE "${TEST_USER}@${TEST_HOST}:${TEST_HOST_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "SCP to TEST failed." }
OK "Dump at $TEST_HOST_TEMP on TEST host"

# ---------------------------------------------------------------------------
# Step 4 -- Import dump into TEST database
#           SAFE: docker cp + mysql source inside container -- no PS streams.
# ---------------------------------------------------------------------------
Step "4/10  Importing dump into TEST database"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker cp ${TEST_HOST_TEMP} ${TEST_CONTAINER}:${TARGET_CONTAINER_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "docker cp of dump to TEST container failed." }

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_CONTAINER} mysql -u ${TEST_DB_USER} -p'${TEST_DB_PASS}' --default-character-set=utf8mb4 ${TEST_DB_NAME} -e 'source ${TARGET_CONTAINER_TEMP}'"
if ($LASTEXITCODE -ne 0) { Die "Database import on TEST failed." }

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_CONTAINER} rm -f ${TARGET_CONTAINER_TEMP}; rm -f ${TEST_HOST_TEMP}"
OK "Database import complete on TEST"

# ---------------------------------------------------------------------------
# Step 5 -- Clear stale cache tables (objectcache contains LOCAL domain URLs)
# ---------------------------------------------------------------------------
Step "5/10  Clearing stale cache tables on TEST"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_CONTAINER} mysql -u ${TEST_DB_USER} -p'${TEST_DB_PASS}' ${TEST_DB_NAME} -e 'TRUNCATE TABLE objectcache; TRUNCATE TABLE l10n_cache;'"
if ($LASTEXITCODE -ne 0) { Die "Cache truncation on TEST failed." }
OK "objectcache and l10n_cache cleared on TEST"

# ---------------------------------------------------------------------------
# Step 6 -- Reset MediaWiki Admin password to TEST-specific value
#           The imported DB contains LOCAL's admin password; this resets it
#           to the TEST_MW_ADMIN_PASS from .env so admins can log in on TEST.
# ---------------------------------------------------------------------------
Step "6/10  Resetting MediaWiki Admin password on TEST"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_WB_CONTAINER} php /var/www/html/maintenance/run.php changePassword --conf /config/LocalSettings.php --user=admin --password='${TEST_MW_ADMIN_PASS}'"
if ($LASTEXITCODE -ne 0) { Die "Admin password reset on TEST failed." }
OK "Admin password reset to TEST value"

# ---------------------------------------------------------------------------
# Step 7 -- Run MediaWiki maintenance update + rebuild recentchanges
# ---------------------------------------------------------------------------
Step "7/10  Running MediaWiki update on TEST"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_WB_CONTAINER} php /var/www/html/maintenance/run.php update --conf /config/LocalSettings.php --quick"
if ($LASTEXITCODE -ne 0) { Die "MediaWiki update on TEST failed." }

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_WB_CONTAINER} php /var/www/html/maintenance/run.php rebuildrecentchanges --conf /config/LocalSettings.php"
if ($LASTEXITCODE -ne 0) { Die "rebuildrecentchanges on TEST failed." }
OK "MediaWiki update and recentchanges rebuild complete"

# ---------------------------------------------------------------------------
# Step 8 -- Sync uploads/images: tar inside LOCAL container → SCP → extract on TEST
# ---------------------------------------------------------------------------
Step "8/10  Syncing uploads/images from LOCAL to TEST"

Write-Host "  Creating images archive inside LOCAL container (excluding thumbnails)..." -ForegroundColor Yellow
docker exec $LOCAL_WB_CONTAINER tar --exclude=thumb -czf $LOCAL_IMAGES_ARCHIVE /var/www/html/images
if ($LASTEXITCODE -ne 0) { Die "tar archive of LOCAL images failed." }

docker cp "${LOCAL_WB_CONTAINER}:${LOCAL_IMAGES_ARCHIVE}" $LOCAL_IMAGES_FILE
docker exec $LOCAL_WB_CONTAINER rm -f $LOCAL_IMAGES_ARCHIVE

$archiveSize = (Get-Item $LOCAL_IMAGES_FILE).Length
OK "Images archive: $([math]::Round($archiveSize/1MB, 1)) MB -- $LOCAL_IMAGES_FILE"

Write-Host "  Uploading archive to TEST host..." -ForegroundColor Yellow
scp -i $SSH_KEY $LOCAL_IMAGES_FILE "${TEST_USER}@${TEST_HOST}:${TEST_IMAGES_TEMP}"
if ($LASTEXITCODE -ne 0) { Die "SCP of images archive to TEST failed." }

Write-Host "  Extracting archive into TEST container (wikibase_images volume)..." -ForegroundColor Yellow

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker cp ${TEST_IMAGES_TEMP} ${TEST_WB_CONTAINER}:/tmp/images_restore.tar.gz"
if ($LASTEXITCODE -ne 0) { Die "docker cp of images archive to TEST container failed." }

# sh -c inline: clear images (skipping bind-mounted logos), extract tar (exclude logos too), remove archive
ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "docker exec ${TEST_WB_CONTAINER} sh -c 'find /var/www/html/images -mindepth 1 -not -name ckglogo1.png -not -name ckglogo1.svg -delete 2>/dev/null; tar -xzf /tmp/images_restore.tar.gz --strip-components=3 -C /var/www/html --exclude=var/www/html/images/ckglogo1.png --exclude=var/www/html/images/ckglogo1.svg && rm /tmp/images_restore.tar.gz'"
if ($LASTEXITCODE -ne 0) { Die "Images extraction on TEST failed." }

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "rm -f ${TEST_IMAGES_TEMP}"
OK "Images synced to TEST"

# ---------------------------------------------------------------------------
# Step 9 -- Update LocalSettings files on TEST via git pull
#           LocalSettings.*.php files are bind-mounted from /opt/wikibase/ on TEST,
#           so a git pull picks up any changes pushed to master.
# ---------------------------------------------------------------------------
Step "9/10  Updating LocalSettings files on TEST via git pull"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "cd /opt/wikibase && git fetch origin && git pull origin master"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] git pull on TEST failed or repo not configured. LocalSettings files may be stale." -ForegroundColor Yellow
    Write-Host "       Manually run: ssh root@${TEST_HOST} 'cd /opt/wikibase && git pull origin master'" -ForegroundColor Yellow
} else {
    OK "git pull complete on TEST -- LocalSettings files updated"
}

# ---------------------------------------------------------------------------
# Step 10 -- Re-register sitelinks and restart wikibase on TEST
# ---------------------------------------------------------------------------
Step "10/10  Restarting TEST containers"

ssh -i $SSH_KEY "${TEST_USER}@${TEST_HOST}" "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.test.yml restart wikibase-sitelinks-init && sleep 15 && docker compose -f docker-compose.yml -f docker-compose.test.yml restart wikibase"
if ($LASTEXITCODE -ne 0) { Die "Container restart on TEST failed." }
OK "Sitelinks re-registered and wikibase restarted on TEST"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " LOCAL -> TEST sync complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  DB dump file    : $LOCAL_FILE"
Write-Host "  Images archive  : $LOCAL_IMAGES_FILE"
Write-Host "  Timestamp       : $TIMESTAMP"
Write-Host ""
Write-Host "Verify at https://test-climatekg.semanticclimate.org" -ForegroundColor Yellow
Write-Host ""
Write-Host "NOTE: Admin login on TEST uses the password from TEST_MW_ADMIN_PASS in C:\Wikibase\.env" -ForegroundColor Yellow
Write-Host ""
