#!/usr/bin/env python3
"""Generate the small, strict release manifest consumed by the in-app updater."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path
from typing import Any


PLATFORMS = {
    "windows-x64": ("pocketgigascan-ota-windows-x64.json", "PocketGigaScan-Windows-x64.zip"),
    "android-arm64": ("pocketgigascan-ota-android-arm64.json", "PocketGigaScan-Android-arm64.apk"),
    "macos-arm64": ("pocketgigascan-ota-macos-arm64.json", "PocketGigaScan-macOS-arm64.zip"),
}
VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read valid JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path}")
    return value


def version_tuple(value: Any) -> tuple[int, int, int, int]:
    if not isinstance(value, str) or not (match := VERSION_RE.fullmatch(value)):
        raise ValueError("Version must be numeric MAJOR.MINOR.PATCH+BUILD with positive build number")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_existing(path: Path, platform: str) -> dict[str, Any]:
    manifest = read_json(path)
    expected_name, expected_asset = PLATFORMS[platform]
    if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1 or manifest.get("platform") != platform:
        raise ValueError(f"Existing OTA manifest has incompatible schema/platform: {expected_name}")
    if manifest.get("asset") != expected_asset:
        raise ValueError("Existing OTA manifest has an unexpected asset name")
    version_tuple(manifest.get("version"))
    if type(manifest.get("sizeBytes")) is not int or manifest["sizeBytes"] <= 0:
        raise ValueError("Existing OTA manifest has invalid sizeBytes")
    if manifest["sizeBytes"] > 2 * 1024 * 1024 * 1024:
        raise ValueError("Existing OTA manifest exceeds the 2 GiB download limit")
    if not isinstance(manifest.get("sha256"), str) or not SHA_RE.fullmatch(manifest["sha256"]):
        raise ValueError("Existing OTA manifest has invalid SHA-256")
    return manifest


def generate(platform: str, package: Path, build_manifest: Path, pubspec: Path,
             expected_commit: str | None, current_manifest: Path | None) -> dict[str, Any]:
    if platform not in PLATFORMS:
        raise ValueError(f"Unsupported platform: {platform}")
    _, expected_asset = PLATFORMS[platform]
    if package.name != expected_asset or not package.is_file():
        raise ValueError(f"Package must be an existing file named exactly {expected_asset}")

    pubspec_text = pubspec.read_text(encoding="utf-8-sig")
    versions = re.findall(r"(?m)^version:\s*([^\s#]+)\s*(?:#.*)?$", pubspec_text)
    if len(versions) != 1:
        raise ValueError("pubspec.yaml must contain exactly one version field")
    version = versions[0]
    version_tuple(version)

    source = read_json(build_manifest)
    commit_fields = {
        "windows-x64": ("githubSha", "sourceCommit"),
        "android-arm64": ("coreSourceCommit",),
        "macos-arm64": ("sourceRevision",),
    }
    commit = next((source.get(field) for field in commit_fields[platform] if source.get(field)), None)
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit):
        raise ValueError(f"Build manifest must identify its source using {', '.join(commit_fields[platform])}")
    if not expected_commit:
        raise ValueError("Expected source commit is required")
    if expected_commit and commit.lower() != expected_commit.lower():
        raise ValueError("Build manifest source commit does not match the expected release commit")
    if platform == "windows-x64":
        signing = source.get("authenticodeSigning")
        if not isinstance(signing, dict) or signing.get("verifiedBy") != "Windows Authenticode and SignTool":
            raise ValueError("Windows OTA requires the verified Authenticode signing metadata")
        if signing.get("productVersion") != version:
            raise ValueError("Signed Windows product version does not match tracked pubspec version")
        try:
            with zipfile.ZipFile(package) as archive:
                embedded = json.loads(archive.read("build-manifest.json").decode("utf-8-sig"))
        except (OSError, KeyError, UnicodeError, json.JSONDecodeError, zipfile.BadZipFile) as exc:
            raise ValueError(f"Windows package does not contain a readable build-manifest.json: {exc}") from exc
        if embedded != source:
            raise ValueError("Windows package build-manifest.json does not match the verified sidecar manifest")
        checksum_path = package.with_name(package.name + ".sha256")
        try:
            checksum_text = checksum_path.read_text(encoding="ascii").strip()
        except (OSError, UnicodeError) as exc:
            raise ValueError(f"Windows package checksum file is missing or unreadable: {exc}") from exc
        expected_checksum = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?" + re.escape(package.name), checksum_text)
        if not expected_checksum:
            raise ValueError("Windows package checksum file has an invalid format")
        if expected_checksum.group(1).lower() != file_sha256(package):
            raise ValueError("Windows package bytes do not match the adjacent SHA-256 file")

    size = package.stat().st_size
    if size <= 0:
        raise ValueError("Package is empty")
    if size > 2 * 1024 * 1024 * 1024:
        raise ValueError("Package exceeds the 2 GiB updater download limit")
    manifest = {
        "schemaVersion": 1,
        "platform": platform,
        "version": version,
        "asset": expected_asset,
        "sizeBytes": size,
        "sha256": file_sha256(package),
    }

    if current_manifest:
        current = validate_existing(current_manifest, platform)
        old_version, new_version = version_tuple(current["version"]), version_tuple(version)
        if new_version[:3] < old_version[:3]:
            raise ValueError(f"Refusing OTA rollback from {current['version']} to {version}")
        if new_version != old_version and new_version[3] <= old_version[3]:
            raise ValueError(f"Refusing version change without increasing build number from {current['version']} to {version}")
        if new_version == old_version and manifest["sha256"] != current["sha256"]:
            raise ValueError(f"Refusing to replace bytes without incrementing version {version}")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--build-manifest", type=Path, required=True)
    parser.add_argument("--pubspec", type=Path, required=True)
    parser.add_argument("--expected-commit")
    parser.add_argument("--current-manifest", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        manifest = generate(args.platform, args.package, args.build_manifest, args.pubspec,
                            args.expected_commit, args.current_manifest)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError) as exc:
        print(f"OTA manifest generation failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
