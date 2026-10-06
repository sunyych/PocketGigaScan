# PocketGigaScan

Independent DWARF panorama stitching on shared Flutter/Rust processing layers. Windows has a published build; the Android ARM64 APK passes host tests and packaging inspection, with connected-device qualification pending. The portable processing boundary is retained for future iOS work. This product does not use the retired OpenPocketCine/DJI application or protocol code.

## Download

[Latest Windows download](https://github.com/sunyych/PocketGigaScan/releases/download/latest/PocketGigaScan-Windows-x64.zip) · [Releases](https://github.com/sunyych/PocketGigaScan/releases) · [Build status](https://github.com/sunyych/PocketGigaScan/actions)

Extract the entire ZIP and run `PocketGigaScan.exe`. The EXE requires the included Flutter DLL, native core and data directory; do not copy it alone. Every push creates a build artifact; successful default-branch builds refresh the stable `latest` download. The executable is currently unsigned.

## Stitching

- Import DWARF photo grids, inspect rows/columns/order and estimate horizontal/vertical overlap from textured central neighbors.
- Compare adjacent photos; refine texture geometry and retain every input. Explicit nominal/forced grid placement remains labelled as estimated and needs visual review.
- Process individual jobs or queue child folders with resource-bounded concurrency, pause/resume and progress.
- Choose PNG, TIFF/BigTIFF or JPEG XL. New Windows tasks default to TIFF and export automatically after successful rendering.
- Open completed results in a tiled viewer with wheel zoom and drag. Task removal deletes only task records, never originals or exported images.
- Follow the system language: Chinese locales use Chinese; other locales use English.

Android adds folder access through the system document picker, streamed save/share,
foreground processing and pinch/drag viewing. Android grids have no arbitrary
photo-count or axis limit: more than 6 rows, 6 columns or 36 photos requires
confirmation before processing. Concurrency remains bounded by actual resources.
Package/device qualification status is recorded in the
[Android evidence](docs/gigascan/evidence/ANDROID-STITCH-2026-10-05.md).

Old completed layouts must be copied into a new task and recomputed to receive geometry improvements. Changing their export format does not change alignment. Some original-photo obstructions have no clean neighbor coverage and remain in the result.

## Source and build

| Path | Purpose |
| --- | --- |
| `Apps/Flutter/stitch_app` | Shared application and Windows/Android runners |
| `native/core` | Vendored independent Rust/OpenCV stitching and export engine |
| `scripts/build-dwarf-stitch-windows.ps1` | Source build, verification and complete Windows ZIP |
| `scripts/build-stitch-android-core.ps1` | Pinned ARM64/optional x86_64 native source build and license staging |
| `justfile` | Current product build/check recipes |
| `branding` | Original icon source and generator |
| `docs` | Build, tests, scope and validation records |

[Build instructions](docs/BUILD.md) · [Tests](docs/gigascan/STITCH-TESTING.md) · [Scope/migration](docs/RESTRUCTURE.md)

The original Apache2.0 license and historical NOTICE are retained. Current native/Flutter dependencies ship with their required licenses. No camera connectivity or physical capture qualification is claimed by stitching tests.
