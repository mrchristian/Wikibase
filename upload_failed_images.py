"""Upload the two previously failed images."""

import sys
import os
import requests

BASE_URL = "http://localhost:8080/w/api.php"
IMAGES_DIR = "images"
USERNAME = "admin"
PASSWORD = os.environ.get("LOCAL_MW_ADMIN_PASS", "adminpass123!")

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
    """Upload a single file."""
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

login()
csrf_token = get_csrf_token()

failed_images = [
    ("0f716d182560d9bc8edaeede0f45dd62 IPCC_AR6_WGI_Figure_8_10.png", "0f716d182560d9bc8edaeede0f45dd62_IPCC_AR6_WGI_Figure_8_10.png"),
    ("2635486ac58ac406ff5417aa417692de IPCC_AR6_WGI_CCBox_12_2_Figure_2.png", "2635486ac58ac406ff5417aa417692de_IPCC_AR6_WGI_CCBox_12_2_Figure_2.png"),
]

for local_name, wiki_name in failed_images:
    filepath = os.path.join(IMAGES_DIR, local_name)
    if os.path.exists(filepath):
        success, result = upload_file(filepath, wiki_name, csrf_token)
        status = "OK (Success)" if success else f"FAILED: {result}"
        print(f"Uploading: {wiki_name} ... {status}")
    else:
        print(f"File not found: {filepath}")

print("\nDone!")
