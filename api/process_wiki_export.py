"""
Configurable script to clean and process wiki page exports.
This makes the exported HTML clean, self-contained, with local images.

Usage:
    python api/process_wiki_export.py --config sr15-ch1
    python api/process_wiki_export.py --config wgiii-ch9
    
Or edit the CONFIG dictionary and run directly.
"""

import argparse
from pathlib import Path
from bs4 import BeautifulSoup, Comment
import re

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIGS = {
    'sr15-ch1': {
        'input_html': 'api/sr15-ch1.html',
        'output_html': 'api/sr15-ch1.html',  # Overwrite the raw file
        'images_dir': 'sr15_ch1_images',
        'page_title': 'IPCC:AR6/SR15/Chapter-1'
    },
    'wgiii-ch9': {
        'input_html': 'api/chapter_9.html',
        'output_html': 'api/chapter_9.html',
        'images_dir': 'chapter_9_images',
        'page_title': 'IPCC:AR6/WGIII/Chapter-9'
    }
}

# Default config if not using command line
DEFAULT_CONFIG = 'sr15-ch1'

# ============================================================================
# CLEANING FUNCTIONS
# ============================================================================

def clean_html(html_content):
    """Remove templates, navboxes, infoboxes, and other non-content elements."""
    soup = BeautifulSoup(html_content, 'html.parser')
    
    # First, remove chapter navigation boxes before processing main_content
    for elem in soup.find_all('div', {'class': 'cn-box'}):
        elem.decompose()
    for elem in soup.find_all('table', {'class': 'cn-row'}):
        elem.decompose()
    
    main_content = soup.find('div', {'class': 'mw-parser-output'})
    
    if main_content:
        # Templates and template-related elements to remove
        selectors_to_remove = [
            # Navigation and metadata templates
            'div.navbox',
            'div.navframe', 
            'div.navbox-inner',
            'table.navbox',
            'table.navbox-inner',
            
            # Infoboxes and data boxes
            'table.infobox',
            'div.infobox',
            'div.infobox_v2',
            'table.infobox_v2',
            
            # Reference and citation templates
            'div.reflist',
            'ol.references',
            'div.reference',
            'span.reference',
            
            # Content templates
            'div.toc',
            'div.toc_wrapper',
            'div.mw-collapsible',
            'div.mw-collapsible-toggle',
            
            # Edit sections
            'div.mw-editsection',
            'span.mw-editsection',
            'span.mw-editsection-bracket',
            
            # Misc non-content
            'div.noprint',
            'div.mw-ui-button',
            'div.mw-template-box',
            'div.template',
            'div.templatedata',
            'div.mbox',  # Message boxes
            'table.mbox',
            'div.ambox',  # Article message boxes
            'div.hatnote',  # "See also" style boxes
            'div.dablink',  # Disambiguation links
            'div.boilerplate',
            'div.mainarticle',
            
            # Chapter navigation ({{ChapterNavigation}} template)
            'div.cn-box',
            'table.cn-row',
            
            # Category and metadata
            'div.metadata',
            'div.mw-category',
            'div.printfooter',
            'div.catlinks'
        ]
        
        for selector in selectors_to_remove:
            for element in main_content.select(selector):
                element.decompose()
        
        # Direct removal for chapter navigation elements
        for elem in main_content.find_all('div', {'class': 'cn-box'}):
            elem.decompose()
        for elem in main_content.find_all('table', {'class': 'cn-row'}):
            elem.decompose()
        
        # Remove script tags and event handlers
        for script in main_content.find_all('script'):
            script.decompose()
        
        # Remove comment nodes that might contain template data
        for comment in main_content.find_all(string=lambda text: isinstance(text, Comment)):
            comment.extract()
        
        # Remove template-related attributes
        for element in main_content.find_all(True):  # True = all elements
            # Remove data attributes that might be template-related
            attrs_to_remove = [attr for attr in element.attrs if attr.startswith('data-')]
            for attr in attrs_to_remove:
                del element.attrs[attr]
            
            # Remove typeof attributes (RDFa/microdata)
            if 'typeof' in element.attrs:
                del element.attrs['typeof']
            
            # Remove rel attributes for templates
            if 'rel' in element.attrs:
                rel = element.attrs['rel']
                if isinstance(rel, list):
                    rel = [r for r in rel if r not in ['mw-is-toc']]
                    if rel:
                        element.attrs['rel'] = rel
                    else:
                        del element.attrs['rel']
            
            # Remove role attributes from TOC
            if 'role' in element.attrs and element.attrs['role'] in ['navigation', 'button']:
                del element.attrs['role']
            
            # Remove aria attributes
            attrs_to_remove = [attr for attr in element.attrs if attr.startswith('aria-')]
            for attr in attrs_to_remove:
                del element.attrs[attr]
        
        # Remove any remaining {{...}} template markup
        html_str = str(main_content)
        html_str = re.sub(r'\{\{.*?\}\}', '', html_str, flags=re.DOTALL)
        return html_str
    
    return html_content

