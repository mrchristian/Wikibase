#Requires -Version 5.1
<#
.SYNOPSIS
    Experimental import workflow with state tracking for LOCAL database.

.DESCRIPTION
    Manages a safe workflow for testing experimental data imports in LOCAL
    without affecting your clean DEV-synced database.
    
    Workflow states:
    - CLEAN: Pure DEV data (or approved experiments) - ready for new experiments or DEV sync
    - EXPERIMENTAL: Has unapproved experimental changes - review and approve/rollback

.PARAMETER Action
    start    - Create snapshot and begin experiment
    status   - Check current workflow state
    approve  - Approve experiment (becomes new clean base)
    rollback - Discard experiment (restore clean base)
    sync     - Pull from DEV (only if no active experiment)

.EXAMPLE
    .\scripts\experimental-import-workflow.ps1 start
    .\scripts\import\my-import.ps1
    .\scripts\experimental-import-workflow.ps1 approve

.EXAMPLE
    .\scripts\experimental-import-workflow.ps1 start
    .\scripts\import\my-import.ps1
    # Looks wrong, discard it
    .\scripts\experimental-import-workflow.ps1 rollback

.NOTES
    State is tracked in C:\Wikibase\backups\.workflow_state.json
    Snapshots are stored in C:\Wikibase\backups\
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('start', 'status', 'approve', 'rollback', 'sync')]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$BACKUP_DIR = "C:\Wikibase\backups"
$SNAPSHOT_FILE = Join-Path $BACKUP_DIR "experimental_snapshot.sql"
$STATE_FILE = Join-Path $BACKUP_DIR ".workflow_state.json"
$LOCAL_DB_USER = "wikibase"
$LOCAL_DB_PASS = "wikibase"
$LOCAL_DB_NAME = "my_wiki"
$LOCAL_CONTAINER = "wikibase-mariadb"

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------
function Get-WorkflowState {
    if (Test-Path $STATE_FILE) {
        return Get-Content $STATE_FILE | ConvertFrom-Json
    }
    return @{ 
        state = "CLEAN"
        timestamp = $null
        lastSync = $null
    }
}

function Set-WorkflowState($state, $lastSync = $null) {
    $currentState = Get-WorkflowState
    $stateObj = @{
        state = $state
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        lastSync = if ($lastSync) { $lastSync } else { $currentState.lastSync }
    }
    $stateObj | ConvertTo-Json | Set-Content $STATE_FILE
}

function Show-Status {
    $state = Get-WorkflowState
    Write-Host ""
    Write-Host "=== LOCAL Workflow Status ===" -ForegroundColor Cyan
    Write-Host "Current State: " -NoNewline
    
    switch ($state.state) {
        "CLEAN" { 
            Write-Host "CLEAN" -ForegroundColor Green -NoNewline
            Write-Host " (ready for experiments or DEV sync)"
        }
        "EXPERIMENTAL" { 
            Write-Host "EXPERIMENTAL" -ForegroundColor Yellow -NoNewline
            Write-Host " (review and approve/rollback before DEV sync)"
        }
        default { 
            Write-Host $state.state -ForegroundColor White 
        }
    }
    
    if ($state.lastSync) {
        Write-Host "Last DEV Sync: " -NoNewline
        Write-Host $state.lastSync -ForegroundColor Gray
    } else {
        Write-Host "Last DEV Sync: " -NoNewline
        Write-Host "Never" -ForegroundColor Gray
    }
    
    if ($state.timestamp) {
        Write-Host "State Changed: " -NoNewline
        Write-Host $state.timestamp -ForegroundColor Gray
    }
    
    if (Test-Path $SNAPSHOT_FILE) {
        $snapshotSize = (Get-Item $SNAPSHOT_FILE).Length
        Write-Host "Snapshot Size: " -NoNewline
        Write-Host "$([math]::Round($snapshotSize/1MB, 1)) MB" -ForegroundColor Gray
    }
    
    Write-Host ""
}

