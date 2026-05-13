"""
Push all properties (P1-P12) and items (Q1-Q192) from localhost
(http://localhost:8080) to production (https://dev-climatekg.semanticclimate.org).

Strategy:
  1. Fetch all properties from localhost; upsert P1-P12 on production.
  2. Fetch all items from localhost; upsert Q1-Q192 stubs (no statements) on production.
  3. Add/update statements on every item on production (second pass).

"Upsert" means: try to edit the entity by its existing ID; if it doesn't exist
on production yet, create it with wbeditentity new=property/item.
"""

import os
import requests
import json
import time
import sys

SOURCE_API  = "http://localhost:8080/w/api.php"
TARGET_API  = "https://dev-climatekg.semanticclimate.org/w/api.php"
USERNAME    = "admin"
PASSWORD    = os.environ.get("MW_ADMIN_PASS")
if not PASSWORD:
    print("Error: MW_ADMIN_PASS environment variable is not set.")
    print("  PowerShell: $env:MW_ADMIN_PASS='your-password'")
    print("  The value is stored in /opt/wikibase/.env on the production server.")
    sys.exit(1)

PROP_IDS = [f"P{i}" for i in range(1, 13)]   # P1-P12
ITEM_IDS = [f"Q{i}" for i in range(1, 193)]   # Q1-Q192

session = requests.Session()
session.headers.update({"User-Agent": "WikibasePushToProd/1.0"})


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

def login():
    r = session.get(TARGET_API, params={
        "action": "query", "meta": "tokens", "type": "login", "format": "json"
    })
    login_token = r.json()["query"]["tokens"]["logintoken"]

    r = session.post(TARGET_API, data={
        "action":     "login",
        "lgname":     USERNAME,
        "lgpassword": PASSWORD,
        "lgtoken":    login_token,
        "format":     "json",
    })
    result = r.json()["login"]["result"]
    if result != "Success":
        print(f"Login failed: {result}")
        sys.exit(1)
    print(f"Logged in to production as {USERNAME}")


def get_token():
    r = session.get(TARGET_API, params={
        "action": "query", "meta": "tokens", "format": "json"
    })
    return r.json()["query"]["tokens"]["csrftoken"]


# ---------------------------------------------------------------------------
# Fetch entities from source (localhost)
# ---------------------------------------------------------------------------

def fetch_entities(ids):
    """Fetch entities in batches of 50 from source API."""
    all_entities = {}
    for i in range(0, len(ids), 50):
        chunk = ids[i:i+50]
        r = session.get(SOURCE_API, params={
            "action": "wbgetentities",
            "ids":    "|".join(chunk),
            "format": "json",
        })
        data = r.json()
        if "entities" in data:
            all_entities.update(data["entities"])
        time.sleep(0.3)
    return all_entities


# ---------------------------------------------------------------------------
# Check what already exists on production
# ---------------------------------------------------------------------------

def get_production_existing(ids):
    """Return set of IDs that already exist (non-missing) on production."""
    existing = set()
    for i in range(0, len(ids), 50):
        chunk = ids[i:i+50]
        r = session.get(TARGET_API, params={
            "action": "wbgetentities",
            "ids":    "|".join(chunk),
            "format": "json",
            "props":  "info",
        })
        data = r.json()
        for eid, edata in data.get("entities", {}).items():
            if "missing" not in edata:
                existing.add(eid)
        time.sleep(0.2)
    return existing


# ---------------------------------------------------------------------------
# Clean entity data (strip source-specific fields)
# ---------------------------------------------------------------------------