def update_image_urls(html_content, images_dir_name):
    """Replace remote image URLs with local file references."""
    soup = BeautifulSoup(html_content, 'html.parser')
    
    img_tags = soup.find_all('img')
    print(f"  Found {len(img_tags)} img tags in HTML")
    
    updated_count = 0
    for img_tag in img_tags:
        src = img_tag.get('src', '')
        
        if not src:
            continue
        
        # Extract filename from URL path
        # e.g., /w/images/thumb/1/1a/Cover-SR15.jpg/96px-Cover-SR15.jpg -> 96px-Cover-SR15.jpg
        # or /w/images/3/33/996ff39772146c351a403c017d2d3cb9_Chapter-1-figure-1-1024x568.png
        filename = src.split('/')[-1]
        
        # Check if we have a local image with this filename (or similar)
        # For srcset, we downloaded the higher resolution version
        if 'srcset' in img_tag.attrs:
            srcset = img_tag.attrs['srcset']
            # Get the highest resolution version from srcset (usually last)
            srcset_parts = srcset.split(',')
            if srcset_parts:
                highest_res_url = srcset_parts[-1].strip().split()[0]
                filename = highest_res_url.split('/')[-1]
        
        # Update src to local path
        img_tag['src'] = f"{images_dir_name}/{filename}"
        
        # Remove srcset to avoid broken thumbnail links
        if 'srcset' in img_tag.attrs:
            del img_tag.attrs['srcset']
        
        # Remove decoding attribute (not needed for local files)
        if 'decoding' in img_tag.attrs:
            del img_tag.attrs['decoding']
        
        updated_count += 1
    
    print(f"  Updated {updated_count} image links to local paths")
    
    return str(soup)

def wrap_html_document(content_html, page_title):
    """Wrap content in a complete HTML document."""
    html_doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{page_title}</title>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen-Sans, Ubuntu, Cantarell, "Helvetica Neue", sans-serif;
            line-height: 1.6;
            max-width: 900px;
            margin: 0 auto;
            padding: 20px;
            color: #333;
        }}
        img {{
            max-width: 100%;
            height: auto;
            margin: 10px 0;
        }}
        h1, h2, h3 {{
            margin-top: 1.5em;
            margin-bottom: 0.5em;
        }}
        a {{
            color: #0645ad;
            text-decoration: none;
        }}
        a:visited {{
            color: #663399;
        }}
        table {{
            border-collapse: collapse;
            width: 100%;
            margin: 1em 0;
        }}
        table, th, td {{
            border: 1px solid #aaa;
        }}
        th, td {{
            padding: 0.5em;
        }}
    </style>
</head>
<body>
{content_html}
</body>
</html>"""
    return html_doc

# ============================================================================
# MAIN PROCESSING
# ============================================================================

def process_export(config):
    """Process a wiki export using the given configuration."""
    input_path = Path(config['input_html'])
    output_path = Path(config['output_html'])
    images_dir = config['images_dir']
    page_title = config['page_title']
    
    print(f"\n{'='*70}")
    print(f"Processing: {page_title}")
    print(f"{'='*70}")
    
    # Check if input file exists
    if not input_path.exists():
        print(f"❌ Error: Input file not found: {input_path}")
        return False
    
    # Read raw HTML
    print(f"\n1. Reading raw HTML from {input_path}...")
    with open(input_path, 'r', encoding='utf-8') as f:
        raw_html = f.read()
    print(f"   ✓ Read {len(raw_html)} characters")
    
    # Clean HTML
    print(f"\n2. Cleaning HTML (removing navigation, TOC, templates)...")
    cleaned_html = clean_html(raw_html)
    print(f"   ✓ Cleaned HTML ({len(cleaned_html)} characters)")
    
    # Update image URLs
    print(f"\n3. Updating image URLs to point to {images_dir}/...")
    cleaned_html = update_image_urls(cleaned_html, images_dir)
    
    # Wrap in complete HTML document
    print(f"\n4. Wrapping in complete HTML document...")
    final_html = wrap_html_document(cleaned_html, page_title)
    print(f"   ✓ Final HTML ready ({len(final_html)} characters)")
    
    # Save output
    print(f"\n5. Saving to {output_path}...")
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(final_html)
    print(f"   ✓ Saved successfully")
    
    print(f"\n{'='*70}")
    print(f"✅ Processing complete!")
    print(f"{'='*70}")
    print(f"Output: {output_path}")
    print(f"Images: {images_dir}/")
    
    return True

def main():
    parser = argparse.ArgumentParser(
        description="Clean and process wiki page exports with local images"
    )
    parser.add_argument(
        '--config',
        type=str,
        choices=list(CONFIGS.keys()),
        default=DEFAULT_CONFIG,
        help=f'Configuration preset to use (default: {DEFAULT_CONFIG})'
    )
    
    args = parser.parse_args()
    
    config = CONFIGS[args.config]
    process_export(config)

if __name__ == "__main__":
    main()
