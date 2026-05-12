"""
Migrate all properties (P1-P12) and items (Q1-Q192) from
https://wikibase.runstop.uk into the local Wikibase (http://localhost:8080).

Strategy:
  1. Fetch all properties from source; create P1-P12 in order on localhost.
  2. Fetch all items from source; create Q1-Q192 in order WITHOUT statements.
  3. Add statements to every item (second pass) so all IDs exist before referencing.
"""

import requests
import json
import time
import sys

SOURCE_API = "https://wikibase.runstop.uk/w/api.php"
TARGET_API = "http://localhost:8080/w/api.php"
USERNAME   = "admin"
PASSWORD   = "adminpass123!"

PROP_IDS = [f"P{i}" for i in range(1, 13)]       # P1-P12
ITEM_IDS = [f"Q{i}" for i in range(1, 193)]       # Q1-Q192

session = requests.Session()
session.headers.update({"User-Agent": "WikibaseMigrate/1.0"})


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

def login():
    r = session.get(TARGET_API, params={
        "action": "query", "meta": "tokens", "type": "login", "format": "json"
    })
    login_token = r.json()["query"]["tokens"]["logintoken"]

    r = session.post(TARGET_API, data={
        "action": "login",
        "lgname": USERNAME,
        "lgpassword": PASSWORD,
        "lgtoken": login_token,
        "format": "json"
    })
    result = r.json()["login"]["result"]
    if result != "Success":
        print(f"Login failed: {result}")
        sys.exit(1)
    print(f"Logged in as {USERNAME}")


def get_token():
    r = session.get(TARGET_API, params={
        "action": "query", "meta": "tokens", "format": "json"
    })
    return r.json()["query"]["tokens"]["csrftoken"]


# ---------------------------------------------------------------------------
# Fetch entities from source
# ---------------------------------------------------------------------------

def fetch_entities(ids):
    """Fetch entities in batches of 50 from source API."""
    all_entities = {}
    for i in range(0, len(ids), 50):
        chunk = ids[i:i+50]
        r = session.get(SOURCE_API, params={
            "action": "wbgetentities",
            "ids": "|".join(chunk),
            "format": "json"
        })
        data = r.json()
        if "entities" in data:
            all_entities.update(data["entities"])
        time.sleep(0.3)
    return all_entities


# ---------------------------------------------------------------------------
# Clean entity data (strip source-specific fields)
# ---------------------------------------------------------------------------

def clean_claims(claims):
    """Strip source statement IDs and snak hashes; keep only the data."""
    cleaned = {}
    for prop, statements in claims.items():
        cleaned_stmts = []
        for stmt in statements:
            s = {
                "type": "statement",
                "rank": stmt.get("rank", "normal"),
                "mainsnak": clean_snak(stmt["mainsnak"]),
            }
            if stmt.get("qualifiers"):
                s["qualifiers"] = {
                    p: [clean_snak(sn) for sn in snaks]
                    for p, snaks in stmt["qualifiers"].items()
                }
            if stmt.get("references"):
                s["references"] = [
                    {
                        "snaks": {
                            p: [clean_snak(sn) for sn in snaks]
                            for p, snaks in ref["snaks"].items()
                        }
                    }
                    for ref in stmt["references"]
                ]
            cleaned_stmts.append(s)
        cleaned[prop] = cleaned_stmts
    return cleaned


def clean_snak(snak):
    """Remove hash field from a snak."""
    s = {k: v for k, v in snak.items() if k != "hash"}
    return s


# ---------------------------------------------------------------------------
# Create entities on localhost
# ---------------------------------------------------------------------------

def create_property(entity, token):
    data = {
        "labels":       entity.get("labels", {}),
        "descriptions": entity.get("descriptions", {}),
        "aliases":      entity.get("aliases", {}),
        "datatype":     entity["datatype"],
    }
    r = session.post(TARGET_API, data={
        "action": "wbeditentity",
        "new":    "property",
        "data":   json.dumps(data),
        "token":  token,
        "format": "json",
    })
    return r.json()


def create_item_stub(entity, token):
    """Create item with labels/descriptions/aliases only (no statements)."""
    data = {
        "labels":       entity.get("labels", {}),
        "descriptions": entity.get("descriptions", {}),
        "aliases":      entity.get("aliases", {}),
    }
    r = session.post(TARGET_API, data={
        "action": "wbeditentity",
        "new":    "item",
        "data":   json.dumps(data),
        "token":  token,
        "format": "json",
    })
    return r.json()


def add_claims_to_item(qid, claims, token):
    """Edit an existing item to add its statements."""
    if not claims:
        return {"skipped": True}
    data = {"claims": clean_claims(claims)}
    r = session.post(TARGET_API, data={
        "action": "wbeditentity",
        "id":     qid,
        "data":   json.dumps(data),
        "token":  token,
        "format": "json",
    })
    return r.json()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    login()
    token = get_token()

    # --- Step 1: Create properties ---
    print("\n=== Creating properties P1-P12 ===")
    source_props = fetch_entities(PROP_IDS)

    for i, pid in enumerate(PROP_IDS, 1):
        entity = source_props.get(pid)
        if not entity:
            print(f"  {pid}: not found in source, skipping")
            continue

        result = create_property(entity, token)
        token = get_token()

        if "error" in result:
            print(f"  {pid} ERROR: {result['error']}")
        else:
            new_id = result.get("entity", {}).get("id", "?")
            label  = entity.get("labels", {}).get("en", {}).get("value", pid)
            print(f"  {pid} -> {new_id}  ({label})")
        time.sleep(0.2)

    # --- Step 2: Create item stubs Q1-Q192 ---
    print("\n=== Creating item stubs Q1-Q192 ===")
    source_items = fetch_entities(ITEM_IDS)

    # Store original claims for pass 2
    item_claims = {}

    for qid in ITEM_IDS:
        entity = source_items.get(qid)
        if not entity:
            print(f"  {qid}: not found in source, skipping")
            continue

        item_claims[qid] = entity.get("claims", {})

        result = create_item_stub(entity, token)
        token = get_token()

        if "error" in result:
            print(f"  {qid} ERROR: {result['error']}")
        else:
            new_id = result.get("entity", {}).get("id", "?")
            label  = entity.get("labels", {}).get("en", {}).get("value", qid)
            print(f"  {qid} -> {new_id}  ({label})")
        time.sleep(0.2)

    # --- Step 3: Add statements to items ---
    print("\n=== Adding statements to items ===")
    for qid in ITEM_IDS:
        claims = item_claims.get(qid, {})
        if not claims:
            continue

        result = add_claims_to_item(qid, claims, token)
        token = get_token()

        if result.get("skipped"):
            continue
        if "error" in result:
            label = source_items.get(qid, {}).get("labels", {}).get("en", {}).get("value", qid)
            print(f"  {qid} ({label}) ERROR: {result['error']}")
        else:
            label = source_items.get(qid, {}).get("labels", {}).get("en", {}).get("value", qid)
            print(f"  {qid} ({label}) - statements added")
        time.sleep(0.2)

    print("\n=== Migration complete ===")


if __name__ == "__main__":
    main()
