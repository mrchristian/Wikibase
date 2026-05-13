#!/usr/bin/env python3
import os
import subprocess
import json
import sys

def register_images():
    images_dir = '/var/www/html/images'
    db_user = 'wikibase'
    db_pass = os.environ.get('DB_PASS')
    if not db_pass:
        print('Error: DB_PASS environment variable is not set.')
        sys.exit(1)
    db_name = 'my_wiki'
    
    # Get list of image files from filesystem
    files = [f for f in os.listdir(images_dir) 
             if os.path.isfile(os.path.join(images_dir, f)) and f not in ['.htaccess', 'README']]
    
    print(f"Found {len(files)} image files to register")
    
    # Insert files into the image table
    count = 0
    for filename in files:
        filepath = os.path.join(images_dir, filename)
        size = os.path.getsize(filepath)
        
        # Determine MIME type
        if filename.endswith('.jpg') or filename.endswith('.jpeg'):
            media_type = 'image/jpeg'
            major_mime = 'image'
            minor_mime = 'jpeg'
        elif filename.endswith('.png'):
            media_type = 'image/png'
            major_mime = 'image'
            minor_mime = 'png'
        elif filename.endswith('.gif'):
            media_type = 'image/gif'
            major_mime = 'image'
            minor_mime = 'gif'
        else:
            print(f"Unknown format: {filename}")
            continue
        
        # Build SQL INSERT
        sql = f"""INSERT IGNORE INTO image 
                  (img_name, img_size, img_width, img_height, img_media_type, img_major_mime, img_minor_mime, img_timestamp, img_sha1, img_metadata)
                  VALUES ('{filename}', {size}, 0, 0, '{media_type}', '{major_mime}', '{minor_mime}', NOW(), '', '');"""
        
        # Execute via mysql
        try:
            subprocess.run(
                ['mysql', '-u', db_user, f'-p{db_pass}', db_name, '-e', sql],
                check=True,
                capture_output=True
            )
            count += 1
            if count % 500 == 0:
                print(f"  Registered {count} images...")
        except subprocess.CalledProcessError as e:
            print(f"Error registering {filename}: {e}")
    
    print(f"✓ Successfully registered {count} images to database")

if __name__ == '__main__':
    register_images()
