#!/bin/bash
# Generate SQL to register all images from filesystem

echo "Generating SQL for image registration..."

mysql_statements=""
count=0

for file in /var/www/html/images/*; do
    filename=$(basename "$file")
    
    # Skip directories and special files
    if [ ! -f "$file" ] || [ "$filename" = ".htaccess" ] || [ "$filename" = "README" ]; then
        continue
    fi
    
    # Get file size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    
    # Determine MIME type based on extension
    case "$filename" in
        *.jpg|*.jpeg) mime="image/jpeg"; major="image"; minor="jpeg" ;;
        *.png) mime="image/png"; major="image"; minor="png" ;;
        *.gif) mime="image/gif"; major="image"; minor="gif" ;;
        *) continue ;;
    esac
    
    # Generate INSERT statement
    echo "INSERT IGNORE INTO image (img_name, img_size, img_width, img_height, img_media_type, img_major_mime, img_minor_mime, img_timestamp, img_sha1, img_metadata) 
VALUES ('$filename', $size, 0, 0, '$mime', '$major', '$minor', NOW(), '', '');"
    
    ((count++))
done

echo "Generated SQL for $count files"
