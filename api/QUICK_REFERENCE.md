# Quick Reference: Export Wiki Pages

## 🚀 Fastest Method (Recommended)

**For a complete export with one command:**

1. Edit `fetch_wiki_page_clean.py`:
   - Change `PAGE_TITLE`
   - Change `IMAGES_DIR` 
   - Change `output_file`

2. Run:
   ```bash
   python api/fetch_wiki_page_clean.py
   ```

**Done!** You get:
- ✅ Clean HTML (no navigation, TOC, templates)
- ✅ All images downloaded locally
- ✅ Consistent formatting with other exports

---

## 📋 Manual Method (More Control)

### Step 1: Fetch Raw HTML
```bash
# Edit fetch_wiki_page.py configuration
python api/fetch_wiki_page.py
```

### Step 2: Download Images
```bash
# Create/edit download script
python api/download_YOUR_PAGE_images.py
```

### Step 3: Clean & Process
```bash
# Add config to process_wiki_export.py
python api/process_wiki_export.py --config your-page
```

---

## 📝 Naming Convention

| Element | Pattern | Example |
|---------|---------|---------|
| Page Title | `IPCC:AR6/REPORT/Chapter-N` | `IPCC:AR6/SR15/Chapter-1` |
| HTML File | `report-chN.html` | `sr15-ch1.html` |
| Images Dir | `report_chN_images` | `sr15_ch1_images` |

---

## ✅ What Gets Cleaned

The processor removes:
- ✅ Chapter navigation boxes
- ✅ Table of contents (TOC)
- ✅ Edit section links
- ✅ MediaWiki templates
- ✅ Metadata attributes
- ✅ Remote image URLs (replaced with local)

And wraps in:
- ✅ Clean HTML5 document structure
- ✅ Responsive CSS styling
- ✅ Consistent typography

---

## 📦 Output Format

All cleaned exports have:
- Same HTML structure
- Same CSS styling
- Local image references
- No wiki navigation elements
- Self-contained (can be viewed offline)

This ensures consistency across all chapter exports!
