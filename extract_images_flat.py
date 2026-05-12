#!/usr/bin/env python3
import zipfile
import os

zip_path = '/tmp/images_flat.zip'
extract_path = '/var/www/html/images'

print(f"Extracting {zip_path} to {extract_path}...")

try:
    with zipfile.ZipFile(zip_path, 'r') as zip_ref:
        file_list = zip_ref.namelist()
        print(f"Found {len(file_list)} files in ZIP")
        
        zip_ref.extractall(extract_path)
    
    # Count extracted files
    if os.path.isdir(extract_path):
        file_count = len([f for f in os.listdir(extract_path) if os.path.isfile(os.path.join(extract_path, f))])
        print(f"✓ Extraction complete! Total files: {file_count}")
    
    # Cleanup
    if os.path.exists(zip_path):
        os.remove(zip_path)
        print("✓ Cleaned up ZIP file")
    
except Exception as e:
    print(f"✗ Error: {e}")
    import traceback
    traceback.print_exc()
    exit(1)
