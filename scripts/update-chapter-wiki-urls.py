"""
update-chapter-wiki-urls.py

For all Wikibase items with P1=Q6 (Chapters), replace the P5 (Wiki URL)
with the URL derived from the item's 'climatekg-wiki' sitelink.

Usage (from C:\Wikibase):
    python scripts/update-chapter-wiki-urls.py [--env local|dev|test|prod] [--dry-run]

Credentials are read from the environment (same vars used by sync scripts):
    LOCAL_MW_ADMIN_PASS
    DEV_MW_ADMIN_PASS
    TEST_MW_ADMIN_PASS
    PROD_MW_ADMIN_PASS

If the variable is not set, falls back to reading C:\Wikibase\.env, then
prompts interactively as a last resort.

Example:
    python scripts/update-chapter-wiki-urls.py --env local --dry-run
    python scripts/update-chapter-wiki-urls.py --env local
"""

import argparse
import json
import os
import sys
import time

import requests

# ---------------------------------------------------------------------------
# Per-environment configuration
# ---------------------------------------------------------------------------

ENV_CONFIG = {
    "local": {
        "api_url":     "http://localhost:8080/w/api.php",
        "sparql_url":  "http://localhost:9999/bigdata/namespace/wdq/sparql",
        "entity_base": "http://localhost:8080/entity/",
        "prop_base":   "http://localhost:8080/prop/direct/",
        "wiki_base":   "http://localhost:8080",
        "password_env": "WB_PASSWORD",
        "username":    "admin",
    },
    "dev": {
        "api_url":     "https://dev-climatekg.semanticclimate.org/w/api.php",
        "sparql_url":  "https://dev-climatekg.semanticclimate.org/query/proxy/sparql",
        "entity_base": "https://dev-climatekg.semanticclimate.org/entity/",
        "prop_base":   "https://dev-climatekg.semanticclimate.org/prop/direct/",
        "wiki_base":   "https://dev-climatekg.semanticclimate.org",
        "password_env": "DEV_MW_ADMIN_PASS",
        "username":    "admin",
    },
    "test": {
        "api_url":     "https://test-climatekg.semanticclimate.org/w/api.php",
        "sparql_url":  "https://test-climatekg.semanticclimate.org/query/proxy/sparql",
        "entity_base": "https://test-climatekg.semanticclimate.org/entity/",
        "prop_base":   "https://test-climatekg.semanticclimate.org/prop/direct/",
        "wiki_base":   "https://test-climatekg.semanticclimate.org",
        "password_env": "TEST_MW_ADMIN_PASS",
        "username":    "admin",
    },
    "prod": {
        "api_url":     "https://prod-climatekg.semanticclimate.org/w/api.php",
        "sparql_url":  "https://prod-climatekg.semanticclimate.org/query/proxy/sparql",
        "entity_base": "https://prod-climatekg.semanticclimate.org/entity/",
        "prop_base":   "https://prod-climatekg.semanticclimate.org/prop/direct/",
        "wiki_base":   "https://prod-climatekg.semanticclimate.org",
        "password_env": "PROD_MW_ADMIN_PASS",
        "username":    "admin",
    },
}

SITE_ID = "climatekg-wiki"


# ---------------------------------------------------------------------------
# Credential helper
# ---------------------------------------------------------------------------

