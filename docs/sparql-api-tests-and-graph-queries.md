# SPARQL and API Tests + Graph Queries for ClimateKG Wikibase

This document contains working SPARQL queries for visualizing the ClimateKG knowledge graph.

## Verified SPARQL Interfaces (climatekg.tibwiki.io)

The public site is protected by nginx basic auth to reduce bot traffic.

- Username: `ckg`
- Password: `fairdata`

Working addresses:

- Query UI (interactive editor): https://climatekg.tibwiki.io/query/
- SPARQL endpoint (API): https://climatekg.tibwiki.io/query/proxy/sparql

### Quick Smoke Tests

Use these quick checks when you need to confirm the stack is up.

1. SPARQL UI is reachable

```powershell
curl.exe -u ckg:fairdata -s -o NUL -w "%{http_code}`t%{content_type}`t%{url_effective}" https://climatekg.tibwiki.io/query/
```

Expected: `200` and content type containing `text/html`.

2. SPARQL endpoint executes a query

```powershell
curl.exe -u ckg:fairdata -s -G --data-urlencode "query=SELECT * WHERE { ?s ?p ?o } LIMIT 1" -H "Accept: application/sparql-results+json" -o NUL -w "%{http_code}`t%{content_type}`t%{url_effective}" https://climatekg.tibwiki.io/query/proxy/sparql
```

Expected: `200` and content type containing `application/sparql-results+json`.

3. MediaWiki API responds

```powershell
curl.exe -u ckg:fairdata -s -o NUL -w "%{http_code}`t%{content_type}`t%{url_effective}" "https://climatekg.tibwiki.io/w/api.php?action=query&meta=siteinfo&format=json"
```

Expected: `200` and content type containing `application/json`.

### One-Command Smoke Test

Run this PowerShell snippet to check all three endpoints in one go:

```powershell
$checks = @(
  @('SPARQL UI', 'https://climatekg.tibwiki.io/query/', 'text/html'),
  @('SPARQL endpoint', 'https://climatekg.tibwiki.io/query/proxy/sparql?query=SELECT%20*%20WHERE%20%7B%20%3Fs%20%3Fp%20%3Fo%20%7D%20LIMIT%201', 'application/sparql-results+json'),
  @('MediaWiki API', 'https://climatekg.tibwiki.io/w/api.php?action=query&meta=siteinfo&format=json', 'application/json')
)

foreach ($check in $checks) {
  $name = $check[0]
  $url = $check[1]
  $expectedType = $check[2]
  $result = curl.exe -u ckg:fairdata -s -o NUL -w "%{http_code}`t%{content_type}" $url
  $parts = $result -split "`t", 2
  $status = $parts[0]
  $contentType = if ($parts.Count -gt 1) { $parts[1] } else { '' }
  if ($status -eq '200' -and $contentType -like "*$expectedType*") {
    Write-Output "PASS`t$name`t$status`t$contentType"
  } else {
    Write-Output "FAIL`t$name`t$status`t$contentType"
  }
}
```

Expected output shape:

```text
PASS    SPARQL UI        200     text/html; charset=UTF-8
PASS    SPARQL endpoint  200     application/sparql-results+json;charset=utf-8
PASS    MediaWiki API    200     application/json; charset=utf-8
```

### Date-Stamped Connectivity Test

Test date: **2026-10-07**

Test query:

```sparql
SELECT * WHERE { ?s ?p ?o } LIMIT 1
```

Command used:

```powershell
curl.exe -u ckg:fairdata -s -G --data-urlencode "query=SELECT * WHERE { ?s ?p ?o } LIMIT 1" -H "Accept: application/sparql-results+json" -o NUL -w "%{http_code}`t%{content_type}`t%{url_effective}" https://climatekg.tibwiki.io/query/proxy/sparql
```

Observed result:

```text
200	application/sparql-results+json;charset=utf-8	https://climatekg.tibwiki.io/query/proxy/sparql?query=SELECT+%2A+WHERE+%7B+%3Fs+%3Fp+%3Fo+%7D+LIMIT+1
```

UI execution check on the same date:

- https://climatekg.tibwiki.io/query/ returned results for the same query.
- Query executed successfully in the Wikibase Query Service table view.

### API Running Test (MediaWiki API)

Test date: **2026-10-07**

API endpoint:

- https://climatekg.tibwiki.io/w/api.php

Command used:

```powershell
curl.exe -u ckg:fairdata -s -o NUL -w "%{http_code}`t%{content_type}`t%{url_effective}" "https://climatekg.tibwiki.io/w/api.php?action=query&meta=siteinfo&format=json"
```

Observed result:

```text
200	application/json; charset=utf-8	https://climatekg.tibwiki.io/w/api.php?action=query&meta=siteinfo&format=json
```

Optional content check (returns JSON including `query.general.sitename`):

```powershell
curl.exe -u ckg:fairdata -s "https://climatekg.tibwiki.io/w/api.php?action=query&meta=siteinfo&format=json"
```

Expected indicator in response body:

- `"sitename":"ClimateKG"`

## Important Notes

- **Use full property URIs**: The `wdt:` prefix may not work consistently. Use full URIs like `<https://prod-climatekg.semanticclimate.org/prop/direct/P12>` instead.
- **Graph view trigger**: Add `#defaultView:Graph` as the first line to automatically switch to graph visualization.
- **Query interface**: https://climatekg.tibwiki.io/query/

## Key Properties Discovered

