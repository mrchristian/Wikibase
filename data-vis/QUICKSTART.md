# Quick Start Guide: AR6 Authors Distribution Analysis

## What's Been Created

✓ **Jupyter Notebook**: `ar6-authors-distribution-analysis.ipynb`  
✓ **Requirements File**: `requirements.txt`  
✓ **Documentation**: `README.md`  
✓ All packages verified and working

## Before You Start

### 1. Ensure Wikibase is Running
```powershell
cd C:\Wikibase
docker compose ps
# If not running: docker compose up -d
```

### 2. Verify SPARQL Endpoint
Open in browser: http://localhost:9999/bigdata/sparql

### 3. Check Author Data Import
Verify your authors are in Wikibase: http://localhost:8080/wiki/Special:RecentChanges

## How to Use the Notebook

### Step 1: Open the Notebook
The notebook is already open in VS Code with the Python kernel configured and running.

### Step 2: Update Property IDs (IMPORTANT!)
In cell 4 (Section 3), you'll see a SPARQL query with property IDs like P3, P7, P8, etc.

**These need to match YOUR Wikibase schema!**

To find the correct property IDs:
1. Visit: http://localhost:8080/wiki/Special:ListProperties
2. Find the properties you need:
   - **P3**: "instance of" (or similar)
   - **P7**: Gender property
   - **P8**: Citizenship property
   - **P9**: Country of residence property
   - **P10**: Chapter contribution property

3. Update the query with your actual property IDs

Example of what to look for:
```sparql
?author wdt:P3 wd:Q2 .  # Change P3 to your "instance of" property
?author wdt:P7 ?genderItem .  # Change P7 to your gender property
```

### Step 3: Run the Cells

**Option A: Run All Cells**
- Click "Run All" button in the notebook toolbar

**Option B: Run Step-by-Step**
- Execute each cell sequentially (Shift+Enter)
- Review outputs as you go
- Adjust code if needed

### Step 4: View Visualizations
Interactive Plotly charts will display inline. You can:
- Hover for details
- Zoom and pan
- Download as PNG

### Step 5: Export Results (Optional)
Add cells at the end to export data:
```python
# Save visualizations
fig.write_html("author_distribution.html")

# Export data
df_unique_authors.to_csv("authors_summary.csv", index=False)
```

## Troubleshooting

### Problem: No Data Returned (Query Returns Empty)

**Likely Causes:**
1. Property IDs in SPARQL query don't match your schema
2. Author data not imported yet
3. Wikibase not running

**Solutions:**
```powershell
# Check Wikibase status
docker compose ps

# Check if data exists
# Open http://localhost:8080 and search for an author name
```

### Problem: SPARQL Query Error

**Cause:** Property IDs or entity IDs don't exist

**Solution:** 
- Visit http://localhost:8080/wiki/Special:ListProperties
- Copy the exact property IDs from your instance
- Update the query in cell 4

### Problem: Visualization Not Showing

**Cause:** Plotly display issue

**Solution:**
```python
# In a new cell, try:
import plotly.io as pio
pio.renderers.default = "notebook"
# Then re-run the visualization cell
```

## Understanding the Analysis

### 1. Regional Distribution (Global North/South)
Shows where authors are from geographically and economically.

**Interpretation:**
- High Global North percentage = predominantly developed countries
- More balanced = better geographic diversity

### 2. Gender Distribution
Shows the gender balance among authors.

**Interpretation:**
- Percentages show representation
- Ratio indicates balance (e.g., 1.5:1 means 60% to 40%)

### 3. Intersectional Analysis
Combines region and gender to reveal compound patterns.

**Key Questions:**
- Is gender balance similar in North and South?
- Are there regional differences in participation?

### 4. Chapter-Level Variations
Shows how demographics vary across different AR6 chapters/reports.

**Insights:**
- Some chapters may have more diverse authorship
- Patterns may reflect disciplinary norms

## Next Steps

Once you have basic results:

1. **Refine Classifications**
   - Adjust Global North/South country list
   - Add more granular categories

2. **Add More Analysis**
   - Role-based analysis (Lead Author vs Review Editor)
   - Temporal comparisons (if you have AR5 data)
   - Statistical significance tests

3. **Create Presentations**
   - Export key charts as HTML or PNG
   - Prepare summary statistics table
   - Highlight key findings

4. **Build Dashboard**
   - Consider Dash or Streamlit for interactive exploration
   - Add filters and drill-downs

## Key Files Reference

```
data-vis/
├── ar6-authors-distribution-analysis.ipynb  ← Main notebook
├── requirements.txt                          ← Python dependencies
├── README.md                                 ← Detailed documentation
└── QUICKSTART.md                            ← This file
```

## Support Resources

- **Wikibase properties**: http://localhost:8080/wiki/Special:ListProperties
- **SPARQL endpoint**: http://localhost:9999/bigdata/sparql
- **Project memory**: C:\Wikibase\memory.md
- **Repo memory**: Check /memories/repo/wikibase-project.md

---

**Ready to Start?** Run cell 2 in the notebook (the import cell)!
