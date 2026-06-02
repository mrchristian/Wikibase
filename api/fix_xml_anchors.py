#!/usr/bin/env python3
"""
Fix citation anchor targets in a MediaWiki XML export.

The body text contains links like [[#Ürge-Vorsatz--2020|Ürge-Vorsatz et al. 2020]]
that should jump to the corresponding entry in the References section.
Those anchor targets (<span id="...">) were removed; this script restores them.

Output: writes a new file with '-anchored' suffix in the same directory.
"""

import re
import sys
from urllib.parse import unquote
from pathlib import Path
from unicodedata import normalize
from collections import defaultdict  # still used for span_map


# ── config ─────────────────────────────────────────────────────────────────────
INPUT_FILE = Path("api/xml/ClimateKG-20260602204800.xml")
OUTPUT_FILE = Path("api/xml/ClimateKG-20260602204800-anchored.xml")
# ───────────────────────────────────────────────────────────────────────────────


def nfc(text: str) -> str:
    return normalize("NFC", text)


def norm(text: str) -> str:
    """Lower-case NFC-normalised string for fuzzy matching."""
    return normalize("NFC", text.lower().strip())


def parse_anchor_id(raw_id: str):
    """
    Decode and split an anchor ID into (author_key, year_base, suffix).

    Examples:
      'Ürge-Vorsatz--2020'          -> ('Ürge-Vorsatz', '2020', '')
      'IEA--2019a'                  -> ('IEA', '2019', 'a')
      'Acil%20Allen%20Consulting--2015' -> ('Acil Allen Consulting', '2015', '')
      'von%20L%C3%BCpke--2020'      -> ('von Lüpke', '2020', '')
    """
    decoded = unquote(raw_id)
    sep = decoded.find("--")
    if sep == -1:
        return None, None, None
    author_key = decoded[:sep]
    year_str = decoded[sep + 2 :]
    m = re.match(r"^(\d{4})([a-z]?)$", year_str)
    if m:
        return author_key, m.group(1), m.group(2)
    return author_key, year_str, ""


def citation_matches(para_text: str, author_key: str, year: str, suffix: str = "") -> bool:
    """
    Return True if a reference paragraph belongs to author_key + year + suffix.

    For unsuffixed anchors (suffix=''), the year must NOT be followed by a letter
    so that 'IEA--2020' doesn't accidentally match the 'IEA, 2020a' paragraph.
    For suffixed anchors (suffix='a','b',...), the full year+suffix string must appear.
    Handles both plain-text citations and those starting with [[#...|...]] links.
    """
    stripped = para_text.strip()

    # Skip structural markup
    if stripped.startswith("<") or stripped.startswith("=") or stripped.startswith("{"):
        return False

    norm_key = norm(author_key)

    # Handle [[#id|label]] at start of paragraph (some refs already have these)
    wiki_match = re.match(r"^\[\[#[^\]|]+\|([^\]]+)\]\]", stripped)
    if wiki_match:
        label = wiki_match.group(1)
        if not norm(label).startswith(norm_key):
            return False
    else:
        n = norm(stripped)
        # Must start with author key followed by , or space
        if not (n.startswith(norm_key + ",") or n.startswith(norm_key + " ")):
            return False

    # Match the year (+ optional suffix) in the paragraph text
    if suffix:
        # Full year+suffix must appear as a word.
        # Edge case: year appears inside a wiki-link label and suffix follows outside,
        # e.g. "[[#Co-author--2020|Co-author, 2020]] a:" — match "2020]] a" pattern too.
        direct = re.search(r"\b" + re.escape(year + suffix) + r"\b", para_text)
        split_wiki = re.search(
            r"\b" + re.escape(year) + r"\]\]\s+" + re.escape(suffix) + r"(?![a-z])",
            para_text,
        )
        if not (direct or split_wiki):
            return False
    else:
        # Year must appear but NOT immediately followed by a letter
        # (prevents matching '2020a' when we want the plain '2020' entry)
        if not re.search(r"\b" + re.escape(year) + r"(?![a-z])", para_text):
            return False

    return True


