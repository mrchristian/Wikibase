#Requires -Version 5.1
<#
.SYNOPSIS
    Pull production MediaWiki image files and overwrite the local wikibase container's
    images volume.

.DESCRIPTION
    1. Creates a compressed tar of /var/www/html/images (excluding thumb/) inside
       the production wikibase container.
    2. Copies it from the container to the production host, then SCP's it to this
       Windows machine (C:\Wikibase\backups\wiki_images_<timestamp>.tar.gz).
    3. Serves the archive over a temporary local HTTP server so the local container
       can download it via curl — this avoids the docker cp large-file pipe crash
       that occurs on Windows Docker Desktop with files > ~100 MB.
    4. Extracts the archive directly into the container's images volume
       (/var/www/html/images), fixing ownership to www-data afterwards.
    5. Deletes stale thumbnails so MediaWiki regenerates them on demand.
    6. Cleans up all temporary files on production host, local host, and in both
       containers.

.NOTES
    Requires:
      - Docker Desktop running locally
      - OpenSSH (ssh + scp) available on PATH
      - SSH key at C:\Users\<you>\.ssh\id_wikibase_sync loaded (passphrase-free)
      - Python 3 on PATH (used for the temporary HTTP server)
      - Port 9876 free on the local machine during the transfer

    The local container must have curl available (the default wikibase image does).

    Thumbnails (~287 MB) are excluded from the transfer; MediaWiki regenerates them
    automatically when a page is first viewed after the restore.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$PROD_HOST        = "178.104.156.88"
$PROD_USER        = "root"
$PROD_CONTAINER   = "wikibase"          # production wikibase (Apache/PHP) container

$LOCAL_CONTAINER  = "wikibase"          # local wikibase container name
$CONTAINER_IMAGES = "/var/www/html/images"

$BACKUP_DIR       = "C:\Wikibase\backups"
$TIMESTAMP        = Get-Date -Format "yyyyMMdd_HHmmss"
$ARCHIVE_NAME     = "wiki_images_$TIMESTAMP.tar.gz"
$ARCHIVE_LOCAL    = Join-Path $BACKUP_DIR $ARCHIVE_NAME

$HTTP_PORT        = 9876                # temporary HTTP server port
$SSH_KEY          = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"

$PROD_CONTAINER_TMP = "/tmp/$ARCHIVE_NAME"   # inside production container
$PROD_HOST_TMP      = "/tmp/$ARCHIVE_NAME"   # on production host
$LOCAL_CONTAINER_TMP = "/tmp/$ARCHIVE_NAME"  # inside local container (downloaded via curl)

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

foreach ($cmd in @("docker", "ssh", "scp", "python")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Die "'$cmd' not found on PATH. See docs/pull-images-guide.md for prerequisites."
    }
}
OK "All required commands found (docker, ssh, scp, python)"

if (-not (Test-Path $SSH_KEY)) {
    Die "SSH key not found at $SSH_KEY. See docs/sync-guide.md for setup instructions."
}

Write-Host "Testing SSH connectivity to $PROD_HOST ..." -ForegroundColor Yellow
$sshTest = ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 "${PROD_USER}@${PROD_HOST}" "echo OK" 2>&1
if ($LASTEXITCODE -ne 0) {
    Die "Cannot SSH to ${PROD_USER}@${PROD_HOST} with key $SSH_KEY. Ensure the public key is in authorized_keys on the server."
}
OK "SSH connectivity confirmed (passphrase-free)"

# Confirm the local wikibase container is running
$running = docker inspect --format "{{.State.Running}}" $LOCAL_CONTAINER 2>&1
if ($running -ne "true") {
    Die "Local container '$LOCAL_CONTAINER' is not running. Start the stack first: docker compose up -d"
}
OK "Local container '$LOCAL_CONTAINER' is running"

# Check that port 9876 is free
$portInUse = Get-NetTCPConnection -LocalPort $HTTP_PORT -ErrorAction SilentlyContinue
if ($portInUse) {
    Die "Port $HTTP_PORT is already in use. Either free the port or edit `$HTTP_PORT in this script."
}
OK "Port $HTTP_PORT is free"

# ---------------------------------------------------------------------------
# Step 1 — Check production image count before transfer
# ---------------------------------------------------------------------------
Step "1/6  Checking production image count"

$prodCount = ssh -i $SSH_KEY "${PROD_USER}@${PROD_HOST}" `
    "docker exec $PROD_CONTAINER bash -c `"find $CONTAINER_IMAGES -type f -not -path '*/thumb/*' -not -name '.htaccess' -not -name 'README' | wc -l`""
OK "Production image files (excluding thumbnails): $($prodCount.Trim())"

# ---------------------------------------------------------------------------
# Step 2 — Create tar archive inside the production container
#           Excludes thumb/ — thumbnails regenerate automatically on demand.
# ---------------------------------------------------------------------------
Step "2/6  Archiving production images (excluding thumbnails)"

Write-Host "This may take a minute for large image sets..." -ForegroundColor Yellow
ssh -i $SSH_KEY "${PROD_USER}@${PROD_HOST}" `
    "docker exec $PROD_CONTAINER tar -czf $PROD_CONTAINER_TMP -C $CONTAINER_IMAGES --exclude=./thumb . && echo DONE"
if ($LASTEXITCODE -ne 0) {
    Die "tar failed inside production container. Check disk space and container health."
}
OK "Archive created at $PROD_CONTAINER_TMP inside production container"

# ---------------------------------------------------------------------------
# Step 3 — Copy archive from container to production host, then SCP to local
# ---------------------------------------------------------------------------
Step "3/6  Downloading archive to local machine"

ssh -i $SSH_KEY "${PROD_USER}@${PROD_HOST}" `
    "docker cp ${PROD_CONTAINER}:${PROD_CONTAINER_TMP} ${PROD_HOST_TMP} && echo DONE"
