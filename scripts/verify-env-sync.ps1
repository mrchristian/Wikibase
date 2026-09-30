#Requires -Version 5.1
<#
.SYNOPSIS
    Verify whether ClimateKG environments are in sync.

.DESCRIPTION
    Checks LOCAL, DEV, TEST, and PROD against DEV as the database source of truth.
    By default it verifies:
      1. Wiki responds
      2. Query UI responds
      3. SPARQL responds
      4. MAX(rc_timestamp) from recentchanges
      5. Chapter item count in SPARQL (P1=Q6)
      6. Whether Q128 is indexed in SPARQL

    LOCAL is included by default. If LOCAL is being used for experimental work,
    use -ExcludeLocal to skip it.

.PARAMETER ExcludeLocal
    Skip LOCAL in the checks.

.EXAMPLE
    .\scripts\verify-env-sync.ps1

.EXAMPLE
    .\scripts\verify-env-sync.ps1 -ExcludeLocal
#>

param(
    [switch]$ExcludeLocal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SSH_KEY = "C:\Users\$env:USERNAME\.ssh\id_wikibase_sync"
if (-not (Test-Path $SSH_KEY)) {
    $SSH_KEY = "C:\Users\$env:USERNAME\.ssh\id_rsa"
}

$envFile = "C:\Wikibase\.env"
$DEV_DB_PASS = $null
$TEST_DB_PASS = $null
$PROD_DB_PASS = $null
$DEV_NEW_DB_PASS = $null
$TEST_NEW_DB_PASS = $null
$PROD_NEW_DB_PASS = $null
$IMPORT_DB_PASS = $null
$WEB_BASIC_AUTH_USER = $null
$WEB_BASIC_AUTH_PASS = $null

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^DEV_DB_PASS\s*=") { $DEV_DB_PASS = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^TEST_DB_PASS\s*=") { $TEST_DB_PASS = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^PROD_DB_PASS\s*=") { $PROD_DB_PASS = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^DEV_NEW_DB_PASS\s*=") { $DEV_NEW_DB_PASS = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^TEST_NEW_DB_PASS\s*=") { $TEST_NEW_DB_PASS = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^PROD_NEW_DB_PASS\s*=") { $PROD_NEW_DB_PASS = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^IMPORT_DB_PASS\s*=") { $IMPORT_DB_PASS = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^WEB_BASIC_AUTH_USER\s*=") { $WEB_BASIC_AUTH_USER = ($_ -split "=", 2)[1].Trim() }
        if ($_ -match "^WEB_BASIC_AUTH_PASS\s*=") { $WEB_BASIC_AUTH_PASS = ($_ -split "=", 2)[1].Trim() }
    }
}

# DEV/TEST/PROD sit behind a host-level Nginx Basic Auth wall (see
# docs/temporary-web-password-protection.md). LOCAL has none.
$WebBasicAuth = $null
if ($WEB_BASIC_AUTH_USER -and $WEB_BASIC_AUTH_PASS) {
    $WebBasicAuth = "${WEB_BASIC_AUTH_USER}:${WEB_BASIC_AUTH_PASS}"
}

