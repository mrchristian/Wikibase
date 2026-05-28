#!/usr/bin/env python3
"""
upload_to_wikibase.py
Upload IPCC Glossary XML terms to a Wikibase instance.

Workflow:
  1. Run once with PROP_PART_OF unset → creates the property, prints its ID,
     then exits.
  2. Add that ID to .env (or set it below), then run again to upload items.

Usage:
  python upload_to_wikibase.py              # full upload
  DRY_RUN=true python upload_to_wikibase.py # dry run (no writes)
"""

import os
import sys
import json
import xml.etree.ElementTree as ET
from pathlib import Path

# ── Optional .env loading ──────────────────────────────────────────────────────
try:
    from dotenv import load_dotenv
    # Walk up to find .env at repository root
    _env_path = Path(__file__).resolve().parent
    while _env_path != _env_path.parent:
        if (_env_path / '.env').exists():
            load_dotenv(_env_path / '.env')
            break
        _env_path = _env_path.parent
except ImportError:
    pass  # python-dotenv not installed; rely on env vars or defaults below

try:
    from wikibaseintegrator import WikibaseIntegrator, wbi_login
    from wikibaseintegrator.wbi_config import config as wbi_config
    from wikibaseintegrator import datatypes as wbi_datatypes
    from wikibaseintegrator.models import Qualifiers, References, Reference
    from wikibaseintegrator.wbi_enums import ActionIfExists
except ImportError:
    sys.exit(
        "wikibaseintegrator not found.\n"
        "Install it with:  pip install wikibaseintegrator\n"
    )

# ── Configuration ──────────────────────────────────────────────────────────────
# Override any of these via environment variables or .env

WIKIBASE_URL = os.getenv("WIKIBASE_URL", "http://localhost:8080")
MW_API_URL   = os.getenv("MW_API_URL",   f"{WIKIBASE_URL}/api.php")
SPARQL_URL   = os.getenv("SPARQL_URL",   "http://localhost:9999/bigdata/sparql")
WB_USER      = os.getenv("WB_USER",      "admin")
WB_PASSWORD  = os.getenv("WB_PASSWORD",  "")

# Property IDs — leave blank to auto-create on first run.
# After creation, set these from the printed output or store in .env:
#   PROP_INSTANCE_OF=P1
#   PROP_PART_OF=P2
#   PROP_SOURCE_VERSION=P3
#   PROP_REFERENCE_URL=P4
#   PROP_DATE_ACCESSED=P5
#   PROP_HAS_TAG=P6  (defaults to P12 — the existing Has Tag property)
PROP_INSTANCE_OF    = os.getenv("PROP_INSTANCE_OF",    "")
PROP_PART_OF        = os.getenv("PROP_PART_OF",        "")
PROP_SOURCE_VERSION = os.getenv("PROP_SOURCE_VERSION", "")
PROP_REFERENCE_URL  = os.getenv("PROP_REFERENCE_URL",  "")
PROP_DATE_ACCESSED  = os.getenv("PROP_DATE_ACCESSED",  "")
PROP_DEFINITION     = os.getenv("PROP_DEFINITION",     "")
PROP_HAS_TAG        = os.getenv("PROP_HAS_TAG",        "P12")

# QID for the 'Category' item — target of every 'instance of' statement.
INSTANCE_OF_QID = os.getenv("INSTANCE_OF_QID", "Q1")

DRY_RUN  = os.getenv("DRY_RUN", "false").lower() == "true"
XML_PATH = Path(__file__).parent / "outputs" / "glossary.xml"
# Set LIMIT to a positive integer to process only the first N terms (for test runs).
LIMIT    = int(os.getenv("LIMIT", "0"))   # 0 = no limit


# ── Wikibase connection ────────────────────────────────────────────────────────

def connect() -> WikibaseIntegrator:
    wbi_config["MEDIAWIKI_API_URL"]   = MW_API_URL
    wbi_config["SPARQL_ENDPOINT_URL"] = SPARQL_URL
    wbi_config["WIKIBASE_URL"]        = WIKIBASE_URL
    login = wbi_login.Login(user=WB_USER, password=WB_PASSWORD)
    return WikibaseIntegrator(login=login)


# ── Property setup ─────────────────────────────────────────────────────────────

