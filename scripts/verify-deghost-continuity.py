#!/usr/bin/env python3
"""Extract an existing spherical pyramid ROI and write comparable ROI layouts.

The ROI keeps the original angular pixel pitch and every source tile. Rendering
the crop still changes the renderer's global coarse ownership-map lattice; these
diagnostics are useful for local comparisons, not a byte-equivalent replay of the
full panorama.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys

import cv2
import numpy as np


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object: {path}")
    return value


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_crop(layout: dict, x: int, y: int, width: int, height: int) -> None:
    if width <= 0 or height <= 0:
        raise ValueError("crop width and height must be positive")
    if min(x, y) < 0 or x + width > layout["width"] or y + height > layout["height"]:
        raise ValueError(
            f"crop ({x},{y},{width},{height}) falls outside "
            f"layout {layout['width']}x{layout['height']}"
        )


def crop_angles(layout: dict, x: int, y: int, width: int, height: int) -> dict:
    """Return bounds whose dimensions preserve the full layout's radians/pixel."""
    full_width = layout["width"]
    full_height = layout["height"]
    yaw_span = layout["yawMaxRad"] - layout["yawMinRad"]
    pitch_span = layout["pitchMaxRad"] - layout["pitchMinRad"]
    return {
        "width": width,
        "height": height,
        "yawMinRad": layout["yawMinRad"] + x * yaw_span / full_width,
        "yawMaxRad": layout["yawMinRad"] + (x + width) * yaw_span / full_width,
        "pitchMaxRad": layout["pitchMaxRad"] - y * pitch_span / full_height,
        "pitchMinRad": layout["pitchMaxRad"] - (y + height) * pitch_span / full_height,
    }


