#Requires -Version 5.1
<#
.SYNOPSIS
    Full WDQS/Blazegraph re-index on the PRODUCTION server.

.DESCRIPTION
    Use when the SPARQL index is stale or out of sync with the Wikibase database.

    Steps performed:
      1. Stop wdqs-updater (incremental updater)
      2. Stop wdqs (Blazegraph)
      3. Clear the Blazegraph journal file from the wdqs_data volume
      4. Start wdqs with a fresh empty journal
      5. Wait for wdqs to become healthy
      6. Start wdqs-updater -- it will load all items from scratch

    WDQS will be unavailable during the re-index. The updater re-ingests every
    item from the Wikibase API; expect 10-30+ minutes depending on item count.

.EXAMPLE
    .\scripts\wdqs-reindex-prod.ps1

.NOTES
    SSH key: C:\Users\<user>\.ssh\id_rsa  (or id_wikibase_sync if available)
    Make sure the SSH agent is running or that id_wikibase_sync is passphrase-free.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$PROD_HOST   = "178.105.222.174"
$PROD_USER   = "root"
$SSH_KEY     = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"
if (-not (Test-Path $SSH_KEY)) {
    $SSH_KEY = "C:\Users\$env:USERNAME\.ssh\id_rsa"
}
$COMPOSE_CMD = "docker compose -f docker-compose.yml -f docker-compose.prod.yml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Step([string]$msg) { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Die([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

function Invoke-SSH([string]$cmd) {
    ssh -i $SSH_KEY -o StrictHostKeyChecking=no "${PROD_USER}@${PROD_HOST}" $cmd
    if ($LASTEXITCODE -ne 0) { Die "SSH command failed (exit $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
# Safety confirmation
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== WDQS Full Re-index on PRODUCTION ===" -ForegroundColor Yellow
Write-Host "Server : prod-climatekg.semanticclimate.org ($PROD_HOST)" -ForegroundColor Yellow
Write-Host ""
Write-Host "This will:"
Write-Host "  1. Stop wdqs-updater and wdqs containers"
Write-Host "  2. Delete the Blazegraph journal (all SPARQL index data)"
Write-Host "  3. Restart wdqs with an empty journal"
Write-Host "  4. Restart wdqs-updater to re-load ALL items from scratch"
Write-Host ""
Write-Host "WDQS/SPARQL will be UNAVAILABLE for 10-30+ minutes." -ForegroundColor Red
Write-Host ""
$confirm = Read-Host "Type REINDEX to confirm"
if ($confirm -ne "REINDEX") {
    Write-Host "Aborted -- no changes made." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
Step "Pre-flight"

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { Die "ssh not found on PATH." }
if (-not (Test-Path $SSH_KEY)) { Die "SSH key not found at $SSH_KEY." }

Write-Host "Testing SSH to PROD ($PROD_HOST)..." -ForegroundColor Yellow
$tcpTest = Test-NetConnection -ComputerName $PROD_HOST -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $tcpTest) { Die "Cannot reach PROD port 22." }
OK "SSH port reachable"

# ---------------------------------------------------------------------------
# Step 1 -- Stop wdqs-updater
# ---------------------------------------------------------------------------
Step "1/5  Stopping wdqs-updater"
Invoke-SSH "cd /opt/wikibase && $COMPOSE_CMD stop wdqs-updater"
OK "wdqs-updater stopped"

# ---------------------------------------------------------------------------
# Step 2 -- Stop wdqs (Blazegraph)
# ---------------------------------------------------------------------------
Step "2/5  Stopping wdqs (Blazegraph)"
Invoke-SSH "cd /opt/wikibase && $COMPOSE_CMD stop wdqs"
OK "wdqs stopped"

# ---------------------------------------------------------------------------
# Step 3 -- Clear Blazegraph journal from volume
# ---------------------------------------------------------------------------
Step "3/5  Clearing Blazegraph journal"

# Discover the Docker volume name (typically wikibase_wdqs_data) dynamically
# to avoid hardcoding the compose project prefix.
$clearCmd = "WDQS_VOL=`$(docker volume ls -q --filter name=wdqs_data | head -1) && " +
            "echo Volume: `$WDQS_VOL && " +
            "docker run --rm -v `${WDQS_VOL}:/wdqs/data alpine " +
            "sh -c 'rm -f /wdqs/data/*.jnl && echo Journal cleared. Remaining: && ls /wdqs/data'"

Invoke-SSH $clearCmd
OK "Blazegraph journal removed"

# ---------------------------------------------------------------------------
# Step 4 -- Start wdqs with fresh journal
# ---------------------------------------------------------------------------
Step "4/5  Starting wdqs with fresh journal"
Invoke-SSH "cd /opt/wikibase && $COMPOSE_CMD up -d wdqs"

Write-Host "Waiting for wdqs to become healthy (up to 5 minutes)..."
$waitCmd = "i=0; while [ `$i -lt 30 ]; do " +
           "docker exec wikibase-wdqs curl --silent --fail localhost:9999/bigdata/namespace/wdq/sparql 2>/dev/null " +
           "&& echo WDQS is ready && break; " +
           "i=`$((i+1)); echo Waiting `${i}/30...; sleep 10; done"
Invoke-SSH $waitCmd
OK "wdqs is healthy"

# ---------------------------------------------------------------------------
# Step 5 -- Start wdqs-updater (full re-index from scratch)
# ---------------------------------------------------------------------------
Step "5/5  Starting wdqs-updater (full re-index begins)"
Invoke-SSH "cd /opt/wikibase && $COMPOSE_CMD up -d wdqs-updater"
OK "wdqs-updater started -- re-indexing all items from scratch"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Re-index started ===" -ForegroundColor Green
Write-Host ""
Write-Host "Monitor progress (Ctrl+C to stop watching -- does NOT stop the updater):"
Write-Host "  ssh -i $SSH_KEY root@$PROD_HOST 'docker logs -f wikibase-wdqs-updater'" -ForegroundColor Cyan
Write-Host ""
Write-Host "Verify SPARQL is returning results once complete:"
Write-Host "  https://prod-climatekg.semanticclimate.org/query/proxy/sparql" -ForegroundColor Cyan
Write-Host ""
