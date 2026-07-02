#!/usr/bin/env python3
"""
Generate corpus-ar6.xml from corpus-ar6.csv.

Element names match the updated corpus-ar6.dtd:
  report_series   (was: publication)
  report          (was: series)
  text_division_spm_ts  (was: front_matter)
  text_divisions  (was: books)
  text_division   (was: book)

CSV column layout:
  WIKI, REPORT, TEXT_DIVISION, CHAPTER, TITLE, DESCRIPTION,
  SOURCE, PDF, DOI, OPENALEX, TAGLIST, LICENSE, DATE

Row types (by REPORT / TEXT_DIVISION / CHAPTER values):
  TD=0, CH=0   -> report header (title, doi, license, etc.)
  TD=0, CH>0   -> text_division_spm_ts chapters (SPM, TS)
  TD>0, CH=10  -> text_division group title row
  TD>0, CH>10  -> chapters within that text_division
"""

import csv
import re
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

CSV_FILE = Path(__file__).parent / "corpus-ar6.csv"
XML_FILE = Path(__file__).parent / "corpus-ar6.xml"
DTD_REF  = "corpus-ar6.dtd"

# DOI -> stable XML id for each report element
REPORT_IDS = {
    "10.1017/9781009157940": "IPCC_AR6_SR15",
    "10.1017/9781009157988": "IPCC_AR6_SRCCL",
    "10.1017/9781009157964": "IPCC_AR6_SROCC",
    "10.1017/9781009157896": "IPCC_AR6_WGI",
    "10.1017/9781009325844": "IPCC_AR6_WGII",
    "10.1017/9781009157926": "IPCC_AR6_WGIII",
    "10.59327/IPCC/AR6-9789291691647": "IPCC_AR6_SYR",
}


def normalize_key(raw):
    """Extract the plain uppercase word from headers like '"WIKI" \'URL\''."""
    m = re.match(r'^"?([A-Z_]+)"?', raw.strip())
    return m.group(1) if m else raw.strip()


def sub(parent, tag, text):
    """Append a child element only when text is non-empty."""
    if text and text.strip():
        el = ET.SubElement(parent, tag)
        el.text = text.strip()
        return el
    return None


def build_chapter(parent, row, ch_id):
    ch = ET.SubElement(parent, "chapter")
    ch.set("id", str(ch_id))
    sub(ch, "title",    row["TITLE"])
    sub(ch, "wiki",     row["WIKI"])
    sub(ch, "source",   row["SOURCE"])
    sub(ch, "pdf",      row["PDF"])
    sub(ch, "doi",      row["DOI"])
    sub(ch, "openalex", row["OPENALEX"])
    sub(ch, "tags",     row["TAGLIST"])
    return ch


def main():
    # ------------------------------------------------------------------ read
    with open(CSV_FILE, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        raw_rows = list(reader)

    # Normalise column keys
    col_map = {k: normalize_key(k) for k in raw_rows[0].keys()}
    rows = [{col_map[k]: v for k, v in r.items()} for r in raw_rows]

    # Group by REPORT index (0-5)
    by_report = defaultdict(list)
    for row in rows:
        by_report[int(row["REPORT"])].append(row)

    # ----------------------------------------------------------------- build
    root = ET.Element("work")

    rs = ET.SubElement(root, "report_series")
    rs.set("id", "IPCC_AR6")
    ET.SubElement(rs, "title").text       = "IPCC Sixth Assessment Report"
    ET.SubElement(rs, "description").text = "IPCC Cycle"

    for report_idx in sorted(by_report):
        report_rows = by_report[report_idx]

        # Report-level header row
        header = next(
            (r for r in report_rows if int(r["TEXT_DIVISION"]) == 0 and int(r["CHAPTER"]) == 0),
            None,
        )
        if header is None:
            continue

        doi = header["DOI"].strip()
        report_id = REPORT_IDS.get(doi, f"IPCC_AR6_REPORT_{report_idx}")

        rpt = ET.SubElement(rs, "report")
        rpt.set("id", report_id)
        sub(rpt, "title",       header["TITLE"])
        sub(rpt, "description", header["DESCRIPTION"])
        sub(rpt, "doi",         header["DOI"])
        sub(rpt, "license",     header["LICENSE"])
        sub(rpt, "tags",        header["TAGLIST"])
        sub(rpt, "date",        header["DATE"])
        sub(rpt, "pdf",         header["PDF"])
        sub(rpt, "openalex",    header["OPENALEX"])

        # text_division_spm_ts  (TD=0, CH>=1)
        fm_rows = sorted(
            [r for r in report_rows if int(r["TEXT_DIVISION"]) == 0 and int(r["CHAPTER"]) > 0],
            key=lambda r: int(r["CHAPTER"]),
        )
        if fm_rows:
            spm_ts = ET.SubElement(rpt, "text_division_spm_ts")
            for i, row in enumerate(fm_rows, 1):
                build_chapter(spm_ts, row, i)

        # text_divisions  (TD>0)
        td_indices = sorted({int(r["TEXT_DIVISION"]) for r in report_rows if int(r["TEXT_DIVISION"]) > 0})
        if td_indices:
            tds = ET.SubElement(rpt, "text_divisions")
            for td_idx in td_indices:
                td_rows = sorted(
                    [r for r in report_rows if int(r["TEXT_DIVISION"]) == td_idx],
                    key=lambda r: int(r["CHAPTER"]),
                )
                # Title from the CH=10 placeholder row
                td_header = next((r for r in td_rows if int(r["CHAPTER"]) == 10), None)
                td_title  = td_header["TITLE"].strip() if td_header else f"Text Division {td_idx}"

                td_el = ET.SubElement(tds, "text_division")
                td_el.set("id", str(td_idx))
                ET.SubElement(td_el, "title").text = td_title

                chapter_rows = sorted(
                    [r for r in td_rows if int(r["CHAPTER"]) > 10],
                    key=lambda r: int(r["CHAPTER"]),
                )
                if chapter_rows:
                    chapters_el = ET.SubElement(td_el, "chapters")
                    for i, row in enumerate(chapter_rows, 1):
                        build_chapter(chapters_el, row, i)

    # ----------------------------------------------------------------- write
    ET.indent(root, space="  ")
    xml_body = ET.tostring(root, encoding="unicode")

    output = (
        '<?xml version="1.0" encoding="UTF-8" ?>\n'
        f'<!DOCTYPE work SYSTEM "{DTD_REF}">\n'
        + xml_body
        + "\n"
    )

    XML_FILE.write_text(output, encoding="utf-8")
    print(f"Written: {XML_FILE}")

    # Quick summary
    reports_written = len(by_report)
    chapters_written = sum(1 for r in rows if int(r["CHAPTER"]) > 10 or (int(r["TEXT_DIVISION"]) == 0 and int(r["CHAPTER"]) > 0))
    print(f"  {reports_written} reports, {chapters_written} chapters")


if __name__ == "__main__":
    main()