def setup_properties(wbi: WikibaseIntegrator, existing: dict) -> dict:
    """Create any missing properties and return {name: pid} for newly created ones."""
    prop_defs = [
        ("instance of",              "wikibase-item",  "Class or type this item is an instance of"),
        ("part of series",           "wikibase-item",  "IPCC report series this term appears in"),
        ("source version",           "string",         "Title and version of the source dataset"),
        ("reference URL",            "url",            "URL of the source reference"),
        ("date accessed",            "time",           "Date the source was accessed"),
        ("Definition", "monolingualtext", "Full IPCC glossary definition text"),
    ]
    created = {}
    for label, datatype, description in prop_defs:
        if existing.get(label):
            continue  # already configured — skip
        prop = wbi.property.new()
        prop.labels.set(language="en", value=label)
        prop.descriptions.set(language="en", value=description)
        prop.datatype = datatype
        result = prop.write()
        created[label] = result.id
        print(f"  Created property '{label}': {result.id}")
    return created


# ── XML parsing ────────────────────────────────────────────────────────────────

def parse_xml(xml_path: Path) -> tuple[dict, list[dict]]:
    """Parse glossary XML; return (metadata, terms)."""
    tree = ET.parse(xml_path)
    root = tree.getroot()

    meta_el = root.find("metadata")
    title   = (meta_el.findtext("title")   or "").strip()
    version = (meta_el.findtext("version") or "").strip()
    source  = (meta_el.findtext("source")  or "").strip()
    date    = (meta_el.findtext("date")    or "").strip()
    metadata = {
        "source_version": f"{title} {version}".strip(),
        "source_url":     source,
        # Convert YYYY-MM-DD → Wikibase time format (+YYYY-MM-DDT00:00:00Z)
        "date_accessed":  f"+{date}T00:00:00Z" if date else "",
    }

    terms = []
    for term_el in root.find("terms"):
        name       = (term_el.findtext("name")          or "").strip()
        aka        = (term_el.findtext("also_known_as")  or "").strip()
        definition = (term_el.findtext("definition")     or "").strip()
        series = [
            {"qid": ref.get("qid"), "label": (ref.text or "").strip()}
            for ref in term_el.findall(".//series_ref")
        ]
        terms.append({
            "id":            term_el.get("id"),
            "name":          name,
            "also_known_as": aka,
            "definition":    definition,
            "series":        series,
        })
    return metadata, terms


# ── Item upload ────────────────────────────────────────────────────────────────

