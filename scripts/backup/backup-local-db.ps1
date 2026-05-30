#Requires -Version 5.1
<#
.SYNOPSIS
    Dump the local Wikibase MariaDB database to a timestamped SQL file in
    C:\Wikibase\backups\.

.DESCRIPTION
    Uses mysqldump --result-file= inside the container so that the dump is
    written as UTF-8 directly to the container filesystem, then copied out
    with docker cp.  This avoids the UTF-16LE corruption that occurs when
    PowerShell 5.1 > redirection is used.

    See backups/mariadb-backup-powershell-encoding-notes.md for full details.

.EXAMPLE
    .\backup-local-db.ps1

    Produces: C:\Wikibase\backups\mw_db_20260530_143000.sql

.NOTES
    Prerequisites: Docker Desktop running, wikibase-mariadb container up.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$LOCAL_DB_USER   = "wikibase"
$LOCAL_DB_PASS   = "wikibase"
$LOCAL_DB_NAME   = "my_wiki"
$LOCAL_CONTAINER = "wikibase-mariadb"
$BACKUP_DIR      = "C:\Wikibase\backups"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
$TS             = Get-Date -Format "yyyyMMdd_HHmmss"
$CONTAINER_PATH = "/tmp/mw_db_$TS.sql"
$HOST_PATH      = "$BACKUP_DIR\mw_db_$TS.sql"

Write-Host "==> Dumping $LOCAL_DB_NAME from container $LOCAL_CONTAINER ..."

$dumpArgs = @(
    "exec", $LOCAL_CONTAINER, "mysqldump",
    "-u", $LOCAL_DB_USER, "-p$LOCAL_DB_PASS",
    "--host=127.0.0.1",
    "--default-character-set=utf8mb4",
    "--single-transaction",
    "--quick",
    "--max_allowed_packet=512M",
    "--add-drop-table",
    "--result-file=$CONTAINER_PATH",
    $LOCAL_DB_NAME
)
& docker @dumpArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "mysqldump failed (exit $LASTEXITCODE). Aborting."
    exit 1
}

Write-Host "==> Copying dump out of container ..."
docker cp "${LOCAL_CONTAINER}:${CONTAINER_PATH}" $HOST_PATH

if ($LASTEXITCODE -ne 0) {
    Write-Error "docker cp failed (exit $LASTEXITCODE). Aborting."
    exit 1
}

Write-Host "==> Cleaning up temp file inside container ..."
docker exec $LOCAL_CONTAINER rm -f $CONTAINER_PATH

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
$size      = (Get-Item $HOST_PATH).Length
$sizeMB    = [math]::Round($size / 1MB, 1)
$firstLine = Get-Content $HOST_PATH -TotalCount 1

Write-Host ""
Write-Host "Done: $HOST_PATH"
Write-Host "Size: $sizeMB MB"
Write-Host "First line: $firstLine"

if (-not $firstLine.StartsWith("/*M!")) {
    Write-Warning "Unexpected first line -- file may be corrupt. Expected it to start with '/*M!'."
} else {
    Write-Host "Encoding check passed."
}