$environments = @(
    [pscustomobject]@{
        Name = "LOCAL"
        WikiUrl = "http://localhost:8080/wiki/Main_Page"
        QueryUrl = "http://localhost:8081"
        SparqlUrl = "http://localhost:9999/bigdata/namespace/wdq/sparql"
        DbMode = "local"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = "wikibase"
        EntityBase = "http://localhost:8080/entity/"
        PropDirectBase = "http://localhost:8080/prop/direct/"
        BasicAuth = $null
        UseSudo = $false
    }
    [pscustomobject]@{
        Name = "DEV"
        WikiUrl = "https://dev-climatekg.semanticclimate.org/wiki/Main_Page"
        QueryUrl = "https://dev-climatekg.semanticclimate.org/query/"
        SparqlUrl = "https://dev-climatekg.semanticclimate.org/query/proxy/sparql"
        DbMode = "remote"
        Host = "178.104.156.88"
        User = "root"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = $DEV_DB_PASS
        EntityBase = "https://dev-climatekg.semanticclimate.org/entity/"
        PropDirectBase = "https://dev-climatekg.semanticclimate.org/prop/direct/"
        BasicAuth = $WebBasicAuth
        UseSudo = $false
    }
    [pscustomobject]@{
        Name = "TEST"
        WikiUrl = "https://test-climatekg.semanticclimate.org/wiki/Main_Page"
        QueryUrl = "https://test-climatekg.semanticclimate.org/query/"
        SparqlUrl = "https://test-climatekg.semanticclimate.org/query/proxy/sparql"
        DbMode = "remote"
        Host = "46.224.66.24"
        User = "root"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = $TEST_DB_PASS
        EntityBase = "https://test-climatekg.semanticclimate.org/entity/"
        PropDirectBase = "https://test-climatekg.semanticclimate.org/prop/direct/"
        BasicAuth = $WebBasicAuth
        UseSudo = $false
    }
    [pscustomobject]@{
        Name = "PROD"
        WikiUrl = "https://prod-climatekg.semanticclimate.org/wiki/Main_Page"
        QueryUrl = "https://prod-climatekg.semanticclimate.org/query/"
        SparqlUrl = "https://prod-climatekg.semanticclimate.org/query/proxy/sparql"
        DbMode = "remote"
        Host = "178.105.222.174"
        User = "root"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = $PROD_DB_PASS
        EntityBase = "https://prod-climatekg.semanticclimate.org/entity/"
        PropDirectBase = "https://prod-climatekg.semanticclimate.org/prop/direct/"
        BasicAuth = $WebBasicAuth
        UseSudo = $false
    }
    # --- New TIB machines (staged validation - old envs above are the still-canonical ones) ---
    [pscustomobject]@{
        Name = "DEV-NEW"
        WikiUrl = "https://dev-climatekg.tibwiki.io/wiki/Main_Page"
        QueryUrl = "https://dev-climatekg.tibwiki.io/query/"
        SparqlUrl = "https://dev-climatekg.tibwiki.io/query/proxy/sparql"
        DbMode = "remote"
        Host = "climatekg01.develop.service.tib.eu"
        User = "worthingtons"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = $DEV_NEW_DB_PASS
        EntityBase = "https://dev-climatekg.tibwiki.io/entity/"
        PropDirectBase = "https://dev-climatekg.tibwiki.io/prop/direct/"
        BasicAuth = $null
        UseSudo = $true
    }
    [pscustomobject]@{
        Name = "TEST-NEW"
        WikiUrl = "https://test-climatekg.tibwiki.io/wiki/Main_Page"
        QueryUrl = "https://test-climatekg.tibwiki.io/query/"
        SparqlUrl = "https://test-climatekg.tibwiki.io/query/proxy/sparql"
        DbMode = "remote"
        Host = "climatekg11.test.service.tib.eu"
        User = "worthingtons"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = $TEST_NEW_DB_PASS
        EntityBase = "https://test-climatekg.tibwiki.io/entity/"
        PropDirectBase = "https://test-climatekg.tibwiki.io/prop/direct/"
        BasicAuth = $null
        UseSudo = $true
    }
    [pscustomobject]@{
        Name = "PROD-NEW"
        WikiUrl = "https://climatekg.tibwiki.io/wiki/Main_Page"
        QueryUrl = "https://climatekg.tibwiki.io/query/"
        SparqlUrl = "https://climatekg.tibwiki.io/query/proxy/sparql"
        DbMode = "remote"
        Host = "climatekg21.service.tib.eu"
        User = "worthingtons"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = $PROD_NEW_DB_PASS
        EntityBase = "https://climatekg.tibwiki.io/entity/"
        PropDirectBase = "https://climatekg.tibwiki.io/prop/direct/"
        BasicAuth = $null
        UseSudo = $true
    }
    [pscustomobject]@{
        Name = "IMPORT"
        WikiUrl = "https://import-climatekg.tibwiki.io/wiki/Main_Page"
        QueryUrl = "https://import-climatekg.tibwiki.io/query/"
        SparqlUrl = "https://import-climatekg.tibwiki.io/query/proxy/sparql"
        DbMode = "remote"
        Host = "climatekgdi21.service.tib.eu"
        User = "worthingtons"
        DbContainer = "wikibase-mariadb"
        DbUser = "wikibase"
        DbName = "my_wiki"
        DbPass = $IMPORT_DB_PASS
        EntityBase = "https://import-climatekg.tibwiki.io/entity/"
        PropDirectBase = "https://import-climatekg.tibwiki.io/prop/direct/"
        BasicAuth = $null
        UseSudo = $true
    }
)

