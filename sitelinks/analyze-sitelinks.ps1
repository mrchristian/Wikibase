# Sitelink Analysis Script
# Analyzes sitelink coverage for Chapters (Q6) and Series (Q4) across environments
# Usage: .\analyze-sitelinks.ps1 [-Environment "prod"|"dev"|"all"]

param(
    [string]$Environment = "all"
)

function Analyze-Environment {
    param(
        [string]$EnvName,
        [string]$JsonFile,
        [string]$BaseUrl
    )

    Write-Host "`n=== Analyzing $EnvName Environment ===" -ForegroundColor Cyan

    # Read JSON data
    $data = Get-Content $JsonFile | ConvertFrom-Json
    $bindings = $data.results.bindings

    # Separate by type and sitelink status
    $seriesItems = $bindings | Where-Object { $_.type.value -like "*/Q4" }
    $chapterItems = $bindings | Where-Object { $_.type.value -like "*/Q6" }

    # Count sitelinks by status (Yes=Registered, Unregistered=Page exists but not linked, No=Missing)
    $seriesRegistered = $seriesItems | Where-Object { $_.sitelinkStatus.value -eq "Yes" }
    $seriesUnregistered = $seriesItems | Where-Object { $_.sitelinkStatus.value -eq "Unregistered" }
    $seriesMissing = $seriesItems | Where-Object { $_.sitelinkStatus.value -eq "No" }
    
    $chaptersRegistered = $chapterItems | Where-Object { $_.sitelinkStatus.value -eq "Yes" }
    $chaptersUnregistered = $chapterItems | Where-Object { $_.sitelinkStatus.value -eq "Unregistered" }
    $chaptersMissing = $chapterItems | Where-Object { $_.sitelinkStatus.value -eq "No" }

    # Total with any sitelink (registered or unregistered)
    $seriesWithSitelinks = $seriesItems | Where-Object { $_.sitelink }
    $chaptersWithSitelinks = $chapterItems | Where-Object { $_.sitelink }

    # Calculate stats
    $stats = @{
        Environment = $EnvName
        TotalSeries = $seriesItems.Count
        SeriesRegistered = $seriesRegistered.Count
        SeriesUnregistered = $seriesUnregistered.Count
        SeriesMissing = $seriesMissing.Count
        SeriesWithAny = $seriesWithSitelinks.Count
        SeriesPercentage = if ($seriesItems.Count -gt 0) { [math]::Round(($seriesWithSitelinks.Count / $seriesItems.Count) * 100, 1) } else { 0 }
        TotalChapters = $chapterItems.Count
        ChaptersRegistered = $chaptersRegistered.Count
        ChaptersUnregistered = $chaptersUnregistered.Count
        ChaptersMissing = $chaptersMissing.Count
        ChaptersWithAny = $chaptersWithSitelinks.Count
        ChaptersPercentage = if ($chapterItems.Count -gt 0) { [math]::Round(($chaptersWithSitelinks.Count / $chapterItems.Count) * 100, 1) } else { 0 }
        TotalItems = $bindings.Count
        TotalRegistered = ($seriesRegistered.Count + $chaptersRegistered.Count)
        TotalUnregistered = ($seriesUnregistered.Count + $chaptersUnregistered.Count)
        TotalMissing = ($seriesMissing.Count + $chaptersMissing.Count)
        TotalWithAny = ($seriesWithSitelinks.Count + $chaptersWithSitelinks.Count)
        TotalPercentage = if ($bindings.Count -gt 0) { [math]::Round((($seriesWithSitelinks.Count + $chaptersWithSitelinks.Count) / $bindings.Count) * 100, 1) } else { 0 }
    }

    # Output summary
    Write-Host "`nSeries (Q4): $($stats.SeriesWithAny)/$($stats.TotalSeries) ($($stats.SeriesPercentage)%) - Registered: $($stats.SeriesRegistered), Unregistered: $($stats.SeriesUnregistered), Missing: $($stats.SeriesMissing)" -ForegroundColor $(if ($stats.SeriesPercentage -gt 50) { "Green" } else { "Yellow" })
    Write-Host "Chapters (Q6): $($stats.ChaptersWithAny)/$($stats.TotalChapters) ($($stats.ChaptersPercentage)%) - Registered: $($stats.ChaptersRegistered), Unregistered: $($stats.ChaptersUnregistered), Missing: $($stats.ChaptersMissing)" -ForegroundColor $(if ($stats.ChaptersPercentage -gt 50) { "Green" } else { "Yellow" })
    Write-Host "Total: $($stats.TotalWithAny)/$($stats.TotalItems) ($($stats.TotalPercentage)%) - Registered: $($stats.TotalRegistered), Unregistered: $($stats.TotalUnregistered), Missing: $($stats.TotalMissing)" -ForegroundColor $(if ($stats.TotalPercentage -gt 50) { "Green" } else { "Yellow" })

    # Generate CSV export
    $csvData = @()
    foreach ($item in $bindings) {
        $itemId = ($item.item.value -split '/')[-1]
        $typeLabel = if ($item.type.value -like "*/Q4") { "Series" } else { "Chapter" }
        $status = if ($item.sitelinkStatus) { $item.sitelinkStatus.value } else { "No" }
        $sitelinkUrl = if ($item.sitelink) { $item.sitelink.value } else { "" }
        
        $csvData += [PSCustomObject]@{
            ItemID = $itemId
            ItemLabel = $item.itemLabel.value
            Type = $typeLabel
            SitelinkStatus = $status
            SitelinkURL = $sitelinkUrl
        }
    }
    
    $csvFile = ".\sitelinks\$($EnvName.ToLower())-sitelinks.csv"
    $csvData | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-Host "CSV exported to: $csvFile" -ForegroundColor Green

    # Generate Markdown report
    $mdReport = @"
# Sitelink Coverage Report: $EnvName Environment

**Generated:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
**Base URL:** $BaseUrl

---

## Summary Statistics

| Metric | Count | Percentage |
|--------|-------|------------|
| **Series (Q4)** | | |
| - Registered Sitelinks ✅ | $($stats.SeriesRegistered) | $(if ($stats.TotalSeries -gt 0) { [math]::Round(($stats.SeriesRegistered / $stats.TotalSeries) * 100, 1) } else { 0 })% |
| - Unregistered Pages ⚠️ | $($stats.SeriesUnregistered) | $(if ($stats.TotalSeries -gt 0) { [math]::Round(($stats.SeriesUnregistered / $stats.TotalSeries) * 100, 1) } else { 0 })% |
| - Missing ❌ | $($stats.SeriesMissing) | $(if ($stats.TotalSeries -gt 0) { [math]::Round(($stats.SeriesMissing / $stats.TotalSeries) * 100, 1) } else { 0 })% |
| - **Total Series** | **$($stats.TotalSeries)** | **100%** |
| | | |
| **Chapters (Q6)** | | |
| - Registered Sitelinks ✅ | $($stats.ChaptersRegistered) | $(if ($stats.TotalChapters -gt 0) { [math]::Round(($stats.ChaptersRegistered / $stats.TotalChapters) * 100, 1) } else { 0 })% |
| - Unregistered Pages ⚠️ | $($stats.ChaptersUnregistered) | $(if ($stats.TotalChapters -gt 0) { [math]::Round(($stats.ChaptersUnregistered / $stats.TotalChapters) * 100, 1) } else { 0 })% |
| - Missing ❌ | $($stats.ChaptersMissing) | $(if ($stats.TotalChapters -gt 0) { [math]::Round(($stats.ChaptersMissing / $stats.TotalChapters) * 100, 1) } else { 0 })% |
| - **Total Chapters** | **$($stats.TotalChapters)** | **100%** |
| | | |
| **Overall** | | |
| - Registered Sitelinks ✅ | $($stats.TotalRegistered) | $(if ($stats.TotalItems -gt 0) { [math]::Round(($stats.TotalRegistered / $stats.TotalItems) * 100, 1) } else { 0 })% |
| - Unregistered Pages ⚠️ | $($stats.TotalUnregistered) | $(if ($stats.TotalItems -gt 0) { [math]::Round(($stats.TotalUnregistered / $stats.TotalItems) * 100, 1) } else { 0 })% |
| - Missing ❌ | $($stats.TotalMissing) | $(if ($stats.TotalItems -gt 0) { [math]::Round(($stats.TotalMissing / $stats.TotalItems) * 100, 1) } else { 0 })% |
| - **Total Items** | **$($stats.TotalItems)** | **100%** |

---

## Series (Q4) - Registered Sitelinks ✅

| Item ID | Item Label | Sitelink URL |
|---------|------------|--------------|
"@

    foreach ($item in ($seriesRegistered | Sort-Object { $_.itemLabel.value })) {
        $itemId = ($item.item.value -split '/')[-1]
        $mdReport += "| [$itemId]($($item.item.value)) | $($item.itemLabel.value) | [$($item.sitelink.value -replace '^.*/wiki/', '')]($($item.sitelink.value)) |`n"
    }

    $mdReport += @"

---

## Series (Q4) - Unregistered Pages ⚠️

*These items have corresponding wiki pages that exist but are not registered as sitelinks in Wikibase.*

| Item ID | Item Label | Wiki Page URL |
|---------|------------|---------------|
"@

    foreach ($item in ($seriesUnregistered | Sort-Object { $_.itemLabel.value })) {
        $itemId = ($item.item.value -split '/')[-1]
        $mdReport += "| [$itemId]($($item.item.value)) | $($item.itemLabel.value) | [$($item.sitelink.value -replace '^.*/wiki/', '')]($($item.sitelink.value)) |`n"
    }

    $mdReport += @"

---

## Series (Q4) - Missing ❌

*These items have no wiki pages.*

| Item ID | Item Label |
|---------|------------|
"@

    foreach ($item in ($seriesMissing | Sort-Object { $_.itemLabel.value })) {
        $itemId = ($item.item.value -split '/')[-1]
        $mdReport += "| [$itemId]($($item.item.value)) | $($item.itemLabel.value) |`n"
    }

    $mdReport += @"

---

## Chapters (Q6) - Registered Sitelinks ✅

| Item ID | Item Label | Sitelink URL |
|---------|------------|--------------|
"@

    foreach ($item in ($chaptersRegistered | Sort-Object { $_.itemLabel.value })) {
        $itemId = ($item.item.value -split '/')[-1]
        $mdReport += "| [$itemId]($($item.item.value)) | $($item.itemLabel.value) | [$($item.sitelink.value -replace '^.*/wiki/', '')]($($item.sitelink.value)) |`n"
    }

    $mdReport += @"

---

## Chapters (Q6) - Unregistered Pages ⚠️

*These items have corresponding wiki pages that exist but are not registered as sitelinks in Wikibase.*

| Item ID | Item Label | Wiki Page URL |
|---------|------------|---------------|
"@

    foreach ($item in ($chaptersUnregistered | Sort-Object { $_.itemLabel.value })) {
        $itemId = ($item.item.value -split '/')[-1]
        $mdReport += "| [$itemId]($($item.item.value)) | $($item.itemLabel.value) | [$($item.sitelink.value -replace '^.*/wiki/', '')]($($item.sitelink.value)) |`n"
    }

    $mdReport += @"

---

## Chapters (Q6) - Missing ❌

*These items have no wiki pages.*

| Item ID | Item Label |
|---------|------------|
"@

    foreach ($item in ($chaptersMissing | Sort-Object { $_.itemLabel.value })) {
        $itemId = ($item.item.value -split '/')[-1]
        $mdReport += "| [$itemId]($($item.item.value)) | $($item.itemLabel.value) |`n"
    }

    foreach ($item in ($chaptersWithoutSitelinks | Sort-Object { $_.itemLabel.value })) {
        $itemId = ($item.item.value -split '/')[-1]
        $mdReport += "| [$itemId]($($item.item.value)) | $($item.itemLabel.value) |`n"
    }

    $mdReport += @"

---

## Data Files

- **JSON Source:** $JsonFile
- **CSV Export:** $csvFile
- **Query Endpoint:** $BaseUrl/query/proxy/sparql

---

*Generated by analyze-sitelinks.ps1*
"@

    $mdFile = ".\sitelinks\$($EnvName.ToLower())-sitelinks-report.md"
    $mdReport | Out-File -FilePath $mdFile -Encoding UTF8
    Write-Host "Markdown report saved to: $mdFile" -ForegroundColor Green

    return $stats
}

