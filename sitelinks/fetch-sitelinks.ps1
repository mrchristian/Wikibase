# Fetch Sitelinks via MediaWiki API
# This script queries the MediaWiki API directly for accurate sitelink detection
# Usage: .\fetch-sitelinks.ps1 -Environment "prod"|"dev"

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("prod", "dev")]
    [string]$Environment
)

# Environment configuration
$envConfig = @{
    prod = @{
        BaseUrl = "https://prod-climatekg.semanticclimate.org"
        OutputFile = ".\sitelinks\prod-sitelinks.json"
    }
    dev = @{
        BaseUrl = "https://dev-climatekg.semanticclimate.org"
        OutputFile = ".\sitelinks\dev-sitelinks.json"
    }
}

$config = $envConfig[$Environment]
$apiUrl = "$($config.BaseUrl)/api.php"

Write-Host "=== Fetching sitelinks from $Environment ===" -ForegroundColor Cyan

# Step 1: Get all Series (Q4) and Chapter (Q6) items via SPARQL
Write-Host "Querying SPARQL for all Series and Chapter items..." -ForegroundColor Yellow

$sparqlQuery = @"
SELECT ?item WHERE { 
  VALUES ?type { <$($config.BaseUrl)/entity/Q6> <$($config.BaseUrl)/entity/Q4> } 
  ?item <$($config.BaseUrl)/prop/direct/P1> ?type . 
}
"@

$sparqlEndpoint = "$($config.BaseUrl)/query/proxy/sparql"
$sparqlResult = curl -s $sparqlEndpoint -H "Accept: application/json" --data-urlencode "query=$sparqlQuery" | ConvertFrom-Json

$itemIds = $sparqlResult.results.bindings | ForEach-Object {
    ($_.item.value -split '/')[-1]
}

Write-Host "Found $($itemIds.Count) items" -ForegroundColor Green

# Step 2: Fetch entity data including sitelinks from MediaWiki API
Write-Host "Fetching entity data with sitelinks from MediaWiki API..." -ForegroundColor Yellow

$batchSize = 50
$allResults = @()

for ($i = 0; $i -lt $itemIds.Count; $i += $batchSize) {
    $batch = $itemIds[$i..[Math]::Min($i + $batchSize - 1, $itemIds.Count - 1)]
    $batchIds = $batch -join '|'
    
    Write-Host "  Processing batch $([Math]::Floor($i / $batchSize) + 1) of $([Math]::Ceiling($itemIds.Count / $batchSize))..." -ForegroundColor Gray
    
    $apiCall = "$apiUrl`?action=wbgetentities&ids=$batchIds&props=labels|claims|sitelinks&format=json"
    $result = Invoke-RestMethod -Uri $apiCall -Method Get
    
    if ($result.entities) {
        foreach ($entityId in $result.entities.PSObject.Properties.Name) {
            $entity = $result.entities.$entityId
            
            # Skip if entity doesn't exist
            if ($entity.missing -eq $true) { continue }
            
            # Get label
            $label = if ($entity.labels.en) { $entity.labels.en.value } else { $entityId }
            
            # Get type (Q4 = Series, Q6 = Chapter)
            $typeId = $null
            if ($entity.claims.P1) {
                $typeId = $entity.claims.P1[0].mainsnak.datavalue.value.id
            }
            $type = if ($typeId -eq "Q4") { "Series" } elseif ($typeId -eq "Q6") { "Chapter" } else { "Unknown" }
            
            # Get registered sitelink from Wikibase
            $sitelink = $null
            $sitelinkTitle = $null
            $sitelinkStatus = "No"
            if ($entity.sitelinks -and $entity.sitelinks.'climatekg-wiki') {
                $sitelinkTitle = $entity.sitelinks.'climatekg-wiki'.title
                $sitelink = "$($config.BaseUrl)/wiki/$sitelinkTitle"
                $sitelinkStatus = "Yes"
            }
            
            # If no registered sitelink, check if wiki page exists (unregistered)
            $unregisteredPage = $null
            if (-not $sitelink) {
                # Try common patterns based on entity type and label
                $potentialPages = @()
                
                if ($type -eq "Series") {
                    # Series patterns
                    if ($label -match "Synthesis") {
                        $potentialPages += "IPCC:AR6/SYR"
                    }
                    elseif ($label -match "Working Group II|WGII") {
                        $potentialPages += "IPCC:AR6/WGII"
                    }
                    elseif ($label -match "Working Group III|WGIII") {
                        $potentialPages += "IPCC:AR6/WGIII"
                    }
                    elseif ($label -match "Working Group I|WGI") {
                        $potentialPages += "IPCC:AR6/WGI"
                    }
                }
                elseif ($type -eq "Chapter") {
                    # For chapters, check if there's a page using the item ID
                    # Query wiki API for pages that might reference this item
                    $searchResult = Invoke-RestMethod -Uri "$apiUrl`?action=query&list=search&srsearch=$entityId&srnamespace=3000&format=json" -Method Get -ErrorAction SilentlyContinue
                    if ($searchResult.query.search.Count -gt 0) {
                        $potentialPages += $searchResult.query.search[0].title
                    }
                }
                
                # Check if any potential page exists
                foreach ($pageName in $potentialPages) {
                    try {
                        $pageCheck = Invoke-WebRequest -Uri "$($config.BaseUrl)/api.php?action=query&titles=$pageName&format=json" -Method Get -UseBasicParsing -ErrorAction SilentlyContinue
                        $pageCheckJson = $pageCheck.Content | ConvertFrom-Json
                        $pageExists = -not ($pageCheckJson.query.pages.PSObject.Properties.Name | Where-Object { $_ -eq "-1" })
                        
                        if ($pageExists) {
                            $unregisteredPage = $pageName
                            $sitelinkStatus = "Unregistered"
                            $sitelink = "$($config.BaseUrl)/wiki/$pageName"
                            break
                        }
                    }
                    catch {
                        # Silently continue if check fails
                    }
                }
            }
            
            $allResults += [PSCustomObject]@{
                ItemID = $entityId
                ItemLabel = $label
                Type = $type
                TypeID = $typeId
                HasSitelink = $sitelinkStatus
                SitelinkTitle = if ($sitelinkTitle) { $sitelinkTitle } elseif ($unregisteredPage) { $unregisteredPage } else { "" }
                SitelinkURL = if ($sitelink) { $sitelink } else { "" }
            }
        }
    }
    
    Start-Sleep -Milliseconds 100  # Be nice to the API
}

