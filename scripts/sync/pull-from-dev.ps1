#Requires -Version 5.1
<#
.SYNOPSIS
    Pull the DEV MariaDB database (and optionally uploaded images) and overwrite
    the local Wikibase instance, then re-register localhost sitelinks.

.DESCRIPTION
    1. Dumps the DEV database inside the DEV MariaDB container using
       --result-file (bypasses SSH/PowerShell stream encoding -- see
       backups/mariadb-backup-powershell-encoding-notes.md).
    2. Copies the dump from the container to the DEV host, then SCP's it
       to this Windows machine.
    3. Copies the SQL file into the local MariaDB container and imports it from
       inside (no PowerShell stream involved -- avoids UTF-16LE corruption).
    4. Re-registers localhost sitelinks by restarting wikibase-sitelinks-init.
    5. Restarts the wikibase container to clear PHP/object caches.

    With -IncludeImages:
    6. Tars /var/www/html/images (excluding thumb/) from the DEV wikibase
       container, SCPs it to this machine, then serves it via a temporary
       local HTTP server so the local container can fetch it with curl
       (avoids the docker cp large-file pipe crash on Windows Docker Desktop).
       Fixes www-data ownership and purges stale thumbnails after extraction.

.PARAMETER IncludeImages
    Also pull uploaded images from DEV (/var/www/html/images volume).

.NOTES
    DEV DB password is read from DEV_DB_PASS in a local .env file
    (C:\Wikibase\.env), which is gitignored.  Add the following line to that
    file before running:

        DEV_DB_PASS=<actual-password>

    If the variable is absent the script will prompt securely.
#>
param(
    [switch]$IncludeImages
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
$SSH_KEY         = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"

$LOCAL_DB_USER    = "wikibase"
$LOCAL_DB_PASS    = "wikibase"
$LOCAL_DB_NAME    = "my_wiki"
$LOCAL_CONTAINER  = "wikibase-mariadb"

$BACKUP_DIR       = "C:\Wikibase\backups"
$TIMESTAMP        = Get-Date -Format "yyyyMMdd_HHmmss"
$DUMP_FILENAME    = "prod_pull_$TIMESTAMP.sql"
$IMAGES_FILENAME  = "dev_images_$TIMESTAMP.tar.gz"

$CONTAINER_TEMP   = "/tmp/$DUMP_FILENAME"      # path inside DEV container
$DEV_HOST_TEMP    = "/tmp/$DUMP_FILENAME"      # path on DEV host after docker cp
$LOCAL_FILE       = Join-Path $BACKUP_DIR $DUMP_FILENAME
$LOCAL_CONTAINER_TEMP = "/tmp/restore.sql"      # path inside local container

$DEV_WIKIBASE_CONTAINER  = "wikibase"           # wikibase container name on DEV
$LOCAL_WIKIBASE_CONTAINER = "wikibase"          # wikibase container name on LOCAL
$IMAGES_CONTAINER_TEMP   = "/tmp/$IMAGES_FILENAME"  # path inside DEV wikibase container
$IMAGES_DEV_HOST_TEMP    = "/tmp/$IMAGES_FILENAME"  # path on DEV host after docker cp
$IMAGES_LOCAL_FILE       = Join-Path $BACKUP_DIR $IMAGES_FILENAME
$IMAGES_LOCAL_CONTAINER_TEMP = "/tmp/$IMAGES_FILENAME"  # path inside local container (downloaded via curl)
$IMAGES_HTTP_PORT        = 9876                 # temporary HTTP server port (must be free)

# ---------------------------------------------------------------------------
# Resolve DEV DB password
# ---------------------------------------------------------------------------
$envFile = "C:\Wikibase\.env"
$DEV_DB_PASS = $null

if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match "^DEV_DB_PASS\s*=" } | ForEach-Object {
        $DEV_DB_PASS = ($_ -split "=", 2)[1].Trim()
    }
}