if ($LASTEXITCODE -ne 0) {
    Die "docker cp from production container to host failed."
}
OK "Archive staged at $PROD_HOST_TMP on production host"

Write-Host "Downloading via SCP (this will take several minutes for large image sets)..." -ForegroundColor Yellow
scp -i $SSH_KEY "${PROD_USER}@${PROD_HOST}:${PROD_HOST_TMP}" $ARCHIVE_LOCAL
if ($LASTEXITCODE -ne 0) {
    Die "SCP download failed."
}

$archiveSize = (Get-Item $ARCHIVE_LOCAL).Length
if ($archiveSize -lt 1MB) {
    Die "Downloaded archive is only $archiveSize bytes — transfer likely failed. Do not proceed."
}
OK "Archive saved as $ARCHIVE_LOCAL ($([math]::Round($archiveSize / 1MB, 1)) MB)"

# Tidy up production temp files
ssh -i $SSH_KEY "${PROD_USER}@${PROD_HOST}" `
    "docker exec $PROD_CONTAINER rm -f $PROD_CONTAINER_TMP ; rm -f $PROD_HOST_TMP"
OK "Cleaned up temp files on production server"

# ---------------------------------------------------------------------------
# Step 4 — Serve archive over HTTP so the local container can fetch it
#           docker cp of large files (> ~100 MB) crashes Docker Desktop on
#           Windows via the named-pipe backend. Serving over HTTP and using
#           curl inside the container is a reliable workaround.
# ---------------------------------------------------------------------------
Step "4/6  Transferring archive into local container (via HTTP)"

Write-Host "Starting temporary HTTP server on port $HTTP_PORT ..." -ForegroundColor Yellow
$httpJob = Start-Job -ScriptBlock {
    param($dir, $port)
    Set-Location $dir
    python -m http.server $port
} -ArgumentList $BACKUP_DIR, $HTTP_PORT

Start-Sleep -Seconds 2

Write-Host "Container downloading archive from host (host.docker.internal:$HTTP_PORT)..." -ForegroundColor Yellow
docker exec $LOCAL_CONTAINER curl -s -o $LOCAL_CONTAINER_TMP `
    "http://host.docker.internal:${HTTP_PORT}/${ARCHIVE_NAME}"
if ($LASTEXITCODE -ne 0) {
    Stop-Job $httpJob | Out-Null ; Remove-Job $httpJob | Out-Null
    Die "curl inside container failed. Ensure curl is available in the container image."
}

# Verify the download completed fully inside the container
$innerSize = docker exec $LOCAL_CONTAINER bash -c "stat -c%s $LOCAL_CONTAINER_TMP 2>/dev/null || echo 0"
if ([long]$innerSize.Trim() -lt 1MB) {
    Stop-Job $httpJob | Out-Null ; Remove-Job $httpJob | Out-Null
    Die "Archive inside container is too small ($innerSize bytes). Download may have been truncated."
}
OK "Archive downloaded into container ($([math]::Round([long]$innerSize.Trim() / 1MB, 1)) MB)"

Stop-Job $httpJob | Out-Null
Remove-Job $httpJob | Out-Null
OK "Temporary HTTP server stopped"

# ---------------------------------------------------------------------------
# Step 5 — Extract archive into the images volume
# ---------------------------------------------------------------------------
Step "5/6  Extracting images into container volume"

Write-Host "Extracting into ${CONTAINER_IMAGES} ..." -ForegroundColor Yellow
docker exec $LOCAL_CONTAINER tar -xzf $LOCAL_CONTAINER_TMP -C $CONTAINER_IMAGES
if ($LASTEXITCODE -ne 0) {
    Die "tar extraction failed inside local container."
}
OK "Extraction complete"

# Fix ownership so MediaWiki (www-data) can read and write files
docker exec $LOCAL_CONTAINER chown -R www-data:www-data $CONTAINER_IMAGES
OK "Ownership set to www-data:www-data"

# Delete stale thumbnails — MediaWiki regenerates them on first page view
docker exec $LOCAL_CONTAINER bash -c "find ${CONTAINER_IMAGES}/thumb -mindepth 1 -delete 2>/dev/null; echo done" | Out-Null
OK "Stale thumbnails cleared (will regenerate on demand)"

# Clean up the archive from inside the container
docker exec $LOCAL_CONTAINER rm -f $LOCAL_CONTAINER_TMP
OK "Cleaned up archive from local container"

# ---------------------------------------------------------------------------
# Step 6 — Verify
# ---------------------------------------------------------------------------
Step "6/6  Verification"

$localCount = docker exec $LOCAL_CONTAINER bash -c `
    "find $CONTAINER_IMAGES -type f -not -path '*/thumb/*' -not -name '.htaccess' -not -name 'README' | wc -l"
OK "Local image files after restore: $($localCount.Trim())"

if ([int]$localCount.Trim() -lt [int]$prodCount.Trim()) {
    Write-Host "[WARN] Local count ($($localCount.Trim())) is less than production count ($($prodCount.Trim())). Some files may be missing." -ForegroundColor Yellow
} else {
    OK "Image counts match or exceed production ($($prodCount.Trim()) production / $($localCount.Trim()) local)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Pull images from production complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Archive saved  : $ARCHIVE_LOCAL"
Write-Host "  Production imgs: $($prodCount.Trim())"
Write-Host "  Local imgs now : $($localCount.Trim())"
Write-Host ""
Write-Host "Verify images at http://localhost:8080/wiki/Special:ListFiles" -ForegroundColor Yellow
Write-Host ""
Write-Host "Note: Thumbnails will regenerate automatically on first page view."
