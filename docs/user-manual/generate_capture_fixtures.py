"""Create a small, deterministic 2x3 set of overlapping panorama JPEGs."""

from __future__ import annotations

import random
from pathlib import Path
import argparse

from PIL import Image, ImageDraw, ImageFont


def _make_dense(target: Path, rng: random.Random) -> None:
    width, height = 640, 400
    panorama_width, panorama_height = 1280, 600
    canvas = Image.new("RGB", (panorama_width, panorama_height), (231, 231, 224))
    draw = ImageDraw.Draw(canvas)

    # Build one continuous synthetic texture, then crop overlapping frames from
    # it so every shared detail has an exact counterpart in adjacent photos.
    for index in range(500):
        x = rng.randrange(8, panorama_width - 8)
        y = rng.randrange(8, panorama_height - 8)
        radius_x = rng.randrange(5, 25)
        radius_y = rng.randrange(5, 21)
        base = rng.choice(
            [
                (24, 77, 128), (192, 51, 44), (34, 132, 83),
                (112, 48, 137), (224, 133, 20), (31, 132, 151),
                (178, 48, 98), (75, 92, 42),
            ]
        )
        light = tuple(min(255, component + rng.randrange(48, 91)) for component in base)
        dark = tuple(max(0, component - rng.randrange(28, 67)) for component in base)
        bounds = (x - radius_x, y - radius_y, x + radius_x, y + radius_y)
        shape = index % 5
        if shape == 0:
            draw.ellipse(bounds, fill=light, outline=dark, width=2)
        elif shape == 1:
            draw.rounded_rectangle(bounds, radius=rng.randrange(2, 8), fill=base, outline=light, width=2)
        elif shape == 2:
            points = [
                (
                    x + int(radius_x * rng.uniform(-1, 1)),
                    y + int(radius_y * rng.uniform(-1, 1)),
                )
                for _ in range(rng.randrange(4, 8))
            ]
            draw.polygon(points, fill=light, outline=dark)
        elif shape == 3:
            draw.arc(bounds, start=rng.randrange(0, 130), end=rng.randrange(210, 360), fill=base, width=4)
        else:
            draw.line(
                (x - radius_x, y - radius_y, x + radius_x, y + radius_y),
                fill=dark,
                width=rng.randrange(2, 6),
            )
            draw.line(
                (x - radius_x, y + radius_y, x + radius_x, y - radius_y),
                fill=light,
                width=rng.randrange(2, 5),
            )

        # Each marker receives a unique small motif and asymmetric accents.
        draw.line((x - radius_x - 4, y, x + radius_x + 4, y), fill=(19, 28, 35), width=1)
        if index % 2 == 0:
            draw.ellipse((x - 2, y - 2, x + 2, y + 2), fill=(250, 247, 222))

    try:
        font = ImageFont.truetype("arial.ttf", 14)
    except OSError:
        font = ImageFont.load_default()
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    for index in range(90):
        x = rng.randrange(4, panorama_width - 55)
        y = rng.randrange(4, panorama_height - 18)
        code = "".join(rng.choice(alphabet) for _ in range(5))
        draw.text((x, y), code, fill=(15, 27, 38), font=font,
                  stroke_width=1, stroke_fill=(250, 247, 222))

    for row, y in enumerate((0, 200), start=1):
        for column, x in enumerate((0, 320, 640), start=1):
            frame = canvas.crop((x, y, x + width, y + height))
            frame.save(target / f"row_{row:02d}_col_{column:02d}.jpg", "JPEG", quality=92)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    parser.add_argument("--dense", action="store_true", help="use a 500-detail, 50%-overlap scene")
    args = parser.parse_args()
    target = args.target
    target.mkdir(parents=True, exist_ok=True)
    width, height = 640, 400
    rng = random.Random(821)

    if args.dense:
        _make_dense(target, rng)
        return

    panorama_width, panorama_height = 1600, 700

    canvas = Image.new("RGB", (panorama_width, panorama_height), (221, 229, 216))
    draw = ImageDraw.Draw(canvas)
    # A quiet horizon and broad color blocks add structure; the high-contrast
    # primitives below supply repeatable, local features across each overlap.
    draw.rectangle((0, 0, panorama_width, 230), fill=(188, 214, 225))
    draw.rectangle((0, 430, panorama_width, panorama_height), fill=(173, 194, 151))
    draw.line((0, 385, panorama_width, 385), fill=(97, 125, 90), width=8)
    for i in range(95):
        x = rng.randrange(12, panorama_width - 12)
        y = rng.randrange(15, panorama_height - 15)
        radius = rng.randrange(5, 24)
        color = rng.choice(
            [(223, 137, 67), (72, 105, 142), (237, 207, 104), (116, 77, 112)]
        )
        shape = i % 3
        if shape == 0:
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)
        elif shape == 1:
            draw.rectangle((x - radius, y - radius, x + radius, y + radius), fill=color)
        else:
            draw.polygon(
                [(x, y - radius), (x + radius, y + radius), (x - radius, y + radius)],
                fill=color,
            )
        draw.line((x - radius - 4, y, x + radius + 4, y), fill=(42, 51, 58), width=2)
        draw.line((x, y - radius - 4, x, y + radius + 4), fill=(42, 51, 58), width=2)

    try:
        font = ImageFont.truetype("arial.ttf", 24)
    except OSError:
        font = ImageFont.load_default()
    for x in range(80, panorama_width, 210):
        draw.text((x, 54 + (x // 210 % 3) * 36), f"CAPTURE {x // 210:02d}",
                  fill=(37, 57, 68), font=font, stroke_width=1, stroke_fill=(244, 241, 220))

    # 25% horizontal and 25% vertical overlap. The shared scene coordinates
    # ensure adjacent frames contain the same visual features for registration.
    for row, y in enumerate((0, 300), start=1):
        for column, x in enumerate((0, 480, 960), start=1):
            frame = canvas.crop((x, y, x + width, y + height))
            frame.save(target / f"row_{row:02d}_col_{column:02d}.jpg", "JPEG", quality=88)


if __name__ == "__main__":
    main()
