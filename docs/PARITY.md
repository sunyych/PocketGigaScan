# PocketGigaScan platform behavior and verification

PocketGigaScan is a panorama stitcher for DWARF photo grids. The Flutter
application and portable Rust/OpenCV engine are shared where each platform's
packaging supports them. Android camera listing and a verified original
download have device evidence; full camera-origin panorama reconstruction and
physical iOS transfer remain unqualified. See the [DWARF mobile import evidence](gigascan/evidence/DWARF-MOBILE-IMPORT-2026-10-07.md).

| Surface | Shared behavior | Platform behavior and verification |
| --- | --- | --- |
| Import and grid | Preserve selected JPEG originals, neighbor-only registration, center horizontal/vertical overlap, texture refinement and checked complete-grid validation. No fixed photo or axis cap. | Windows uses filesystem selection; Android uses the system file/tree picker with streamed private copies. Android confirms rows > 6, columns > 6 or photos > 36 before processing. |
| Tasks and batches | Persisted queue, pause/recovery, resource admission and record-only deletion that preserves inputs and exports. | Android uses current CPU/RAM/storage/thermal readings and a foreground-service adapter. Process death requires checkpoint recovery; charger state is advisory. |
| Exports | Automatic lossless PNG/TIFF/BigTIFF or lossy JPEG XL (distance 1.0, exact alpha); TIFF is the default for new jobs. | Select a format before processing; completed tasks make a copy to edit settings. Export failure recovery remains available. Android saves through the system destination picker or shares an app-owned file with the matching MIME type. |
| Huge viewer | Task-bound pyramid tiles, visible-region decoding, cache eviction, fit/zoom/pan and initially collapsed output information. | Desktop supports wheel/drag; Android supports pinch/drag and narrow layouts. Viewing task outputs is separate from decoding an arbitrary external image without its pyramid. |
| Identity and language | PocketGigaScan title/icon and `com.lumiaiq.pocketgigascan` application identity; English default and Chinese system locale, including auto-export options and task phases. | Windows preserves lookup of compatible existing task directories. Android task files are app-private. Native service notification strings have locale resources. |
| Platform builds | Shared presentation and portable core are qualified separately from platform runtime behavior. | Windows Release and macOS Apple silicon source builds include native stitching. Android ARM64 host/package checks cover its bundled core. The iOS runner builds without native stitching linkage; iOS signing, device and native stitching qualification remain open. |

Build and package evidence is tracked by platform: see the [roadmap](gigascan/ROADMAP.md),
[Android qualification](gigascan/evidence/ANDROID-STITCH-2026-10-05.md),
[macOS qualification](gigascan/evidence/FOUR-PLATFORM-BUILD-2026-10-17.md) and
[four-platform build record](gigascan/evidence/FOUR-PLATFORM-BUILD-2026-10-17.md).
Package checks do not establish physical-device or visual acceptance.
