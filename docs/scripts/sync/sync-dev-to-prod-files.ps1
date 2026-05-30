#Requires -Version 5.1
<#
.SYNOPSIS
    Promote the DEV images/uploads to the PRODUCTION server.

.DESCRIPTION
    1. Creates compressed tar.gz archive of /var/www/html/images from DEV container
    2. Transfers archive to Windows machine via SCP
    3. Uploads archive to PROD server
    4. Extracts archive directly to PROD Docker volume (/var/lib/docker/volumes/wikibase_images/_data)
    5. Restarts PROD wikibase container to reflect changes

.NOTES
    SSH key setup (one-time, as Administrator):
        Set-Service -Name ssh-agent -StartupType Automatic
        Start-Service ssh-agent
        ssh-add C:\Users\<user>\.ssh\id_rsa

    WARNING: This operation overwrites the PRODUCTION images/uploads. Confirm with the
    team before running this script.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Safety confirmation
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "WARNING: This will overwrite PRODUCTION images/uploads with DEV data." -ForegroundColor Red
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
$DEV_HOST       = "178.104.156.88"
$DEV_USER       = "root"
$DEV_CONTAINER  = "wikibase"

$PROD_HOST      = "178.105.222.174"
$PROD_USER      = "root"
$PROD_CONTAINER = "wikibase"

$SSH_KEY        = "C:\Users\$env:USERNAME\.ssh\id_rsa"
$BACKUP_DIR     = "C:\Wikibase\backups"
$TIMESTAMP      = Get-Date -Format "yyyyMMdd_HHmmss"
$ARCHIVE_NAME   = "dev_to_prod_images_$TIMESTAMP.tar.gz"

$IMAGES_PATH         = "/var/www/html/images"
$CONTAINER_TEMP      = "/tmp/$ARCHIVE_NAME"
$DEV_HOST_TEMP       = "/tmp/$ARCHIVE_NAME"
$LOCAL_FILE          = Join-Path $BACKUP_DIR $ARCHIVE_NAME
$PROD_HOST_TEMP      = "/tmp/$ARCHIVE_NAME"

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

function Warn([string]$msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Die([string]$msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

function BytesToMB([long]$bytes) {
    return [math]::Round($bytes / 1MB, 2)
}

# ---------------------------------------------------------------------------
# Main Steps
# ---------------------------------------------------------------------------

Step "1. Creating tar.gz archive of DEV images (excluding thumbnails)"
$cmd = "docker exec $DEV_CONTAINER tar --exclude=thumb -czf /tmp/$ARCHIVE_NAME /var/www/html/images"
$sshCmd = "ssh -i $SSH_KEY $DEV_USER@$DEV_HOST '$cmd'"
$null = Invoke-Expression $sshCmd 2>&1
OK "Archive created on DEV"

Step "2. Copying archive from DEV to Windows machine"
scp -i $SSH_KEY "$DEV_USER@$DEV_HOST`:/tmp/$ARCHIVE_NAME" "$LOCAL_FILE"
OK "Archive copied to: $LOCAL_FILE"

# Verify archive size
$fileInfo = Get-Item $LOCAL_FILE -ErrorAction SilentlyContinue
if (-not $fileInfo) {
    Die "Archive file not found: $LOCAL_FILE"
}
$fileSizeMB = BytesToMB $fileInfo.Length
if ($fileInfo.Length -lt 1MB) {
    Die "Archive too small ($fileSizeMB MB); expected > 1 MB"
}
OK "Archive size verified: $fileSizeMB MB"

Step "3. Uploading archive to PROD host"
scp -i $SSH_KEY "$LOCAL_FILE" "$PROD_USER@$PROD_HOST`:/tmp/$ARCHIVE_NAME"
OK "Archive uploaded to PROD"

Step "4. Extracting images to PROD Docker volume"
$cmd = @"
mkdir -p $PROD_VOLUME
cd /tmp
tar -xzf $ARCHIVE_NAME --strip-components=4 -C $PROD_VOLUME
chown -R www-data:www-data $PROD_VOLUME
"@
$sshCmd = "ssh -i $SSH_KEY $PROD_USER@$PROD_HOST '$cmd'"
$null = Invoke-Expression $sshCmd 2>&1
OK "Images extracted to PROD volume"

Step "5. Restarting PROD wikibase container"
$cmd = "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase"
$sshCmd = "ssh -i $SSH_KEY $PROD_USER@$PROD_HOST '$cmd'"
$null = Invoke-Expression $sshCmd 2>&1
OK "PROD wikibase container restarted"

Step "6. Cleanup: removing temporary files"
# DEV cleanup
$cmd = "rm -f /tmp/$ARCHIVE_NAME"
$sshCmd = "ssh -i $SSH_KEY $DEV_USER@$DEV_HOST '$cmd'"
$null = Invoke-Expression $sshCmd 2>&1
OK "Cleaned up DEV temporary files"

# PROD cleanup
$cmd = "rm -f /tmp/$ARCHIVE_NAME"
$sshCmd = "ssh -i $SSH_KEY $PROD_USER@$PROD_HOST '$cmd'"
$null = Invoke-Expression $sshCmd 2>&1
OK "Cleaned up PROD temporary files"

Write-Host ""
Write-Host "=== FILE SYNC COMPLETE ===" -ForegroundColor Green
Write-Host "DEV images successfully synced to PROD" -ForegroundColor Green
Write-Host "Archive backup: $LOCAL_FILE" -ForegroundColor Gray
Write-Host ""
