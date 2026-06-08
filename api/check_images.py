from bs4 import BeautifulSoup

with open('api/sr15-ch1.html', 'r', encoding='utf-8') as f:
    html = f.read()

soup = BeautifulSoup(html, 'html.parser')
imgs = soup.find_all('img')

print(f'Total images found: {len(imgs)}')
print('\nFirst 5 image sources:')
for i, img in enumerate(imgs[:5], 1):
    src = img.get('src', 'NO SRC ATTRIBUTE')
    print(f'{i}. {src[:150]}')

# Also check for any img tags with data attributes
print('\nImage attributes (first one):')
if imgs:
    for attr, val in imgs[0].attrs.items():
        print(f'  {attr}: {str(val)[:100]}')
