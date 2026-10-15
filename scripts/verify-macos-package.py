#!/usr/bin/env python3
"""Validate the pinned macOS model and a built Apple Silicon app bundle."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import math
import plistlib
import platform
import re
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "scripts" / "scene-model-export.lock.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_model(model_path: Path, manifest_path: Path) -> dict:
    model_path = model_path.resolve(strict=True)
    manifest_path = manifest_path.resolve(strict=True)
    mac_lock = json.loads((ROOT / "scripts" / "macos-dependencies.lock.json").read_text(encoding="utf-8"))
    model_lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    actual_size = model_path.stat().st_size
    actual_sha = sha256(model_path)
    expected = mac_lock["sceneModel"]
    if model_path.name != expected["fileName"]:
        raise ValueError(f"Unexpected model filename: {model_path.name}")
    if actual_size != expected["sizeBytes"] or actual_sha != expected["sha256"]:
        raise ValueError(f"Pinned scene model size/SHA mismatch: size={actual_size} sha256={actual_sha}")
    if actual_size != model_lock["expectedSizeBytes"] or actual_sha != model_lock["expectedSha256"]:
        raise ValueError("Scene model differs from scripts/scene-model-export.lock.json")
    if manifest.get("schemaVersion") != 1 or manifest.get("onnxFile") != expected["fileName"]:
        raise ValueError("Scene model exporter manifest has an unsupported schema or filename")
    if manifest.get("sizeBytes") != actual_size or manifest.get("sha256", "").lower() != actual_sha:
        raise ValueError("Scene model exporter manifest does not match the ONNX file")
    if manifest.get("modelId") != f"{model_lock['modelId']}@{model_lock['revision']}":
        raise ValueError("Scene model exporter manifest identity does not match the pinned revision")
    if manifest.get("license") != model_lock["license"]:
        raise ValueError("Scene model exporter manifest license differs from the pinned model-card license")
    readme_path = model_path.parent / "scene-model-README.md"
    if manifest.get("sourceReadmeFile") != "scene-model-README.md" or not readme_path.is_file():
        raise ValueError("Pinned upstream model README is missing from the model export")
    if manifest.get("licenseNoticeFile") != "scene-model-NOTICE.txt" or not (model_path.parent / "scene-model-NOTICE.txt").is_file():
        raise ValueError("Pinned model license notice is missing from the model export")
    readme_parts = readme_path.read_text(encoding="utf-8").split("---", 2)
    readme_license = None
    if len(readme_parts) >= 3:
        readme_license = next((
            line.split(":", 1)[1].strip().lower()
            for line in readme_parts[1].splitlines()
            if line.strip().lower().startswith("license:")
        ), None)
    if readme_license != model_lock["license"].lower():
        raise ValueError("Pinned upstream model README does not declare the locked model license")
    notice_path = model_path.parent / "scene-model-NOTICE.txt"
    if manifest.get("licenseNoticeFile") != "scene-model-NOTICE.txt" or not notice_path.is_file():
        raise ValueError("Pinned model license notice is missing from the model export")
    notice = notice_path.read_text(encoding="utf-8")
    for required_notice_text in (model_lock["modelId"], model_lock["revision"], model_lock["license"]):
        if required_notice_text.lower() not in notice.lower():
            raise ValueError(f"Pinned model notice is missing its source attribution field: {required_notice_text}")
    return {"path": str(model_path), "sizeBytes": actual_size, "sha256": actual_sha, "manifest": manifest}


def run(command: list[str]) -> str:
    completed = subprocess.run(command, check=True, text=True, capture_output=True)
    return completed.stdout.strip()


def verify_macho_minimum(binary: Path, expected: str) -> None:
    load_commands = run(["otool", "-l", str(binary)])
    for block in re.split(r"(?m)^Load command \d+\s*$", load_commands):
        if "LC_BUILD_VERSION" not in block and "LC_VERSION_MIN_MACOSX" not in block:
            continue
        match = re.search(r"(?m)^\s*minos\s+([0-9.]+)|^\s*version\s+([0-9.]+)", block)
        if not match:
            continue
        actual = next(group for group in match.groups() if group)
        actual_parts = tuple(map(int, actual.split(".")))
        expected_parts = tuple(map(int, expected.split(".")))
        width = max(3, len(actual_parts), len(expected_parts))
        actual_version = actual_parts + (0,) * (width - len(actual_parts))
        expected_version = expected_parts + (0,) * (width - len(expected_parts))
        if actual_version > expected_version:
            raise ValueError(f"{binary.name} requires macOS {actual}, above package minimum {expected}")
        return
    raise ValueError(f"Could not read a macOS minimum version from Mach-O load commands: {binary}")


def verify_bundle(bundle: Path, smoke: bool) -> dict:
    if platform.system() != "Darwin":
        raise RuntimeError("Bundle Mach-O and ONNX smoke checks must run on macOS.")
    if platform.machine() != "arm64":
        raise RuntimeError("This bundle verifier currently requires a native Apple Silicon runner.")
    bundle = bundle.resolve(strict=True)
    contents = bundle / "Contents"
    info_path = contents / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != "com.lumiaiq.pocketgigascan":
        raise ValueError("macOS bundle identifier is not com.lumiaiq.pocketgigascan")
    if info.get("LSMinimumSystemVersion") != "14.0":
        raise ValueError("macOS minimum deployment target must be 14.0")
    executable = contents / "MacOS" / info["CFBundleExecutable"]
    resources = contents / "Resources"
    model_path = resources / "models" / "scene-model-v1.onnx"
    model_manifest_path = resources / "models" / "scene-model-v1.manifest.json"
    model = verify_model(model_path, model_manifest_path)
    core = contents / "Frameworks" / "liblumia_gigascan_core.dylib"
    ort = contents / "Frameworks" / "libonnxruntime.dylib"
    if not core.is_file() or not ort.is_file():
        raise ValueError("Bundle is missing the native core or the adjacent ONNX Runtime dylib")
    dylibs = sorted((contents / "Frameworks").glob("*.dylib"))
    required = {
        "liblumia_gigascan_core.dylib",
        "libonnxruntime.dylib",
        "libopencv_stitching.dylib",
        "libopencv_calib3d.dylib",
        "libopencv_features2d.dylib",
        "libopencv_flann.dylib",
        "libopencv_imgcodecs.dylib",
        "libopencv_imgproc.dylib",
        "libopencv_core.dylib",
        "libopencv_photo.dylib",
    }
    names = {path.name for path in dylibs}
    missing = sorted(required - names)
    if missing:
        raise ValueError("Bundle is missing required native dylibs: " + ", ".join(missing))
    framework_binaries = []
    for path in (contents / "Frameworks").rglob("*"):
        if not path.is_file() or ".framework/" not in path.as_posix():
            continue
        framework_name = next(part[:-len(".framework")] for part in path.parts if part.endswith(".framework"))
        if path.name == framework_name:
            framework_binaries.append(path)
    mach_o_binaries = sorted(set(dylibs + framework_binaries + [executable]))
    for binary in mach_o_binaries:
        run(["lipo", "-verify_arch", "arm64", str(binary)])
        verify_macho_minimum(binary, "14.0")
        dependencies = run(["otool", "-L", str(binary)]).splitlines()[1:]
        for dependency in dependencies:
            name = dependency.strip().split(" ", 1)[0]
            if name.startswith(("/opt/homebrew/", "/usr/local/", "/Users/")):
                raise ValueError(f"Unbundled or machine-specific dylib dependency in {binary.name}: {name}")
            if name.startswith(("@rpath/", "@loader_path/")) and ".framework/" not in name:
                if not (contents / "Frameworks" / Path(name.split("/", 1)[1])).exists():
                    raise ValueError(f"Unresolved bundled dependency in {binary.name}: {name}")
    run(["codesign", "--verify", "--strict", "--deep", str(bundle)])
    entitlements = run(["codesign", "-d", "--entitlements", ":-", str(bundle)])
    if "com.apple.security.app-sandbox" in entitlements:
        raise ValueError("Release package must be non-sandboxed for user-selected local photo import/export")
    if not smoke:
        return {"bundle": str(bundle), "model": model, "dylibCount": len(dylibs)}

    library = ctypes.CDLL(str(core))
    library.lumia_gigascan_abi_version.restype = ctypes.c_uint32
    library.lumia_gigascan_is_available.restype = ctypes.c_uint32
    if library.lumia_gigascan_abi_version() != 1 or library.lumia_gigascan_is_available() != 1:
        raise ValueError("Native core ABI smoke failed")
    job_json = library.lumia_gigascan_job_json
    job_json.argtypes = [ctypes.c_char_p]
    job_json.restype = ctypes.c_void_p
    release = library.lumia_gigascan_free
    release.argtypes = [ctypes.c_void_p]
    release.restype = None

    def call(request: dict) -> dict:
        pointer = job_json(json.dumps(request, separators=(",", ":")).encode("utf-8"))
        if not pointer:
            raise RuntimeError("Public job API returned a null response")
        try:
            response = json.loads(ctypes.string_at(pointer).decode("utf-8"))
        finally:
            release(pointer)
        if response.get("ok") is not True:
            raise RuntimeError(f"Public job API failed: {response}")
        return response

    def png(path: Path, shift: int) -> None:
        width, height = 640, 480
        rows = bytearray()
        for y in range(height):
            rows.append(0)
            for x in range(width):
                sx = (x + shift) % width
                value = (sx * 37 + y * 71 + (sx * y) % 251 + ((sx // 13) ^ (y // 11)) * 29) & 255
                rows.extend((value, (value * 3 + y) & 255, (value * 7 + sx) & 255))
        raw = bytes(rows)

        def chunk(kind: bytes, payload: bytes) -> bytes:
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)

        data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 3)) + chunk(b"IEND", b"")
        path.write_bytes(data)

    with tempfile.TemporaryDirectory(prefix="pocketgigascan-macos-smoke-") as temporary:
        capabilities = call({"command": "capabilities"}).get("capabilities", {})
        memory = capabilities.get("systemMemory") or {}
        if not capabilities.get("sceneAnalysisAvailable") or not capabilities.get("jpegXlAvailable"):
            raise RuntimeError("Packaged core lacks scene-analysis or JPEG XL capability")
        if not isinstance(memory.get("totalMemoryMiB"), int) or not isinstance(memory.get("availableMemoryMiB"), int):
            raise RuntimeError("Packaged core did not report valid macOS system memory")
        configured = call({
            "command": "configureResources",
            "totalCpuWorkers": 2,
            "totalMemoryBudgetMiB": 2048,
            "maxConcurrentJobs": 1,
        })
        if configured.get("ok") is not True:
            raise RuntimeError(f"Could not configure resources for the packaged smoke job: {configured}")
        root = Path(temporary)
        source_dir = root / "sources"
        source_dir.mkdir()
        sources = [source_dir / "tile-0.png", source_dir / "tile-1.png"]
        png(sources[0], 0)
        png(sources[1], 91)
        output = root / "render"
        request = {
            "rows": 1, "columns": 2,
            "tiles": [{"row": 0, "column": index, "path": str(path)} for index, path in enumerate(sources)],
            "sourceWidth": 640, "sourceHeight": 480,
            "fx": 800.0, "fy": 800.0, "cx": 319.5, "cy": 239.5,
            "placementMode": "grid-assisted", "gridHorizontalOverlap": 0.8,
            "gridVerticalOverlap": 0.3, "refineGridNeighbors": True,
            "autoGridOverlap": False, "allowNominalGridFallback": True,
            "seamBlendMode": "deghost", "localTextureWarp": True,
            "useAlignmentCache": True, "alignmentCacheDir": str(root / ".alignment-cache"),
            "parallelRendering": True, "protectPeople": True, "smoothWater": True,
            "sceneModelPath": str(model_path), "sceneModelSha256": model["sha256"],
            "sceneCacheDir": str(root / "scene-cache"),
        }
        started = call({"command": "start", "request": request, "outputDir": str(output), "workers": 2, "memoryBudgetMiB": 2048})
        job_id = started["jobId"]
        deadline = time.monotonic() + 900
        while True:
            status = call({"command": "status", "jobId": job_id})
            if status["state"] in ("completed", "failed", "cancelled"):
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("Public job smoke timed out while rendering with the packaged scene model")
            time.sleep(1)
        if status["state"] != "completed":
            raise RuntimeError(f"Scene-enabled render failed: {status}")
        manifest_path = Path(status["manifestPath"])
        if not manifest_path.is_absolute():
            manifest_path = output / manifest_path
        render_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        semantic = render_manifest.get("semanticAnalysis")
        if not semantic or semantic.get("modelSha256") != model["sha256"] or len(semantic.get("sources", [])) != 2:
            raise ValueError("Render manifest does not prove scene model inference and per-source masks")
        if not all(source.get("maskSha256") and source.get("maskPath") for source in semantic["sources"]):
            raise ValueError("Scene analysis did not persist source mask artifacts")

        export_signatures = {"png": (b"\x89PNG\r\n\x1a\n",), "tiff": (b"II*\x00", b"MM\x00*"), "jxl": (b"\xff\x0a", b"\x00\x00\x00\x0cJXL \r\n\x87\n")}
        for extension in ("png", "tiff", "jxl"):
            target = root / f"result.{extension}"
            call({"command": "export", "jobId": job_id, "destination": str(target)})
            while True:
                exported = call({"command": "status", "jobId": job_id})
                if exported["state"] in ("completed", "failed", "cancelled") and exported.get("operation") != "render":
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"{extension} export smoke timed out")
                time.sleep(1)
            if exported["state"] != "completed" or not target.is_file() or target.stat().st_size < 16:
                raise RuntimeError(f"{extension} export failed: {exported}")
            header = target.read_bytes()[:12]
            expected = export_signatures[extension]
            if not any(header.startswith(signature) for signature in expected):
                raise ValueError(f"Unexpected {extension} output header: {header!r}")
    return {"bundle": str(bundle), "model": model, "dylibCount": len(dylibs), "ffiAbi": 1, "sceneInference": "public job JSON render passed", "exports": ["PNG", "TIFF", "JXL"]}


def write_package_manifest(package: Path, lock_path: Path) -> dict:
    package = package.resolve(strict=True)
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    bundle = package / "PocketGigaScan.app"
    bundle_result = verify_bundle(bundle, smoke=False)
    files = []
    for path in sorted(item for item in package.rglob("*") if item.is_file() and item.name != "build-manifest.json"):
        files.append({"path": path.relative_to(package).as_posix(), "sizeBytes": path.stat().st_size, "sha256": sha256(path)})
    manifest = {
        "schemaVersion": 1,
        "product": "PocketGigaScan",
        "platform": "macOS",
        "architecture": lock["architecture"],
        "minimumMacOS": lock["minimumMacOS"],
        "bundleIdentifier": "com.lumiaiq.pocketgigascan",
        "distribution": "local ad-hoc signed developer test build; not notarized",
        "dependencies": lock,
        "sceneModel": {"path": "PocketGigaScan.app/Contents/Resources/models/scene-model-v1.onnx", "sha256": bundle_result["model"]["sha256"], "sizeBytes": bundle_result["model"]["sizeBytes"]},
        "files": files,
    }
    (package / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--write-manifest", type=Path)
    parser.add_argument("--lock", type=Path, default=ROOT / "scripts" / "macos-dependencies.lock.json")
    args = parser.parse_args()
    try:
        if args.write_manifest:
            result = write_package_manifest(args.write_manifest, args.lock)
        elif args.bundle:
            result = verify_bundle(args.bundle, args.smoke)
        elif args.model and args.manifest:
            result = verify_model(args.model, args.manifest)
        else:
            parser.error("provide --model and --manifest, --bundle, or --write-manifest")
            return 64
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"macOS package verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
