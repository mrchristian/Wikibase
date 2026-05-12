#!/usr/bin/env python3
import zipfile
import os

zip_path = '/tmp/images.zip'
extract_path = '/var/www/html'

print(f"Extracting {zip_path} to {extract_path}...")

try:
    with zipfile.ZipFile(zip_path, 'r') as zip_ref:
        zip_ref.extractall(extract_path)
    
    # Count extracted files
    images_dir = os.path.join(extract_path, 'images')
    if os.path.isdir(images_dir):
        file_count = len([f for f in os.listdir(images_dir) if os.path.isfile(os.path.join(images_dir, f))])
        print(f"✓ Extraction complete! Found {file_count} image files")
    
    # Cleanup
    os.remove(zip_path)
    print("✓ Cleaned up ZIP file")
    
except Exception as e:
    print(f"✗ Error: {e}")
    exit(1)