| Property | URI | Description |
|----------|-----|-------------|
| P1 | `.../prop/direct/P1` | Instance of / type |
| P3 | `.../prop/direct/P3` | Category (e.g., Chapters) |
| P12 | `.../prop/direct/P12` | Related topics/items |
| P10 | `.../prop/direct/P10` | DOI identifier |
| P5, P6, P7 | `.../prop/direct/P5-7` | External URLs |

## Working Graph Queries

### 1. Topic Relationships (Simple)

Shows connections between items via the P12 (related topics) property.

```sparql
#defaultView:Graph
SELECT ?item ?itemLabel ?linkTo ?linkToLabel
WHERE {
  ?item <https://prod-climatekg.semanticclimate.org/prop/direct/P12> ?linkTo .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
LIMIT 200
```

### 2. All Direct Connections (Comprehensive)

Shows all entity-to-entity connections across all direct properties.

```sparql
#defaultView:Graph
SELECT ?item ?itemLabel ?linkTo ?linkToLabel
WHERE {
  ?item ?property ?linkTo .
  FILTER(STRSTARTS(STR(?property), "https://prod-climatekg.semanticclimate.org/prop/direct/P"))
  FILTER(STRSTARTS(STR(?linkTo), "https://prod-climatekg.semanticclimate.org/entity/Q"))
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
LIMIT 300
```

**Recommended**: Try this query first to see the full knowledge graph structure.

### 3. Chapters and Their Connections

Focuses on items classified as chapters (Q110) and their related topics.

```sparql
#defaultView:Graph
SELECT ?chapter ?chapterLabel ?related ?relatedLabel
WHERE {
  ?chapter <https://prod-climatekg.semanticclimate.org/prop/direct/P3> <https://prod-climatekg.semanticclimate.org/entity/Q110> .
  ?chapter <https://prod-climatekg.semanticclimate.org/prop/direct/P12> ?related .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
```

### 4. Instance-of Relationships

Shows the type hierarchy (P1 = instance of).

```sparql
#defaultView:Graph
SELECT ?item ?itemLabel ?type ?typeLabel
WHERE {
  ?item <https://prod-climatekg.semanticclimate.org/prop/direct/P1> ?type .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
LIMIT 150
```

### 5. Two-Hop Network (Explore from One Item)

Shows items connected to Q114 (Oceans chapter) and their connections.

```sparql
#defaultView:Graph
SELECT ?item1 ?item1Label ?item2 ?item2Label
WHERE {
  {
    <https://prod-climatekg.semanticclimate.org/entity/Q114> ?prop1 ?item2 .
    BIND(<https://prod-climatekg.semanticclimate.org/entity/Q114> AS ?item1)
  } UNION {
    <https://prod-climatekg.semanticclimate.org/entity/Q114> ?prop1 ?mid .
    ?mid ?prop2 ?item2 .
    BIND(?mid AS ?item1)
    FILTER(?mid != <https://prod-climatekg.semanticclimate.org/entity/Q114>)
  }
  FILTER(STRSTARTS(STR(?item2), "https://prod-climatekg.semanticclimate.org/entity/Q"))
  FILTER(STRSTARTS(STR(?item1), "https://prod-climatekg.semanticclimate.org/entity/Q"))
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
LIMIT 200
```

**Usage**: Replace Q114 with any item ID to explore its neighborhood.

## Non-Graph Queries (List Views)

### List All Items

```sparql
SELECT DISTINCT ?item ?itemLabel
WHERE {
  ?item ?p ?o .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
LIMIT 100
```

### Explore One Item's Properties

Replace Q114 with your target item.

```sparql
SELECT ?propertyLabel ?value ?valueLabel
WHERE {
  <https://prod-climatekg.semanticclimate.org/entity/Q114> ?property ?value .
  FILTER(STRSTARTS(STR(?property), "https://prod-climatekg.semanticclimate.org/prop/direct/"))
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
```

### Discover Available Properties

```sparql
SELECT DISTINCT ?prop
WHERE {
  ?s ?prop ?o .
  FILTER(STRSTARTS(STR(?prop), "https://prod-climatekg.semanticclimate.org/prop/direct/P"))
}
LIMIT 50
```

## Troubleshooting

### Query Returns Empty Results

- Check that you're using full URIs: `<https://prod-climatekg.semanticclimate.org/...>` instead of prefixed names
- Verify the property/item exists in your instance
- Try reducing LIMIT or removing filters

### Graph View Not Appearing

- Ensure the query returns two connected variables (e.g., `?item` and `?linkTo`)
- Add `#defaultView:Graph` as the first line
- Click the "Graph" button above the results table if needed

### Performance Issues

- Reduce the LIMIT value
- Add more specific FILTER conditions
- Focus on specific properties rather than querying all properties

## Example Items in ClimateKG

| ID | Label | Type |
|----|-------|------|
| Q114 | Oceans and Coastal Ecosystems and Their Services | Chapter |
| Q116 | Water | Chapter |
| Q117 | Food, Fibre and Other Ecosystem Products | Chapter |
| Q110 | Chapters | Type/Category |
| Q102 | Climate services | Topic |
| Q115 | Water security | Topic |

## See Also

- [Multi-Environment Workflow](multi-env-workflow.md) — Environment URLs and access
- [Wikidata SPARQL Query Help](https://www.wikidata.org/wiki/Wikidata:SPARQL_query_service/Wikidata_Query_Help) — General SPARQL guidance
