from wikibaseintegrator import WikibaseIntegrator, wbi_login
from wikibaseintegrator.wbi_config import config as wbi_config
wbi_config['MEDIAWIKI_API_URL'] = 'http://localhost:8080/api.php'
wbi_config['WIKIBASE_URL'] = 'http://localhost:8080'
login = wbi_login.Login(user='admin', password='adminpass123!')
wbi = WikibaseIntegrator(login=login)

for qid in ['Q249', 'Q252']:
    item = wbi.item.get(qid)
    label = item.labels.get('en').value
    desc = item.descriptions.get('en').value
    claims = item.claims.get('P18')
    if claims:
        text = claims[0].mainsnak.datavalue['value']['text']
        print(f'{qid} {label}: desc={len(desc)} chars, definition={len(text)} chars')
        print(f'  Definition preview: {text[:100]}...')
    else:
        print(f'{qid} {label}: no P18 definition claim found')
