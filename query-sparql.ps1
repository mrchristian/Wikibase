#!/usr/bin/env pwsh
<#
.SYNOPSIS
Query Wikibase WDQS SPARQL endpoint

.PARAMETER Query
SPARQL query string

.EXAMPLE
.\query-sparql.ps1 -Query 'SELECT ?p ?o WHERE { <http://localhost:8080/entity/Q1> ?p ?o . } LIMIT 100'

.NOTES
WDQS frontend has missing i18n assets, so this script queries the backend directly.
#>

param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [string]$Query
)

$endpoint = "http://localhost:9999/bigdata/namespace/wdq/sparql"
$encoded = [uri]::EscapeDataString($Query)
$url = "$endpoint`?query=$encoded"

Write-Host "Querying: $endpoint" -ForegroundColor Cyan
Write-Host "Query: $Query`n" -ForegroundColor Gray

try {
    $response = Invoke-WebRequest -Uri $url -Headers @{Accept='application/sparql-results+json'} -UseBasicParsing
    $json = $response.Content | ConvertFrom-Json
    
    Write-Host "Status: $($response.StatusCode)" -ForegroundColor Green
    Write-Host "Results: $($json.results.bindings.Count) rows`n"
    
    if ($json.results.bindings.Count -gt 0) {
        $json.results.bindings | ConvertTo-Json -Depth 8 | Write-Host
    }
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
