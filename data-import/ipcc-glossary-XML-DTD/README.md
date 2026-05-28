# IPCC Glossary Import Project

This project imports IPCC glossary terms into Wikibase LOCAL using a structured XML workflow.

## Workflow

```
ipccglossary.csv → csv_to_xml.ipynb → glossary.xml → [import script] → Wikibase LOCAL
```

## Files

- **`ipccglossary.csv`** - Source data: IPCC glossary terms with Series, Category, Also Known As, and Definition
- **`glossary.dtd`** - DTD schema defining the XML structure
- **`csv_to_xml.ipynb`** - Jupyter notebook to convert CSV → XML with validation and HTML preview
- **`upload_to_wikibase.py`** - Python script to upload `glossary.xml` to Wikibase
- **`upload_to_wikibase.ipynb`** - Jupyter notebook version of the upload script
- **`cleanup_test_items.py`** - Utility: delete test items by QID range (Q200–Q249)
- **`cleanup_stale_hastag.py`** - Utility: remove stale `has tag` claims from series items
- **`outputs/glossary.xml`** - Generated XML (DTD-validated)
- **`outputs/glossary.html`** - HTML preview for review
- **`outputs/upload_log.json`** - Log of uploaded items and QIDs (created on upload)

## Data Structure

### CSV Columns

1. **Series** - Semicolon-separated report series (WGI, WGII, WGIII, SR15, etc.)
2. **Category** - The glossary term name
3. **Longer term (Also known as)** - Alternative names/aliases
4. **Definition (Description)** - Term definition

### Series → Wikibase QID Mapping

Per CSV instructions:
- **WGI** → Q77
- **WGII** → Q106
- **WGIII** → Q150
- **SR15** → Q10

## XML Structure

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE glossary SYSTEM "glossary.dtd">
<glossary id="IPCC_AR6_Glossary">
  <metadata>
    <title>IPCC Glossary</title>
    <version>v1.5</version>
    <source>https://apps.ipcc.ch/glossary/</source>
    <date>2026-05-27</date>
    <description>IPCC Assessment Report Glossary Terms</description>
  </metadata>
  <terms>
    <term id="term_001">
      <name>1.5°C pathway</name>
      <also_known_as>1.5°C pathway</also_known_as>
      <definition>A pathway of emissions...</definition>
      <series>
        <series_ref qid="Q77">WGI</series_ref>
        <series_ref qid="Q150">WGIII</series_ref>
      </series>
    </term>
    <!-- more terms -->
  </terms>
</glossary>
```

## Usage

### 1. Convert CSV to XML

Open `csv_to_xml.ipynb` in Jupyter Lab and run all cells:

```bash
cd data-import/ipcc-glossary-XML-DTD
jupyter lab csv_to_xml.ipynb
```

This will:
- Parse `ipccglossary.csv` (skipping instruction row)
- Generate `outputs/glossary.xml` with DTD validation
- Create `outputs/glossary.html` searchable preview
- Display statistics and validation results

### 2. Review XML Output

- Check `outputs/glossary.xml` for structure
- Open `outputs/glossary.html` in browser to review all terms interactively
- Verify DTD validation passed

### 3. Import to Wikibase

#### Prerequisites

**LocalSettings.php — description length limit**

The default Wikibase description limit is 250 characters. IPCC glossary definitions are up to ~2,100 characters, so this must be raised **before** uploading. The setting lives in `LocalSettings.general.php` at the repo root:

```php
$wgWBRepoSettings['string-limits']['multilang']['length'] = 2500;
```

This file is mounted into the `wikibase` container via Docker Compose. To apply it:

```bash
# From the repo root
docker compose restart wikibase
```

This is already in place for LOCAL. For other environments (test, prod), the change flows through the standard devops workflow — commit to this repo and deploy via Docker Compose as normal.

---

Two options — Python script or Notebook. Both require `wikibaseintegrator` and `python-dotenv`:

```bash
pip install wikibaseintegrator python-dotenv
```

#### Option A — Notebook (recommended for interactive use)

Open `upload_to_wikibase.ipynb` and run cells step by step:
1. **Section 3** — connects to Wikibase and creates any missing properties. Copy the printed IDs into `.env`.
2. **Configuration cell** — set all `PROP_*` variables (or load from `.env`).
3. **Sections 4–6** — parse XML, upload all terms and save results.

Set `DRY_RUN = True` in the Configuration cell to preview without writing.
Set `LIMIT = 9` for a test run of the first 9 terms.

#### Option B — Python script

```bash
# First run — creates any missing properties, prints IDs, then exits:
python upload_to_wikibase.py

