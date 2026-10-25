#!/usr/bin/env python3
"""Validate and archive an unsigned iOS app bundle produced by Flutter/Xcode."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
PUBSPEC = ROOT / "Apps/Flutter/stitch_app/pubspec.yaml"
EXPECTED_BUNDLE_ID = "com.lumiaiq.pocketgigascan"
EXPECTED_BUILD = {"device": "Release", "simulator": "Debug"}
REQUIRED_NATIVE_SYMBOLS = (
    "lumia_gigascan_abi_version",
    "lumia_gigascan_job_json",
    "lumia_gigascan_free",
    "lumia_gigascan_is_available",
)
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


def inspect_native_manifest(native_manifest_path: Path, kind: str,
                            minimum_ios: object) -> tuple[dict[str, object], dict[str, str]]:
    if not native_manifest_path.is_file():
        fail(f"Native core build manifest is missing: {native_manifest_path}")
    try:
        native_manifest = json.loads(native_manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Cannot read native core build manifest: {error}")
    if not isinstance(native_manifest, dict) or native_manifest.get("schemaVersion") != 1:
        fail("Native core build manifest has an unsupported schemaVersion.")
    if not native_manifest.get("sourceRevision") or not native_manifest.get("nativeCoreSourceRevision"):
        fail("Native core build manifest does not identify its source revisions.")
    if str(native_manifest.get("minimumIOS")) != str(minimum_ios):
        fail("Native core minimum iOS version does not match the built app.")

    sdk = PLATFORM[kind][1]
    variants = native_manifest.get("variants")
    if not isinstance(variants, list) or not any(
        isinstance(variant, dict)
        and variant.get("kind") == kind
        and variant.get("sdk") == sdk
        and variant.get("architecture") == "arm64"
        for variant in variants
    ):
        fail(f"Native core build manifest has no arm64 {sdk} variant.")

    retained = native_manifest.get("retainedSymbols")
    if not isinstance(retained, list) or not set(REQUIRED_NATIVE_SYMBOLS).issubset(retained):
        fail("Native core build manifest is missing one or more required FFI symbols.")
    capabilities = native_manifest.get("capabilities")
    expected_capabilities = {"png": True, "tiff": True, "jpeg": True, "jxl": True,
                             "sceneAnalysis": False}
    if not isinstance(capabilities, dict) or any(
        capabilities.get(name) is not expected for name, expected in expected_capabilities.items()
    ):
        fail("Native core capabilities do not match the iOS build contract.")

    archive_key = "deviceArchives" if kind == "device" else "simulatorArchives"
    archives = native_manifest.get(archive_key)
    archive_dir = native_manifest_path.parent / sdk
    if not isinstance(archives, dict) or not archives:
        fail(f"Native core manifest has no {archive_key} SHA-256 map.")
    checked_archives: dict[str, str] = {}
    for filename, expected_hash in sorted(archives.items()):
        if not isinstance(filename, str) or Path(filename).name != filename:
            fail(f"Native archive map contains an invalid filename: {filename!r}")
        archive = archive_dir / filename
        if not archive.is_file():
            fail(f"Native core archive is missing: {archive}")
        actual_hash = sha256_file(archive)
        if not isinstance(expected_hash, str) or actual_hash.lower() != expected_hash.lower():
            fail(f"Native core archive SHA-256 mismatch: {archive.name}")
        checked_archives[filename] = actual_hash

    licenses = native_manifest.get("licenses")
    if not isinstance(licenses, list) or not licenses:
        fail("Native core manifest has no retained license/notice files.")
    if any(not isinstance(relative_name, str) for relative_name in licenses):
        fail("Native core license entries must be relative paths.")
    license_root = native_manifest_path.parent / "licenses"
    checked_licenses: dict[str, str] = {}
    for relative_name in sorted(licenses):
        license_path = (native_manifest_path.parent / relative_name).resolve()
        if license_root.resolve() not in license_path.parents or not license_path.is_file():
            fail(f"Native core license/notice file is missing or escapes the license directory: {relative_name}")
        checked_licenses[relative_name] = sha256_file(license_path)

    return native_manifest, checked_licenses


def inspect_app(app: Path, kind: str, configuration: str,
                native_manifest_path: Path) -> tuple[dict[str, object], dict[str, object]]:
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

    symbol_output = run_checked(["xcrun", "nm", "-gU", str(executable)]).stdout
    exported_symbols = {
        line.split()[-1].lstrip("_")
        for line in symbol_output.splitlines()
        if line.split()
    }
    missing_symbols = sorted(set(REQUIRED_NATIVE_SYMBOLS) - exported_symbols)
    if missing_symbols:
        fail(
            "Built application does not export the linked Rust panorama core ABI: "
            + ", ".join(missing_symbols)
        )

    asset_output = run_checked(
        ["xcrun", "--sdk", sdk, "assetutil", "--info", str(assets_path)]
    ).stdout
    try:
        asset_metadata = json.loads(asset_output)
    except json.JSONDecodeError as error:
        fail(f"Apple assetutil returned invalid JSON for the built AppIcon catalog: {error}")
    if not contains_app_icon(asset_metadata):
        fail("The compiled app asset catalog does not contain the AppIcon entry.")

    details = {
        "platform": "iOS device" if kind == "device" else "iOS simulator",
        "configuration": configuration,
        "bundle_id": info["CFBundleIdentifier"],
        "marketing_version": marketing_version,
        "build_number": build_number,
        "minimum_ios": info.get("MinimumOSVersion"),
        "supported_platforms": info["CFBundleSupportedPlatforms"],
        "architectures": architectures,
        "native_core": "linked-rust-ffi",
        "native_abi_symbols": list(REQUIRED_NATIVE_SYMBOLS),
        "app_icon_catalog": "AppIcon",
        "compiled_asset_catalog": "Assets.car",
    }
    native_manifest, license_hashes = inspect_native_manifest(
        native_manifest_path, kind, info.get("MinimumOSVersion")
    )
    return details, {
        "source_revision": native_manifest["sourceRevision"],
        "native_core_source_revision": native_manifest["nativeCoreSourceRevision"],
        "minimum_ios": native_manifest["minimumIOS"],
        "declared_capabilities": native_manifest["capabilities"],
        "retained_symbols": native_manifest["retainedSymbols"],
        "archives_sha256": {
            filename: sha256_file(native_manifest_path.parent / PLATFORM[kind][1] / filename)
            for filename in sorted(native_manifest["deviceArchives" if kind == "device" else "simulatorArchives"])
        },
        "licenses_sha256": license_hashes,
    }


def package(app: Path, kind: str, configuration: str, output_dir: Path,
            source_revision: str, flutter_version: str,
            native_manifest_path: Path) -> tuple[Path, Path, Path, Path]:
    details, native_evidence = inspect_app(app, kind, configuration, native_manifest_path)
    if native_evidence["source_revision"] != source_revision:
        fail("Native core source revision does not match the app package source revision.")
    stem = f"PocketGigaScan-iOS-{kind}-{configuration.lower()}-unsigned"
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"{stem}.zip"
    manifest_path = output_dir / f"{stem}.build-manifest.json"
    readme_path = output_dir / f"{stem}.README.txt"
    checksum_path = output_dir / f"{stem}.zip.sha256"
    evidence_dir = output_dir / f"{stem}.native-evidence"
    evidence_license_dir = evidence_dir / "licenses"
    evidence_license_dir.mkdir(parents=True, exist_ok=True)
    evidence_manifest_path = evidence_dir / "build-manifest.json"
    shutil.copy2(native_manifest_path, evidence_manifest_path)
    for relative_name in native_evidence["licenses_sha256"]:
        source = native_manifest_path.parent / relative_name
        shutil.copy2(source, evidence_license_dir / source.name)

    # ditto preserves the .app bundle metadata inside a package that also carries
    # the exact native dependency manifest and license/notice files.
    with tempfile.TemporaryDirectory(prefix=f"{stem}-", dir=output_dir) as temporary:
        package_root = Path(temporary) / stem
        package_root.mkdir()
        run_checked(["ditto", str(app), str(package_root / app.name)])
        shutil.copytree(evidence_dir, package_root / "native-evidence")
        run_checked([
            "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
            str(package_root), str(archive),
        ])
    if not archive.is_file() or archive.stat().st_size == 0:
        fail(f"Apple archive tool did not produce a non-empty package: {archive}")

    manifest = {
        **details,
        "artifact": archive.name,
        "source_revision": source_revision,
        "flutter_version": flutter_version,
        "signing": "no-codesign",
        "installable_ipa": False,
        "native_stitching": "Rust panorama core linked; runtime smoke is a separate CI check",
        "native_evidence_directory": evidence_dir.name,
        "native_build": native_evidence,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    readme_path.write_text(
        "PocketGigaScan iOS build verification artifact\n"
        f"Build: {details['platform']} {configuration}\n"
        f"App bundle: {archive.name}\n"
        "The app bundle was built with Flutter's --no-codesign option. This ZIP is not a signed IPA.\n"
        "The Rust panorama core is linked into the Runner executable; required ABI exports were checked with nm.\n"
        "The native dependency manifest and license/notice files are inside this ZIP under native-evidence/ and beside it in the .native-evidence directory.\n"
        "Archive SHA-256 records are checked before packaging and included in the build manifest.\n"
        "Apple signing, TestFlight distribution, and installation on a physical device are not qualified by this unsigned package.\n"
        "The compiled AppIcon catalog, bundle identifier, app version, platform, arm64 architecture, and native ABI were checked.\n",
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
    parser.add_argument("--native-manifest", type=Path, required=True)
    args = parser.parse_args()
    outputs = package(
        args.app,
        args.kind,
        args.configuration,
        args.output_dir,
        args.source_revision,
        args.flutter_version,
        args.native_manifest,
    )
    for path in outputs:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
