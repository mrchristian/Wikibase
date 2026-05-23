import re

with open(r'c:\Wikibase\pages\ipcc-namespace-export.xml', encoding='utf-8') as f:
    content = f.read()

pages = re.findall(r'<page>', content)
print(f'<page> elements: {len(pages)}')

titles = re.findall(r'<title>([^<]+)</title>', content)
print(f'<title> elements: {len(titles)}')
for t in titles:
    print(' ', t)

anchors = re.findall(r'\[\[[^\]]*#[^\]]+\]\]', content)
print(f'\nAnchor wikilinks in content: {len(anchors)}')
if anchors:
    for a in anchors[:10]:
        print(' ', a)

wg = re.findall(r'Wg[123]:Chapter', content)
print(f'\nOld Wg1/2/3 patterns: {len(wg)}')

ar6 = re.findall(r'AR6/WG[^"<\s]+', content)
print(f'AR6/WGI patterns: {len(ar6)}')
if ar6:
    for a in sorted(set(ar6))[:10]:
        print(' ', a)
