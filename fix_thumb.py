import os
import requests
import re

BASE_URL = "http://localhost:8080/w/api.php"
USERNAME = "admin"
PASSWORD = os.environ.get("LOCAL_MW_ADMIN_PASS", "adminpass123!")

session = requests.Session()

def login():
    r = session.get(BASE_URL, params={"action": "query", "meta": "tokens", "type": "login", "format": "json"})
    token = r.json()["query"]["tokens"]["logintoken"]
    r = session.post(BASE_URL, data={"action": "login", "lgname": USERNAME, "lgpassword": PASSWORD, "lgtoken": token, "format": "json"})
    return r.json()["login"]["result"] == "Success"

def get_csrf_token():
    r = session.get(BASE_URL, params={"action": "query", "meta": "tokens", "format": "json"})
    return r.json()["query"]["tokens"]["csrftoken"]

def search_pages():
    pages = []
    params = {"action": "query", "list": "allpages", "apnamespace": "0", "aplimit": 500, "format": "json"}
    while True:
        r = session.get(BASE_URL, params=params)
        data = r.json()
        pages.extend(data["query"]["allpages"])
        if "continue" in data:
            params["apcontinue"] = data["continue"]["apcontinue"]
        else:
            break
    return pages

def get_content(title):
    r = session.get(BASE_URL, params={"action": "query", "titles": title, "prop": "revisions", "rvprop": "content", "rvslots": "main", "format": "json"})
    page = next(iter(r.json()["query"]["pages"].values()))
    if "revisions" in page:
        return page["revisions"][0]["slots"]["main"]["*"]
    return None

def save_page(title, content):
    csrf = get_csrf_token()
    r = session.post(BASE_URL, data={"action": "edit", "title": title, "text": content, "summary": "Remove |thumb|400x300px from File markup", "token": csrf, "format": "json"})
    resp = r.json()
    if "edit" not in resp:
        return f"ERROR: {resp}"
    return resp["edit"].get("result", "unknown")

if not login():
    print("Login failed")
    exit(1)

print("Logged in.")
results = search_pages()
print(f"Found {len(results)} page(s) in Main namespace matching '400x300px'")

pattern = re.compile(r'\|thumb\|400x300px', re.IGNORECASE)

for page in results:
    title = page["title"]
    content = get_content(title)
    if content and pattern.search(content):
        new_content = pattern.sub("", content)
        result = save_page(title, new_content)
        print(f"  UPDATED [{result}]: {title}")
    else:
        print(f"  SKIPPED (pattern not in wikitext): {title}")

print("Done.")
