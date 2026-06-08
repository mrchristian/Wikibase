import requests
from bs4 import BeautifulSoup
from pathlib import Path
from urllib.parse import urljoin
import time

# Configuration
WIKI_URL = "https://prod-climatekg.semanticclimate.org"
HTML_FILE = "api/sr15-ch1.html"
OUTPUT_DIR = "api/sr15_ch1_images"

def download_images():
    """Download all images from the HTML file."""
    # Read HTML file
    with open(HTML_FILE, 'r', encoding='utf-8') as f:
        html = f.read()
    
    soup = BeautifulSoup(html, 'html.parser')
    imgs = soup.find_all('img')
    
    print(f'Found {len(imgs)} images to download')
    
    # Create output directory if it doesn't exist
    Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)
    
    downloaded = 0
    skipped = 0
    
    for i, img in enumerate(imgs, 1):
        src = img.get('src')
        if not src:
            print(f'{i}. No src attribute, skipping')
            skipped += 1
            continue
        
        # Handle srcset for higher resolution images
        srcset = img.get('srcset')
        if srcset:
            # Get the highest resolution version from srcset
            srcset_parts = srcset.split(',')
            # Last item usually has highest resolution
            highest_res = srcset_parts[-1].strip().split()[0]
            src = highest_res
        
        # Build full URL
        full_url = urljoin(WIKI_URL, src)
        
        # Get filename from URL
        filename = src.split('/')[-1]
        output_path = Path(OUTPUT_DIR) / filename
        
        # Skip if already downloaded
        if output_path.exists():
            print(f'{i}. Already exists: {filename}')
            skipped += 1
            continue
        
        try:
            print(f'{i}. Downloading: {filename}')
            response = requests.get(full_url, timeout=30)
            response.raise_for_status()
            
            with open(output_path, 'wb') as f:
                f.write(response.content)
            
            downloaded += 1
            print(f'   Saved to {output_path}')
            
            # Be nice to the server
            time.sleep(0.5)
            
        except Exception as e:
            print(f'   Error downloading {filename}: {e}')
            skipped += 1
    
    print(f'\nDownload complete!')
    print(f'Downloaded: {downloaded}')
    print(f'Skipped: {skipped}')
    print(f'Total: {len(imgs)}')

if __name__ == "__main__":
    download_images()
