# Wiki Page HTML Exporter

This directory contains scripts for exporting wiki pages from the ClimateKG MediaWiki instance, including their HTML content and embedded images.

## Overview

The exporter provides two workflows:

### Recommended: Complete Workflow (fetch + clean in one step)
1. **`fetch_wiki_page_clean.py`** - Fetches page, downloads images, cleans HTML, and creates self-contained export

### Manual Workflow (for custom processing)
1. **`fetch_wiki_page.py`** - Fetches raw page HTML from the MediaWiki API
2. **`download_*_images.py`** - Downloads all images to a local directory
3. **`process_wiki_export.py`** - Cleans HTML, removes navigation, links local images
4. **`check_images.py`** - (Optional) Analyzes images in the HTML

## Quick Start (Recommended Method)

The easiest way to export a page is using `fetch_wiki_page_clean.py`, which does everything in one step.

### Option A: Use Existing Configuration

Edit `fetch_wiki_page_clean.py` and change these lines:

```python
# Configuration
WIKI_URL = "https://prod-climatekg.semanticclimate.org"
PAGE_TITLE = "IPCC:AR6/SR15/Chapter-1"  # Change this
OUTPUT_DIR = Path(__file__).parent
IMAGES_DIR = OUTPUT_DIR / "sr15_ch1_images"  # Change this
```

Then in the main function, update the output filename:

```python
output_file = OUTPUT_DIR / "sr15-ch1.html"  # Change this
```

Run:
```bash
python api/fetch_wiki_page_clean.py
```

This will:
- ✅ Fetch the page HTML
- ✅ Download all images to the images directory  
- ✅ Clean the HTML (remove navigation, TOC, templates)
- ✅ Update image links to local paths
- ✅ Create a complete, self-contained HTML file

---

## Manual Workflow (Step by Step)

If you need more control over the process, follow these steps:

### 1. Fetch a Wiki Page

Edit the configuration in `fetch_wiki_page.py`:

```python
# Configuration
WIKI_URL = "https://prod-climatekg.semanticclimate.org"
PAGE_TITLE = "IPCC:AR6/SR15/Chapter-1"
```

Then set the output file path in the main section:

```python
if __name__ == "__main__":
    # ...
    output_file = "api/sr15-ch1.html"  # Change this to your desired path
    save_html_to_file(html, output_file)
```

Run the script:
```bash
python api/fetch_wiki_page.py
```

### 2. Check Images in the Page

Update `check_images.py` to point to your HTML file:

```python
with open('api/sr15-ch1.html', 'r', encoding='utf-8') as f:
    html = f.read()
```

Run to see what images are available:
```bash
python api/check_images.py
```

This will display:
- Total number of images found
- First 5 image sources
- Detailed attributes of the first image

### 3. Download All Images

Create a download script for your page (or modify an existing one like `download_sr15_ch1_images.py`):

**Note:** If you used `fetch_wiki_page_clean.py`, skip to step 4 as images are already downloaded.

```python
# Configuration
WIKI_URL = "https://prod-climatekg.semanticclimate.org"
HTML_FILE = "api/sr15-ch1.html"          # Path to your HTML file
OUTPUT_DIR = "api/sr15_ch1_images"        # Where to save images
```

Run the download script:
```bash
python api/download_sr15_ch1_images.py
```

The script will:
- Parse all `<img>` tags from the HTML
- Download images at highest available resolution (using `srcset` if available)
- Save them to the specified output directory
- Skip already downloaded images
- Rate limit requests to be server-friendly (0.5s delay)

### 4. Clean and Process the HTML

This step removes wiki navigation, templates, and TOC, and links images locally:

```bash
python api/process_wiki_export.py --config sr15-ch1
```

Or add your configuration to `process_wiki_export.py`:

```python
CONFIGS = {
    'your-page': {
        'input_html': 'api/your-page.html',
        'output_html': 'api/your-page.html',  # Will overwrite
        'images_dir': 'your_page_images',
        'page_title': 'IPCC:AR6/Your/Page'
    }
}
```

The processor will:
- ✅ Remove chapter navigation boxes
- ✅ Remove table of contents (TOC)
- ✅ Remove edit section links
- ✅ Remove MediaWiki templates and metadata
- ✅ Update all image URLs to local paths
- ✅ Wrap in clean HTML document with styling
- ✅ Create consistent, self-contained output