# Sort results
$allResults = $allResults | Sort-Object Type, ItemLabel

# Save detailed CSV with status information
$csvFile = $config.OutputFile -replace '.json$', '-detailed.csv'
$allResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
Write-Host "Detailed CSV saved to: $csvFile" -ForegroundColor Green

# Save as JSON for analyze-sitelinks.ps1 compatibility
$jsonOutput = @{
    head = @{
        vars = @("item", "itemLabel", "type", "typeLabel", "sitelink", "sitelinkStatus")
    }
    results = @{
        bindings = @(
            foreach ($item in $allResults) {
                $binding = @{
                    item = @{
                        type = "uri"
                        value = "$($config.BaseUrl)/entity/$($item.ItemID)"
                    }
                    itemLabel = @{
                        'xml:lang' = "en"
                        type = "literal"
                        value = $item.ItemLabel
                    }
                    type = @{
                        type = "uri"
                        value = "$($config.BaseUrl)/entity/$($item.TypeID)"
                    }
                    typeLabel = @{
                        type = "literal"
                        value = $item.Type
                    }
                    sitelinkStatus = @{
                        type = "literal"
                        value = $item.HasSitelink
                    }
                }
                
                if ($item.SitelinkURL) {
                    $binding.sitelink = @{
                        type = "uri"
                        value = $item.SitelinkURL
                    }
                }
                
                $binding
            }
        )
    }
}

$jsonOutput | ConvertTo-Json -Depth 10 | Out-File -FilePath $config.OutputFile -Encoding UTF8

Write-Host "`nResults saved to: $($config.OutputFile)" -ForegroundColor Green
Write-Host "Total items: $($allResults.Count)" -ForegroundColor White
Write-Host "  Series (Q4): $(($allResults | Where-Object { $_.TypeID -eq 'Q4' }).Count)" -ForegroundColor White
Write-Host "  Chapters (Q6): $(($allResults | Where-Object { $_.TypeID -eq 'Q6' }).Count)" -ForegroundColor White
Write-Host "  With registered sitelinks: $(($allResults | Where-Object { $_.HasSitelink -eq 'Yes' }).Count)" -ForegroundColor Green
Write-Host "  With unregistered pages: $(($allResults | Where-Object { $_.HasSitelink -eq 'Unregistered' }).Count)" -ForegroundColor Yellow
Write-Host "  Without any sitelinks: $(($allResults | Where-Object { $_.HasSitelink -eq 'No' }).Count)" -ForegroundColor Red

Write-Host "`nRun analyze-sitelinks.ps1 to generate reports" -ForegroundColor Cyan
