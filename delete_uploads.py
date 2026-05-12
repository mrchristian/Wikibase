"""
Delete all File: pages from the local MediaWiki instance.
"""

import sys
import time
import requests

BASE_URL = "http://localhost:8080/w/api.php"
USERNAME = "admin"
PASSWORD = "adminpass123!"

session = requests.Session()


def login():
    r = session.get(BASE_URL, params={"action": "query", "meta": "tokens", "type": "login", "format": "json"})
    r.raise_for_status()
    token = r.json()["query"]["tokens"]["logintoken"]
    r = session.post(BASE_URL, data={
        "action": "login", "lgname": USERNAME, "lgpassword": PASSWORD,
        "lgtoken": token, "format": "json",
    })
    r.raise_for_status()
    if r.json()["login"]["result"] != "Success":
        print("Login failed"); sys.exit(1)
    print("Logged in as admin.")


def get_csrf_token():
    r = session.get(BASE_URL, params={"action": "query", "meta": "tokens", "format": "json"})
    r.raise_for_status()
    return r.json()["query"]["tokens"]["csrftoken"]


def list_all_files():
    """Return list of all file titles (e.g. 'File:Foo.png') in the wiki."""
    files = []
    params = {"action": "query", "list": "allimages", "ailimit": 500, "format": "json"}
    while True:
        r = session.get(BASE_URL, params=params)
        r.raise_for_status()
        data = r.json()
        for img in data["query"]["allimages"]:
            files.append("File:" + img["name"])
        if "continue" in data:
            params["aicontinue"] = data["continue"]["aicontinue"]
        else:
            break
    return files


def delete_file(title, csrf_token):
    r = session.post(BASE_URL, data={
        "action": "delete", "title": title,
        "reason": "Bulk upload removal",
        "token": csrf_token, "format": "json",
    })
    r.raise_for_status()
    data = r.json()
    if "delete" in data:
        return True, data["delete"].get("title", title)
    elif "error" in data:
        return False, data["error"].get("info", str(data["error"]))
    return False, str(data)


login()
files = list_all_files()
print(f"Found {len(files)} file(s) to delete.")

if not files:
    print("Nothing to delete.")
    sys.exit(0)

csrf_token = get_csrf_token()
succeeded = 0
failed = 0

for i, title in enumerate(files, 1):
    print(f"[{i}/{len(files)}] Deleting: {title} ... ", end="", flush=True)
    try:
        ok, msg = delete_file(title, csrf_token)
        print("OK" if ok else f"FAILED: {msg}")
        if ok:
            succeeded += 1
        else:
            failed += 1
    except Exception as e:
        print(f"ERROR: {e}")
        failed += 1

    if i % 100 == 0:
        csrf_token = get_csrf_token()
    time.sleep(0.05)

print(f"\nDone. Deleted: {succeeded}, Failed: {failed}")
