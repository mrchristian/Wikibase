"""Remove stale 'has tag' (P12) claims from series items where the referenced item no longer exists."""
import requests
from wikibaseintegrator import WikibaseIntegrator, wbi_login
from wikibaseintegrator.wbi_config import config as wbi_config
from wikibaseintegrator.wbi_enums import ActionIfExists

wbi_config['MEDIAWIKI_API_URL'] = 'http://localhost:8080/api.php'
wbi_config['WIKIBASE_URL'] = 'http://localhost:8080'
login = wbi_login.Login(user='admin', password='adminpass123!')
wbi = WikibaseIntegrator(login=login)

API = 'http://localhost:8080/api.php'
PROP_HAS_TAG = 'P12'
# Series items to clean
SERIES_QIDS = ['Q77', 'Q106', 'Q150', 'Q10']

s = requests.Session()
r = s.get(API, params={'action': 'query', 'meta': 'tokens', 'type': 'login', 'format': 'json'})
tok = r.json()['query']['tokens']['logintoken']
s.post(API, data={'action': 'login', 'lgname': 'admin', 'lgpassword': 'adminpass123!', 'lgtoken': tok, 'format': 'json'})

for series_qid in SERIES_QIDS:
    item = wbi.item.get(series_qid)
    has_tag_claims = item.claims.get(PROP_HAS_TAG)
    if not has_tag_claims:
        print(f'{series_qid}: no has tag claims')
        continue

    stale = []
    valid = []
    for claim in has_tag_claims:
        ref_qid = claim.mainsnak.datavalue['value']['id']
        # Check if item exists
        r = s.get(API, params={'action': 'wbgetentities', 'ids': ref_qid, 'props': 'info', 'format': 'json'})
        entity = r.json().get('entities', {}).get(ref_qid, {})
        if entity.get('missing') == '':
            stale.append((claim, ref_qid))
        else:
            valid.append(ref_qid)

    if not stale:
        print(f'{series_qid}: all {len(has_tag_claims)} claims valid')
        continue

    print(f'{series_qid}: removing {len(stale)} stale claims (keeping {len(valid)})')
    for claim, ref_qid in stale:
        claim.remove()

    item.sitelinks.sitelinks.clear()
    item.write()
    print(f'{series_qid}: done')
