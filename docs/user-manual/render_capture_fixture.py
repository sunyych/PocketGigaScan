#!/usr/bin/env python3
"""Run an isolated native render/export fixture for the manual viewer screen.

This creates local evidence only under .local/manual-capture. A successful
native job proves that this fixture was rendered by the selected DLL; it is not
an image-quality or real-scene alignment qualification.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import math
import os
import platform
import re
import sys
import time
from pathlib import Path
from typing import Any

from PIL import Image


REPO = Path(__file__).resolve().parents[2]
_ENV_LIBRARY = os.environ.get("POCKETGIGASCAN_NATIVE_LIBRARY")
_REPO_LIBRARY = REPO / ".local" / "flutter-stitch-core" / "windows" / "lumia_gigascan_core.dll"
DEFAULT_LIBRARY = Path(_ENV_LIBRARY) if _ENV_LIBRARY else (
    _REPO_LIBRARY if _REPO_LIBRARY.is_file() else None
)
DEFAULT_SOURCE = REPO / ".local" / "manual-capture" / "originals"
DEFAULT_OUTPUT = REPO / ".local" / "manual-capture" / "native-result"
FILENAME_RE = re.compile(r"row_(\d+)_col_(\d+)\.jpe?g$", re.I)
TERMINAL = {"completed", "failed", "cancelled"}


class NativeCallError(RuntimeError):
    def __init__(self, response: dict[str, Any]):
        error = response.get("error")
        if isinstance(error, dict):
            self.code = str(error.get("code", "NATIVE_ERROR"))
            self.message = str(error.get("message", "native call failed"))
        else:
            self.code = "NATIVE_ERROR"
            self.message = str(error or "native call failed")
        super().__init__(f"{self.code}: {self.message}")


class NativeJobApi:
    def __init__(self, library_path: Path):
        if os.name != "nt":
            raise RuntimeError("This fixture loader is for Windows DLLs.")
        if not library_path.is_file():
            raise FileNotFoundError(f"Native DLL not found: {library_path}")
        self._dll_dirs: list[Any] = []
        for directory in (library_path.parent, library_path.parent / "data"):
            if directory.is_dir():
                self._dll_dirs.append(os.add_dll_directory(str(directory)))
        self.library = ctypes.WinDLL(str(library_path))
        self.library.lumia_gigascan_abi_version.argtypes = []
        self.library.lumia_gigascan_abi_version.restype = ctypes.c_uint32
        self.library.lumia_gigascan_job_json.argtypes = [ctypes.c_char_p]
        self.library.lumia_gigascan_job_json.restype = ctypes.c_void_p
        self.library.lumia_gigascan_free.argtypes = [ctypes.c_void_p]
        self.library.lumia_gigascan_free.restype = None
        version = int(self.library.lumia_gigascan_abi_version())
        if version != 1:
            raise RuntimeError(f"Unsupported native ABI {version}; expected 1")

    def call(self, command: dict[str, Any]) -> dict[str, Any]:
        encoded = json.dumps(command, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        ) + b"\0"
        response_ptr = self.library.lumia_gigascan_job_json(encoded)
        if not response_ptr:
            raise RuntimeError("Native core returned a null JSON response.")
        try:
            response = json.loads(ctypes.string_at(response_ptr).decode("utf-8"))
        finally:
            self.library.lumia_gigascan_free(response_ptr)
        if not isinstance(response, dict):
            raise RuntimeError("Native response was not a JSON object.")
        if response.get("ok") is not True:
            raise NativeCallError(response)
        return response

    def close(self) -> None:
        self._dll_dirs.clear()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _sources(directory: Path) -> tuple[list[dict[str, Any]], int, int]:
    if not directory.is_dir():
        raise FileNotFoundError(f"Synthetic source directory not found: {directory}")
    candidates = sorted(path for path in directory.iterdir() if path.is_file())
    photos: dict[tuple[int, int], dict[str, Any]] = {}
    dimensions: tuple[int, int] | None = None
    for path in candidates:
        match = FILENAME_RE.fullmatch(path.name)
        if not match:
            continue
        row, column = int(match.group(1)) - 1, int(match.group(2)) - 1
        with Image.open(path) as photo:
            photo.verify()
        with Image.open(path) as photo:
            width, height = photo.size
            if photo.format != "JPEG":
                raise ValueError(f"Expected JPEG source: {path.name}")
        if dimensions is None:
            dimensions = (width, height)
        elif dimensions != (width, height):
            raise ValueError(f"Source dimensions differ: {path.name}")
        cell = (row, column)
        if cell in photos:
            raise ValueError(f"Duplicate source grid cell: {cell}")
        photos[cell] = {
            "row": row,
            "column": column,
            "path": str(path.resolve()),
            "forceGrid": False,
            "placementConstraint": {
                "kind": "gridPrior",
                "origin": "systemFallback",
            },
            "name": path.name,
            "sha256": _sha256(path),
            "width": width,
            "height": height,
        }
    expected = {(row, column) for row in range(2) for column in range(3)}
    if set(photos) != expected:
        found = sorted(photos)
        raise ValueError(
            "Expected exactly a complete 2x3 source grid; "
            f"found cells {found} in {directory}"
        )
    if dimensions != (640, 400):
        raise ValueError(f"Expected six 640x400 sources, got {dimensions}")
    ordered = [photos[cell] for cell in sorted(photos)]
    return ordered, dimensions[0], dimensions[1]


def _request(
    tiles: list[dict[str, Any]],
    width: int,
    height: int,
    output_root: Path,
    *,
    estimated_fallback: bool,
) -> dict[str, Any]:
    focal = width / (2 * math.tan(math.radians(45) / 2))
    if estimated_fallback:
        request_tiles = [
            {
                "row": tile["row"],
                "column": tile["column"],
                "path": tile["path"],
                "forceGrid": True,
                "placementConstraint": {
                    "kind": "hardGridLock",
                    "origin": "operator",
                },
            }
            for tile in tiles
        ]
    else:
        request_tiles = [
            {key: tile[key] for key in (
                "row", "column", "path", "forceGrid", "placementConstraint"
            )}
            for tile in tiles
        ]
    request: dict[str, Any] = {
        "tiles": request_tiles,
        "rows": 2,
        "columns": 3,
        "fx": focal,
        "fy": focal,
        "cx": (width - 1) / 2,
        "cy": (height - 1) / 2,
        "sourceWidth": width,
        "sourceHeight": height,
        "placementMode": "grid-assisted",
        "neighborMode": "eight",
        "parallelMatching": True,
        "parallelRendering": True,
        "useSourceCache": True,
        "useAlignmentCache": False,
        "alignmentCacheDir": str((output_root.parent / ".alignment-cache").resolve()),
        "featureType": "sift",
        "matcherType": "bf",
        "registrationMegapixels": 2.0,
        "allowPrecisionRecovery": False,
        "allowNominalGridFallback": estimated_fallback,
        "autoGridOverlap": not estimated_fallback,
        "refineGridNeighbors": not estimated_fallback,
        "seamBlendMode": "feather",
        "localTextureWarp": not estimated_fallback,
        "maxEdgeReprojectionRmsPixels": 12,
        "protectPeople": False,
        "smoothWater": False,
    }
    if estimated_fallback:
        # The native engine uses these nominal overlap values only for the
        # explicitly estimated-grid fallback; this is not visual registration.
        request["gridHorizontalOverlap"] = 0.25
        request["gridVerticalOverlap"] = 0.25
    return request


def _record(path: Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _wait_for_terminal(
    api: NativeJobApi,
    job_id: str,
    timeout_seconds: float,
    status_path: Path,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last_signature = None
    latest: dict[str, Any] = {}
    while time.monotonic() < deadline:
        latest = api.call({"command": "status", "jobId": job_id})
        state = str(latest.get("state", "unknown"))
        stage = str(latest.get("stage", ""))
        progress = latest.get("progress")
        signature = (state, stage, round(float(progress or 0), 2))
        if signature != last_signature:
            print(f"Native job: state={state}, stage={stage}, progress={progress}")
            _record(status_path, latest)
            last_signature = signature
        if state in TERMINAL:
            return latest
        time.sleep(0.5)
    try:
        api.call({"command": "cancel", "jobId": job_id})
    except NativeCallError:
        pass
    cancel_deadline = time.monotonic() + 20
    while time.monotonic() < cancel_deadline:
        latest = api.call({"command": "status", "jobId": job_id})
        if latest.get("state") in TERMINAL:
            return latest
        time.sleep(0.5)
    raise TimeoutError(f"Native job {job_id} did not settle after cancellation.")


def _run_one(
    api: NativeJobApi,
    output_dir: Path,
    sources: list[dict[str, Any]],
    width: int,
    height: int,
    timeout_seconds: float,
    *,
    estimated_fallback: bool,
) -> dict[str, Any]:
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    if output_dir.exists():
        raise FileExistsError(
            f"Refusing to reuse native job directory: {output_dir}; "
            "inspect or move the existing fixture output first."
        )
    request = _request(
        sources, width, height, output_dir,
        estimated_fallback=estimated_fallback,
    )
    started = api.call({
        "command": "start",
        "request": request,
        "outputDir": str(output_dir.resolve()),
        "memoryBudgetMiB": 128,
        "workers": 1,
    })
    job_id = started.get("jobId")
    if not isinstance(job_id, str) or not job_id:
        raise RuntimeError(f"Native start response did not include jobId: {started}")
    status_path = output_dir.parent / f"{output_dir.name}-status.json"
    _record(status_path, started)
    status = _wait_for_terminal(api, job_id, timeout_seconds, status_path)
    if status.get("state") != "completed" or status.get("error") is not None:
        raise NativeCallError({"error": status.get("error") or {
            "code": "NATIVE_JOB_FAILED",
            "message": f"job ended in state {status.get('state')} at {status.get('stage')}",
        }})
    manifest_path = output_dir / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Native render did not produce {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("complete") is not True:
        raise RuntimeError(f"Native render manifest is incomplete: {manifest}")
    layout_path = output_dir / "layout.json"
    if not layout_path.is_file():
        raise FileNotFoundError(f"Native render did not produce {layout_path}")
    layout = json.loads(layout_path.read_text(encoding="utf-8"))
    report = layout.get("report") if isinstance(layout, dict) else None
    report = report if isinstance(report, dict) else {}
    export_path = output_dir / "export.png"
    export_started = api.call({
        "command": "export",
        "jobId": job_id,
        "destination": str(export_path.resolve()),
    })
    _record(status_path, export_started)
    exported = _wait_for_terminal(api, job_id, timeout_seconds, status_path)
    if exported.get("state") != "completed" or exported.get("error") is not None:
        raise NativeCallError({"error": exported.get("error") or {
            "code": "NATIVE_EXPORT_FAILED",
            "message": f"export ended in state {exported.get('state')}",
        }})
    if not export_path.is_file() or export_path.stat().st_size <= 1024:
        raise RuntimeError(f"Native export is missing or unexpectedly small: {export_path}")
    with Image.open(export_path) as result:
        result.verify()
    with Image.open(export_path) as result:
        export_width, export_height = result.size
        if (export_width, export_height) != (manifest.get("width"), manifest.get("height")):
            raise RuntimeError(
                "PNG dimensions differ from native render manifest: "
                f"{(export_width, export_height)} vs "
                f"{(manifest.get('width'), manifest.get('height'))}"
            )
    return {
        "jobId": job_id,
        "outputDir": str(output_dir.resolve()),
        "statusPath": str(status_path.resolve()),
        "manifestPath": str(manifest_path.resolve()),
        "layoutPath": str(layout_path.resolve()),
        "exportPath": str(export_path.resolve()),
        "exportSha256": _sha256(export_path),
        "exportBytes": export_path.stat().st_size,
        "exportDimensions": [export_width, export_height],
        "finalState": exported.get("state"),
        "finalStage": exported.get("stage"),
        "manifestComplete": manifest.get("complete"),
        "qualityStatus": report.get("qualityStatus"),
        "qualityWarnings": report.get("qualityWarnings", []),
        "visualTileCount": report.get("visualTileCount"),
        "gridEstimatedTileCount": report.get("gridEstimatedTileCount"),
        "visualGraphComponentCount": report.get("visualGraphComponentCount"),
        "connectedTileCount": report.get("connectedTileCount"),
        "registrationMs": report.get("totalAlignmentMs"),
        "autoGridOverlap": report.get("autoGridOverlap"),
        "nativeFinalState": exported.get("state"),
        "nativeFinalStage": exported.get("stage"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--library",
        type=Path,
        default=DEFAULT_LIBRARY,
        help=(
            "Native DLL path. Defaults to POCKETGIGASCAN_NATIVE_LIBRARY, then "
            "the repo-local .local/flutter-stitch-core/windows DLL if present."
        ),
    )
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--timeout-seconds", type=float, default=180)
    parser.add_argument("--skip-estimated-fallback", action="store_true")
    args = parser.parse_args()
    if args.library is None:
        parser.error(
            "no native DLL found; set POCKETGIGASCAN_NATIVE_LIBRARY or pass --library"
        )
    api: NativeJobApi | None = None
    try:
        source_dir = args.source_dir.resolve()
        sources, width, height = _sources(source_dir)
        print(f"Validated {len(sources)} synthetic JPEGs: {width}x{height}")
        for source in sources:
            print(f"  {source['name']} sha256={source['sha256']}")
        api = NativeJobApi(args.library.resolve())
        capabilities = api.call({"command": "capabilities"}).get("capabilities", {})
        print(f"Native ABI=1, backend={capabilities.get('backend')}")
        if capabilities.get("activeJobs", 0) != 0:
            raise RuntimeError(
                "The selected native library already reports active jobs; "
                "use a dedicated DLL process before capturing."
            )
        try:
            result = _run_one(
                api, args.output_dir.resolve(), sources, width, height,
                args.timeout_seconds, estimated_fallback=False,
            )
            if result.get("gridEstimatedTileCount", 0):
                result["placementEvidence"] = "partial_visual_evidence_with_estimated_grid_bridges"
            else:
                result["placementEvidence"] = "visual_registration"
            result["visualQualityClaim"] = False
        except (NativeCallError, TimeoutError, RuntimeError) as auto_error:
            if args.skip_estimated_fallback:
                raise
            fallback_dir = args.output_dir.with_name(args.output_dir.name + "-estimated-grid")
            print(f"Auto registration did not produce an export: {auto_error}")
            print(f"Trying an explicitly estimated forced-grid render in {fallback_dir}")
            fallback = _run_one(
                api, fallback_dir.resolve(), sources, width, height,
                args.timeout_seconds, estimated_fallback=True,
            )
            fallback["placementEvidence"] = "nominal_forced_grid_estimate"
            fallback["visualQualityClaim"] = False
            fallback["autoRegistrationFailure"] = str(auto_error)
            result = fallback
        record = {
            "fixtureType": "synthetic_2x3_panorama_viewer_demo",
            "appVersion": "1.5.2+31 source baseline",
            "createdUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "hostPlatform": platform.platform(),
            "nativeLibrary": str(args.library.resolve()),
            "nativeAbi": 1,
            "nativeBackend": capabilities.get("backend"),
            "sourceImages": [
                {key: source[key] for key in (
                    "name", "sha256", "width", "height", "row", "column"
                )}
                for source in sources
            ],
            **result,
            "qualificationBoundary": (
                "A native-rendered synthetic fixture for UI documentation only. "
                "This does not qualify real-scene registration, panorama quality, "
                "hardware performance, or a production installation."
            ),
        }
        record_path = Path(record["outputDir"]).parent / (
            f"capture-fixture-{Path(record['outputDir']).name}.json"
        )
        _record(record_path, record)
        print(f"Native job state={record['finalState']} stage={record['finalStage']}")
        print(f"Placement evidence={record['placementEvidence']}")
        print(f"Export={record['exportPath']}")
        print(f"Export SHA-256={record['exportSha256']}")
        print(f"Manifest={record['manifestPath']}")
        print(f"Evidence={record_path.resolve()}")
        return 0
    except Exception as error:
        print(f"Native capture fixture failed: {error}", file=sys.stderr)
        return 2
    finally:
        if api is not None:
            api.close()


if __name__ == "__main__":
    raise SystemExit(main())
