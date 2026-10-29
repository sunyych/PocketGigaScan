#!/usr/bin/env python3
"""Make screenshot contact sheets and inspect the bilingual manual PDFs."""

from __future__ import annotations

import argparse
import json
import re
import textwrap
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont, ImageOps


REPO = Path(__file__).resolve().parents[2]
PDF_DIR = REPO / "output" / "pdf"
PDF_NAMES = {
    "zh": "PocketGigaScan_Functional_Manual_ZH.pdf",
    "en": "PocketGigaScan_Functional_Manual_EN.pdf",
}
GROUP_LIMIT = 12
GROUP_MIN = 9
PATH_PATTERNS = [
    re.compile(r"(?i)\bsunyy\b"),
    re.compile(r"(?i)C:\\Users\\[^\\/\s]+(?:\\[^\s]*)?"),
]


def _parse_group(path: Path) -> tuple[str, str, str] | None:
    tokens = [token for token in re.split(r"[-_]+", path.stem.lower()) if token]
    language = next((token for token in tokens if token in {"zh", "en"}), None)
    if language is None:
        return None

    scale = "unspecified"
    for token in tokens:
        match = re.fullmatch(r"(\d{2,3})(?:%|pct|percent)?", token)
        if match:
            scale = f"{match.group(1)}pct"
            break

    viewport = next(
        (token for token in tokens if token in {"desktop", "mobile"}),
        "unspecified",
    )
    return language, scale, viewport


