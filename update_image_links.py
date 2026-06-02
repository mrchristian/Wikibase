from bs4 import BeautifulSoup
from pathlib import Path
import re

# Read the HTML file
with open('api/chapter_9.html', 'r', encoding='utf-8') as f:
    html_content = f.read()

soup = BeautifulSoup(html_content, 'html.parser')

# Get list of image files in chapter_9_images
images_dir = Path('api/chapter_9_images')
image_files = {f.name.lower(): f.name for f in images_dir.glob('*') if f.is_file()}

print(f"Found {len(image_files)} image files in chapter_9_images/")

# Update all img src attributes
updated_count = 0
for img in soup.find_all('img'):
    src = img.get('src', '')
    
    # Extract filename from the original src (last part of path)
    filename = Path(src).name
    
    # Try to match with local files (case-insensitive)
    local_filename = image_files.get(filename.lower())
    
    if local_filename:
        img['src'] = f"chapter_9_images/{local_filename}"
        updated_count += 1
    else:
        print(f"Warning: Could not find local file for {filename}")

print(f"Updated {updated_count} image src attributes")

# Save the updated HTML
updated_html = str(soup.prettify())
with open('api/chapter_9.html', 'w', encoding='utf-8') as f:
    f.write(updated_html)

print("HTML file updated and saved")

# Verify
with open('api/chapter_9.html', 'r', encoding='utf-8') as f:
    html = f.read()
    soup = BeautifulSoup(html, 'html.parser')
    imgs = soup.find_all('img')
    if imgs:
        print(f"Sample image src after update: {imgs[0].get('src')}")
