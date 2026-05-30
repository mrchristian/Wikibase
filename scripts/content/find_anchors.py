import re

with open(r'C:\Wikibase\pages\wikibase-20260508122004.xml', encoding='utf-8') as f:
    content = f.read()

results = {'wikilink': set(), 'external': set(), 'span-id': set()}

# Wikilinks with anchors: [[Page#anchor]] or [[Page#anchor|label]] or [[#anchor]]
for m in re.finditer(r'\[\[([^\]]*?#[^\]|]*)', content):
    val = m.group(1).strip()
    # Skip pure footnote reference noise (#fn:r123)
    if not re.match(r'^#fn:r\d+$', val):
        results['wikilink'].add(val)

# External links with anchors: [https://...#anchor ...]
for m in re.finditer(r'\[(https?://[^\s\]]*#[^\s\]]+)', content):
    results['external'].add(m.group(1).strip())

# Span id anchor definitions — stored as HTML entities in MediaWiki XML
for m in re.finditer(r'&lt;span id=["\']([^"\']*)["\']', content):
    results['span-id'].add(m.group(1))

with open(r'C:\Wikibase\all-anchor-links.txt', 'w', encoding='utf-8') as f:
    for t, items in results.items():
        sorted_items = sorted(items)
        f.write(f'\n=== {t} ({len(sorted_items)}) ===\n')
        for i in sorted_items:
            f.write(i + '\n')
        print(f'\n=== {t} ({len(sorted_items)}) ===')
        for i in sorted_items:
            print(i)

print('\nSaved to all-anchor-links.txt')
