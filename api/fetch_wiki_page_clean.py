import requests
import os
import sys
import argparse
from pathlib import Path
from urllib.parse import quote, urlparse
from bs4 import BeautifulSoup, Comment
import re

# Configuration
WIKI_URL = "https://prod-climatekg.semanticclimate.org"
PAGE_TITLE = "IPCC:AR6/WGIII/Chapter-9"
OUTPUT_DIR = Path(__file__).parent  # Store everything in api/ directory
IMAGES_DIR = OUTPUT_DIR / "chapter_9_images"

def fetch_wiki_page_html(wiki_url, page_title):
    """
    Fetch clean HTML content of a wiki page using the MediaWiki API.
    
    Args:
        wiki_url: Base URL of the wiki
        page_title: Title of the page to fetch
    
    Returns:
        str: HTML content of the page
    """
    api_url = f"{wiki_url}/w/api.php"
    
    params = {
        'action': 'parse',
        'page': page_title,
        'format': 'json',
        'prop': 'text',
        'disabletoc': 1,              # Remove table of contents
        'disableeditsection': 1,       # Remove edit section links
        'disablelimitreport': 1        # Remove parser limit report
    }
    
    try:
        response = requests.get(api_url, params=params, timeout=30)
        response.raise_for_status()
        data = response.json()
        
        if 'parse' in data and 'text' in data['parse']:
            return data['parse']['text']['*']
        elif 'error' in data:
            raise Exception(f"API Error: {data['error']['info']}")
        else:
            raise Exception("Unexpected API response format")
            
    except requests.exceptions.RequestException as e:
        raise Exception(f"Request failed: {e}")

def extract_image_urls_from_html(html_content, wiki_url):
    """Extract image URLs directly from the parsed HTML."""
    soup = BeautifulSoup(html_content, 'html.parser')
    image_urls = {}
    
    for img in soup.find_all('img'):
        src = img.get('src', '')
        alt = img.get('alt', 'image')
        
        if src:
            # Handle relative URLs
            if src.startswith('/'):
                full_url = f"{wiki_url}{src}"
            else:
                full_url = src
            
            # Generate filename from URL
            filename = urlparse(full_url).path.split('/')[-1]
            if filename:
                image_urls[full_url] = (filename, alt)
    
    return image_urls

def download_images(image_urls, images_dir, skip_existing=False):
    """Download all images and return mapping of URLs to local paths.
    
    Args:
        image_urls: Dict of image URLs to download
        images_dir: Directory to save images to
        skip_existing: If True, skip images that already exist locally
    """
    images_dir.mkdir(exist_ok=True)
    url_mapping = {}
    
    for idx, (image_url, (filename, alt)) in enumerate(image_urls.items(), 1):
        filepath = images_dir / filename
        
        # Check if file already exists
        if filepath.exists() and skip_existing:
            print(f"[{idx}/{len(image_urls)}] Already exists (skipped): {filename}")
            url_mapping[image_url] = filepath.name
            continue
        
        try:
            print(f"[{idx}/{len(image_urls)}] Downloading: {filename}")
            response = requests.get(image_url, timeout=20)
            response.raise_for_status()
            
            with open(filepath, 'wb') as f:
                f.write(response.content)
            
            url_mapping[image_url] = filepath.name
            
        except Exception as e:
            print(f"  Error downloading {filename}: {e}")
    
    return url_mapping

def clean_html(html_content):
    """Remove templates, navboxes, infoboxes, and other non-content elements."""
    soup = BeautifulSoup(html_content, 'html.parser')
    
    # First, remove chapter navigation boxes before processing main_content
    # This handles elements that might be at the top level
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
        
        # Remove any remaining {{...}} template markup (e.g., {{ChapterNavigation}})
        # Using re.DOTALL so . matches newlines for multi-line templates
        html_str = str(main_content)
        html_str = re.sub(r'\{\{.*?\}\}', '', html_str, flags=re.DOTALL)
        return html_str
    
    return html_content

def update_image_urls(html_content, url_mapping, images_dir_name):
    """Replace remote image URLs with local file references."""
    soup = BeautifulSoup(html_content, 'html.parser')
    
    # Create a mapping of filename to local path
    # url_mapping is: { remote_url: local_filename }
    url_to_filename = {local_filename: f"{images_dir_name}/{local_filename}" 
                       for remote_url, local_filename in url_mapping.items()}
    
    print(f"  Found {len(url_to_filename)} filenames to match")
    
    img_tags = soup.find_all('img')
    print(f"  Found {len(img_tags)} img tags in HTML")
    
    updated_count = 0
    for img_tag in img_tags:
        src = img_tag.get('src', '')
        
        # Match by checking if filename appears anywhere in src
        for local_filename, local_path in url_to_filename.items():
            if local_filename in src:
                img_tag['src'] = local_path
                # Remove srcset to avoid broken thumbnail links
                if 'srcset' in img_tag.attrs:
                    del img_tag.attrs['srcset']
                updated_count += 1
                break
    
    print(f"  Updated {updated_count} image links")
    
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

def main(skip_existing_images=False):
    try:
        print(f"Fetching page: {PAGE_TITLE}")
        html = fetch_wiki_page_html(WIKI_URL, PAGE_TITLE)
        
        print("\nExtracting image URLs from HTML...")
        image_urls = extract_image_urls_from_html(html, WIKI_URL)
        print(f"Found {len(image_urls)} images")
        
        print("\nCleaning HTML...")
        clean_html_content = clean_html(html)
        
        if image_urls:
            print(f"\nDownloading images to {IMAGES_DIR}/...")
            url_mapping = download_images(image_urls, IMAGES_DIR, skip_existing=skip_existing_images)
            
            print("\nUpdating image URLs in HTML...")
            clean_html_content = update_image_urls(clean_html_content, url_mapping, IMAGES_DIR.name)
            
            print(f"Successfully downloaded {len(url_mapping)}/{len(image_urls)} images")
        
        # Wrap in complete HTML document
        final_html = wrap_html_document(clean_html_content, PAGE_TITLE)
        
        # Save main HTML file
        output_file = OUTPUT_DIR / "chapter_9.html"
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(final_html)
        
        print(f"\n✓ HTML saved to {output_file}")
        if image_urls:
            print(f"✓ Images saved to {IMAGES_DIR}/")
            print(f"✓ Total files created: 1 HTML + {len(url_mapping)} images")
        
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Fetch and clean wiki page HTML with local images"
    )
    parser.add_argument(
        '--skip-existing-images',
        action='store_true',
        help='Skip downloading images if they already exist locally (faster re-runs)'
    )
    
    args = parser.parse_args()
    main(skip_existing_images=args.skip_existing_images)