def extract_paragraphs(lines: list[str]):
    """
    Yield (start_line_idx, end_line_idx, paragraph_text) for every
    non-empty paragraph block in `lines`.
    """
    i = 0
    while i < len(lines):
        if lines[i].strip():
            j = i + 1
            while j < len(lines) and lines[j].strip():
                j += 1
            yield i, j, "\n".join(lines[i:j])
            i = j
        else:
            i += 1


def main():
    print(f"Reading {INPUT_FILE} …")
    content = INPUT_FILE.read_text(encoding="utf-8")

    # ── Split body / references ────────────────────────────────────────────────
    ref_match = re.search(r"^== References ==", content, re.MULTILINE)
    if not ref_match:
        sys.exit("ERROR: '== References ==' section not found.")

    body = content[: ref_match.start()]
    references_raw = content[ref_match.start() :]
    print(f"  Body: {len(body):,} chars | References: {len(references_raw):,} chars")

    # ── Extract all citation anchor IDs from body ──────────────────────────────
    anchor_re = re.compile(r"\[\[#([^\]|#\n]+?)(?:\|[^\]\n]+)?\]\]")
    cited_raw: set[str] = set()
    for m in anchor_re.finditer(body):
        aid = m.group(1).strip()
        if re.search(r"--\d{4}", aid):
            cited_raw.add(aid)

    print(f"  Unique citation anchor IDs in body: {len(cited_raw)}")

    # ── Parse references section into paragraphs ───────────────────────────────
    ref_lines = references_raw.split("\n")
    paragraphs = list(extract_paragraphs(ref_lines))
    print(f"  Reference paragraphs found: {len(paragraphs)}")

    # ── Match each anchor directly using exact author + year + suffix ──────────
    # span_map: para_start_line_idx -> [anchor_id, …]
    span_map: dict[int, list[str]] = defaultdict(list)
    unmatched: list[str] = []

    for raw_id in sorted(cited_raw):
        author_key, year, suffix = parse_anchor_id(raw_id)
        if not author_key or not year:
            continue
        decoded_id = unquote(raw_id)

        matches = [
            (start, end, text)
            for start, end, text in paragraphs
            if citation_matches(text, author_key, year, suffix)
        ]
        matches.sort(key=lambda x: x[0])

        if not matches:
            unmatched.append(decoded_id)
        else:
            para_start = matches[0][0]
            span_map[para_start].append(decoded_id)

    matched_count = sum(len(v) for v in span_map.values())
    print(f"  Matched: {matched_count} | Unmatched: {len(unmatched)}")
    if unmatched:
        print(f"  Unmatched sample (first 20):")
        for uid in sorted(unmatched)[:20]:
            print(f"    {uid}")

    # ── Apply span insertions ──────────────────────────────────────────────────
    new_ref_lines = ref_lines.copy()
    for para_start, anchor_ids in span_map.items():
        # Multiple anchors on one paragraph (rare): sort for determinism
        spans = "".join(f'<span id="{aid}"></span>' for aid in sorted(anchor_ids))
        new_ref_lines[para_start] = spans + new_ref_lines[para_start]

    new_content = body + "\n".join(new_ref_lines)

    OUTPUT_FILE.write_text(new_content, encoding="utf-8")
    print(f"\nWritten → {OUTPUT_FILE}")

    # ── Quick verification ─────────────────────────────────────────────────────
    checks = [
        "Ürge-Vorsatz--2020",
        "Abrahamse--2013",
        "IEA--2019a",
        "IEA--2019c",
        "IEA--2019e",
        "von Lüpke--2020",
        "Dreyfus--2020a",
        "Dreyfus--2020b",
    ]
    print("\nVerification spot-checks:")
    for cid in checks:
        found = f'id="{cid}"' in new_content
        print(f"  {'✓' if found else '✗'} {cid}")


if __name__ == "__main__":
    main()
