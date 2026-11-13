#!/usr/bin/env python3
"""
Copy the legal/about wiki pages from the LOCAL wiki to another environment.

Page text lives in the wiki database, not the repo, so after changing the
footer links (LocalSettings.general.php) the pages must be created per env.

Usage (from C:\\Wikibase, venv active):
    python scripts\\sync-policy-pages.py --env newdev --dry-run
    python scripts\\sync-policy-pages.py --env newdev
    python scripts\\sync-policy-pages.py --env newdev --force   # overwrite existing pages
"""

import argparse
import importlib.util
import os
import sys

import requests

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "chapter_urls", os.path.join(_here, "update-chapter-wiki-urls.py"))
cu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cu)

LOCAL_API = "http://localhost:8080/w/api.php"
PAGES = [
    "Imprint",
    "Accessibility statement",
    "ClimateKG:Privacy policy",
    "ClimateKG:Data protection",
    "ClimateKG:About",
    "ClimateKG:General disclaimer",
]
# Pages transcluded by the above; must exist on the target (not copied).
REQUIRED = ["About-Us"]


def get_text(session, api, title):
    r = session.get(api, params={
        "action": "query", "prop": "revisions", "rvprop": "content",
        "rvslots": "main", "titles": title, "format": "json", "formatversion": 2})
    r.raise_for_status()
    page = r.json()["query"]["pages"][0]
    if page.get("missing"):
        return None
    return page["revisions"][0]["slots"]["main"]["content"]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True, choices=sorted(cu.ENV_CONFIG))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="Overwrite pages that already exist")
    args = ap.parse_args()

    cfg = cu.ENV_CONFIG[args.env]
    api = cfg["api_url"]
    local = requests.Session()
    s = requests.Session()
    auth = cu.get_basic_auth(args.env)
    if auth:
        s.auth = auth
    cu.login(s, api, cfg["username"], cu.get_password(cfg["password_env"]))
    token = cu.get_csrf_token(s, api)

    for title in REQUIRED:
        if get_text(s, api, title) is None:
            print(f"[warn]   required page '{title}' is missing on {args.env}")

    failed = 0
    for title in PAGES:
        text = get_text(local, LOCAL_API, title)
        if text is None:
            print(f"[skip]   {title}: missing locally")
            continue
        existing = get_text(s, api, title)
        if existing == text:
            print(f"[same]   {title}")
            continue
        if existing is not None and not args.force:
            print(f"[exists] {title}: differs on {args.env}; use --force to overwrite")
            continue
        print(f"[{'update' if existing is not None else 'create'}] {title}")
        if args.dry_run:
            continue
        try:
            r = s.post(api, data={
                "action": "edit", "title": title, "text": text, "token": token,
                "summary": "Sync legal/about pages from local", "format": "json"})
            r.raise_for_status()
        except requests.RequestException as e:
            print(f"[error]  {title}: {type(e).__name__} ({len(text)} chars)")
            failed += 1
            continue
        out = r.json()
        if "error" in out:
            print(f"[error]  {title}: {out['error'].get('code')}: {out['error'].get('info')}")
            sys.exit(1)

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
