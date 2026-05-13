"""
Restore MediaWiki image files to the local Wikibase container by computing
the hashed directory paths and copying files directly into the container.

MediaWiki stores files at:
  images/{c1}/{c1c2}/{filename}
where c1 = first char of md5(dbkey), c1c2 = first two chars of md5(dbkey),
and dbkey is the file title with spaces replaced by underscores,
first letter uppercased.

Usage:
    python restore_images.py [--dry-run]
"""

import os
import sys
import hashlib
import shutil
import subprocess
import tempfile
import argparse

IMAGES_DIR    = os.path.join(os.path.dirname(__file__), "images")
CONTAINER     = "wikibase"
CONTAINER_DST = "/var/www/html/images"


def mw_hash_path(filename):
    """Return (dir1, dir2) for a given MediaWiki file title (filename with underscores)."""
    # MediaWiki normalises: spaces -> underscores, first letter uppercase
    dbkey = filename.replace(" ", "_")
    if dbkey:
        dbkey = dbkey[0].upper() + dbkey[1:]
    h = hashlib.md5(dbkey.encode("utf-8")).hexdigest()
    return h[0], h[:2]


def get_source_files():
    files = []
    for entry in sorted(os.listdir(IMAGES_DIR)):
        full_path = os.path.join(IMAGES_DIR, entry)
        if os.path.isfile(full_path):
            # Local filename uses spaces; MW title uses underscores
            mw_name = entry.replace(" ", "_")
            files.append((full_path, mw_name))
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="Show what would be copied, don't run docker cp")
    args = parser.parse_args()

    files = get_source_files()
    print(f"Found {len(files)} source images in {IMAGES_DIR}")

    # Build a temp staging directory that mirrors the MW hashed layout
    staging = tempfile.mkdtemp(prefix="mw_images_restore_")
    print(f"Staging directory: {staging}")

    try:
        for src_path, mw_name in files:
            d1, d12 = mw_hash_path(mw_name)
            dest_dir = os.path.join(staging, d1, d12)
            os.makedirs(dest_dir, exist_ok=True)
            dest_file = os.path.join(dest_dir, mw_name)
            if args.dry_run:
                print(f"  {mw_name} -> {d1}/{d12}/{mw_name}")
            else:
                shutil.copy2(src_path, dest_file)

        if args.dry_run:
            print("\nDry run complete — no files copied.")
            return

        print(f"\nCopying staged tree into container {CONTAINER}:{CONTAINER_DST} ...")
        # docker cp copies the *contents* of the source dir when trailing /. is used
        result = subprocess.run(
            ["docker", "cp", staging + "/.", f"{CONTAINER}:{CONTAINER_DST}"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"docker cp failed:\n{result.stderr}")
            sys.exit(1)

        print("docker cp complete.")

        # Fix ownership and permissions inside the container (www-data = 33)
        print("Fixing file ownership in container ...")
        result = subprocess.run(
            ["docker", "exec", CONTAINER, "chown", "-R", "www-data:www-data", CONTAINER_DST],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"chown warning (non-fatal): {result.stderr}")

        # Verify
        result = subprocess.run(
            ["docker", "exec", CONTAINER, "find", CONTAINER_DST, "-type", "f",
             "!", "-name", ".htaccess", "!", "-name", "README"],
            capture_output=True, text=True
        )
        count = len(result.stdout.strip().splitlines())
        print(f"\nFiles now in container images directory: {count}")

    finally:
        shutil.rmtree(staging, ignore_errors=True)
        print("Staging directory cleaned up.")


if __name__ == "__main__":
    main()
