"""
Export a complete QID/label/series log for all uploaded glossary terms.
Uses the MediaWiki Wikibase API directly (not SPARQL) so results are always
current regardless of WDQS indexing state.
Writes outputs/upload_log_full.json and outputs/upload_log_full.csv
"""
import csv
import json
import requests
from pathlib import Path
from dotenv import dotenv_values

env = dotenv_values(Path(__file__).parent.parent.parent / ".env")

MW_API      = "http://localhost:8080/api.php"
WB_USER     = env.get("WB_USER", "admin")
WB_PASSWORD = env.get("WB_PASSWORD", "")

PROP_INSTANCE_OF = env.get("PROP_INSTANCE_OF", "P1")
PROP_PART_OF     = env.get("PROP_PART_OF",     "P3")
INSTANCE_OF_QID  = "Q1"

session = requests.Session()

# ── Login ─────────────────────────────────────────────────────────────────────
def login():
    token_r = session.get(MW_API, params={"action": "query", "meta": "tokens", "type": "login", "format": "json"})
    token = token_r.json()["query"]["tokens"]["logintoken"]
    session.post(MW_API, data={"action": "login", "lgname": WB_USER, "lgpassword": WB_PASSWORD, "lgtoken": token, "format": "json"})

login()
print("Logged in.\n")

# ── Fetch all item QIDs in namespace 120 ──────────────────────────────────────
print("Fetching all item QIDs …")
qids = []
cont = None
while True:
    params = {"action": "query", "list": "allpages", "apnamespace": "120", "aplimit": "500", "format": "json"}
    if cont:
        params["apcontinue"] = cont
    r = session.get(MW_API, params=params)
    batch = r.json()["query"]["allpages"]
    qids.extend(p["title"].replace("Item:", "") for p in batch)
    cont = r.json().get("continue", {}).get("apcontinue")
    if not cont:
        break

print(f"Found {len(qids)} items total.\n")

# ── Fetch entity details in batches of 50 ────────────────────────────────────
print("Fetching entity details …")

def fetch_entities(ids):
    r = session.get(MW_API, params={
        "action": "wbgetentities",
        "ids": "|".join(ids),
        "props": "labels|claims",
        "languages": "en",
        "format": "json",
    })
    return r.json().get("entities", {})

records = []
BATCH = 50
for i in range(0, len(qids), BATCH):
    batch_ids = qids[i:i + BATCH]
    entities  = fetch_entities(batch_ids)
    for qid, entity in entities.items():
        if entity.get("missing"):
            continue
        label = entity.get("labels", {}).get("en", {}).get("value", "")
        claims = entity.get("claims", {})

        # Only include items that are "instance of" Q1 (glossary terms)
        instance_claims = claims.get(PROP_INSTANCE_OF, [])
        if not any(
            c.get("mainsnak", {}).get("datavalue", {}).get("value", {}).get("id") == INSTANCE_OF_QID
            for c in instance_claims
        ):
            continue

        # Collect series QIDs / labels
        part_of_claims = claims.get(PROP_PART_OF, [])
        series_qids  = [c["mainsnak"]["datavalue"]["value"]["id"] for c in part_of_claims if "datavalue" in c["mainsnak"]]
        records.append({"qid": qid, "term": label, "series": "; ".join(series_qids)})

    if (i // BATCH + 1) % 5 == 0 or i + BATCH >= len(qids):
        print(f"  Processed {min(i + BATCH, len(qids))}/{len(qids)} items, {len(records)} glossary terms so far …")

print(f"\nGlossary terms found: {len(records)}")

# Sort by QID numerically
records.sort(key=lambda x: int(x["qid"].lstrip("Q")))

# ── Write JSON ────────────────────────────────────────────────────────────────
out_dir  = Path(__file__).parent / "outputs"
out_dir.mkdir(exist_ok=True)

json_path = out_dir / "upload_log_full.json"
with open(json_path, "w", encoding="utf-8") as fh:
    json.dump(records, fh, indent=2, ensure_ascii=False)
print(f"JSON saved  → {json_path}")

# ── Write CSV ─────────────────────────────────────────────────────────────────
csv_path = out_dir / "upload_log_full.csv"
with open(csv_path, "w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=["qid", "term", "series"])
    writer.writeheader()
    writer.writerows(records)
print(f"CSV saved   → {csv_path}")
