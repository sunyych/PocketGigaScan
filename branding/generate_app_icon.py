#!/usr/bin/env python3
"""Generate the editable PocketGigaScan mark and platform icon sizes.

The path coordinates below are the single geometry source for both the SVG
and PNG assets. PNGs are rasterized at four times their output size and then
downsampled with Pillow's Lanczos filter.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "branding"
APP = ROOT / "Apps/Flutter/stitch_app"
WINDOWS_ICON = APP / "windows/runner/resources/app_icon.ico"
IOS_ICONSET = APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
ANDROID_RES = APP / "android/app/src/main/res"
MACOS_ICONSET = APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
MACOS_SIZES = (16, 32, 64, 128, 256, 512, 1024)

VIEW_SIZE = 256
BACKGROUND = "#0B1B2B"
OUTER_RIBBON = "#12677D"
RIBBON = "#30C9CB"
RIBBON_LIGHT = "#82F1E6"
AMBER = "#FFBB62"
DOT_CENTER = (189.0, 76.0)
DOT_RADIUS = 6.5
DOT_HALO_RADIUS = 8.7
GLINT_CENTER = (187.5, 74.5)
GLINT_RADIUS = 1.5

# Each path is M followed by one or more cubic Bezier segments. The G is a
# single open ribbon: its open end folds inward to form the crossbar.
G_PATH = (
    (188, 78),
    (166, 61, 139, 57, 116, 65),
    (81, 76, 59, 103, 57, 136),
    (54, 171, 77, 197, 111, 204),
    (146, 212, 177, 192, 190, 166),
    (198, 151, 201, 137, 197, 122),
    (181, 121, 165, 122, 148, 124),
)
SWEEP_PATH = (
    (78, 143),
    (99, 130, 121, 121, 143, 122),
    (160, 122, 177, 128, 191, 138),
)

RIBBONS = (
    # A dark edge gives the mark clear separation from the navy tile at small sizes.
    {"path": G_PATH, "width": 32, "color": "#123A50", "opacity": 1.0},
    {"path": SWEEP_PATH, "width": 20, "color": "#123A50", "opacity": 1.0},
    {"path": G_PATH, "width": 25, "color": OUTER_RIBBON, "opacity": 1.0},
    {"path": SWEEP_PATH, "width": 15, "color": OUTER_RIBBON, "opacity": 1.0},
    {"path": G_PATH, "width": 18, "color": RIBBON, "opacity": 1.0},
    {"path": SWEEP_PATH, "width": 10, "color": RIBBON, "opacity": 1.0},
    {"path": G_PATH, "width": 3.3, "color": RIBBON_LIGHT, "opacity": 0.72},
    {"path": SWEEP_PATH, "width": 2.2, "color": RIBBON_LIGHT, "opacity": 0.72},
)


def svg_path(path: tuple[tuple[float, ...], ...]) -> str:
    commands = [f"M {path[0][0]} {path[0][1]}"]
    commands.extend(
        "C " + " ".join(f"{x:g} {y:g}" for x, y in zip(segment[0::2], segment[1::2]))
        for segment in path[1:]
    )
    return " ".join(commands)


def sampled_path(path: tuple[tuple[float, ...], ...], steps: int = 48) -> list[tuple[float, float]]:
    points = [(float(path[0][0]), float(path[0][1]))]
    start = points[0]
    for segment in path[1:]:
        p0 = start
        p1 = (segment[0], segment[1])
        p2 = (segment[2], segment[3])
        p3 = (segment[4], segment[5])
        for index in range(1, steps + 1):
            t = index / steps
            inverse = 1 - t
            x = inverse**3 * p0[0] + 3 * inverse**2 * t * p1[0] + 3 * inverse * t**2 * p2[0] + t**3 * p3[0]
            y = inverse**3 * p0[1] + 3 * inverse**2 * t * p1[1] + 3 * inverse * t**2 * p2[1] + t**3 * p3[1]
            points.append((x, y))
        start = p3
    return points


def color_with_alpha(color: str, opacity: float) -> tuple[int, int, int, int]:
    value = color.removeprefix("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4)) + (round(255 * opacity),)


def render(size: int, *, rounded_tile: bool) -> Image.Image:
    """Render the mark at `size`; use transparent rounded corners when requested."""
    scale = 4
    high_size = size * scale
    image = Image.new("RGBA", (high_size, high_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    coordinate_scale = high_size / VIEW_SIZE
    if rounded_tile:
        draw.rounded_rectangle(
            (0, 0, high_size - 1, high_size - 1),
            radius=round(52 * coordinate_scale),
            fill=BACKGROUND,
        )
    else:
        draw.rectangle((0, 0, high_size - 1, high_size - 1), fill=BACKGROUND)

    for ribbon in RIBBONS:
        overlay = Image.new("RGBA", (high_size, high_size), (0, 0, 0, 0))
        draw_ribbon = ImageDraw.Draw(overlay)
        width = max(1, round(ribbon["width"] * coordinate_scale))
        points = [
            (round(x * coordinate_scale), round(y * coordinate_scale))
            for x, y in sampled_path(ribbon["path"])
        ]
        draw_ribbon.line(points, fill=color_with_alpha(ribbon["color"], ribbon["opacity"]), width=width, joint="curve")
        cap_radius = width // 2
        for x, y in (points[0], points[-1]):
            draw_ribbon.ellipse((x - cap_radius, y - cap_radius, x + cap_radius, y + cap_radius), fill=color_with_alpha(ribbon["color"], ribbon["opacity"]))
        image = Image.alpha_composite(image, overlay)

    # Amber survey/alignment point where the upper ribbon begins.
    def circle_bounds(center: tuple[float, float], radius: float) -> tuple[int, int, int, int]:
        cx, cy = (round(value * coordinate_scale) for value in center)
        scaled_radius = round(radius * coordinate_scale)
        return (cx - scaled_radius, cy - scaled_radius, cx + scaled_radius, cy + scaled_radius)

    draw_dot = ImageDraw.Draw(image)
    draw_dot.ellipse(circle_bounds(DOT_CENTER, DOT_HALO_RADIUS), fill=BACKGROUND)
    draw_dot.ellipse(circle_bounds(DOT_CENTER, DOT_RADIUS), fill=AMBER)
    draw_dot.ellipse(circle_bounds(GLINT_CENTER, GLINT_RADIUS), fill="#FFE4B6")

    return image.resize((size, size), Image.Resampling.LANCZOS)


def write_svg() -> None:
    ribbon_elements = []
    for ribbon in RIBBONS:
        ribbon_elements.append(
            f'<path d="{svg_path(ribbon["path"])}" fill="none" '
            f'stroke="{ribbon["color"]}" stroke-width="{ribbon["width"]}" '
            f'stroke-linecap="round" stroke-linejoin="round" opacity="{ribbon["opacity"]}"/>'
        )
    svg = "\n".join(
        [
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" role="img">',
            "  <title>PocketGigaScan panorama mark</title>",
            '  <desc>Teal panoramic ribbons form a G around an amber alignment point.</desc>',
            f'  <rect width="256" height="256" rx="52" fill="{BACKGROUND}"/>',
            *(f"  {element}" for element in ribbon_elements),
            f'  <circle cx="{DOT_CENTER[0]}" cy="{DOT_CENTER[1]}" r="{DOT_HALO_RADIUS}" fill="{BACKGROUND}"/>',
            f'  <circle cx="{DOT_CENTER[0]}" cy="{DOT_CENTER[1]}" r="{DOT_RADIUS}" fill="{AMBER}"/>',
            f'  <circle cx="{GLINT_CENTER[0]}" cy="{GLINT_CENTER[1]}" r="{GLINT_RADIUS}" fill="#FFE4B6"/>',
            "</svg>",
            "",
        ]
    )
    (BRANDING / "dwarf-stitch-icon.svg").write_text(svg, encoding="utf-8")


def write_ios_icons() -> None:
    contents_path = IOS_ICONSET / "Contents.json"
    contents = json.loads(contents_path.read_text(encoding="utf-8"))
    for item in contents["images"]:
        filename = item.get("filename")
        if not filename:
            continue
        points = float(item["size"].split("x")[0])
        scale = int(item["scale"].removesuffix("x"))
        pixels = round(points * scale)
        render(pixels, rounded_tile=False).convert("RGB").save(IOS_ICONSET / filename, format="PNG", optimize=True)


def write_macos_icons() -> None:
    MACOS_ICONSET.mkdir(parents=True, exist_ok=True)
    for size in MACOS_SIZES:
        render(size, rounded_tile=True).save(
            MACOS_ICONSET / f"app_icon_{size}.png", format="PNG", optimize=True
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--macos",
        action="store_true",
        help="Generate only the macOS AppIcon.appiconset PNGs.",
    )
    args = parser.parse_args()
    if args.macos:
        write_macos_icons()
        print("Generated macOS AppIcon PNGs.")
        return

    BRANDING.mkdir(parents=True, exist_ok=True)
    write_svg()

    render(1024, rounded_tile=True).save(BRANDING / "app-icon-master.png", format="PNG", optimize=True)
    render(256, rounded_tile=True).save(BRANDING / "app-icon-preview.png", format="PNG", optimize=True)

    icon_sizes = (16, 24, 32, 48, 64, 128, 256)
    ico_frames = [render(size, rounded_tile=True) for size in icon_sizes]
    ico_frames[-1].save(WINDOWS_ICON, format="ICO", sizes=[(size, size) for size in icon_sizes], append_images=ico_frames[:-1])

    for density, pixels in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        render(pixels, rounded_tile=False).save(ANDROID_RES / f"mipmap-{density}/ic_launcher.png", format="PNG", optimize=True)

    write_ios_icons()
    write_macos_icons()
    write_small_size_contact_sheet()
    print("Generated SVG, master/preview PNGs, Windows ICO, Android density icons, iOS AppIcon set, and macOS AppIcon set.")


def write_small_size_contact_sheet() -> None:
    """Create an enlarged nearest-neighbor inspection sheet for tiny icons."""
    scale = 3
    cell_width, cell_height = 128, 112
    sheet = Image.new("RGB", (cell_width * 3, cell_height), "#E7EDF2")
    draw = ImageDraw.Draw(sheet)
    for index, size in enumerate((16, 24, 32)):
        icon = render(size, rounded_tile=True)
        shown = icon.resize((size * scale, size * scale), Image.Resampling.NEAREST)
        x = index * cell_width + (cell_width - shown.width) // 2
        y = 4
        sheet.paste(shown, (x, y), shown)
        draw.text((index * cell_width + 6, 96), f"{size} px", fill="#0B1B2B")
    sheet.save(BRANDING / "app-icon-small-sizes.png", format="PNG", optimize=True)


if __name__ == "__main__":
    main()