if ([string]::IsNullOrEmpty($DEV_DB_PASS)) {
    Write-Host ""
    Write-Host "DEV_DB_PASS not found in $envFile."
    Write-Host "Add  DEV_DB_PASS=<password>  to that file (it is gitignored), or enter it now."
    $securePwd = Read-Host "DEV DB password" -AsSecureString
    $DEV_DB_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
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

if ($IncludeImages) {
    $null = Get-Command python -ErrorAction SilentlyContinue
    if (-not $?) { Die "python not found on PATH. Required for -IncludeImages (temporary HTTP server)." }

    $portInUse = Get-NetTCPConnection -LocalPort $IMAGES_HTTP_PORT -ErrorAction SilentlyContinue
    if ($portInUse) {
        Die "Port $IMAGES_HTTP_PORT is already in use. Free the port or edit `$IMAGES_HTTP_PORT in this script."
    }
    OK "Port $IMAGES_HTTP_PORT is free"
}

OK "All required commands found"

# Verify the passphrase-free sync key exists
if (-not (Test-Path $SSH_KEY)) {
    Die "Sync key not found at $SSH_KEY. Re-run the key setup steps in docs/sync-guide.md."
}

# Verify we can reach the DEV server without a passphrase
Write-Host "Testing SSH connectivity to $DEV_HOST ..." -ForegroundColor Yellow
$sshTest = ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 "${DEV_USER}@${DEV_HOST}" "echo OK" 2>&1
if ($LASTEXITCODE -ne 0) {
    Die "Cannot SSH to ${DEV_USER}@${DEV_HOST} with key $SSH_KEY. Ensure the public key is in authorized_keys on the server."
}
OK "SSH connectivity confirmed (passphrase-free)"

# ---------------------------------------------------------------------------
# Step 1 — Dump production DB inside the container using --result-file
#           This writes UTF-8 directly to disk inside the container; it never
#           passes through any shell redirection that could corrupt encoding.
# ---------------------------------------------------------------------------
Step "1/7  Dumping DEV database (inside container)"

$dumpCmd = "docker exec $DEV_CONTAINER mysqldump " +
    "-u $DEV_DB_USER -p'$DEV_DB_PASS' " +
    "--default-character-set=utf8mb4 " +
    "--single-transaction " +
    "--quick " +
    "--max_allowed_packet=512M " +
    "--result-file=$CONTAINER_TEMP " +
    "$DEV_DB_NAME"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" $dumpCmd
OK "Dump written to $CONTAINER_TEMP inside $DEV_CONTAINER"

# ---------------------------------------------------------------------------
# Step 2 — Copy dump from container to DEV host filesystem
# ---------------------------------------------------------------------------
Step "2/7  Copying dump from container to DEV host"

ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker cp ${DEV_CONTAINER}:${CONTAINER_TEMP} ${DEV_HOST_TEMP}"
OK "Dump now at ${DEV_HOST_TEMP} on DEV host"

# ---------------------------------------------------------------------------
# Step 3 — SCP dump to local Windows machine
#           SCP transfers bytes unchanged — no encoding transformation.
# ---------------------------------------------------------------------------
Step "3/7  Downloading dump to local machine"

scp -i $SSH_KEY "${DEV_USER}@${DEV_HOST}:${DEV_HOST_TEMP}" $LOCAL_FILE
OK "Dump saved as $LOCAL_FILE"

# Verify the downloaded file is not empty
$fileSize = (Get-Item $LOCAL_FILE).Length
if ($fileSize -lt 1MB) {
    Die "Downloaded dump is suspiciously small ($fileSize bytes). The DEV mysqldump likely failed. Check SSH connectivity and DB credentials."
}
OK "Dump size: $([math]::Round($fileSize/1MB, 1)) MB — looks valid"

# Tidy up remote files now they are no longer needed
ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "docker exec ${DEV_CONTAINER} rm -f ${CONTAINER_TEMP}"
ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" "rm -f ${DEV_HOST_TEMP}"
OK "Cleaned up temp files on DEV server"

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
# Step 6 — Clear stale DEV cache entries from the imported database
#           The DEV dump contains objectcache and l10n_cache rows that
#           were generated with the DEV URL. Truncating them forces
#           MediaWiki to regenerate them with localhost:8080 URLs.
# ---------------------------------------------------------------------------
Step "6/8  Clearing stale cache tables"

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
#           The imported DEV DB will contain DEV URL sitelinks.
#           Restarting wikibase-sitelinks-init re-runs init-sitelinks.sh which
#           imports sites.xml (localhost:8080 paths) and sets site_language.
# ---------------------------------------------------------------------------
Step "6b/8  Re-registering localhost sitelinks (mywiki)"

docker compose --project-directory "C:\Wikibase" restart wikibase-sitelinks-init

# Give the init container time to complete
Write-Host "Waiting 15 seconds for sitelinks-init to complete..." -ForegroundColor Yellow
Start-Sleep -Seconds 15
OK "Sitelinks init restarted"

# ---------------------------------------------------------------------------
# Step 7 — Restart wikibase to clear PHP/object caches
# ---------------------------------------------------------------------------
Step "7/8  Restarting wikibase container"

docker compose --project-directory "C:\Wikibase" restart wikibase
OK "Wikibase container restarted"

# ---------------------------------------------------------------------------
# Step 8 — Reset local admin password
#           The imported DEV DB carries the DEV admin password.
#           Reset it back to the standard localhost default so local logins work.
# ---------------------------------------------------------------------------
Step "8/8  Resetting local admin password"

docker exec wikibase php /var/www/html/maintenance/run.php changePassword `
    --conf /config/LocalSettings.php --user admin --password "adminpass123!"

OK "Admin password reset to local default (adminpass123!)"

# ---------------------------------------------------------------------------
# Optional: Pull images from DEV
# ---------------------------------------------------------------------------
if ($IncludeImages) {
    # Count images on DEV before transfer for verification
    Step "Images 1/5  Checking DEV image count"
    $devCount = ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" `
        "docker exec $DEV_WIKIBASE_CONTAINER bash -c `"find /var/www/html/images -type f -not -path '*/thumb/*' -not -name '.htaccess' -not -name 'README' | wc -l`""
    OK "DEV image files (excluding thumbnails): $($devCount.Trim())"

    # -------------------------------------------------------------------------
    # Archive images inside DEV container (exclude thumb/ -- regenerated on demand)
    # -------------------------------------------------------------------------
    Step "Images 2/5  Archiving DEV wikibase images (excluding thumbnails)"

    Write-Host "This may take a minute for large image sets..." -ForegroundColor Yellow
    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" `
        "docker exec $DEV_WIKIBASE_CONTAINER tar -czf $IMAGES_CONTAINER_TEMP --exclude=./thumb -C /var/www/html/images . && echo DONE"
    if ($LASTEXITCODE -ne 0) { Die "tar failed inside DEV container. Check disk space and container health." }
    OK "Archive created at $IMAGES_CONTAINER_TEMP inside $DEV_WIKIBASE_CONTAINER"

    # -------------------------------------------------------------------------
    # Copy archive to DEV host then SCP to local machine
    # -------------------------------------------------------------------------
    Step "Images 3/5  Downloading archive to local machine"

    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" `
        "docker cp ${DEV_WIKIBASE_CONTAINER}:${IMAGES_CONTAINER_TEMP} ${IMAGES_DEV_HOST_TEMP} && echo DONE"
    if ($LASTEXITCODE -ne 0) { Die "docker cp from DEV container to host failed." }

    Write-Host "Downloading via SCP (may take several minutes for large image sets)..." -ForegroundColor Yellow
    scp -i $SSH_KEY "${DEV_USER}@${DEV_HOST}:${IMAGES_DEV_HOST_TEMP}" $IMAGES_LOCAL_FILE
    if ($LASTEXITCODE -ne 0) { Die "SCP download of images archive failed." }

    $archiveSize = (Get-Item $IMAGES_LOCAL_FILE).Length
    if ($archiveSize -lt 100KB) {
        Die "Downloaded archive is only $archiveSize bytes -- transfer likely failed."
    }
    OK "Archive saved as $IMAGES_LOCAL_FILE ($([math]::Round($archiveSize / 1MB, 1)) MB)"

    # Tidy up remote temp files
    ssh -i $SSH_KEY "${DEV_USER}@${DEV_HOST}" `
        "docker exec $DEV_WIKIBASE_CONTAINER rm -f $IMAGES_CONTAINER_TEMP ; rm -f $IMAGES_DEV_HOST_TEMP"
    OK "Cleaned up temp files on DEV server"

    # -------------------------------------------------------------------------
    # Serve archive over HTTP so the local container can fetch it via curl.
    # docker cp of large files (> ~100 MB) crashes Docker Desktop on Windows
    # via the named-pipe backend. Serving over HTTP is the reliable workaround.
    # -------------------------------------------------------------------------
    Step "Images 4/5  Transferring archive into local container (via HTTP)"

    Write-Host "Starting temporary HTTP server on port $IMAGES_HTTP_PORT ..." -ForegroundColor Yellow
    $httpJob = Start-Job -ScriptBlock {
        param($dir, $port)
        Set-Location $dir
        python -m http.server $port
    } -ArgumentList $BACKUP_DIR, $IMAGES_HTTP_PORT

    Start-Sleep -Seconds 2

    Write-Host "Container downloading archive from host (host.docker.internal:$IMAGES_HTTP_PORT)..." -ForegroundColor Yellow
    docker exec $LOCAL_WIKIBASE_CONTAINER curl -s -o $IMAGES_LOCAL_CONTAINER_TEMP `
        "http://host.docker.internal:${IMAGES_HTTP_PORT}/${IMAGES_FILENAME}"
    if ($LASTEXITCODE -ne 0) {
        Stop-Job $httpJob | Out-Null ; Remove-Job $httpJob | Out-Null
        Die "curl inside container failed. Ensure curl is available in the container image."
    }

    $innerSize = docker exec $LOCAL_WIKIBASE_CONTAINER bash -c "stat -c%s $IMAGES_LOCAL_CONTAINER_TEMP 2>/dev/null || echo 0"
    if ([long]$innerSize.Trim() -lt 100KB) {
        Stop-Job $httpJob | Out-Null ; Remove-Job $httpJob | Out-Null
        Die "Archive inside container is too small ($innerSize bytes). Download may have been truncated."
    }
    OK "Archive downloaded into container ($([math]::Round([long]$innerSize.Trim() / 1MB, 1)) MB)"

    Stop-Job $httpJob | Out-Null
    Remove-Job $httpJob | Out-Null
    OK "Temporary HTTP server stopped"

    # -------------------------------------------------------------------------
    # Extract, fix ownership, purge stale thumbnails
    # -------------------------------------------------------------------------
    Step "Images 5/5  Extracting images and fixing ownership"

    docker exec $LOCAL_WIKIBASE_CONTAINER tar -xzf $IMAGES_LOCAL_CONTAINER_TEMP -C /var/www/html/images
    if ($LASTEXITCODE -ne 0) { Die "tar extraction failed inside local container." }

    docker exec $LOCAL_WIKIBASE_CONTAINER chown -R www-data:www-data /var/www/html/images
    OK "Ownership set to www-data:www-data"

    # Purge stale thumbnails -- MediaWiki regenerates them on first page view
    docker exec $LOCAL_WIKIBASE_CONTAINER bash -c "find /var/www/html/images/thumb -mindepth 1 -delete 2>/dev/null; echo done" | Out-Null
    OK "Stale thumbnails cleared (will regenerate on demand)"

    docker exec $LOCAL_WIKIBASE_CONTAINER rm -f $IMAGES_LOCAL_CONTAINER_TEMP
    OK "Cleaned up archive from local container"

    # Verify file count
    $localCount = docker exec $LOCAL_WIKIBASE_CONTAINER bash -c `
        "find /var/www/html/images -type f -not -path '*/thumb/*' -not -name '.htaccess' -not -name 'README' | wc -l"
    OK "Local image files after restore: $($localCount.Trim())"
    if ([int]$localCount.Trim() -lt [int]$devCount.Trim()) {
        Write-Host "[WARN] Local count ($($localCount.Trim())) is less than DEV count ($($devCount.Trim())). Some files may be missing." -ForegroundColor Yellow
    } else {
        OK "Image counts match or exceed DEV ($($devCount.Trim()) DEV / $($localCount.Trim()) local)"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Pull from DEV complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Local dump file : $LOCAL_FILE"
if ($IncludeImages) {
    Write-Host "  Images archive  : $IMAGES_LOCAL_FILE"
}
Write-Host "  Timestamp       : $TIMESTAMP"
Write-Host ""
Write-Host "Verify at http://localhost:8080" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Local admin login: admin / adminpass123!" -ForegroundColor Yellow
Write-Host ""
if ($IncludeImages) {
    Write-Host "  Verify images at http://localhost:8080/wiki/Special:ListFiles" -ForegroundColor Yellow
    Write-Host ""
}
Write-Host "Note: Sitelinks should now be registered for mywiki (localhost)."
Write-Host "Verify at http://localhost:8080/wiki/Special:Sites"
