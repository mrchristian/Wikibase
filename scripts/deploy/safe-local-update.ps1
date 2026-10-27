[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string[]]$ComposeFiles = @('docker-compose.yml', 'docker-compose.override.yml'),
    [string]$HealthUrl = 'http://localhost:8080/wiki/Main_Page',
    [string]$DbName = 'my_wiki',
    [string]$DbUser = 'wikibase',
    [string]$DbPassword = 'wikibase',
    [switch]$SkipGitPull,
    [switch]$SkipDbBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

function Write-Step {
    param([string]$Message)
    Write-Host "" 
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-HealthCheck {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 15,
        [int]$MaxMinutes = 5
    )

    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                return $true
            }
            $lastError = "HTTP $($response.StatusCode)"
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 10
    }

    throw "Health check failed for $Url after $MaxMinutes minutes. Last error: $lastError"
}

function Invoke-Rollback {
    param(
        [string]$PreviousCommit,
        [string]$BackupPath
    )

    Write-Step 'Rolling back to the last known-good state'

    if ($PSCmdlet.ShouldProcess("git reset --hard $PreviousCommit", 'Restore the repo to the previous commit')) {
        git reset --hard $PreviousCommit
    }

    if ((-not [string]::IsNullOrWhiteSpace($BackupPath)) -and (Test-Path $BackupPath)) {
        if ($PSCmdlet.ShouldProcess("restore database from $BackupPath", 'Restore the database backup')) {
            $rollbackComposeArgs = @('compose')
            foreach ($file in $ComposeFiles) {
                $rollbackComposeArgs += @('-f', $file)
            }
            $rollbackComposeArgs += @('up', '-d', 'mariadb')
            & docker @rollbackComposeArgs
            if ($LASTEXITCODE -ne 0) {
                throw 'Rollback database container restart failed.'
            }

            Get-Content -Path $BackupPath -Raw | docker exec -i wikibase-mariadb sh -c "mysql -u'$DbUser' -p'$DbPassword' '$DbName'"
        }
    }

    if ($PSCmdlet.ShouldProcess('docker compose up -d --build', 'Restart the stack after rollback')) {
        $composeArgs = @('compose')
        foreach ($file in $ComposeFiles) {
            $composeArgs += @('-f', $file)
        }
        $composeArgs += @('up', '-d', '--build')
        & docker @composeArgs
        if ($LASTEXITCODE -ne 0) {
            throw 'Rollback restart failed.'
        }
    }

    Write-Host "Rollback complete. Verify the site again at $HealthUrl" -ForegroundColor Yellow
    exit 1
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupDir = Join-Path $repoRoot ("backups\safe-update-$timestamp")
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$previousCommit = (git rev-parse HEAD).Trim()
$previousCommitFile = Join-Path $backupDir 'last-good-commit.txt'
Set-Content -Path $previousCommitFile -Value $previousCommit

Write-Step "Preparing a safe deployment"
Write-Host "Repo root: $repoRoot"
Write-Host "Current HEAD: $previousCommit"
Write-Host "Health URL: $HealthUrl"

$status = git status --porcelain
if ($status) {
    throw 'The repo has uncommitted changes. Commit or stash them before running a safe update.'
}

if (-not $SkipGitPull) {
    Write-Step 'Fetching upstream changes'
    if ($PSCmdlet.ShouldProcess('git fetch --all --prune && git pull --ff-only', 'Update the repo to the latest commit')) {
        git fetch --all --prune
        git pull --ff-only
    }
}

$dbDumpPath = $null
if (-not $SkipDbBackup) {
    Write-Step 'Creating a database backup before redeploy'
    if (docker ps --format '{{.Names}}' | Select-String -Pattern '^wikibase-mariadb$') {
        $dbDumpPath = Join-Path $backupDir 'wikibase-predeploy.sql'
        if ($PSCmdlet.ShouldProcess("mysqldump to $dbDumpPath", 'Backup the live database')) {
            docker exec wikibase-mariadb sh -c "mysqldump -u'$DbUser' -p'$DbPassword' --databases '$DbName'" > $dbDumpPath
            if ($LASTEXITCODE -ne 0) {
                throw "Database backup failed. Check the MariaDB container and credentials."
            }
        }
    }
    else {
        Write-Host 'No mariadb container is running. Skipping database backup.' -ForegroundColor Yellow
    }
}

$composeArgs = @('compose')
foreach ($file in $ComposeFiles) {
    $composeArgs += @('-f', $file)
}
$pullArgs = @('compose')
foreach ($file in $ComposeFiles) {
    $pullArgs += @('-f', $file)
}
$pullArgs += @('pull')

Write-Step 'Pulling the newest Docker image tags for the Wikibase suite'
if ($PSCmdlet.ShouldProcess("docker $($pullArgs -join ' ')", 'Fetch the latest application images before restarting the stack')) {
    & docker @pullArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'docker compose pull failed while updating the application suite.'
    }
}

$composeArgs += @('up', '-d', '--build')

Write-Step 'Starting the rebuild'
if ($PSCmdlet.ShouldProcess("docker $($composeArgs -join ' ')", 'Redeploy the stack with the latest Docker config')) {
    & docker @composeArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'docker compose failed during the update.'
    }
}

try {
    Write-Step 'Waiting for the wiki to become healthy again'
    Invoke-HealthCheck -Url $HealthUrl -TimeoutSeconds 15 -MaxMinutes 5
    Write-Host 'Deployment health check passed.' -ForegroundColor Green
    Write-Host "Safe update completed successfully. Rollback point: $previousCommit" -ForegroundColor Green
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Invoke-Rollback -PreviousCommit $previousCommit -BackupPath $dbDumpPath
}
