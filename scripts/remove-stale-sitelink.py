#!/usr/bin/env python3
"""
Remove a stale sitelink (e.g. the retired 'mywiki' site id) from items.

Background: after the old 'mywiki' site row is removed from the sites table,
items whose stored JSON still lists a 'mywiki' sitelink make
Special:EntityData emit PHP warnings (SiteList.php: Undefined array key),
which breaks the wdqs-updater's Turtle parsing for that item.

Usage (from C:\\Wikibase, venv active):
    python scripts\\remove-stale-sitelink.py --env newdev --site mywiki Q128
    python scripts\\remove-stale-sitelink.py --env newdev --site mywiki Q128 --dry-run
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


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True, choices=sorted(cu.ENV_CONFIG))
    ap.add_argument("--site", default="mywiki", help="Stale site id to remove")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("qids", nargs="+", help="Item ids, e.g. Q128")
    args = ap.parse_args()

    cfg = cu.ENV_CONFIG[args.env]
    api = cfg["api_url"]
    s = requests.Session()
    auth = cu.get_basic_auth(args.env)
    if auth:
        s.auth = auth
    cu.login(s, api, cfg["username"], cu.get_password(cfg["password_env"]))
    token = cu.get_csrf_token(s, api)

    for qid in args.qids:
        r = s.get(api, params={"action": "wbgetentities", "ids": qid,
                               "props": "sitelinks", "format": "json"})
        r.raise_for_status()
        links = r.json()["entities"][qid].get("sitelinks", {})
        if args.site not in links:
            print(f"[skip]   {qid}: no '{args.site}' sitelink")
            continue
        print(f"[remove] {qid}: {args.site} -> {links[args.site]['title']}")
        if args.dry_run:
            continue
        r = s.post(api, data={
            "action": "wbeditentity", "id": qid, "token": token, "format": "json",
            "summary": f"Remove stale sitelink {args.site}",
            "data": '{"sitelinks":{"%s":{"site":"%s","remove":""}}}' % (args.site, args.site),
        })
        r.raise_for_status()
        out = r.json()
        if "error" in out:
            print(f"[error]  {qid}: {out['error'].get('code')}: {out['error'].get('info')}")
            sys.exit(1)
        print(f"[ok]     {qid}: saved")


if __name__ == "__main__":
    main()