**Result:** Clean HTML that matches the format of `chapter_9.html`

## Creating a New Export (Complete Workflow)

### Recommended: One-Step Method

**Step 1:** Edit `fetch_wiki_page_clean.py` configuration:

```python
# Configuration
WIKI_URL = "https://prod-climatekg.semanticclimate.org"
PAGE_TITLE = "IPCC:AR6/WGIII/Chapter-9"  # Change to your page
OUTPUT_DIR = Path(__file__).parent
IMAGES_DIR = OUTPUT_DIR / "wgiii_ch9_images"  # Change to match

# In main():
output_file = OUTPUT_DIR / "wgiii-ch9.html"  # Change to match
```

**Step 2:** Run the script:

```bash
python api/fetch_wiki_page_clean.py
```

**Done!** You now have:
- ✅ `api/wgiii-ch9.html` - Clean, self-contained HTML
- ✅ `api/wgiii_ch9_images/` - All images downloaded locally

---

### Alternative: Manual Multi-Step Method

If you need more control, follow these steps:

**Step 1:** Fetch raw HTML with `fetch_wiki_page.py`
**Step 2:** Download images with custom download script
**Step 3:** Clean and process with `process_wiki_export.py`

See "Manual Workflow" section above for details.

## File Naming Conventions

Recommended naming patterns:

**HTML Files:**
- `sr15-ch1.html` - Special Report 1.5, Chapter 1
- `wgiii-ch9.html` - Working Group III, Chapter 9
- `ar6-wg2-ch4.html` - AR6, Working Group 2, Chapter 4

**Image Directories:**
- `sr15_ch1_images/` - Matches HTML file name with underscores
- `wgiii_ch9_images/`
- `ar6_wg2_ch4_images/`

## Configuration Reference

### fetch_wiki_page_clean.py (Recommended)

| Setting | Description | Example |
|---------|-------------|---------|
| `WIKI_URL` | Base URL of the wiki (without /wiki/) | `https://prod-climatekg.semanticclimate.org` |
| `PAGE_TITLE` | Full page title including namespace | `IPCC:AR6/SR15/Chapter-1` |
| `IMAGES_DIR` | Directory name for images | `"sr15_ch1_images"` |
| `output_file` | Path where HTML will be saved | `OUTPUT_DIR / "sr15-ch1.html"` |

### process_wiki_export.py

Add configurations to the `CONFIGS` dictionary:

```python
CONFIGS = {
    'your-config-name': {
        'input_html': 'api/your-page.html',      # Raw HTML input
        'output_html': 'api/your-page.html',     # Cleaned output (can overwrite)
        'images_dir': 'your_page_images',        # Images directory name
        'page_title': 'IPCC:AR6/Your/Page'       # For HTML <title> tag
    }
}
```

### Recommended: Complete Workflow

```
1. Edit fetch_wiki_page_clean.py
   └─ Set PAGE_TITLE
   └─ Set IMAGES_DIR name
   └─ Set output_file path

2. Run fetch_wiki_page_clean.py
   └─ Fetches HTML from MediaWiki API
   └─ Extracts and downloads images
   └─ Cleans HTML (removes nav, TOC, templates)
   └─ Updates image links to local paths
   └─ Wraps in styled HTML document
   └─ Saves clean, self-contained result

✅ Done! Clean HTML + local images ready to use
```

### Alternative: Manual Workflow

```
1. Edit fetch_wiki_page.py → Run
   └─ Downloads raw HTML from MediaWiki API

2. (Optional) Run check_images.py
   └─ Inspect what images are in the page

3. Create/edit download script → Run
   └─ Downloads all images to directory

4. Run process_wiki_export.py --config your-page
   └─ Cleans HTML and links images locally

✅ Done! Clean HTML + local images ready to us
| `WIKI_URL` | Base URL for constructing image URLs | `https://prod-climatekg.semanticclimate.org` |
| `HTML_FILE` | Path to HTML file containing images | `api/sr15-ch1.html` |
| `OUTPUT_DIR` | Directory where images will be saved | `api/sr15_ch1_images` |

## Workflow Summary

