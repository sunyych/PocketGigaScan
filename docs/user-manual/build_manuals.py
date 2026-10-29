#!/usr/bin/env python3
"""Build the Chinese and English PocketGigaScan feature manuals.

Run from any directory with the bundled Python runtime:
  python build_manuals.py

All referenced screenshots are required. The script intentionally does not
create substitute artwork or silently omit a missing screen capture.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    Image,
    KeepTogether,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CONTENT_PATH = HERE / "manual_content.json"
SCREENSHOT_DIR = HERE / "screenshots"
OUTPUT_DIR = ROOT / "output" / "pdf"
ACCENT = colors.HexColor("#165D8F")
INK = colors.HexColor("#16191C")
MUTED = colors.HexColor("#59636E")
PALE = colors.HexColor("#EEF4F8")
RULE = colors.HexColor("#D4DCE3")


def _font_candidates(language: str) -> list[Path]:
    if language == "zh":
        env = os.environ.get("POCKETGIGASCAN_ZH_FONT")
        candidates = [Path(env)] if env else []
        candidates += [
            Path("C:/Windows/Fonts/msyh.ttc"),
            Path("C:/Windows/Fonts/msyh.ttf"),
            Path("C:/Windows/Fonts/simhei.ttf"),
            Path("/System/Library/Fonts/PingFang.ttc"),
            Path("/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc"),
            Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
        ]
        return candidates
    env = os.environ.get("POCKETGIGASCAN_EN_FONT")
    candidates = [Path(env)] if env else []
    candidates += [
        Path("C:/Windows/Fonts/arial.ttf"),
        Path("C:/Windows/Fonts/segoeui.ttf"),
        Path("/System/Library/Fonts/Supplemental/Arial.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    ]
    return candidates


def _register_fonts(language: str) -> tuple[str, str]:
    face = next((path for path in _font_candidates(language) if path.is_file()), None)
    if face is None:
        candidates = ", ".join(str(p) for p in _font_candidates(language))
        raise FileNotFoundError(
            f"No usable {language} TrueType font found. Set "
            f"POCKETGIGASCAN_{language.upper()}_FONT. Checked: {candidates}"
        )
    try:
        pdfmetrics.registerFont(TTFont(f"Manual-{language}", str(face), subfontIndex=0))
    except TypeError:
        # Older ReportLab releases do not accept subfontIndex for TTF files.
        pdfmetrics.registerFont(TTFont(f"Manual-{language}", str(face)))
    return f"Manual-{language}", f"Manual-{language}"


def _styles(language: str) -> dict[str, ParagraphStyle]:
    regular, bold = _register_fonts(language)
    base = getSampleStyleSheet()
    return {
        "title": ParagraphStyle(
            "ManualTitle", parent=base["Title"], fontName=bold, fontSize=25,
            leading=30, textColor=INK, alignment=TA_LEFT, spaceAfter=8,
        ),
        "intro": ParagraphStyle(
            "ManualIntro", parent=base["BodyText"], fontName=regular,
            fontSize=11, leading=16.5, textColor=MUTED, spaceAfter=8,
        ),
        "body": ParagraphStyle(
            "ManualBody", parent=base["BodyText"], fontName=regular,
            fontSize=11, leading=16.5, textColor=INK, spaceAfter=5,
        ),
        "step": ParagraphStyle(
            "ManualStep", parent=base["BodyText"], fontName=regular,
            fontSize=11, leading=16.5, textColor=INK,
            leftIndent=9 * mm, firstLineIndent=-9 * mm, spaceAfter=4,
        ),
        "callout_title": ParagraphStyle(
            "CalloutTitle", parent=base["BodyText"], fontName=bold,
            fontSize=9.5, leading=13, textColor=ACCENT, spaceAfter=3,
        ),
        "caption": ParagraphStyle(
            "ManualCaption", parent=base["BodyText"], fontName=regular,
            fontSize=9, leading=12, textColor=MUTED, alignment=TA_CENTER,
        ),
        "small": ParagraphStyle(
            "ManualSmall", parent=base["BodyText"], fontName=regular,
            fontSize=9.5, leading=14, textColor=MUTED,
        ),
        "cover_title": ParagraphStyle(
            "CoverTitle", parent=base["Title"], fontName=bold, fontSize=31,
            leading=38, textColor=INK, alignment=TA_CENTER,
        ),
        "cover_subtitle": ParagraphStyle(
            "CoverSubtitle", parent=base["BodyText"], fontName=regular,
            fontSize=14, leading=20, textColor=MUTED, alignment=TA_CENTER,
        ),
        "table_head": ParagraphStyle(
            "TableHead", parent=base["BodyText"], fontName=bold,
            fontSize=9.5, leading=13.5, textColor=colors.white,
        ),
        "table_cell": ParagraphStyle(
            "TableCell", parent=base["BodyText"], fontName=regular,
            fontSize=9.5, leading=13.5, textColor=INK,
        ),
    }


def _escape(value: str) -> str:
    return (value.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))


def _page_chrome(language: str, document: Any) -> None:
    canvas = document.canv
    width, height = A4
    canvas.saveState()
    canvas.setStrokeColor(RULE)
    canvas.setLineWidth(0.55)
    canvas.line(18 * mm, height - 14 * mm, width - 18 * mm, height - 14 * mm)
    canvas.setFont(f"Manual-{language}", 8)
    canvas.setFillColor(MUTED)
    label = "PocketGigaScan | 功能说明书" if language == "zh" else "PocketGigaScan | Feature Manual"
    canvas.drawString(18 * mm, height - 11 * mm, label)
    canvas.line(18 * mm, 14 * mm, width - 18 * mm, 14 * mm)
    canvas.drawRightString(width - 18 * mm, 9 * mm, str(document.page))
    canvas.restoreState()


def _screenshot_flowable(ref: str, caption: str, styles: dict[str, ParagraphStyle]) -> list[Any]:
    image_path = SCREENSHOT_DIR / ref
    if not image_path.is_file():
        raise FileNotFoundError(f"Required screenshot is missing: {image_path}")
    image = Image(str(image_path))
    max_width, max_height = 174 * mm, 108 * mm
    scale = min(max_width / image.imageWidth, max_height / image.imageHeight, 1.0)
    image.drawWidth = image.imageWidth * scale
    image.drawHeight = image.imageHeight * scale
    image.hAlign = "CENTER"
    return [
        Spacer(1, 4 * mm),
        KeepTogether([
            image,
            Spacer(1, 2 * mm),
            Paragraph(_escape(caption), styles["caption"]),
        ]),
    ]


def _story(language: str, payload: dict[str, Any], styles: dict[str, ParagraphStyle]) -> list[Any]:
    story: list[Any] = []
    cover = payload["cover"]
    story.extend([
        Spacer(1, 14 * mm),
        Paragraph(_escape(cover["title"]), styles["cover_title"]),
        Spacer(1, 7 * mm),
        Paragraph(_escape(cover["subtitle"]), styles["cover_subtitle"]),
        Spacer(1, 7 * mm),
        Paragraph(_escape(cover["overview"]), styles["intro"]),
        Spacer(1, 8 * mm),
    ])
    cover_ref = cover.get("screenshot")
    if cover_ref:
        story.extend(_screenshot_flowable(cover_ref, cover["caption"], styles))
    story.extend([
        Spacer(1, 6 * mm),
        Paragraph(_escape(cover["edition"]), styles["caption"]),
        PageBreak(),
    ])

    for index, section in enumerate(payload["sections"]):
        story.append(KeepTogether([
            Paragraph(_escape(section["title"]), styles["title"]),
            Paragraph(_escape(section["intro"]), styles["intro"]),
        ]))
        if section.get("steps"):
            steps = []
            for step_index, step in enumerate(section["steps"], start=1):
                prefix = f"{step_index}." + "&#160;" * 4
                steps.append(Paragraph(f"{prefix}{_escape(step)}", styles["step"]))
            story.extend(steps)
            story.append(Spacer(1, 3 * mm))
        if section.get("note"):
            note = section["note"]
            box = Table([[Paragraph(_escape(note["label"]), styles["callout_title"])],
                         [Paragraph(_escape(note["body"]), styles["body"])]],
                        colWidths=[173 * mm])
            box.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), PALE),
                ("BOX", (0, 0), (-1, -1), 0.5, RULE),
                ("LEFTPADDING", (0, 0), (-1, -1), 8),
                ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]))
            story.extend([box, Spacer(1, 3 * mm)])
        if section.get("format_table"):
            data = [[Paragraph(_escape(c), styles["table_head"])
                     for c in section["format_table"][0]]]
            for row in section["format_table"][1:]:
                data.append([Paragraph(_escape(c), styles["table_cell"]) for c in row])
            table = Table(data, colWidths=[27 * mm, 32 * mm, 55 * mm, 59 * mm], repeatRows=1)
            table.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), ACCENT),
                ("GRID", (0, 0), (-1, -1), 0.4, RULE),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, PALE]),
            ]))
            story.extend([table, Spacer(1, 4 * mm)])
        if section.get("troubleshooting"):
            data = [[Paragraph(_escape(c), styles["table_head"])
                     for c in section["troubleshooting"][0]]]
            for row in section["troubleshooting"][1:]:
                data.append([Paragraph(_escape(c), styles["table_cell"]) for c in row])
            table = Table(data, colWidths=[48 * mm, 125 * mm], repeatRows=1)
            table.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), ACCENT),
                ("GRID", (0, 0), (-1, -1), 0.4, RULE),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, PALE]),
            ]))
            story.extend([table, Spacer(1, 4 * mm)])
        if section.get("screenshot"):
            story.extend(_screenshot_flowable(
                section["screenshot"], section["caption"], styles,
            ))
        if index != len(payload["sections"]) - 1:
            story.append(PageBreak())
    return story


def build(language: str, content: dict[str, Any]) -> Path:
    if language not in ("zh", "en"):
        raise ValueError(f"Unsupported language: {language}")
    payload = content[language]
    output = OUTPUT_DIR / (
        "PocketGigaScan_Functional_Manual_ZH.pdf" if language == "zh"
        else "PocketGigaScan_Functional_Manual_EN.pdf"
    )
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    styles = _styles(language)
    doc = SimpleDocTemplate(
        str(output), pagesize=A4,
        rightMargin=18 * mm, leftMargin=18 * mm,
        topMargin=20 * mm, bottomMargin=19 * mm,
        title=payload["metadata"]["title"],
        author="PocketGigaScan",
        subject=payload["metadata"]["subject"],
    )
    story = _story(language, payload, styles)
    doc.build(story, onFirstPage=lambda c, d: _page_chrome(language, d),
              onLaterPages=lambda c, d: _page_chrome(language, d))
    from pypdf import PdfReader

    actual_pages = len(PdfReader(str(output)).pages)
    expected_pages = len(payload["sections"]) + 1
    if not expected_pages <= actual_pages <= expected_pages + 5:
        raise ValueError(
            f"{output} rendered as {actual_pages} pages; expected between "
            f"{expected_pages} and {expected_pages + 5}. Adjust content or "
            "layout before delivery."
        )
    return output


def _validate_inputs(content: dict[str, Any], languages: list[str]) -> None:
    missing: list[str] = []
    for language in languages:
        payload = content[language]
        refs = [payload["cover"].get("screenshot")]
        refs.extend(section.get("screenshot") for section in payload["sections"])
        for ref in filter(None, refs):
            path = SCREENSHOT_DIR / ref
            if not path.is_file():
                missing.append(str(path))
        if not any(path.is_file() for path in _font_candidates(language)):
            missing.append(
                f"{language} TrueType font (set "
                f"POCKETGIGASCAN_{language.upper()}_FONT)"
            )
    if missing:
        raise FileNotFoundError(
            "Required manual inputs are missing; no PDFs were generated:\n- "
            + "\n- ".join(missing)
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language", choices=["zh", "en", "all"], default="all")
    parser.add_argument("--content", type=Path, default=CONTENT_PATH)
    args = parser.parse_args()
    try:
        content = json.loads(args.content.read_text(encoding="utf-8"))
        languages = ["zh", "en"] if args.language == "all" else [args.language]
        _validate_inputs(content, languages)
        outputs = [build(language, content) for language in languages]
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"Manual build failed: {exc}", file=sys.stderr)
        return 2
    for path in outputs:
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