if ($ExcludeLocal) {
    $environments = $environments | Where-Object { $_.Name -ne "LOCAL" }
}

function Step([string]$msg) { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function OK([string]$msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

function Test-Url200([string]$url, [string]$basicAuth) {
    $curlArgs = @("-s", "-L", "-o", "NUL", "-w", "%{http_code}")
    if ($basicAuth) { $curlArgs += @("-u", $basicAuth) }
    $curlArgs += $url
    $statusCode = curl.exe @curlArgs
    return $LASTEXITCODE -eq 0 -and $statusCode -match '^[23][0-9][0-9]$'
}

function Invoke-SparqlScalar([string]$endpoint, [string]$query, [string]$variableName, [string]$basicAuth) {
    $curlArgs = @("-s", "-L", "-G", "-H", "Accept: application/sparql-results+json")
    if ($basicAuth) { $curlArgs += @("-u", $basicAuth) }
    $curlArgs += @("--data-urlencode", "query=$query", "--data-urlencode", "format=json", $endpoint)
    $json = curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) {
        throw "SPARQL HTTP request failed"
    }
    $response = $json | ConvertFrom-Json
    return $response.results.bindings[0].$variableName.value
}

function Get-LocalDbTimestamp($envConfig) {
    $output = docker exec $envConfig.DbContainer mysql -N -B -u $envConfig.DbUser "-p$($envConfig.DbPass)" $envConfig.DbName -e "SELECT MAX(rc_timestamp) FROM recentchanges;"
    if ($LASTEXITCODE -ne 0) {
        throw "Local DB query failed (exit $LASTEXITCODE)"
    }
    return ($output | Select-Object -Last 1).Trim()
}

function Get-RemoteDbTimestamp($envConfig) {
    if ([string]::IsNullOrEmpty($envConfig.DbPass)) {
        throw "Missing DB password for $($envConfig.Name) in C:\Wikibase\.env"
    }

    $command = "docker exec $($envConfig.DbContainer) mysql -N -B -u $($envConfig.DbUser) -p$($envConfig.DbPass) $($envConfig.DbName) -e 'SELECT MAX(rc_timestamp) FROM recentchanges;'"
    if ($envConfig.UseSudo) {
        $command = "sudo $command"
    }
    $output = ssh -i $SSH_KEY -o StrictHostKeyChecking=no "$($envConfig.User)@$($envConfig.Host)" $command
    if ($LASTEXITCODE -ne 0) {
        throw "Remote DB query failed for $($envConfig.Name) (exit $LASTEXITCODE)"
    }
    return ($output | Select-Object -Last 1).Trim()
}

function Get-DbTimestamp($envConfig) {
    if ($envConfig.DbMode -eq "local") {
        return Get-LocalDbTimestamp $envConfig
    }
    return Get-RemoteDbTimestamp $envConfig
}

function Get-EnvironmentStatus($envConfig) {
    $status = [ordered]@{
        Environment = $envConfig.Name
        Wiki = "FAIL"
        QueryUI = "FAIL"
        SPARQL = "FAIL"
        DbMaxRcTimestamp = "ERROR"
        ChapterCount = "ERROR"
        Q128Triples = "ERROR"
        InSyncWithDev = "CHECK"
        Notes = ""
    }

    $notes = New-Object System.Collections.Generic.List[string]

    if (Test-Url200 $envConfig.WikiUrl $envConfig.BasicAuth) {
        $status.Wiki = "OK"
    } else {
        $notes.Add("wiki down")
    }

    if (Test-Url200 $envConfig.QueryUrl $envConfig.BasicAuth) {
        $status.QueryUI = "OK"
    } else {
        $notes.Add("query ui down")
    }

    try {
        $countQuery = "SELECT (COUNT(*) AS ?c) WHERE { ?item <$($envConfig.PropDirectBase)P1> <$($envConfig.EntityBase)Q6> . }"
        $q128Query = "SELECT (COUNT(*) AS ?c) WHERE { <$($envConfig.EntityBase)Q128> ?p ?o . }"
        $status.ChapterCount = [int](Invoke-SparqlScalar $envConfig.SparqlUrl $countQuery "c" $envConfig.BasicAuth)
        $status.Q128Triples = [int](Invoke-SparqlScalar $envConfig.SparqlUrl $q128Query "c" $envConfig.BasicAuth)
        $status.SPARQL = "OK"
        if ($status.ChapterCount -ne 88) {
            $notes.Add("chapter count $($status.ChapterCount) != 88")
        }
        if ($status.Q128Triples -le 0) {
            $notes.Add("Q128 missing from SPARQL")
        }
    } catch {
        $notes.Add("SPARQL query failed")
    }

    try {
        $status.DbMaxRcTimestamp = Get-DbTimestamp $envConfig
    } catch {
        $notes.Add($_.Exception.Message)
    }

    $status.Notes = ($notes -join "; ")
    return [pscustomobject]$status
}

Step "Checking environment health and sync state"

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "ssh not found on PATH"
}
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe not found on PATH"
}

