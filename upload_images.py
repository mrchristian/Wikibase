"""
Bulk upload images from the images/ directory to the local MediaWiki instance.

Files in images/ are named: {md5hash} {original_filename}
The original filename becomes the MediaWiki file title.

Usage:
    python upload_images.py [--start N] [--limit N] [--dry-run]

Options:
    --start N    Skip the first N files (resume from offset)
    --limit N    Only upload N files (default: all)
    --dry-run    Print what would be uploaded without actually uploading
"""

import argparse
import os
import sys
import time
import requests

BASE_URL = "http://localhost:8080/w/api.php"
IMAGES_DIR = os.path.join(os.path.dirname(__file__), "images")
USERNAME = "admin"
PASSWORD = "adminpass123!"

session = requests.Session()


def login():
    r = session.get(BASE_URL, params={"action": "query", "meta": "tokens", "type": "login", "format": "json"})
    r.raise_for_status()
    token = r.json()["query"]["tokens"]["logintoken"]
    r = session.post(BASE_URL, data={
        "action": "login",
        "lgname": USERNAME,
        "lgpassword": PASSWORD,
        "lgtoken": token,
        "format": "json",
    })
    r.raise_for_status()
    result = r.json()["login"]["result"]
    if result != "Success":
        print(f"Login failed: {result}")
        sys.exit(1)
    print("Logged in as admin.")


def get_csrf_token():
    r = session.get(BASE_URL, params={"action": "query", "meta": "tokens", "format": "json"})
    r.raise_for_status()
    return r.json()["query"]["tokens"]["csrftoken"]


def upload_file(filepath, filename, csrf_token):
    """Upload a single file. Returns (success: bool, message: str)."""
    with open(filepath, "rb") as f:
        r = session.post(BASE_URL, data={
            "action": "upload",
            "filename": filename,
            "comment": "Bulk import of IPCC/climate report figures",
            "ignorewarnings": "true",
            "token": csrf_token,
            "format": "json",
        }, files={"file": (filename, f)})
    r.raise_for_status()
    data = r.json()
    if "upload" in data:
        result = data["upload"].get("result", "unknown")
        return result in ("Success", "Warning"), result
    elif "error" in data:
        return False, data["error"].get("info", str(data["error"]))
    return False, str(data)


def get_image_files():
    """Return sorted list of (filepath, mediawiki_filename) tuples."""
    files = []
    for entry in sorted(os.listdir(IMAGES_DIR)):
        full_path = os.path.join(IMAGES_DIR, entry)
        if not os.path.isfile(full_path):
            continue
        # Use the full entry name (hash + original filename) as the MediaWiki title,
        # replacing spaces with underscores so the title is valid.
        mediawiki_name = entry.replace(" ", "_")
        files.append((full_path, mediawiki_name))
    return files


def main():
    parser = argparse.ArgumentParser(description="Bulk upload images to MediaWiki")
    parser.add_argument("--start", type=int, default=0, metavar="N", help="Skip first N files")
    parser.add_argument("--limit", type=int, default=None, metavar="N", help="Upload at most N files")
    parser.add_argument("--dry-run", action="store_true", help="Print files without uploading")
    args = parser.parse_args()

    files = get_image_files()
    total = len(files)
    print(f"Found {total} image files in {IMAGES_DIR}")

    if args.start:
        files = files[args.start:]
        print(f"Resuming from offset {args.start} ({len(files)} remaining)")
    if args.limit:
        files = files[:args.limit]
        print(f"Limiting to {args.limit} files")

    if args.dry_run:
        print("\n--- DRY RUN (no uploads) ---")
        for filepath, name in files:
            print(f"  Would upload: {name}")
        return

    login()
    csrf_token = get_csrf_token()

    succeeded = 0
    failed = 0
    skipped = 0

    for i, (filepath, name) in enumerate(files, 1):
        global_index = args.start + i
        print(f"[{global_index}/{total}] Uploading: {name} ... ", end="", flush=True)

        try:
            ok, msg = upload_file(filepath, name, csrf_token)
            if ok:
                print(f"OK ({msg})")
                succeeded += 1
            else:
                print(f"FAILED: {msg}")
                failed += 1
        except requests.HTTPError as e:
            print(f"HTTP ERROR: {e}")
            failed += 1
        except Exception as e:
            print(f"ERROR: {e}")
            failed += 1

        # Refresh CSRF token every 100 uploads to avoid expiry
        if i % 100 == 0:
            csrf_token = get_csrf_token()

        # Brief pause to avoid overwhelming the server
        time.sleep(0.1)

    print(f"\nDone. Succeeded: {succeeded}, Failed: {failed}, Skipped: {skipped}")
    print(f"Total processed: {succeeded + failed + skipped} / {len(files)}")


if __name__ == "__main__":
    main()
