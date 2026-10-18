#!/usr/bin/env python3
"""Validate and archive an unsigned iOS app bundle produced by Flutter/Xcode."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
PUBSPEC = ROOT / "Apps/Flutter/stitch_app/pubspec.yaml"
EXPECTED_BUNDLE_ID = "com.lumiaiq.pocketgigascan"
EXPECTED_BUILD = {"device": "Release", "simulator": "Debug"}
PLATFORM = {
    "device": ("iPhoneOS", "iphoneos"),
    "simulator": ("iPhoneSimulator", "iphonesimulator"),
}


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def run_checked(args: list[str]) -> subprocess.CompletedProcess[str]:
    """Run a required Apple packaging tool and preserve its failure status."""
    return subprocess.run(args, check=True, text=True, capture_output=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def app_version() -> tuple[str, str]:
    text = PUBSPEC.read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", text)
    if match is None:
        fail(f"Cannot read a pinned marketing version and build number from {PUBSPEC}")
    return match.group(1), match.group(2)


def contains_app_icon(value: object) -> bool:
    if isinstance(value, dict):
        return any(contains_app_icon(key) or contains_app_icon(item) for key, item in value.items())
    if isinstance(value, list):
        return any(contains_app_icon(item) for item in value)
    return value == "AppIcon"


def inspect_app(app: Path, kind: str, configuration: str) -> dict[str, object]:
    if kind not in PLATFORM:
        fail(f"Unsupported iOS app kind: {kind}")
    if configuration != EXPECTED_BUILD[kind]:
        fail(f"{kind} app must be built as {EXPECTED_BUILD[kind]}, got {configuration}")
    if not app.is_dir() or app.suffix != ".app":
        fail(f"Required built application bundle is missing: {app}")

    info_path = app / "Info.plist"
    assets_path = app / "Assets.car"
    if not info_path.is_file():
        fail(f"Built application is missing Info.plist: {info_path}")
    if not assets_path.is_file():
        fail(f"Built application is missing compiled asset catalog: {assets_path}")
    with info_path.open("rb") as info_file:
        info = plistlib.load(info_file)

    if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
        fail(f"Unexpected iOS bundle identifier: {info.get('CFBundleIdentifier')!r}")
    marketing_version, build_number = app_version()
    if info.get("CFBundleShortVersionString") != marketing_version:
        fail("Built app marketing version does not match pubspec.yaml.")
    if str(info.get("CFBundleVersion")) != build_number:
        fail("Built app build number does not match pubspec.yaml.")

    expected_platform, sdk = PLATFORM[kind]
    if expected_platform not in info.get("CFBundleSupportedPlatforms", []):
        fail(f"Built app does not target {expected_platform}: {info.get('CFBundleSupportedPlatforms')!r}")

    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        fail("Built application has no valid CFBundleExecutable name.")
    app_root = app.resolve()
    executable = (app_root / executable_name).resolve()
    if app_root not in executable.parents or not executable.is_file():
        fail("Built application executable is missing.")
    architectures = run_checked(["xcrun", "lipo", "-archs", str(executable)]).stdout.split()
    if "arm64" not in architectures:
        fail(f"Built {kind} app has no arm64 executable slice: {architectures!r}")

    asset_output = run_checked(
        ["xcrun", "--sdk", sdk, "assetutil", "--info", str(assets_path)]
    ).stdout
    try:
        asset_metadata = json.loads(asset_output)
    except json.JSONDecodeError as error:
        fail(f"Apple assetutil returned invalid JSON for the built AppIcon catalog: {error}")
    if not contains_app_icon(asset_metadata):
        fail("The compiled app asset catalog does not contain the AppIcon entry.")

    return {
        "platform": "iOS device" if kind == "device" else "iOS simulator",
        "configuration": configuration,
        "bundle_id": info["CFBundleIdentifier"],
        "marketing_version": marketing_version,
        "build_number": build_number,
        "minimum_ios": info.get("MinimumOSVersion"),
        "supported_platforms": info["CFBundleSupportedPlatforms"],
        "architectures": architectures,
        "app_icon_catalog": "AppIcon",
        "compiled_asset_catalog": "Assets.car",
    }


def package(app: Path, kind: str, configuration: str, output_dir: Path,
            source_revision: str, flutter_version: str) -> tuple[Path, Path, Path, Path]:
    details = inspect_app(app, kind, configuration)
    stem = f"PocketGigaScan-iOS-{kind}-{configuration.lower()}-unsigned"
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"{stem}.zip"
    manifest_path = output_dir / f"{stem}.build-manifest.json"
    readme_path = output_dir / f"{stem}.README.txt"
    checksum_path = output_dir / f"{stem}.zip.sha256"

    # ditto preserves the .app bundle structure and macOS file metadata.
    run_checked(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
    if not archive.is_file() or archive.stat().st_size == 0:
        fail(f"Apple archive tool did not produce a non-empty package: {archive}")

    manifest = {
        **details,
        "artifact": archive.name,
        "source_revision": source_revision,
        "flutter_version": flutter_version,
        "signing": "no-codesign",
        "installable_ipa": False,
        "native_stitching": "not linked by the existing iOS build",
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    readme_path.write_text(
        "PocketGigaScan iOS build verification artifact\n"
        f"Build: {details['platform']} {configuration}\n"
        f"App bundle: {archive.name}\n"
        "The app bundle was built with Flutter's --no-codesign option. This ZIP is not a signed IPA.\n"
        "The existing iOS build does not link the Rust/OpenCV panorama core, so native stitching is not included.\n"
        "Apple signing, TestFlight distribution, installation on a physical device, and runtime stitching are not qualified.\n"
        "The compiled AppIcon catalog, bundle identifier, app version, platform, and arm64 architecture were checked.\n",
        encoding="utf-8",
    )

    digest = sha256_file(archive)
    checksum_path.write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    return archive, manifest_path, readme_path, checksum_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--kind", choices=sorted(PLATFORM), required=True)
    parser.add_argument("--configuration", choices=("Debug", "Release"), required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--flutter-version", required=True)
    args = parser.parse_args()
    outputs = package(
        args.app,
        args.kind,
        args.configuration,
        args.output_dir,
        args.source_revision,
        args.flutter_version,
    )
    for path in outputs:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