def extract_level_zero(
    tiles_dir: Path, output_path: Path, x: int, y: int, width: int, height: int, tile_size: int
) -> dict:
    crop = np.zeros((height, width, 4), dtype=np.uint8)
    covered = np.zeros((height, width), dtype=np.bool_)
    first_missing: list[str] = []
    touched = 0
    for tile_y in range(y // tile_size, (y + height - 1) // tile_size + 1):
        for tile_x in range(x // tile_size, (x + width - 1) // tile_size + 1):
            path = tiles_dir / f"{tile_y}-{tile_x}.png"
            if not path.is_file():
                if len(first_missing) < 8:
                    first_missing.append(str(path))
                continue
            tile = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
            if tile is None:
                raise ValueError(f"cannot decode tile: {path}")
            if tile.ndim == 2:
                tile = cv2.cvtColor(tile, cv2.COLOR_GRAY2BGRA)
            elif tile.shape[2] == 3:
                tile = cv2.cvtColor(tile, cv2.COLOR_BGR2BGRA)
            elif tile.shape[2] != 4:
                raise ValueError(f"expected RGB/RGBA tile, got {tile.shape}: {path}")

            image_x0 = tile_x * tile_size
            image_y0 = tile_y * tile_size
            ix0, iy0 = max(x, image_x0), max(y, image_y0)
            ix1, iy1 = min(x + width, image_x0 + tile.shape[1]), min(y + height, image_y0 + tile.shape[0])
            if ix0 >= ix1 or iy0 >= iy1:
                continue
            src = tile[iy0 - image_y0 : iy1 - image_y0, ix0 - image_x0 : ix1 - image_x0]
            dst = crop[iy0 - y : iy1 - y, ix0 - x : ix1 - x]
            dst[:] = src
            covered[iy0 - y : iy1 - y, ix0 - x : ix1 - x] = True
            touched += 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(output_path), crop):
        raise OSError(f"failed to write crop: {output_path}")
    return {
        "tileSize": tile_size,
        "tilesRead": touched,
        "coveredPixelFraction": float(covered.mean()),
        "uncoveredPixelCount": int((~covered).sum()),
        "missingTilePaths": first_missing,
    }


def make_variants(layout: dict, x: int, y: int, width: int, height: int) -> dict[str, dict]:
    angles = crop_angles(layout, x, y, width, height)
    variants: dict[str, dict] = {}
    base = json.loads(json.dumps(layout))
    base.update(angles)
    variants["roi-deghost"] = base

    no_warp = json.loads(json.dumps(base))
    for tile in no_warp["tiles"]:
        tile.pop("sourcePlaneWarp", None)
    variants["roi-deghost-no-warp"] = no_warp

    feather = json.loads(json.dumps(base))
    feather["renderBlendMode"] = "feather"
    variants["roi-feather"] = feather

    feather_no_warp = json.loads(json.dumps(no_warp))
    feather_no_warp["renderBlendMode"] = "feather"
    variants["roi-feather-no-warp"] = feather_no_warp
    return variants


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", type=Path, required=True, help="original renderer layout.json")
    parser.add_argument("--tiles", type=Path, required=True, help="original output/level-0 tile directory")
    parser.add_argument("--out-dir", type=Path, required=True, help="diagnostic output directory")
    parser.add_argument("--x", type=int, default=58113, help="full-panorama crop left edge (default: 58113)")
    parser.add_argument("--y", type=int, default=15220, help="full-panorama crop top edge (default: 15220)")
    parser.add_argument("--width", type=int, default=2048, help="crop width (default: 2048)")
    parser.add_argument("--height", type=int, default=1024, help="crop height (default: 1024)")
    parser.add_argument("--tile-size", type=int, default=512, help="pyramid tile edge (default: 512)")
    args = parser.parse_args()

    try:
        layout = load_json(args.layout)
        validate_crop(layout, args.x, args.y, args.width, args.height)
        args.out_dir.mkdir(parents=True, exist_ok=True)
        coverage = extract_level_zero(
            args.tiles,
            args.out_dir / f"existing-render-crop-{args.x}-{args.y}.png",
            args.x,
            args.y,
            args.width,
            args.height,
            args.tile_size,
        )
        variants = make_variants(layout, args.x, args.y, args.width, args.height)
        for name, variant in variants.items():
            write_json(args.out_dir / f"{name}.json", variant)

        full_yaw_pitch = (
            (layout["yawMaxRad"] - layout["yawMinRad"]) / layout["width"],
            (layout["pitchMaxRad"] - layout["pitchMinRad"]) / layout["height"],
        )
        roi = variants["roi-deghost"]
        roi_yaw_pitch = (
            (roi["yawMaxRad"] - roi["yawMinRad"]) / roi["width"],
            (roi["pitchMaxRad"] - roi["pitchMinRad"]) / roi["height"],
        )
        report = {
            "sourceLayout": str(args.layout.resolve()),
            "sourceLevelZero": str(args.tiles.resolve()),
            "crop": {"x": args.x, "y": args.y, "width": args.width, "height": args.height},
            "layoutTileCountPreserved": len(layout["tiles"]),
            "angularRadiansPerPixel": {
                "full": {"yaw": full_yaw_pitch[0], "pitch": full_yaw_pitch[1]},
                "roi": {"yaw": roi_yaw_pitch[0], "pitch": roi_yaw_pitch[1]},
                "preserved": math.isclose(full_yaw_pitch[0], roi_yaw_pitch[0], rel_tol=1e-12)
                and math.isclose(full_yaw_pitch[1], roi_yaw_pitch[1], rel_tol=1e-12),
            },
            "existingCrop": coverage,
            "variants": list(variants),
            "interpretation": (
                "The crop layouts retain the complete source tile list, camera intrinsics/poses, "
                "source-plane warps (except in the explicitly named no-warp variants), and all "
                "other layout/report data. The crop uses the original radians-per-pixel. A crop "
                "render changes the global coarse ownership-map lattice and is therefore a local "
                "diagnostic, not a full-output-equivalent replay."
            ),
        }
        write_json(args.out_dir / "roi-diagnosis.json", report)
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
