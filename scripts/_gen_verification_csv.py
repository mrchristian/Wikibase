import csv, os, time, requests

API        = "http://localhost:8080/w/api.php"
SPARQL     = "http://localhost:9999/bigdata/namespace/wdq/sparql"
ENTITY_BASE = "http://localhost:8080/entity/"
PROP_BASE   = "http://localhost:8080/prop/direct/"
SITE_ID     = "climatekg-wiki"
OUT         = r"C:\Wikibase\chapter-urls-verification.csv"

pw = None
with open(r"C:\Wikibase\.env", encoding="utf-8") as f:
    for line in f:
        if line.strip().startswith("WB_PASSWORD="):
            pw = line.strip().split("=", 1)[1]
            break

session = requests.Session()
session.headers.update({"User-Agent": "ClimateKG-CSV/1.0"})

r = session.get(API, params={"action": "query", "meta": "tokens", "type": "login", "format": "json"})
lt = r.json()["query"]["tokens"]["logintoken"]
session.post(API, data={"action": "login", "lgname": "admin", "lgpassword": pw, "lgtoken": lt, "format": "json"})

q = f"SELECT ?item WHERE {{ ?item <{PROP_BASE}P1> <{ENTITY_BASE}Q6> . }}"
r = requests.get(SPARQL, params={"query": q, "format": "json"}, headers={"Accept": "application/sparql-results+json"})
qids = sorted([b["item"]["value"].rsplit("/", 1)[-1] for b in r.json()["results"]["bindings"]], key=lambda x: int(x[1:]))

entities = {}
for i in range(0, len(qids), 50):
    chunk = qids[i:i + 50]
    r = session.get(API, params={"action": "wbgetentities", "ids": "|".join(chunk), "props": "sitelinks|claims|labels", "format": "json"})
    entities.update(r.json()["entities"])
    time.sleep(0.2)

with open(OUT, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["QID", "Label", "MediaWiki_Page_Title", "P5_URL"])
    for qid in qids:
        e = entities.get(qid, {})
        label      = e.get("labels", {}).get("en", {}).get("value", "")
        page_title = e.get("sitelinks", {}).get(SITE_ID, {}).get("title", "(no sitelink)")
        p5_claims  = e.get("claims", {}).get("P5", [])
        p5_url     = p5_claims[0]["mainsnak"]["datavalue"]["value"] if p5_claims else "(no P5)"
        w.writerow([qid, label, page_title, p5_url])

print(f"Written {len(qids)} rows -> {OUT}")