def upload_term(
    wbi: WikibaseIntegrator,
    term: dict,
    metadata: dict,
    prop_instance_of: str,
    prop_part_of: str,
    prop_source_version: str,
    prop_reference_url: str,
    prop_date_accessed: str,
    prop_definition: str = "",
) -> str | None:
    """Create a new Wikibase item for a glossary term. Returns QID or None."""
    item = wbi.item.new()

    item.labels.set(language="en", value=term["name"])
    item.descriptions.set(language="en", value=f"Subject, term, tag: {term['name']}")

    # Alias — only if it differs from the label
    if term["also_known_as"] and term["also_known_as"] != term["name"]:
        item.aliases.set(language="en", values=[term["also_known_as"]])

    claims = []

    # instance of: Category (Q1)
    #   qualifier  — source version: "IPCC Glossary v1.5"
    #   reference  — reference URL + date accessed
    if prop_instance_of:
        qualifiers = Qualifiers()
        if prop_source_version and metadata["source_version"]:
            qualifiers.add(
                wbi_datatypes.String(
                    prop_nr=prop_source_version,
                    value=metadata["source_version"],
                )
            )

        references = References()
        ref = Reference()
        if prop_reference_url and metadata["source_url"]:
            ref.add(wbi_datatypes.URL(
                prop_nr=prop_reference_url,
                value=metadata["source_url"],
            ))
        if prop_date_accessed and metadata["date_accessed"]:
            ref.add(wbi_datatypes.Time(
                prop_nr=prop_date_accessed,
                time=metadata["date_accessed"],
                precision=11,   # day
                timezone=0,
                before=0,
                after=0,
                calendarmodel="http://www.wikidata.org/entity/Q1985727",
            ))
        if ref.snaks:
            references.add(ref)

        claims.append(
            wbi_datatypes.Item(
                prop_nr=prop_instance_of,
                value=INSTANCE_OF_QID,
                qualifiers=qualifiers,
                references=references,
            )
        )

    # Part-of-series statements
    if prop_part_of:
        for series in term["series"]:
            qid = (series.get("qid") or "").strip()
            if qid:
                claims.append(
                    wbi_datatypes.Item(prop_nr=prop_part_of, value=qid)
                )

    # IPCC definition
    if prop_definition and term["definition"]:
        qualifiers = Qualifiers()
        if prop_source_version and metadata["source_version"]:
            qualifiers.add(
                wbi_datatypes.String(
                    prop_nr=prop_source_version,
                    value=metadata["source_version"],
                )
            )

        references = References()
        ref = Reference()
        if prop_reference_url and metadata["source_url"]:
            ref.add(wbi_datatypes.URL(
                prop_nr=prop_reference_url,
                value=metadata["source_url"],
            ))
        if prop_date_accessed and metadata["date_accessed"]:
            ref.add(wbi_datatypes.Time(
                prop_nr=prop_date_accessed,
                time=metadata["date_accessed"],
                precision=11,
                timezone=0,
                before=0,
                after=0,
                calendarmodel="http://www.wikidata.org/entity/Q1985727",
            ))
        if ref.snaks:
            references.add(ref)

        claims.append(
            wbi_datatypes.MonolingualText(
                prop_nr=prop_definition,
                text=term["definition"],
                language="en",
                qualifiers=qualifiers,
                references=references,
            )
        )

    if claims:
        item.claims.add(claims)

    if DRY_RUN:
        return None

    result = item.write()
    return result.id


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    print(f"{'[DRY RUN] ' if DRY_RUN else ''}Connecting to {WIKIBASE_URL} …")

    wbi = connect()
    print("Connected.\n")

    # ── Step 1: property setup ─────────────────────────────────────────────────
    existing_props = {
        "instance of":                 PROP_INSTANCE_OF,
        "part of series":              PROP_PART_OF,
        "source version":              PROP_SOURCE_VERSION,
        "reference URL":               PROP_REFERENCE_URL,
        "date accessed":               PROP_DATE_ACCESSED,
        "Definition": PROP_DEFINITION,
    }
    env_map = {
        "instance of":                 "PROP_INSTANCE_OF",
        "part of series":              "PROP_PART_OF",
        "source version":              "PROP_SOURCE_VERSION",
        "reference URL":               "PROP_REFERENCE_URL",
        "date accessed":               "PROP_DATE_ACCESSED",
        "Definition": "PROP_DEFINITION",
    }
    if not all(existing_props.values()):
        print("Some property IDs not configured — creating missing properties now …\n")
        created = setup_properties(wbi, existing_props)
        if created:
            print(
                "\nProperties created. Add the following to your .env file "
                "(or set as environment variables) and re-run:"
            )
            for label, pid in created.items():
                print(f"  {env_map[label]}={pid}")
            print("\n  # PROP_HAS_TAG defaults to P12 (existing property)")
        return

    prop_instance_of    = PROP_INSTANCE_OF
    prop_part_of        = PROP_PART_OF
    prop_source_version = PROP_SOURCE_VERSION
    prop_reference_url  = PROP_REFERENCE_URL
    prop_date_accessed  = PROP_DATE_ACCESSED
    prop_definition     = PROP_DEFINITION

    # ── Step 2: parse XML ──────────────────────────────────────────────────────
    print(f"Parsing {XML_PATH} …")
    metadata, terms = parse_xml(XML_PATH)
    print(f"Found {len(terms)} terms.")
    print(f"Source  : {metadata['source_version']}")
    print(f"URL     : {metadata['source_url']}")
    print(f"Date    : {metadata['date_accessed']}")
    if LIMIT:
        terms = terms[:LIMIT]
        print(f"LIMIT   : processing first {LIMIT} terms\n")
    else:
        print()

    # ── Step 3: upload ────────────────────────────────────────────────────────
    uploaded: list[dict] = []
    failed:   list[dict] = []
    total = len(terms)

    for i, term in enumerate(terms, 1):
        try:
            qid = upload_term(
                wbi, term, metadata,
                prop_instance_of, prop_part_of,
                prop_source_version, prop_reference_url, prop_date_accessed,
                prop_definition,
            )
            label = "[DRY RUN]" if DRY_RUN else qid
            uploaded.append({"term": term["name"], "qid": qid, "series": [s["qid"] for s in term["series"]]})
            print(f"[{i:>4}/{total}] ✓  {term['name']}  →  {label}")
        except Exception as exc:
            failed.append({"term": term["name"], "error": str(exc)})
            print(f"[{i:>4}/{total}] ✗  {term['name']}  ERROR: {exc}")

    # ── Summary ────────────────────────────────────────────────────────────────
    print(f"\n── Summary {'(DRY RUN) ' if DRY_RUN else ''}────────────────────────")
    print(f"  Terms uploaded : {len(uploaded)}")
    print(f"  Terms failed   : {len(failed)}")

    if failed:
        print("\nFailed terms:")
        for f in failed:
            print(f"  • {f['term']}: {f['error']}")

    # Save results log
    log_path = Path(__file__).parent / "outputs" / "upload_log.json"
    with open(log_path, "w", encoding="utf-8") as fh:
        json.dump(
            {"uploaded": uploaded, "failed": failed},
            fh, indent=2, ensure_ascii=False,
        )
    print(f"\nResults saved to {log_path}")


if __name__ == "__main__":
    main()