# Add printed IDs to .env, then upload all 920 terms:
python upload_to_wikibase.py

# Test run (first 9 terms):
LIMIT=9 python upload_to_wikibase.py

# Dry run (no writes):
DRY_RUN=true python upload_to_wikibase.py
```

#### Environment variables (.env or shell)

| Variable | Description | Default |
|---|---|---|
| `WIKIBASE_URL` | Wikibase base URL | `http://localhost:8080` |
| `WB_USER` | MediaWiki username | `admin` |
| `WB_PASSWORD` | MediaWiki password | *(required)* |
| `PROP_INSTANCE_OF` | Property ID for `instance of` | *(set after first run)* |
| `PROP_PART_OF` | Property ID for series links | *(set after first run)* |
| `PROP_SOURCE_VERSION` | Property ID for source version qualifier | *(set after first run)* |
| `PROP_REFERENCE_URL` | Property ID for reference URL | *(set after first run)* |
| `PROP_DATE_ACCESSED` | Property ID for date accessed | *(set after first run)* |
| `PROP_DEFINITION` | Property ID for glossary definition text | *(set after first run)* |
| `INSTANCE_OF_QID` | QID for the Category item | `Q1` |
| `DRY_RUN` | `true` to preview without writing | `false` |
| `LIMIT` | Process only first N terms (0 = all) | `0` |

Results are saved to `outputs/upload_log.json`.

## Wikibase Schema

### Item Structure

```
Glossary Term (Qxxx)
├─ label       : [term name]
├─ description : Subject, term, tag: [term name]
├─ alias       : [also known as] (optional, when different from label)
├─ instance of : Category (Q1)
│  ├─ qualifier : source version = "IPCC Glossary v1.5"
│  └─ reference : URL = https://apps.ipcc.ch/glossary/
│                 date accessed = 2026-05-27
├─ part of series : [Series Qxx] (one statement per series)
└─ Definition  : [full definition text — monolingualtext, up to 2,500 chars]
   ├─ qualifier : source version = "IPCC Glossary v1.5"
   └─ reference : URL = https://apps.ipcc.ch/glossary/
                  date accessed = 2026-05-27
```

### Properties

| Property | PID (LOCAL) | Datatype | Notes |
|---|---|---|---|
| instance of | P1 | wikibase-item | Target: Q1 (Category) |
| part of series | P3 | wikibase-item | Target: Q77/Q106/Q150/Q10 |
| Source | P6 | url | Reference on statements |
| Definition | P13 | monolingualtext | Full glossary definition text |
| date accessed | P18 | time | Reference on statements |
| source version | P19 | string | Qualifier on statements |

## Example Term

**CSV Row:**
```
WGI; WGIII,1.5°C pathway,1.5°C pathway,"A pathway of emissions..."
```

**Wikibase Result:**
- **Label:** 1.5°C pathway
- **Description:** Subject, term, tag: 1.5°C pathway
- **Statements:**
  - instance of: Category (Q1)
    - qualifier: source version = IPCC Glossary v1.5
    - reference: https://apps.ipcc.ch/glossary/ + date accessed: 2026-05-27
  - part of series: WGI (Q77)
  - part of series: WGIII (Q150)
  - Definition: "A pathway of emissions..." (en)
    - qualifier: source version = IPCC Glossary v1.5
    - reference: https://apps.ipcc.ch/glossary/ + date accessed: 2026-05-27

## Statistics

Run the notebook to see:
- Total terms processed
- Terms per series (WGI, WGII, WGIII, SR15, etc.)
- Terms with/without series associations
- Terms with/without aliases

## Requirements

- Python 3.10+
- pandas
- lxml
- wikibaseintegrator
- python-dotenv
- Jupyter Lab

Install dependencies:
```bash
pip install pandas lxml jupyterlab wikibaseintegrator python-dotenv
```

## LocalSettings Prerequisite

The Wikibase monolingualtext character limit must be raised in `LocalSettings.general.php` (repo root):

```php
# Increase monolingualtext string length limit so full definitions fit in the Definition statement.
# Default is 400; raising to 2500 accommodates the longest IPCC glossary entry (~2103 chars).
$wgWBRepoSettings['string-limits']['VT:monolingualtext']['length'] = 2500;
```

This file is bind-mounted into the `wikibase` container. Changes take effect after:

```bash
docker compose restart wikibase
```

This applies to all environments — LOCAL, test, and prod — via the Docker Compose devops workflow. Deploy as normal by committing to this repo and running the appropriate compose file for each environment.

## Related Projects

This project follows the same pattern as `corpus-backbone-XML-DTD/` which imports IPCC report structure data.
