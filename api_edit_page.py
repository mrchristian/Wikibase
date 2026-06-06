#!/usr/bin/env python3
"""
Submit a MediaWiki XML export as a page edit via the MediaWiki Action API.

Reads wikitext from the first <text> element in the XML dump and POSTs it as
an edit to the named page. Credentials are read from .env (WB_PASSWORD /
WB_ADMIN_USER), falling back to the local docker-compose defaults.

Usage:
    python api_edit_page.py
    python api_edit_page.py --xml api/xml/ClimateKG-20260602204800-anchored.xml
    python api_edit_page.py --xml FILE --page "IPCC:AR6/WGIII/Chapter-9" --url http://localhost:8080

Why use this instead of importDump.php:
    importDump.php skips any revision whose ID already exists in the database,
    so re-importing an updated XML export of the same page is silently ignored.
    The Action API creates a fresh revision regardless of prior import history.
"""

import argparse
import http.cookiejar
import json
import os
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

# ── Defaults (overridden by --flags or .env) ──────────────────────────────────
DEFAULT_XML  = "api/xml/ClimateKG-20260602204800-anchored.xml"
DEFAULT_PAGE = "IPCC:AR6/WGIII/Chapter-9"
DEFAULT_URL  = "http://localhost:8080"
DEFAULT_USER = "Admin"
DEFAULT_SUMMARY = "Import anchored wikitext with citation span targets"
# ─────────────────────────────────────────────────────────────────────────────


def load_env(path=".env") -> dict:
    """Read KEY=VALUE pairs from a .env file, ignoring comments and blanks."""
    env = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return env


def make_session(api_url: str):
    """Return a urllib opener that persists cookies across requests."""
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def post(params: dict) -> dict:
        data = urllib.parse.urlencode(params).encode("utf-8")
        req = urllib.request.Request(api_url, data=data)
        with opener.open(req) as resp:
            return json.loads(resp.read())

    return post


def extract_wikitext(xml_file: str) -> str:
    """Parse a MediaWiki XML export and return the wikitext of the first page."""
    tree = ET.parse(xml_file)
    root = tree.getroot()
    ns_map = {"mw": "http://www.mediawiki.org/xml/export-0.11/"}
    text_el = root.find(".//mw:text", ns_map) or root.find(".//text")
    if text_el is None or not text_el.text:
        sys.exit("ERROR: No <text> content found in XML file.")
    return text_el.text


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--xml",     default=DEFAULT_XML,     help="MediaWiki XML export file")
    parser.add_argument("--page",    default=DEFAULT_PAGE,    help="Target page title")
    parser.add_argument("--url",     default=DEFAULT_URL,     help="Wiki base URL")
    parser.add_argument("--user",    default=None,            help="Admin username (default: Admin)")
    parser.add_argument("--summary", default=DEFAULT_SUMMARY, help="Edit summary")
    args = parser.parse_args()

    env = load_env()
    admin_user = args.user or env.get("WB_ADMIN_USER", DEFAULT_USER)
    admin_pass = env.get("WB_PASSWORD", "adminpass123!")
    api_url = args.url.rstrip("/") + "/api.php"

    # ── 1. Extract wikitext ───────────────────────────────────────────────────
    print(f"Reading {args.xml} ...")
    wikitext = extract_wikitext(args.xml)
    span_count = wikitext.count("<span id=")
    print(f"  Length    : {len(wikitext):,} chars")
    print(f"  Span count: {span_count}")

    post = make_session(api_url)

    # ── 2. Login ──────────────────────────────────────────────────────────────
    login_token = post({"action": "query", "meta": "tokens",
                        "type": "login", "format": "json"})["query"]["tokens"]["logintoken"]
    result = post({"action": "login", "lgname": admin_user, "lgpassword": admin_pass,
                   "lgtoken": login_token, "format": "json"})
    login_result = result.get("login", {}).get("result", "UNKNOWN")
    if login_result != "Success":
        sys.exit(f"Login failed ({login_result}): {result}")
    print(f"Logged in as {admin_user}.")

    # ── 3. Get CSRF token ─────────────────────────────────────────────────────
    csrf_token = post({"action": "query", "meta": "tokens",
                       "format": "json"})["query"]["tokens"]["csrftoken"]

    # ── 4. Submit edit ────────────────────────────────────────────────────────
    print(f"Submitting edit to '{args.page}' ...")
    resp = post({
        "action": "edit",
        "title": args.page,
        "text": wikitext,
        "summary": args.summary,
        "token": csrf_token,
        "format": "json",
    })

    edit = resp.get("edit", {})
    if edit.get("result") != "Success":
        sys.exit(f"Edit failed:\n{json.dumps(resp, indent=2)}")

    print(f"Done. New revision: {edit.get('newrevid')}  (page: {edit.get('title')})")


if __name__ == "__main__":
    main()