def _load_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        Path("C:/Windows/Fonts/arial.ttf"),
        Path("C:/Windows/Fonts/segoeui.ttf"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            try:
                return ImageFont.truetype(str(candidate), size=size)
            except OSError:
                continue
    return ImageFont.load_default()


def _wrap_label(label: str, max_chars: int, max_lines: int = 2) -> list[str]:
    lines = textwrap.wrap(label, width=max_chars, break_long_words=True, break_on_hyphens=True)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = lines[-1].rstrip(".-_") + "…"
    return lines or [label]


def _write_contact_sheet(
    images: list[Path],
    group: tuple[str, str, str],
    batch: int,
    output_dir: Path,
) -> dict[str, Any]:
    language, scale, viewport = group
    thumb_width, thumb_height = (390, 844) if viewport == "mobile" else (640, 450)
    label_height = 56
    title_height = 64
    columns = 3
    rows = (len(images) + columns - 1) // columns
    sheet = Image.new(
        "RGB",
        (columns * thumb_width, title_height + rows * (thumb_height + label_height)),
        (238, 241, 245),
    )
    draw = ImageDraw.Draw(sheet)
    title_font = _load_font(24)
    label_font = _load_font(15 if viewport == "mobile" else 17)
    group_title = f"{language.upper()} | {scale} | {viewport} | batch {batch:02d}"
    draw.text((16, 14), group_title, font=title_font, fill=(20, 30, 45))

    for index, path in enumerate(images):
        x = (index % columns) * thumb_width
        y = title_height + (index // columns) * (thumb_height + label_height)
        draw.rectangle((x + 5, y + 5, x + thumb_width - 6, y + thumb_height - 6), fill="white")
        with Image.open(path) as source:
            image = ImageOps.contain(
                source.convert("RGB"),
                (thumb_width - 20, thumb_height - 20),
                method=Image.Resampling.LANCZOS,
            )
        image_x = x + (thumb_width - image.width) // 2
        image_y = y + (thumb_height - image.height) // 2
        sheet.paste(image, (image_x, image_y))

        label = path.name
        lines = _wrap_label(label, 38 if viewport == "mobile" else 72)
        label_y = y + thumb_height + 2
        for line in lines:
            draw.text((x + 8, label_y), line, font=label_font, fill=(26, 37, 52))
            label_y += 20

    output_dir.mkdir(parents=True, exist_ok=True)
    out_path = output_dir / f"{language}_{scale}_{viewport}_{batch:02d}.png"
    sheet.save(out_path, format="PNG", optimize=True)
    return {
        "language": language,
        "scale": scale,
        "viewport": viewport,
        "batch": batch,
        "imageCount": len(images),
        "underTarget": len(images) < GROUP_MIN,
        "contactSheet": str(out_path),
        "sourceNames": [path.name for path in images],
    }


def _make_contact_sheets(screenshot_dir: Path, output_dir: Path) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    grouped: dict[tuple[str, str, str], list[Path]] = defaultdict(list)
    unparsed: list[str] = []
    errors: list[str] = []
    output_root = output_dir.resolve()

    for path in sorted(screenshot_dir.rglob("*.png")):
        resolved = path.resolve()
        if output_root == resolved or output_root in resolved.parents:
            continue
        if not path.is_file():
            continue
        key = _parse_group(path)
        if key is None:
            unparsed.append(path.name)
            continue
        try:
            with Image.open(path) as image:
                image.verify()
        except Exception as error:  # Pillow reports several decoder-specific exceptions.
            errors.append(f"Unreadable screenshot {path}: {error}")
            continue
        grouped[key].append(path)

    sheets: list[dict[str, Any]] = []
    for group in sorted(grouped):
        paths = grouped[group]
        for batch_index in range(0, len(paths), GROUP_LIMIT):
            batch_paths = paths[batch_index : batch_index + GROUP_LIMIT]
            sheets.append(
                _write_contact_sheet(
                    batch_paths,
                    group,
                    batch_index // GROUP_LIMIT + 1,
                    output_dir,
                )
            )
    if not sheets:
        errors.append(f"No grouped PNG screenshots found under {screenshot_dir}")
    return sheets, unparsed, errors


def _object(value: Any) -> Any:
    return value.get_object() if hasattr(value, "get_object") else value


def _walk_fonts(page: Any) -> list[dict[str, Any]]:
    resources = _object(page.get("/Resources", {}))
    font_entries = _object(resources.get("/Font", {})) if resources else {}
    found: list[dict[str, Any]] = []
    for font_ref in font_entries.values():
        font = _object(font_ref)
        base_name = str(font.get("/BaseFont", font.get("/Name", "unknown")))
        is_type0 = str(font.get("/Subtype", "")) == "/Type0"
        candidates = [font]
        descendants = _object(font.get("/DescendantFonts", [])) or []
        candidates.extend(_object(item) for item in descendants)
        embedded_streams: set[str] = set()
        for candidate in candidates:
            descriptor = _object(candidate.get("/FontDescriptor", {}))
            for key in ("/FontFile", "/FontFile2", "/FontFile3"):
                stream = _object(descriptor.get(key)) if descriptor else None
                if stream is not None and hasattr(stream, "get_data"):
                    try:
                        if len(stream.get_data()) > 0:
                            embedded_streams.add(key)
                    except Exception:
                        continue
        cmap_ref = font.get("/ToUnicode")
        cmap = _object(cmap_ref) if cmap_ref is not None else None
        cmap_bytes = cmap.get_data() if cmap is not None and hasattr(cmap, "get_data") else b""
        found.append(
            {
                "name": base_name,
                "embedded": bool(embedded_streams),
                "embeddingStreams": sorted(embedded_streams),
                "type0": is_type0,
                "subtype": str(font.get("/Subtype", "unknown")),
                "unicodeMapChars": sorted(_to_unicode_chars(cmap_bytes)),
            }
        )
    return found


def _decode_cmap_code(value: str) -> str:
    try:
        raw = bytes.fromhex(value)
        if len(raw) % 2:
            return ""
        return raw.decode("utf-16-be")
    except (ValueError, UnicodeDecodeError):
        return ""


def _to_unicode_chars(cmap_bytes: bytes) -> set[str]:
    """Extract destination Unicode characters from bfchar/bfrange CMap data."""
    source = cmap_bytes.decode("latin-1", errors="ignore")
    chars: set[str] = set()
    token = r"<([0-9A-Fa-f]+)>"
    for block_match in re.finditer(r"beginbfchar(.*?)endbfchar", source, re.S):
        block = block_match.group(1)
        for match in re.finditer(token + r"\s*" + token, block):
            chars.update(_decode_cmap_code(match.group(2)))
    for block_match in re.finditer(r"beginbfrange(.*?)endbfrange", source, re.S):
        block = block_match.group(1)
        pattern = token + r"\s*" + token + r"\s*(<([0-9A-Fa-f]+)>|\[(.*?)\])"
        for match in re.finditer(pattern, block, re.S):
            first, last = int(match.group(1), 16), int(match.group(2), 16)
            array_content = match.group(5)
            if array_content is not None:
                destinations = re.findall(token, array_content)
                for destination in destinations:
                    chars.update(_decode_cmap_code(destination))
                continue
            destination = match.group(4)
            initial = _decode_cmap_code(destination)
            if len(initial) != 1:
                continue
            for offset in range(max(0, last - first + 1)):
                codepoint = ord(initial) + offset
                if codepoint <= 0x10FFFF:
                    chars.add(chr(codepoint))
    return chars


def _page_images(page: Any) -> list[Any]:
    resources = _object(page.get("/Resources", {}))
    xobjects = _object(resources.get("/XObject", {})) if resources else {}
    images = []
    for name, reference in xobjects.items():
        obj = _object(reference)
        if str(obj.get("/Subtype", "")) == "/Image":
            images.append(reference)
    return images


def _private_path_hits(text: str) -> list[str]:
    hits: list[str] = []
    for pattern in PATH_PATTERNS:
        hits.extend(match.group(0) for match in pattern.finditer(text))
    return hits


def _check_pdf(path: Path, language: str) -> dict[str, Any]:
    result: dict[str, Any] = {
        "path": str(path),
        "exists": path.is_file(),
        "language": language,
        "errors": [],
        "pageCount": 0,
        "blankTextPages": [],
        "embeddedImageCount": 0,
        "embeddedFonts": [],
        "privatePathHits": [],
    }
    if not path.is_file():
        result["errors"].append("PDF file is missing")
        return result

    try:
        from pypdf import PdfReader

        reader = PdfReader(str(path), strict=False)
        result["pageCount"] = len(reader.pages)
        if not reader.pages:
            result["errors"].append("PDF has no pages")

        image_ids: set[tuple[Any, ...]] = set()
        font_names: dict[str, dict[str, Any]] = {}
        document_text: list[str] = []
        for index, page in enumerate(reader.pages):
            text = page.extract_text() or ""
            document_text.append(text)
            if not text.strip():
                result["blankTextPages"].append(index + 1)
            for reference in _page_images(page):
                object_id = (
                    getattr(reference, "idnum", None),
                    getattr(reference, "generation", None),
                )
                if object_id == (None, None):
                    object_id = (id(_object(reference)),)
                image_ids.add(object_id)
            for font in _walk_fonts(page):
                name = font["name"]
                current = font_names.setdefault(
                    name,
                    {
                        "embedded": False,
                        "type0": False,
                        "subtypes": set(),
                        "embeddingStreams": set(),
                        "unicodeMapChars": set(),
                    },
                )
                current["embedded"] = current["embedded"] or font["embedded"]
                current["type0"] = current["type0"] or font["type0"]
                current["subtypes"].add(font["subtype"])
                current["embeddingStreams"].update(font["embeddingStreams"])
                current["unicodeMapChars"].update(font["unicodeMapChars"])

            annotations = page.get("/Annots", []) or []
            for annotation_ref in annotations:
                annotation = _object(annotation_ref)
                action = _object(annotation.get("/A", {}))
                uri = action.get("/URI")
                if uri is not None:
                    document_text.append(str(uri))

        metadata = reader.metadata
        if metadata:
            document_text.extend(f"{key} {value}" for key, value in metadata.items())
        full_text = "\n".join(document_text)
        result["privatePathHits"] = sorted(set(_private_path_hits(full_text)))
        result["embeddedImageCount"] = len(image_ids)
        result["embeddedFonts"] = [
            {
                **{key: value for key, value in details.items() if key not in {"subtypes", "embeddingStreams", "unicodeMapChars"}},
                "name": name,
                "subtypes": sorted(details["subtypes"]),
                "embeddingStreams": sorted(details["embeddingStreams"]),
                "unicodeMapCjkCharCount": sum(
                    "\u3400" <= char <= "\u9fff" for char in details["unicodeMapChars"]
                ),
            }
            for name, details in sorted(font_names.items())
            if details["embedded"]
        ]

        if result["blankTextPages"]:
            result["errors"].append(
                f"Pages have no extractable text: {result['blankTextPages']}"
            )
        if result["embeddedImageCount"] < 9:
            result["errors"].append(
                f"Expected at least 9 embedded screenshot images, found {result['embeddedImageCount']}"
            )
        if not result["embeddedFonts"]:
            result["errors"].append("No embedded fonts found")
        if language == "zh":
            chinese_keywords = ("功能说明书", "文字大小")
            missing_keywords = [keyword for keyword in chinese_keywords if keyword not in full_text]
            if missing_keywords:
                result["errors"].append(
                    f"Chinese text extraction is missing keywords: {missing_keywords}"
                )
            expected_cjk_chars = {char for word in chinese_keywords for char in word}
            embedded_cjk_chars = {
                char
                for font in font_names.values()
                if font["embedded"]
                for char in font["unicodeMapChars"]
                if "\u3400" <= char <= "\u9fff"
            }
            if not expected_cjk_chars.issubset(embedded_cjk_chars):
                missing_chars = sorted(expected_cjk_chars - embedded_cjk_chars)
                result["errors"].append(
                    f"No embedded TrueType/Type0 Unicode font covers Chinese characters: {missing_chars}"
                )
        if result["privatePathHits"]:
            result["errors"].append("Private user name or Windows profile path found in PDF text/metadata")
    except Exception as error:
        result["errors"].append(f"PDF inspection failed: {type(error).__name__}: {error}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screenshots", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pdf-dir", type=Path, default=PDF_DIR)
    args = parser.parse_args()

    screenshots = args.screenshots.resolve()
    output = args.output.resolve()
    errors: list[str] = []
    if not screenshots.is_dir():
        errors.append(f"Screenshot directory not found: {screenshots}")
        sheets: list[dict[str, Any]] = []
        unparsed: list[str] = []
    else:
        sheets, unparsed, screenshot_errors = _make_contact_sheets(screenshots, output)
        errors.extend(screenshot_errors)

    pdfs = {
        language: _check_pdf(args.pdf_dir / filename, language)
        for language, filename in PDF_NAMES.items()
    }
    for language, result in pdfs.items():
        errors.extend(f"{language.upper()} PDF: {error}" for error in result["errors"])

    report = {
        "createdUtc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "screenshotsDirectory": str(screenshots),
        "contactSheetDirectory": str(output),
        "pdfDirectory": str(args.pdf_dir.resolve()),
        "contactSheets": sheets,
        "unparsedScreenshotNames": unparsed,
        "pdfs": pdfs,
        "errors": errors,
        "passed": not errors,
    }
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "manual-artifact-review.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "contactSheets": len(sheets), "errors": errors, "report": str(report_path)}, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
