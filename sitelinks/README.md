# Sitelinks Analysis Directory

This directory contains sitelink coverage analysis for Chapters (Q6) and Series (Q4) across ClimateKG environments.

## Contents

### Data Files
- `prod-sitelinks.json` — Raw SPARQL query results from PROD environment
- `dev-sitelinks.json` — Raw SPARQL query results from DEV environment
- `prod-sitelinks.csv` — Tabular export of PROD sitelinks (importable to Excel/Google Sheets)
- `dev-sitelinks.csv` — Tabular export of DEV sitelinks

### Reports
- `prod-sitelinks-report.md` — Detailed markdown report for PROD with counts and lists
- `dev-sitelinks-report.md` — Detailed markdown report for DEV with counts and lists
- `comparison-report.md` — Side-by-side comparison of DEV vs PROD coverage

### Scripts
- `analyze-sitelinks.ps1` — PowerShell script to generate all reports and CSV exports

## Usage

### Generate All Reports

```powershell
.\sitelinks\analyze-sitelinks.ps1
```

This will:
1. Analyze both PROD and DEV environments
2. Generate CSV exports for both
3. Generate markdown reports for both
4. Create a comparison report

### Analyze Single Environment

```powershell
# PROD only
.\sitelinks\analyze-sitelinks.ps1 -Environment prod

# DEV only
.\sitelinks\analyze-sitelinks.ps1 -Environment dev
```

## Refresh Data

To get fresh data from the SPARQL endpoints:

```powershell
# Query PROD
curl -s "https://prod-climatekg.semanticclimate.org/query/proxy/sparql" `
  -H "Accept: application/json" `
  --data-urlencode "query=SELECT ?item ?itemLabel ?type ?typeLabel ?sitelink WHERE { VALUES ?type { <https://prod-climatekg.semanticclimate.org/entity/Q6> <https://prod-climatekg.semanticclimate.org/entity/Q4> } ?item <https://prod-climatekg.semanticclimate.org/prop/direct/P1> ?type . OPTIONAL { ?sitelink schema:about ?item ; schema:isPartOf <https://prod-climatekg.semanticclimate.org/> . } SERVICE wikibase:label { bd:serviceParam wikibase:language 'en'. } } ORDER BY ?type ?itemLabel" `
  | ConvertFrom-Json | ConvertTo-Json -Depth 10 > .\sitelinks\prod-sitelinks.json

# Query DEV
curl -s "https://dev-climatekg.semanticclimate.org/query/proxy/sparql" `
  -H "Accept: application/json" `
  --data-urlencode "query=SELECT ?item ?itemLabel ?type ?typeLabel ?sitelink WHERE { VALUES ?type { <https://dev-climatekg.semanticclimate.org/entity/Q6> <https://dev-climatekg.semanticclimate.org/entity/Q4> } ?item <https://dev-climatekg.semanticclimate.org/prop/direct/P1> ?type . OPTIONAL { ?sitelink schema:about ?item ; schema:isPartOf <https://dev-climatekg.semanticclimate.org/> . } SERVICE wikibase:label { bd:serviceParam wikibase:language 'en'. } } ORDER BY ?type ?itemLabel" `
  | ConvertFrom-Json | ConvertTo-Json -Depth 10 > .\sitelinks\dev-sitelinks.json

# Regenerate reports
.\sitelinks\analyze-sitelinks.ps1
```

## Report Structure

Each environment report includes:

1. **Summary Statistics**
   - Series (Q4) counts: with sitelinks, without sitelinks, total, percentage
   - Chapters (Q6) counts: with sitelinks, without sitelinks, total, percentage
   - Overall totals and percentages

2. **Series (Q4) - Items with Sitelinks ✅**
   - Table listing all Series items that have sitelinks
   - Columns: Item ID, Item Label, Sitelink URL

3. **Series (Q4) - Items WITHOUT Sitelinks ❌**
   - Table listing all Series items missing sitelinks
   - Columns: Item ID, Item Label

4. **Chapters (Q6) - Items with Sitelinks ✅**
   - Table listing all Chapter items that have sitelinks
   - Columns: Item ID, Item Label, Sitelink URL

5. **Chapters (Q6) - Items WITHOUT Sitelinks ❌**
   - Table listing all Chapter items missing sitelinks
   - Columns: Item ID, Item Label

## CSV Format

CSV files contain the following columns:
- `ItemID` — Wikibase entity ID (e.g., Q10, Q6)
- `ItemLabel` — Human-readable label
- `Type` — Either "Series" or "Chapter"
- `HasSitelink` — "Yes" or "No"
- `SitelinkURL` — Full URL to wiki page (empty if no sitelink)

## Typical Workflow

1. **Check current status:**
   ```powershell
   .\sitelinks\analyze-sitelinks.ps1
   cat .\sitelinks\comparison-report.md
   ```

2. **Review gaps:**
   - Open `dev-sitelinks-report.md` to see what needs sitelinks in DEV
   - Open `prod-sitelinks-report.md` to see what needs sitelinks in PROD

3. **If DEV has more sitelinks than PROD:**
   ```powershell
   # Sync DEV to PROD
   .\scripts\sync\sync-dev-to-prod.ps1
   ```

4. **Verify sync:**
   ```powershell
   # Refresh PROD data
   curl -s "https://prod-climatekg.semanticclimate.org/query/proxy/sparql" -H "Accept: application/json" --data-urlencode "query=..." | ConvertFrom-Json | ConvertTo-Json -Depth 10 > .\sitelinks\prod-sitelinks.json
   
   # Regenerate reports
   .\sitelinks\analyze-sitelinks.ps1
   ```

## Related Documentation

- [Multi-Environment Workflow](../docs/multi-env-workflow.md) — Database sync procedures
- [SPARQL Graph Queries](../docs/sparql-graph-queries.md) — Query examples

---

*Part of the ClimateKG Wikibase DevOps workflow*