def clean_claims(claims):
    cleaned = {}
    for prop, statements in claims.items():
        cleaned_stmts = []
        for stmt in statements:
            s = {
                "type":     "statement",
                "rank":     stmt.get("rank", "normal"),
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
    return {k: v for k, v in snak.items() if k != "hash"}


# ---------------------------------------------------------------------------
# Upsert helpers
# ---------------------------------------------------------------------------

def upsert_property(pid, entity, token, exists):
    data = {
        "labels":       entity.get("labels", {}),
        "descriptions": entity.get("descriptions", {}),
        "aliases":      entity.get("aliases", {}),
        "datatype":     entity["datatype"],
    }
    params = {
        "action": "wbeditentity",
        "data":   json.dumps(data),
        "token":  token,
        "format": "json",
    }
    if exists:
        params["id"] = pid
    else:
        params["new"] = "property"
    r = session.post(TARGET_API, data=params)
    return r.json()


def upsert_item_stub(qid, entity, token, exists):
    """Upsert item with labels/descriptions/aliases only (no statements)."""
    data = {
        "labels":       entity.get("labels", {}),
        "descriptions": entity.get("descriptions", {}),
        "aliases":      entity.get("aliases", {}),
    }
    params = {
        "action": "wbeditentity",
        "data":   json.dumps(data),
        "token":  token,
        "format": "json",
    }
    if exists:
        params["id"] = qid
    else:
        params["new"] = "item"
    r = session.post(TARGET_API, data=params)
    return r.json()


def replace_claims_on_item(qid, entity, token):
    """Replace all statements on an existing item, preserving labels/descriptions.

    Uses clear=1 to wipe existing statements, but includes labels/descriptions/aliases
    in the same call so they are not lost.
    """
    claims = entity.get("claims", {})
    if not claims:
        return {"skipped": True}
    data = {
        "labels":       entity.get("labels", {}),
        "descriptions": entity.get("descriptions", {}),
        "aliases":      entity.get("aliases", {}),
        "claims":       clean_claims(claims),
    }
    r = session.post(TARGET_API, data={
        "action": "wbeditentity",
        "id":     qid,
        "data":   json.dumps(data),
        "token":  token,
        "format": "json",
        "clear":  "1",  # wipe existing entity then apply data above atomically
    })
    return r.json()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    login()
    token = get_token()

    # ---- Step 1: Properties ----
    print("\n=== Upserting properties P1-P12 on production ===")
    source_props    = fetch_entities(PROP_IDS)
    existing_props  = get_production_existing(PROP_IDS)
    print(f"  {len(existing_props)} of {len(PROP_IDS)} already exist on production")

    for pid in PROP_IDS:
        entity = source_props.get(pid)
        if not entity or "missing" in entity:
            print(f"  {pid}: not found on localhost, skipping")
            continue

        exists = pid in existing_props
        result = upsert_property(pid, entity, token, exists)
        token  = get_token()

        if "error" in result:
            print(f"  {pid} ERROR: {result['error']}")
        else:
            new_id = result.get("entity", {}).get("id", "?")
            label  = entity.get("labels", {}).get("en", {}).get("value", pid)
            action = "updated" if exists else "created"
            print(f"  {pid} -> {new_id}  ({label}) [{action}]")
        time.sleep(0.2)

    # ---- Step 2: Item stubs ----
    print("\n=== Upserting item stubs Q1-Q192 on production ===")
    source_items   = fetch_entities(ITEM_IDS)
    existing_items = get_production_existing(ITEM_IDS)
    print(f"  {len(existing_items)} of {len(ITEM_IDS)} already exist on production")

    item_claims = {}

    for qid in ITEM_IDS:
        entity = source_items.get(qid)
        if not entity or "missing" in entity:
            print(f"  {qid}: not found on localhost, skipping")
            continue

        item_claims[qid] = entity.get("claims", {})

        exists = qid in existing_items
        result = upsert_item_stub(qid, entity, token, exists)
        token  = get_token()

        if "error" in result:
            print(f"  {qid} ERROR: {result['error']}")
        else:
            new_id = result.get("entity", {}).get("id", "?")
            label  = entity.get("labels", {}).get("en", {}).get("value", qid)
            action = "updated" if exists else "created"
            print(f"  {qid} -> {new_id}  ({label}) [{action}]")
        time.sleep(0.2)

    # ---- Step 3: Statements ----
    print("\n=== Replacing statements on items ===")
    for qid in ITEM_IDS:
        entity = source_items.get(qid)
        if not entity or "missing" in entity:
            continue
        claims = entity.get("claims", {})
        if not claims:
            continue

        result = replace_claims_on_item(qid, entity, token)
        token  = get_token()

        if result.get("skipped"):
            continue
        label = entity.get("labels", {}).get("en", {}).get("value", qid)
        if "error" in result:
            print(f"  {qid} ({label}) ERROR: {result['error']}")
        else:
            print(f"  {qid} ({label}) - statements updated")
        time.sleep(0.2)

    print("\n=== Push to production complete ===")


if __name__ == "__main__":
    main()
