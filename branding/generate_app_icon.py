#!/usr/bin/env python3
"""Regenerate the Windows multi-resolution ICO from the DWARF Stitch mark.

The adjacent SVG is the editable vector master. The Pillow drawing below uses
the same 256-unit geometry so generation needs no platform-specific renderer.
"""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Apps/Flutter/stitch_app/windows/runner/resources/app_icon.ico"
SIZES = (16, 24, 32, 48, 64, 128, 256)


def draw_mark(size: int) -> Image.Image:
    scale = size / 256
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    def xy(values):
        return tuple(round(value * scale) for value in values)

    draw.rounded_rectangle(xy((0, 0, 256, 256)), radius=max(1, round(52 * scale)), fill=(16, 40, 59, 255))
    # Grid and survey field.
    for position in (28, 68, 128, 188, 228):
        color = (60, 113, 128, 184)
        draw.line((xy((position, 28)), xy((position, 228))), fill=color, width=max(1, round(3 * scale)))
        draw.line((xy((28, position)), xy((228, position))), fill=color, width=max(1, round(3 * scale)))
    draw.ellipse(xy((35, 35, 221, 221)), outline=(60, 113, 128, 184), width=max(1, round(3 * scale)))

    # Telescope body, with dark outline and warm barrel.
    draw.line((xy((56, 190)), xy((183, 63))), fill=(10, 23, 36, 255), width=max(2, round(30 * scale)))
    draw.line((xy((58, 188)), xy((181, 65))), fill=(247, 185, 85, 255), width=max(2, round(20 * scale)))
    draw.line((xy((80, 166)), xy((158, 87))), fill=(255, 229, 161, 255), width=max(1, round(3 * scale)))

    # Objective lens and eyepiece.
    draw.polygon([xy(point) for point in ((166, 49), (197, 80), (173, 104), (142, 73))], fill=(247, 185, 85, 255), outline=(255, 240, 203, 255), width=max(1, round(5 * scale)))
    draw.polygon([xy(point) for point in ((183, 65), (201, 47), (225, 71), (207, 89))], fill=(131, 211, 223, 255), outline=(217, 247, 251, 255), width=max(1, round(5 * scale)))
    draw.polygon([xy(point) for point in ((89, 163), (107, 181), (79, 209), (61, 191))], fill=(216, 148, 62, 255), outline=(255, 229, 161, 255), width=max(1, round(4 * scale)))
    draw.ellipse(xy((201, 39, 217, 55)), fill=(255, 240, 203, 255))
    return image


def main() -> None:
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    images = [draw_mark(size) for size in SIZES]
    images[-1].save(DESTINATION, format="ICO", sizes=[(size, size) for size in SIZES])
    print(f"Generated {DESTINATION}")


if __name__ == "__main__":
    main()