# Main execution
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir\..

if ($Environment -eq "all" -or $Environment -eq "prod") {
    $prodStats = Analyze-Environment -EnvName "PROD" -JsonFile ".\sitelinks\prod-sitelinks.json" -BaseUrl "https://prod-climatekg.semanticclimate.org"
}

if ($Environment -eq "all" -or $Environment -eq "dev") {
    $devStats = Analyze-Environment -EnvName "DEV" -JsonFile ".\sitelinks\dev-sitelinks.json" -BaseUrl "https://dev-climatekg.semanticclimate.org"
}

# Generate comparison report if both environments analyzed
if ($Environment -eq "all") {
    Write-Host "`n=== Environment Comparison ===" -ForegroundColor Cyan
    
    $comparison = @"
# Sitelink Coverage Comparison: DEV vs PROD

**Generated:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

---

## Summary Comparison

| Metric | DEV | PROD | Delta |
|--------|-----|------|-------|
| **Series (Q4)** | | | |
| - With Sitelinks | $($devStats.SeriesWithSitelinks) ($($devStats.SeriesPercentage)%) | $($prodStats.SeriesWithSitelinks) ($($prodStats.SeriesPercentage)%) | $(if ($devStats.SeriesWithSitelinks -gt $prodStats.SeriesWithSitelinks) { "+$($devStats.SeriesWithSitelinks - $prodStats.SeriesWithSitelinks)" } else { "$($devStats.SeriesWithSitelinks - $prodStats.SeriesWithSitelinks)" }) |
| - Total | $($devStats.TotalSeries) | $($prodStats.TotalSeries) | $(if ($devStats.TotalSeries -eq $prodStats.TotalSeries) { "Same" } else { "$($devStats.TotalSeries - $prodStats.TotalSeries)" }) |
| **Chapters (Q6)** | | | |
| - With Sitelinks | $($devStats.ChaptersWithSitelinks) ($($devStats.ChaptersPercentage)%) | $($prodStats.ChaptersWithSitelinks) ($($prodStats.ChaptersPercentage)%) | $(if ($devStats.ChaptersWithSitelinks -gt $prodStats.ChaptersWithSitelinks) { "+$($devStats.ChaptersWithSitelinks - $prodStats.ChaptersWithSitelinks)" } else { "$($devStats.ChaptersWithSitelinks - $prodStats.ChaptersWithSitelinks)" }) |
| - Total | $($devStats.TotalChapters) | $($prodStats.TotalChapters) | $(if ($devStats.TotalChapters -eq $prodStats.TotalChapters) { "Same" } else { "$($devStats.TotalChapters - $prodStats.TotalChapters)" }) |
| **Overall** | | | |
| - With Sitelinks | $($devStats.TotalWithSitelinks) ($($devStats.TotalPercentage)%) | $($prodStats.TotalWithSitelinks) ($($prodStats.TotalPercentage)%) | $(if ($devStats.TotalWithSitelinks -gt $prodStats.TotalWithSitelinks) { "+$($devStats.TotalWithSitelinks - $prodStats.TotalWithSitelinks)" } else { "$($devStats.TotalWithSitelinks - $prodStats.TotalWithSitelinks)" }) |
| - Total Items | $($devStats.TotalItems) | $($prodStats.TotalItems) | $(if ($devStats.TotalItems -eq $prodStats.TotalItems) { "Same" } else { "$($devStats.TotalItems - $prodStats.TotalItems)" }) |

---

## Key Findings

$(if ($devStats.TotalWithSitelinks -gt $prodStats.TotalWithSitelinks) {
"### ⚠️ Sync Gap Detected

- **DEV has $($devStats.TotalWithSitelinks - $prodStats.TotalWithSitelinks) more sitelinks than PROD**
- DEV coverage: $($devStats.TotalPercentage)%
- PROD coverage: $($prodStats.TotalPercentage)%
- **Action Required:** Sync database from DEV to PROD to propagate sitelinks

``````powershell
# To sync DEV to PROD:
.\scripts\sync\sync-dev-to-prod.ps1
``````
"
} else {
"### ✅ Environments In Sync

Both DEV and PROD have the same sitelink coverage ($($devStats.TotalPercentage)%).
"
})

---

## Detailed Reports

- [DEV Sitelinks Report](dev-sitelinks-report.md)
- [PROD Sitelinks Report](prod-sitelinks-report.md)

---

*Generated by analyze-sitelinks.ps1*
"@

    $comparisonFile = ".\sitelinks\comparison-report.md"
    $comparison | Out-File -FilePath $comparisonFile -Encoding UTF8
    Write-Host "`nComparison report saved to: $comparisonFile" -ForegroundColor Green
    
    Write-Host "`n=== Analysis Complete ===" -ForegroundColor Cyan
    Write-Host "Generated files in .\sitelinks\:" -ForegroundColor White
    Write-Host "  - prod-sitelinks.csv" -ForegroundColor Gray
    Write-Host "  - prod-sitelinks-report.md" -ForegroundColor Gray
    Write-Host "  - dev-sitelinks.csv" -ForegroundColor Gray
    Write-Host "  - dev-sitelinks-report.md" -ForegroundColor Gray
    Write-Host "  - comparison-report.md" -ForegroundColor Gray
}
