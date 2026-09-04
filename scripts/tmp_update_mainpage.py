#!/usr/bin/env python3
"""One-off helper: publish responsive Main Page content and supporting Common.css to LOCAL wiki."""
import requests

MW_API_URL = "http://localhost:8080/w/api.php"
session = requests.Session()

r = session.get(MW_API_URL, params={"action": "query", "meta": "tokens", "type": "login", "format": "json"})
login_token = r.json()["query"]["tokens"]["logintoken"]

r2 = session.post(MW_API_URL, data={
    "action": "login", "lgname": "admin", "lgpassword": "adminpass123!",
    "lgtoken": login_token, "format": "json",
})
assert r2.json()["login"]["result"] == "Success", r2.json()

r3 = session.get(MW_API_URL, params={"action": "query", "meta": "tokens", "format": "json"})
csrf = r3.json()["query"]["tokens"]["csrftoken"]

MAIN_PAGE_WIKITEXT = """<div class="climatekg-home-intro">
'''ClimateKG''' is a community knowledge graph for climate change science literature.

The IPCC's Sixth Assessment Report (AR6) has been converted into structured data for metadata enrichment, document distribution, and data analysis. ClimateKG is open to policymakers, citizen science projects, and scientists.

'''[[Learn-More|Learn more about ClimateKG]]'''
</div>

<div class="climatekg-home-grid">
<div class="climatekg-home-card">
'''Policymakers'''

AR6 has been made browsable and machine accessible via APIs as common document formats.

'''[[IPCC:AR6|Browse IPCC AR6]]'''
</div>

<div class="climatekg-home-card">
'''Citizen science'''

A global youth citizen science programme is in place with our partners #semanticClimate, as Chapter Champions, Hackathons, and for Wikidata contributions.

'''[[Citizen-Science|Browse projects]]'''
</div>

<div class="climatekg-home-card">
'''Scientists'''

AR6 is available as datasets using SPARQL, APIs, and XML. Use or contribute data using Wikibase and our Data Bench community space.

'''[[IPCC-Data|Access Data]]'''
</div>
</div>
"""

CSS_START = "/* climatekg-home-layout:start */"
CSS_END = "/* climatekg-home-layout:end */"
HOME_LAYOUT_CSS = """/* climatekg-home-layout:start */
.climatekg-home-intro {
    margin: 0 0 1.5rem 0;
}

.climatekg-home-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 1rem;
    margin: 0 0 1.5rem 0;
}

.climatekg-home-card {
    padding: 0.85rem;
    border: none;
    border-radius: 6px;
    background: transparent;
    box-sizing: border-box;
}

@media (max-width: 900px) {
    .climatekg-home-grid {
        grid-template-columns: 1fr;
    }
}
/* climatekg-home-layout:end */
"""


def upsert_css_block(css_text):
        start_idx = css_text.find(CSS_START)
        end_idx = css_text.find(CSS_END)
        if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
                end_idx += len(CSS_END)
                return css_text[:start_idx].rstrip() + "\n\n" + HOME_LAYOUT_CSS.strip() + "\n"
        return css_text.rstrip() + "\n\n" + HOME_LAYOUT_CSS.strip() + "\n"


def fetch_page_text(title):
        response = session.get(MW_API_URL, params={
                "action": "query",
                "format": "json",
                "prop": "revisions",
                "titles": title,
                "rvslots": "main",
                "rvprop": "content",
        })
        pages = response.json()["query"]["pages"]
        page = next(iter(pages.values()))
        revisions = page.get("revisions", [])
        if not revisions:
                return ""
        return revisions[0]["slots"]["main"].get("*", "")

r4 = session.post(MW_API_URL, data={
    "action": "edit", "title": "Main Page", "text": MAIN_PAGE_WIKITEXT,
    "summary": "Main Page layout: responsive 3-column desktop, stacked mobile",
    "token": csrf, "format": "json", "bot": 1,
})

current_css = fetch_page_text("MediaWiki:Common.css")
updated_css = upsert_css_block(current_css)

r5 = session.post(MW_API_URL, data={
    "action": "edit", "title": "MediaWiki:Common.css", "text": updated_css,
    "summary": "Main Page responsive grid styles: no blue background, increased card padding",
    "token": csrf, "format": "json", "bot": 1,
})
print("Main Page edit:", r4.json())
print("Common.css edit:", r5.json())
