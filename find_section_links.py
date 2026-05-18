"""
Find all wikilinks of the pattern [[Page#anchor|Section N.N]] in a MediaWiki XML dump.
Output is sorted unique links saved to section-links.txt.

Usage:
    python find_section_links.py [input_xml] [output_txt]

Defaults:
    input_xml  = pages/wikibase-20260518-ns0.xml
    output_txt = section-links.txt
"""
import re
import sys

input_xml = sys.argv[1] if len(sys.argv) > 1 else r'pages/wikibase-20260518-ns0.xml'
output_txt = sys.argv[2] if len(sys.argv) > 2 else r'section-links.txt'

print(f'Reading {input_xml} ...')
with open(input_xml, encoding='utf-8') as f:
    content = f.read()

matches = re.findall(r'\[\[[^\]#|]+#[^\]|]+\|Section[^\]]+\]\]', content)
unique = sorted(set(matches))

with open(output_txt, 'w', encoding='utf-8') as f:
    for m in unique:
        f.write(m + '\n')

print(f'Saved {len(unique)} unique links to {output_txt}')