```
1. Edit fetch_wiki_page.py
   └─ Set PAGE_TITLE
   └─ Set output_file path

2. Run fetch_wiki_page.py
   └─ Downloads HTML from MediaWiki API
   └─ Saves to specified file

3. (Optional) Run check_image (One-Step Method)

```bash
# In fetch_wiki_page_clean.py:
PAGE_TITLE = "IPCC:AR6/SR15/Chapter-1"
IMAGES_DIR = OUTPUT_DIR / "sr15_ch1_images"
output_file = OUTPUT_DIR / "sr15-ch1.html"

# Run
python api/fetch_wiki_page_clean.py
```

**Output:**
- `api/sr15-ch1.html` (clean, styled, self-contained)
- `api/sr15_ch1_images/` (12 images)

### Example 2: WGIII Chapter 9 (One-Step Method)

```bash
# In fetch_wiki_page_clean.py:
PAGE_TITLE = "IPCC:AR6/WGIII/Chapter-9"
IMAGES_DIR = OUTPUT_DIR / "chapter_9_images"
output_file = OUTPUT_DIR / "chapter_9.html"

# Run
python api/fetch_wiki_page_clean.py
```

**Output:**
- `api/chapter_9.html` (clean, styled, self-contained)
- `api/chapter_9_images/` (all images)

### Example 3: Processing Already-Downloaded Page

If you already have_clean.py (Recommended)
- ✅ Complete one-step solution
- Uses MediaWiki API `action=parse` for HTML
- Automatically downloads all images at highest resolution
- Removes navigation, TOC, templates, and metadata
- Updates image URLs to local paths
- Wraps in styled HTML document
- Creates clean, self-contained output
- Option to skip existing images (faster re-runs)

### process_wiki_export.py
- Cleans already-downloaded raw HTML
- Removes: navigation boxes, TOC, edit links, templates, metadata
- Updates image links to local directory
- Wraps in styled HTML document
- Configurable via command-line presets
- Repeatable and consistent output

### fetch_wiki_page.py (Manual workflow)
- Uses MediaWiki API `action=parse` for raw HTML
- Includes proper error handling
- Shows preview of first 500 characters
- Configurable timeout (30s default)

### check_images.py (Optional)
- Parses HTML with BeautifulSoup
- Shows total image count
- Displays first 5 image sources
- Shows all attributes of first image (useful for debugging)

### download_*_images.py (Manual workflow)export.py --config wg2-ch4
```

### Example 2: WGIII Chapter 9
```bash
# In fetch_wiki_page.py:
PAGE_TITLE = "IPCC:AR6/WGIII/Chapter-9"
output_file = "api/wgiii-ch9.html"

# Create api/download_wgiii_ch9_images.py with:
HTML_FILE = "api/wgiii-ch9.html"
OUTPUT_DIR = "api/wgiii_ch9_images"

# Run
python api/fetch_wiki_page.py
python api/download_wgiii_ch9_images.py
```

## Features

### fetch_wiki_page.py
- Uses MediaWiki API `action=parse` for clean HTML
- Includes proper error handling
- Shows preview of first 500 characters
- Configurable timeout (30s default)

### check_images.py
- Parses HTML with BeautifulSoup
- Shows total image count
- Displays first 5 image sources
- Shows all attributes of first image (useful for debugging)

### download_*_images.py
- Automatically extracts highest resolution from `srcset`
- Skips already downloaded files
- Creates output directory if needed
- Rate limiting (0.5s between requests)
- Progress reporting
- Error handling per image (continues on failure)
- Summary statistics at end

## Troubleshooting

**Issue: "Page not found"**
- Check PAGE_TITLE spelling and namespace
- Verify page exists at https://prod-climatekg.semanticclimate.org/wiki/PAGE_TITLE

**Issue: "No images found"**
- Check HTML file path in check_images.py
- Verify HTML was downloaded successfully
- Some pages may legitimately have no images

**Issue: "Failed to download image"**
- Check internet connection
- Verify WIKI_URL is correct
- Some images may have been deleted from the server

**Issue: Image quality is low**
- The script uses `srcset` to get highest resolution
- If still low, check the source page for available resolutions

## Dependencies

```bash
pip install requests beautifulsoup4
```

These should already be installed if you're using the project's virtual environment.
