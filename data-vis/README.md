# IPCC AR6 Authors Distribution Analysis

Interactive Jupyter notebook for analyzing the demographic distribution of IPCC AR6 authors using Wikibase SPARQL queries and Plotly visualizations.

## Overview

This analysis examines:
- **Global North vs Global South distribution**: Regional representation of authors
- **Gender distribution**: Gender balance in IPCC authorship
- **Intersectional analysis**: Combined patterns of gender and region
- **Chapter-level variations**: Demographic differences across AR6 chapters

## Data Source

- **Wikibase Instance**: ClimateKG LOCAL
- **SPARQL Endpoint**: http://localhost:9999/bigdata/sparql
- **Source Data**: `authors-ar6.xml` (imported via `authors-ar6.dtd`)

## Setup

### Prerequisites

1. **Wikibase running**: Ensure Wikibase Docker stack is running
   ```bash
   cd C:\Wikibase
   docker compose up -d
   ```

2. **Author data imported**: The AR6 author data should be imported into Wikibase

3. **Python environment**: Activate the virtual environment
   ```powershell
   .venv\Scripts\Activate.ps1
   ```

### Install Required Packages

```bash
pip install -r requirements.txt
```

Or install individually:
```bash
pip install SPARQLWrapper pandas numpy plotly
```

## Usage

1. Open the notebook in VS Code or JupyterLab:
   ```bash
   jupyter lab ar6-authors-distribution-analysis.ipynb
   ```

2. Run cells sequentially from top to bottom

3. **Important**: Update property IDs in Section 3 if your Wikibase schema differs
   - Check available properties at: http://localhost:8080/wiki/Special:ListProperties
   - Update P3, P7, P8, P9, P10 to match your instance

## Notebook Structure

1. **Setup and Import Libraries**: Load required Python packages
2. **Configure SPARQL Endpoint**: Set up Wikibase connection
3. **Query Author Data**: Fetch author demographics from Wikibase
4. **Data Preprocessing**: Clean and prepare data for analysis
5. **Classify Countries**: Apply Global North/South classification
6. **Visualize Regional Distribution**: Interactive charts for regional patterns
7. **Visualize Gender Distribution**: Gender balance analysis
8. **Combined Analysis**: Intersectional gender-region analysis
9. **Chapter-Level Analysis**: Variations across AR6 chapters
10. **Summary Statistics**: Key findings and metrics

## Visualizations

The notebook generates:
- Bar charts (horizontal and vertical)
- Pie charts
- Grouped and stacked bar charts
- Cross-tabulation tables
- Statistical summaries

All visualizations are interactive (Plotly) with hover tooltips and zoom/pan capabilities.

## Customization

### Adjust Global North/South Classification

Edit the `GLOBAL_NORTH` set in Section 5 to refine country classification based on your criteria (e.g., HDI, income levels, or specific policy contexts).

### Add More Demographics

Extend the SPARQL query in Section 3 to include:
- Institutional affiliation
- Academic seniority
- Prior IPCC participation
- Field of expertise

### Export Results

Save visualizations:
```python
fig.write_html("output_filename.html")  # Interactive HTML
fig.write_image("output_filename.png")  # Static image
```

Save data:
```python
df_unique_authors.to_csv("authors_summary.csv", index=False)
df_authors.to_excel("authors_full.xlsx", index=False)
```

## Troubleshooting

### No Data Returned

1. Verify Wikibase is running: `docker compose ps`
2. Check SPARQL endpoint: http://localhost:9999/bigdata/sparql
3. Confirm author data is imported: http://localhost:8080/wiki/Special:RecentChanges
4. Update property IDs to match your schema

### Package Installation Issues

If packages fail to install, try:
```bash
pip install --upgrade pip
pip install -r requirements.txt --no-cache-dir
```

### Visualization Not Displaying

- Ensure Plotly is installed: `pip install plotly --upgrade`
- In JupyterLab, install extensions: `jupyter labextension install jupyterlab-plotly`
- In VS Code, ensure Jupyter extension is installed and updated

## Related Files

- `authors-ar6.xml`: Source XML data file (parent directory)
- `authors-ar6.dtd`: Document Type Definition for the XML
- `requirements.txt`: Python package dependencies

## Contact & Contribution

For questions about:
- **Wikibase setup**: See `C:\Wikibase\README.md`
- **Data import**: Check `C:\Wikibase\data-import\` scripts
- **Docker configuration**: Review `C:\Wikibase\docker-compose.yml`

## License

This analysis is part of the ClimateKG project. Data sourced from IPCC AR6 author listings.

---

**Last Updated**: June 2026