def get_password(env_var, env_file="C:\\Wikibase\\.env"):
    """Return password from env var, .env file, or interactive prompt."""
    val = os.environ.get(env_var)
    if val:
        return val

    # Try reading C:\Wikibase\.env
    if os.path.isfile(env_file):
        with open(env_file, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                if key.strip() == env_var:
                    return value.strip()

    # Interactive fallback
    import getpass
    print(f"[warn] {env_var} not found in environment or .env file.")
    return getpass.getpass(f"Enter password for {env_var}: ")


# ---------------------------------------------------------------------------
# Auth helpers  (same pattern as migrate_wikibase.py)
# ---------------------------------------------------------------------------

def login(session, api_url, username, password):
    r = session.get(api_url, params={
        "action": "query", "meta": "tokens", "type": "login", "format": "json"
    })
    r.raise_for_status()
    login_token = r.json()["query"]["tokens"]["logintoken"]

    r = session.post(api_url, data={
        "action":    "login",
        "lgname":    username,
        "lgpassword": password,
        "lgtoken":   login_token,
        "format":    "json",
    })
    r.raise_for_status()
    result = r.json()["login"]["result"]
    if result != "Success":
        print(f"[error] Login failed: {result}")
        sys.exit(1)
    print(f"[info]  Logged in as '{username}' on {api_url}")


def get_csrf_token(session, api_url):
    r = session.get(api_url, params={
        "action": "query", "meta": "tokens", "format": "json"
    })
    r.raise_for_status()
    return r.json()["query"]["tokens"]["csrftoken"]


# ---------------------------------------------------------------------------
# Step 1 — SPARQL: find all QIDs where P1 = Q6
# ---------------------------------------------------------------------------

def get_chapter_qids(sparql_url, prop_base, entity_base):
    """Query SPARQL for all items where P1 = Q6. Returns a list of QID strings."""
    p1_uri = prop_base + "P1"
    q6_uri = entity_base + "Q6"

    query = f"""
SELECT ?item WHERE {{
  ?item <{p1_uri}> <{q6_uri}> .
}}
"""
    r = requests.get(sparql_url, params={"query": query, "format": "json"},
                     headers={"Accept": "application/sparql-results+json"})
    r.raise_for_status()
    bindings = r.json()["results"]["bindings"]
    qids = []
    for b in bindings:
        uri = b["item"]["value"]
        qid = uri.rsplit("/", 1)[-1]   # e.g. "Q21"
        qids.append(qid)
    return sorted(qids, key=lambda q: int(q[1:]))


# ---------------------------------------------------------------------------
# Step 2 — API: fetch sitelinks + P5 claims in batches of 50
# ---------------------------------------------------------------------------

def fetch_entities(session, api_url, qids):
    """Fetch sitelinks and claims for a list of QIDs. Returns dict keyed by QID."""
    all_entities = {}
    for i in range(0, len(qids), 50):
        chunk = qids[i:i + 50]
        r = session.get(api_url, params={
            "action": "wbgetentities",
            "ids":    "|".join(chunk),
            "props":  "sitelinks|claims|labels",
            "format": "json",
        })
        r.raise_for_status()
        data = r.json()
        if "entities" in data:
            all_entities.update(data["entities"])
        time.sleep(0.2)
    return all_entities


# ---------------------------------------------------------------------------
# Step 3 — For each item: compute new URL from sitelink
# ---------------------------------------------------------------------------

def build_new_url_from_entity(entity, site_id, wiki_base):
    """
    Return the new P5 URL built from the climatekg-wiki sitelink title.
    Constructs the URL as: {wiki_base}/wiki/{title} (spaces -> underscores).
    Returns None if the item has no sitelink for site_id.
    """
    sitelinks = entity.get("sitelinks", {})
    if site_id not in sitelinks:
        return None
    title = sitelinks[site_id]["title"].replace(" ", "_")
    return f"{wiki_base}/wiki/{title}"


def get_existing_p5(entity):
    """Return (claim_guid, current_value) for P5, or (None, None) if absent."""
    claims = entity.get("claims", {})
    p5_claims = claims.get("P5", [])
    if not p5_claims:
        return None, None
    # Use the first (and normally only) P5 statement
    stmt = p5_claims[0]
    guid = stmt.get("id")
    try:
        current_val = stmt["mainsnak"]["datavalue"]["value"]
    except (KeyError, TypeError):
        current_val = None
    return guid, current_val


# ---------------------------------------------------------------------------
# Step 4 — Apply the change via MediaWiki API
# ---------------------------------------------------------------------------

def set_claim_value(session, api_url, claim_guid, new_url, token):
    """Update an existing P5 claim to new_url."""
    r = session.post(api_url, data={
        "action":    "wbsetclaimvalue",
        "claim":     claim_guid,
        "snaktype":  "value",
        "value":     json.dumps(new_url),
        "token":     token,
        "format":    "json",
    })
    r.raise_for_status()
    return r.json()


def create_claim(session, api_url, qid, new_url, token):
    """Add a new P5 claim to an item that has none."""
    r = session.post(api_url, data={
        "action":    "wbcreateclaim",
        "entity":    qid,
        "snaktype":  "value",
        "property":  "P5",
        "value":     json.dumps(new_url),
        "token":     token,
        "format":    "json",
    })
    r.raise_for_status()
    return r.json()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Replace P5 (Wiki URL) on Chapter items using sitelink URLs."
    )
    parser.add_argument(
        "--env", choices=list(ENV_CONFIG.keys()), default="local",
        help="Target environment (default: local)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Preview changes without writing to Wikibase"
    )
    args = parser.parse_args()

    cfg = ENV_CONFIG[args.env]
    dry = args.dry_run

    print(f"{'[DRY RUN] ' if dry else ''}Environment: {args.env.upper()}")
    print(f"           API:    {cfg['api_url']}")
    print(f"           SPARQL: {cfg['sparql_url']}")
    print()

    # ------------------------------------------------------------------
    # 1. Get QIDs from SPARQL
    # ------------------------------------------------------------------
    print("[1/4] Querying SPARQL for P1=Q6 items...")
    try:
        qids = get_chapter_qids(cfg["sparql_url"], cfg["prop_base"], cfg["entity_base"])
    except Exception as e:
        print(f"[error] SPARQL query failed: {e}")
        print("        Is the WDQS container running? Try: docker compose ps")
        sys.exit(1)
    print(f"       Found {len(qids)} Chapter items: {', '.join(qids[:5])}{'...' if len(qids) > 5 else ''}")
    if not qids:
        print("[warn] No items found. Check that WDQS is up to date.")
        sys.exit(0)

    # ------------------------------------------------------------------
    # 2. Fetch entity data (sitelinks + claims)
    # ------------------------------------------------------------------
    print(f"\n[2/4] Fetching entity data for {len(qids)} items...")
    if not dry:
        password = get_password(cfg["password_env"])
    else:
        password = get_password(cfg["password_env"])

    session = requests.Session()
    session.headers.update({"User-Agent": "ClimateKG-UpdateChapterURLs/1.0"})

    login(session, cfg["api_url"], cfg["username"], password)
    token = get_csrf_token(session, cfg["api_url"])

    entities = fetch_entities(session, cfg["api_url"], qids)
    print(f"       Fetched {len(entities)} entities.")

    # ------------------------------------------------------------------
    # 3. Plan changes
    # ------------------------------------------------------------------
    print(f"\n[3/4] Planning changes...")

    updates    = []   # (qid, claim_guid_or_None, old_val, new_url, label)
    no_sitelink = []  # QIDs with no climatekg-wiki sitelink
    already_ok  = []  # QIDs where P5 already matches

    for qid in qids:
        entity = entities.get(qid)
        if not entity:
            print(f"  [warn] {qid}: not returned by API, skipping.")
            continue

        label = ""
        if "labels" in entity and "en" in entity["labels"]:
            label = entity["labels"]["en"]["value"]

        new_url = build_new_url_from_entity(entity, SITE_ID, cfg["wiki_base"])
        if new_url is None:
            no_sitelink.append((qid, label))
            continue

        claim_guid, old_val = get_existing_p5(entity)

        if old_val == new_url:
            already_ok.append(qid)
            continue

        updates.append((qid, claim_guid, old_val, new_url, label))

    # Print plan
    print(f"\n  Items to update:         {len(updates)}")
    print(f"  Already correct (skip):  {len(already_ok)}")
    print(f"  No sitelink (skip):      {len(no_sitelink)}")

    if no_sitelink:
        print("\n  Items with no climatekg-wiki sitelink:")
        for qid, label in no_sitelink:
            print(f"    {qid}  {label}")

    if updates:
        print("\n  Planned changes:")
        col_qid   = max(len(u[0]) for u in updates) + 2
        for qid, guid, old_val, new_url, label in updates:
            action = "UPDATE" if guid else "CREATE"
            print(f"    [{action}] {qid:<{col_qid}} {label}")
            print(f"             old: {old_val or '(none)'}")
            print(f"             new: {new_url}")

    if dry or not updates:
        print("\n[dry-run] No changes written." if dry else "\n[info] Nothing to update.")
        return

    # ------------------------------------------------------------------
    # 4. Apply changes
    # ------------------------------------------------------------------
    print(f"\n[4/4] Applying {len(updates)} changes...")
    ok_count = 0
    err_count = 0

    for qid, claim_guid, old_val, new_url, label in updates:
        try:
            # Refresh token periodically
            if ok_count > 0 and ok_count % 20 == 0:
                token = get_csrf_token(session, cfg["api_url"])

            if claim_guid:
                result = set_claim_value(session, cfg["api_url"], claim_guid, new_url, token)
            else:
                result = create_claim(session, cfg["api_url"], qid, new_url, token)

            if "error" in result:
                print(f"  [error] {qid}: {result['error'].get('info', result['error'])}")
                err_count += 1
            else:
                print(f"  [ok]    {qid}  {label}  -> {new_url}")
                ok_count += 1

            time.sleep(0.3)

        except Exception as e:
            print(f"  [error] {qid}: {e}")
            err_count += 1

    print(f"\n[done]  Updated: {ok_count}  Errors: {err_count}  Skipped: {len(already_ok) + len(no_sitelink)}")
    if err_count:
        print("        Re-running the script is safe — it skips items already correct.")


if __name__ == "__main__":
    main()
