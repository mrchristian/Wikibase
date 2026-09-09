#!/usr/bin/env python3
"""One-off helper: align Main Page row 1 left inset with row 2 card inset."""
import requests

MW_API_URL = "http://localhost:8080/w/api.php"
USERNAME = "admin"
PASSWORD = "adminpass123!"

CSS_START = "/* climatekg-main-page-row1-align:start */"
CSS_END = "/* climatekg-main-page-row1-align:end */"
CSS_BLOCK = """/* climatekg-main-page-row1-align:start */
.page-Main_Page .climatekg-home-intro {
    padding-left: 0.85rem;
    box-sizing: border-box;
}
/* climatekg-main-page-row1-align:end */
"""


def login_and_get_csrf(session: requests.Session) -> str:
    r = session.get(
        MW_API_URL,
        params={"action": "query", "meta": "tokens", "type": "login", "format": "json"},
        timeout=20,
    )
    login_token = r.json()["query"]["tokens"]["logintoken"]

    r = session.post(
        MW_API_URL,
        data={
            "action": "login",
            "lgname": USERNAME,
            "lgpassword": PASSWORD,
            "lgtoken": login_token,
            "format": "json",
        },
        timeout=20,
    )
    result = r.json().get("login", {}).get("result")
    if result != "Success":
        raise RuntimeError(f"Login failed: {r.text}")

    r = session.get(
        MW_API_URL,
        params={"action": "query", "meta": "tokens", "format": "json"},
        timeout=20,
    )
    return r.json()["query"]["tokens"]["csrftoken"]


def fetch_page_text(session: requests.Session, title: str) -> str:
    r = session.get(
        MW_API_URL,
        params={
            "action": "query",
            "format": "json",
            "prop": "revisions",
            "titles": title,
            "rvslots": "main",
            "rvprop": "content",
        },
        timeout=20,
    )
    pages = r.json()["query"]["pages"]
    page = next(iter(pages.values()))
    revisions = page.get("revisions", [])
    if not revisions:
        return ""
    return revisions[0]["slots"]["main"].get("*", "")


def upsert_css_block(css_text: str) -> str:
    start_idx = css_text.find(CSS_START)
    end_idx = css_text.find(CSS_END)
    if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
        end_idx += len(CSS_END)
        return css_text[:start_idx].rstrip() + "\n\n" + CSS_BLOCK.strip() + "\n"
    return css_text.rstrip() + "\n\n" + CSS_BLOCK.strip() + "\n"


def save_page_text(session: requests.Session, title: str, text: str, csrf: str, summary: str) -> dict:
    r = session.post(
        MW_API_URL,
        data={
            "action": "edit",
            "title": title,
            "text": text,
            "summary": summary,
            "token": csrf,
            "format": "json",
            "bot": 1,
        },
        timeout=30,
    )
    return r.json()


def main() -> None:
    session = requests.Session()
    csrf = login_and_get_csrf(session)

    current_css = fetch_page_text(session, "MediaWiki:Common.css")
    updated_css = upsert_css_block(current_css)

    if updated_css == current_css:
        print("No change required.")
        return

    result = save_page_text(
        session,
        "MediaWiki:Common.css",
        updated_css,
        csrf,
        "Main Page: align row 1 left inset with row 2",
    )
    print(result)


if __name__ == "__main__":
    main()