$results = @()
foreach ($envConfig in $environments) {
    Write-Host "Checking $($envConfig.Name)..." -ForegroundColor Yellow
    $results += Get-EnvironmentStatus $envConfig
}

$devResult = $results | Where-Object { $_.Environment -eq "DEV" } | Select-Object -First 1
foreach ($result in $results) {
    if ($result.Environment -eq "DEV") {
        $result.InSyncWithDev = if ($result.ChapterCount -eq 88 -and $result.Q128Triples -gt 0 -and $result.DbMaxRcTimestamp -ne "ERROR") { "SOURCE" } else { "SOURCE-ISSUE" }
        continue
    }

    if (-not $devResult) {
        $result.InSyncWithDev = "NO-DEV"
        continue
    }

    $dbMatches = $result.DbMaxRcTimestamp -eq $devResult.DbMaxRcTimestamp
    $chapterMatches = $result.ChapterCount -eq $devResult.ChapterCount
    $q128Matches = $result.Q128Triples -eq $devResult.Q128Triples

    if ($dbMatches -and $chapterMatches -and $q128Matches) {
        $result.InSyncWithDev = "YES"
    } else {
        $result.InSyncWithDev = "NO"
        $delta = New-Object System.Collections.Generic.List[string]
        if (-not $dbMatches) { $delta.Add("DB timestamp differs from DEV") }
        if (-not $chapterMatches) { $delta.Add("chapter count differs from DEV") }
        if (-not $q128Matches) { $delta.Add("Q128 SPARQL differs from DEV") }
        if ([string]::IsNullOrEmpty($result.Notes)) {
            $result.Notes = ($delta -join "; ")
        } else {
            $result.Notes = $result.Notes + "; " + ($delta -join "; ")
        }
    }
}

Write-Host ""
Write-Host "=== Sync Report ===" -ForegroundColor Green
$results | Format-Table Environment, Wiki, QueryUI, SPARQL, DbMaxRcTimestamp, ChapterCount, Q128Triples, InSyncWithDev -AutoSize

Write-Host ""
Write-Host "Notes:" -ForegroundColor Cyan
foreach ($result in $results) {
    if ([string]::IsNullOrEmpty($result.Notes)) {
        Write-Host ("  {0}: none" -f $result.Environment)
    } else {
        Write-Host ("  {0}: {1}" -f $result.Environment, $result.Notes)
    }
}

Write-Host ""
if (($results | Where-Object { $_.InSyncWithDev -eq "NO" -or $_.InSyncWithDev -eq "SOURCE-ISSUE" }).Count -eq 0) {
    OK "All checked environments are in sync with DEV."
} else {
    Warn "One or more environments are not in sync. Review the report above."
}