function Die([string]$msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

function OK([string]$msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if (-not (Test-Path $BACKUP_DIR)) {
    New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
}

$null = Get-Command docker -ErrorAction SilentlyContinue
if (-not $?) { 
    Die "docker command not found. Ensure Docker Desktop is running." 
}

# ---------------------------------------------------------------------------
# Action Handlers
# ---------------------------------------------------------------------------
switch ($Action) {
    'status' {
        Show-Status
    }
    
    'start' {
        $state = Get-WorkflowState
        
        if ($state.state -eq "EXPERIMENTAL") {
            Write-Host ""
            Write-Host "[ERROR] Already in EXPERIMENTAL state" -ForegroundColor Red
            Write-Host "Run 'approve' or 'rollback' first" -ForegroundColor Yellow
            Write-Host ""
            Show-Status
            exit 1
        }
        
        Write-Host ""
        Write-Host "=== Starting Experiment ===" -ForegroundColor Cyan
        Write-Host "Creating snapshot of current CLEAN state..." -ForegroundColor Yellow
        
        # Create the snapshot
        docker exec $LOCAL_CONTAINER mysqldump `
            -u $LOCAL_DB_USER -p$LOCAL_DB_PASS `
            --default-character-set=utf8mb4 `
            --single-transaction `
            --quick `
            --max_allowed_packet=512M `
            $LOCAL_DB_NAME > $SNAPSHOT_FILE
        
        if ($LASTEXITCODE -ne 0) {
            Die "Failed to create database snapshot"
        }
        
        $snapshotSize = (Get-Item $SNAPSHOT_FILE).Length
        if ($snapshotSize -lt 1MB) {
            Remove-Item $SNAPSHOT_FILE -ErrorAction SilentlyContinue
            Die "Snapshot is too small ($snapshotSize bytes). Database dump may have failed."
        }
        
        Set-WorkflowState "EXPERIMENTAL"
        
        OK "Snapshot created ($([math]::Round($snapshotSize/1MB, 1)) MB)"
        Write-Host ""
        Write-Host "You can now run your experimental imports." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Run your import scripts" -ForegroundColor White
        Write-Host "  2. Review at http://localhost:8080" -ForegroundColor White
        Write-Host "  3. Run: " -NoNewline -ForegroundColor White
        Write-Host ".\scripts\experimental-import-workflow.ps1 approve" -ForegroundColor Green
        Write-Host "     OR: " -NoNewline -ForegroundColor White
        Write-Host ".\scripts\experimental-import-workflow.ps1 rollback" -ForegroundColor Yellow
        Write-Host ""
    }
    
    'approve' {
        $state = Get-WorkflowState
        
        if ($state.state -ne "EXPERIMENTAL") {
            Write-Host ""
            Write-Host "[ERROR] Not in EXPERIMENTAL state (current: $($state.state))" -ForegroundColor Red
            Write-Host "Nothing to approve." -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }
        
        if (-not (Test-Path $SNAPSHOT_FILE)) {
            Die "Snapshot file not found at $SNAPSHOT_FILE"
        }
        
        Write-Host ""
        Write-Host "=== Approving Experiment ===" -ForegroundColor Cyan
        
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $approvedFile = Join-Path $BACKUP_DIR "approved_experiment_$timestamp.sql"
        Move-Item $SNAPSHOT_FILE $approvedFile
        
        Set-WorkflowState "CLEAN"
        
        OK "Experiment approved"
        Write-Host "Backup archived: " -NoNewline
        Write-Host $approvedFile -ForegroundColor Gray
        Write-Host ""
        Write-Host "LOCAL is now CLEAN (experimental changes are now the base)" -ForegroundColor Green
        Write-Host ""
    }
    
    'rollback' {
        $state = Get-WorkflowState
        
        if ($state.state -ne "EXPERIMENTAL") {
            Write-Host ""
            Write-Host "[ERROR] Not in EXPERIMENTAL state (current: $($state.state))" -ForegroundColor Red
            Write-Host "Nothing to rollback." -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }
        
        if (-not (Test-Path $SNAPSHOT_FILE)) {
            Die "Snapshot file not found at $SNAPSHOT_FILE. Cannot rollback."
        }
        
        Write-Host ""
        Write-Host "=== Rolling Back Experiment ===" -ForegroundColor Yellow
        Write-Host "Restoring to clean base state..." -ForegroundColor Yellow
        
        # Import the snapshot
        Get-Content $SNAPSHOT_FILE | docker exec -i $LOCAL_CONTAINER mysql `
            -u $LOCAL_DB_USER -p$LOCAL_DB_PASS `
            --default-character-set=utf8mb4 `
            $LOCAL_DB_NAME
        
        if ($LASTEXITCODE -ne 0) {
            Die "Failed to restore database snapshot"
        }
        
        # Restart wikibase to clear caches
        Write-Host "Restarting wikibase container..." -ForegroundColor Yellow
        docker compose --project-directory "C:\Wikibase" restart wikibase | Out-Null
        
        Remove-Item $SNAPSHOT_FILE
        Set-WorkflowState "CLEAN"
        
        OK "Rolled back to clean base"
        Write-Host "All experimental changes discarded" -ForegroundColor Gray
        Write-Host ""
    }
    
    'sync' {
        $state = Get-WorkflowState
        
        if ($state.state -eq "EXPERIMENTAL") {
            Write-Host ""
            Write-Host "[ERROR] Cannot sync from DEV while in EXPERIMENTAL state" -ForegroundColor Red
            Write-Host "Run 'approve' or 'rollback' first to resolve the experiment" -ForegroundColor Yellow
            Write-Host ""
            Show-Status
            exit 1
        }
        
        Write-Host ""
        Write-Host "=== Pulling from DEV ===" -ForegroundColor Cyan
        Write-Host "This will overwrite your LOCAL database with DEV content" -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Type 'SYNC' to confirm"
        
        if ($confirm -ne "SYNC") {
            Write-Host "Cancelled" -ForegroundColor Yellow
            exit 0
        }
        
        # Run the pull-from-dev script
        Write-Host ""
        & "C:\Wikibase\scripts\sync\pull-from-dev.ps1"
        
        if ($LASTEXITCODE -ne 0) {
            Die "pull-from-dev.ps1 failed"
        }
        
        Set-WorkflowState "CLEAN" -lastSync (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        
        Write-Host ""
        OK "LOCAL synced with DEV"
        Show-Status
    }
}
