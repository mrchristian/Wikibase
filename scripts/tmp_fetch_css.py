#!/usr/bin/env python3
"""One-off helper: print the raw content of MediaWiki:Common.css."""
import requests

MW_API_URL = "http://localhost:8080/w/api.php"

r = requests.get(
    MW_API_URL,
    params={
        "action": "query",
        "titles": "MediaWiki:Common.css",
        "prop": "revisions",
        "rvprop": "content",
        "rvslots": "main",
        "format": "json",
    },
    timeout=20,
)
pages = r.json()["query"]["pages"]
page = next(iter(pages.values()))
content = page["revisions"][0]["slots"]["main"]["*"]
print(content)
