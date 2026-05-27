#!/usr/bin/env python3
"""
Quick test conversion: ipccglossary.csv → glossary.xml

Run this to verify the conversion logic before using the full notebook.
"""

import sys
import re
import pandas as pd
import xml.etree.ElementTree as ET
from pathlib import Path

# ── Configuration ─────────────────────────────────────────────────────────────
INPUT_CSV = Path('ipccglossary.csv')
DTD_FILE = Path('glossary.dtd')
OUTPUT_DIR = Path('outputs')
OUTPUT_XML = OUTPUT_DIR / 'glossary.xml'

GLOSSARY_ID = 'IPCC_AR6_Glossary'
GLOSSARY_TITLE = 'IPCC Glossary'
GLOSSARY_VERSION = 'v1.5'
GLOSSARY_SOURCE = 'https://apps.ipcc.ch/glossary/'
GLOSSARY_DATE = '2026-05-27'
GLOSSARY_DESC = 'IPCC Assessment Report Glossary Terms'

SERIES_QID_MAP = {
    'WGI': 'Q77',
    'WGII': 'Q106',
    'WGIII': 'Q150',
    'SR15': 'Q10',
    'SRCCL': 'Q107',
    'SROCC': 'Q108',
    'SYR': 'Q151',
}

print("=" * 70)
print("IPCC Glossary CSV → XML Test Conversion")
print("=" * 70)
print()

# ── Load CSV ──────────────────────────────────────────────────────────────────
print(f"📖 Loading CSV: {INPUT_CSV}")
df_raw = pd.read_csv(INPUT_CSV, dtype=str, skiprows=[1]).fillna('')

# Rename columns
column_mapping = {
    'Series': 'SERIES',
    'Category': 'CATEGORY',
    'Longer term (Also known as)': 'ALSO_KNOWN_AS',
    'Definition (Description)': 'DEFINITION'
}
df = df_raw.rename(columns=column_mapping)

# Remove empty rows
df = df[df['CATEGORY'].str.strip() != '']

print(f"✓ Loaded {len(df)} terms")
print()

# ── Parse series ──────────────────────────────────────────────────────────────
def parse_series(series_str):
    """Parse semicolon-separated series string into list."""
    if not series_str or not series_str.strip():
        return []
    series_list = [s.strip() for s in series_str.split(';')]
    return [s for s in series_list if s]

df['SERIES_LIST'] = df['SERIES'].apply(parse_series)

# Show statistics
all_series = [s for series_list in df['SERIES_LIST'] for s in series_list]
series_counts = pd.Series(all_series).value_counts()
print("📊 Series distribution:")
for series, count in series_counts.items():
    qid = SERIES_QID_MAP.get(series, '???')
    print(f"   {series:8s} ({qid}): {count:3d} terms")
print()

# ── Build XML ─────────────────────────────────────────────────────────────────
print("🔨 Building XML tree...")

root = ET.Element('glossary', id=GLOSSARY_ID)

# Metadata
meta = ET.SubElement(root, 'metadata')
ET.SubElement(meta, 'title').text = GLOSSARY_TITLE
ET.SubElement(meta, 'version').text = GLOSSARY_VERSION
ET.SubElement(meta, 'source').text = GLOSSARY_SOURCE
ET.SubElement(meta, 'date').text = GLOSSARY_DATE
ET.SubElement(meta, 'description').text = GLOSSARY_DESC

# Terms
terms_el = ET.SubElement(root, 'terms')

for idx, row in df.iterrows():
    term_id = f'term_{idx+1:03d}'
    term_el = ET.SubElement(terms_el, 'term', id=term_id)
    
    # Name (required)
    ET.SubElement(term_el, 'name').text = row['CATEGORY']
    
    # Also known as (optional)
    if row['ALSO_KNOWN_AS'].strip():
        ET.SubElement(term_el, 'also_known_as').text = row['ALSO_KNOWN_AS']
    
    # Definition (required)
    ET.SubElement(term_el, 'definition').text = row['DEFINITION']
    
    # Series references
    series_list = row['SERIES_LIST']
    series_el = ET.SubElement(term_el, 'series')
    if series_list:
        for series_code in series_list:
            qid = SERIES_QID_MAP.get(series_code, '')
            if qid:
                series_ref = ET.SubElement(series_el, 'series_ref', qid=qid)
            else:
                series_ref = ET.SubElement(series_el, 'series_ref')
            series_ref.text = series_code
    else:
        # No series - add placeholder
        series_ref = ET.SubElement(series_el, 'series_ref')
        series_ref.text = 'NONE'

# Pretty print
if hasattr(ET, 'indent'):
    ET.indent(root, space='  ')

print(f"✓ Built XML tree with {len(df)} terms")
print()

# ── Write XML ─────────────────────────────────────────────────────────────────
OUTPUT_DIR.mkdir(exist_ok=True)

xml_str = ET.tostring(root, encoding='unicode')
with open(OUTPUT_XML, 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f.write('<!DOCTYPE glossary SYSTEM "glossary.dtd">\n')
    f.write(xml_str)
    f.write('\n<!-- Generated from ipccglossary.csv -->\n')

file_size = OUTPUT_XML.stat().st_size
print(f"💾 Written: {OUTPUT_XML} ({file_size:,} bytes)")
print()

# ── Validation ────────────────────────────────────────────────────────────────
print("🔍 Validation:")

# Well-formedness check
try:
    from lxml import etree as lxml_etree
    tree = lxml_etree.parse(str(OUTPUT_XML))
    print(f"✓ Well-formed XML")
    
    # DTD validation
    if DTD_FILE.exists():
        with open(DTD_FILE, 'r', encoding='utf-8') as f:
            dtd = lxml_etree.DTD(f)
        
        if dtd.validate(tree):
            print(f"✓ Passes DTD validation")
        else:
            print(f"✗ DTD validation errors:")
            for error in dtd.error_log:
                print(f"  Line {error.line}: {error.message}")
except ImportError:
    print("⚠ lxml not available - skipping DTD validation")
    print("  (Install with: pip install lxml)")
except Exception as e:
    print(f"✗ Validation error: {e}")

print()

# ── Sample output ─────────────────────────────────────────────────────────────
print("📄 Sample XML (first 3 terms):")
print("-" * 70)
t = ET.parse(str(OUTPUT_XML))
r = t.getroot()
terms = r.find('terms')
for i, term in enumerate(list(terms)[:3], 1):
    name = term.find('name').text
    series_refs = term.find('series')
    series_list = [s.text for s in series_refs]
    series_str = ' | '.join([f"{s} ({sr.get('qid', '?')})" for sr, s in zip(series_refs, series_list)])
    print(f"{i}. {name}")
    print(f"   Series: {series_str}")

print("-" * 70)
print()
print("✅ Test conversion complete!")
print(f"   Review full output: {OUTPUT_XML}")
print(f"   Next: Open csv_to_xml.ipynb for HTML preview")
