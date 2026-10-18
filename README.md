# PocketGigaScan

PocketGigaScan is an independent panorama stitcher for DWARF photo grids, built with Flutter and a Rust/OpenCV engine. It can connect to a DWARF camera over its local network, list panorama packages and download original photos for local stitching; Android has real camera and phone evidence. Windows has a published build; the Android ARM64 package passes host and packaging checks; and the Apple silicon macOS package passes source Release, offline inference and export checks. The existing iOS runner builds for devices and simulators without the native stitching library. Physical iOS camera-transfer behavior, signing and native iOS stitching remain unqualified. Product boundaries and build evidence are documented below.

## Download

[Latest Windows download](https://github.com/sunyych/PocketGigaScan/releases/download/latest/PocketGigaScan-Windows-x64.zip) · [Releases](https://github.com/sunyych/PocketGigaScan/releases) · [Build status](https://github.com/sunyych/PocketGigaScan/actions)

Extract the entire ZIP and run `PocketGigaScan.exe`. The EXE requires the included Flutter DLL, native core and data directory; do not copy it alone. Every push creates a build artifact; successful default-branch builds refresh the stable `latest` download after signing is configured and verified. Current downloads remain unsigned while SignPath Foundation acceptance and repository configuration are pending.

The macOS test client targets Apple silicon (M1 or later), macOS 14 or newer.
Its [Mac build workflow](https://github.com/sunyych/PocketGigaScan/actions/workflows/macos-build.yml)
produces an ad-hoc-signed test ZIP with the native engine, offline scene model,
runtime and licenses. See [Mac build and test instructions](Apps/Flutter/stitch_app/APPLE-BUILD.md)
and [platform qualification evidence](docs/gigascan/evidence/FOUR-PLATFORM-BUILD-2026-10-17.md).
The qualified test build is version 1.5.1+30. Physical Mac launch/import/resume and real-photo visual acceptance remain unqualified.

The existing iOS Flutter runner is built on a hosted Mac by the
[iOS build workflow](https://github.com/sunyych/PocketGigaScan/actions/workflows/ios-build.yml).
It produces unsigned device and simulator app bundles without native stitching
linkage. These bundles are build-validation artifacts, not signed install or
TestFlight releases. Four-platform build limits and hashes are in the
[qualification evidence](docs/gigascan/evidence/FOUR-PLATFORM-BUILD-2026-10-17.md).

## Code signing policy

Planned provider: Free code signing provided by SignPath.io, certificate by SignPath Foundation; the application was submitted on 2026-10-08 and is pending review. The project plans to sign only its own application EXE and Rust core DLL. Bundled upstream DLL bytes, including any vendor signatures already present, remain unchanged. The signing approver is the repository maintainer, and signing requires a protected-environment approval. Read the [Windows code signing policy](docs/WINDOWS-SIGNING.md) for team roles, privacy and current setup status. No signed Windows release is available yet.

## Stitching

- Connect to a DWARF camera over its local network, list panorama packages and download original photos into app-owned storage; stitching and export remain local.
- Import DWARF photo grids, inspect rows/columns/order and estimate horizontal/vertical overlap from textured central neighbors.
- Compare adjacent photos; refine texture geometry and retain every input. Explicit nominal/forced grid placement remains labelled as estimated and needs visual review.
- Process individual jobs or queue child folders with resource-bounded concurrency, pause/resume and progress.
- Choose lossless PNG or TIFF/BigTIFF, or high-quality lossy JPEG XL, before stitching. New Windows tasks default to TIFF and export automatically after successful rendering.
- On Windows/macOS, optionally protect complete people at seams and smooth water overlap. The two settings are independent and default off; the bundled model runs offline. Phones hide these controls and keep semantic inference disabled.
- Open completed results in a tiled viewer with wheel zoom and drag. Task removal deletes only task records, never originals or exported images.
- Completed tasks hide processing settings/progress; create a copy to change settings and stitch again. Stitch details/logs open on demand.
- Open Settings to choose system/English/Chinese language, system/light/dark appearance, accent color, output quality, performance defaults and output folder. Processing defaults apply to new tasks; saved tasks retain their options.
- Expand Stitching log separately from Stitch details to see localized steps with timestamps and start/finish/total wall-clock time, including pauses and automatic export. Legacy tasks without timestamps show unknown times.

Android adds folder access through the system document picker, streamed save/share,
foreground processing and pinch/drag viewing. Android grids have no arbitrary
photo-count or axis limit: more than 6 rows, 6 columns or 36 photos requires
confirmation before processing. Concurrency remains bounded by actual resources.
Choose a persistent output folder in Settings to copy completed Android exports
automatically. The private result remains available for viewing; a failed copy
can be retried without re-encoding. Windows and macOS encode directly into their selected folder.
Package/device qualification status is recorded in the
[Android evidence](docs/gigascan/evidence/ANDROID-STITCH-2026-10-05.md).

Current application identity is `com.lumiaiq.pocketgigascan`. Windows keeps access
to legacy task directories. The new Android package can coexist with the old
package; its private task storage is separate. Shared export/UI corrections and
current package checks are recorded in the
[export and identity evidence](docs/gigascan/evidence/EXPORT-UI-IDENTITY-2026-10-06.md).

Old completed layouts must be copied into a new task and recomputed to receive geometry improvements. Changing their export format does not change alignment. Some original-photo obstructions have no clean neighbor coverage and remain in the result.

New registrations compare the eight immediate neighbors once per pair. A grid
prior allows texture matching; the explicit pin button applies a hard placement
lock and skips that photograph's visual constraints. Legacy locks retain unknown
origin until the operator changes them. Ordinary thumbnail clicks do not change
locks.

Settings includes an automatic/manual shared memory budget using current OS
total/available memory. Larger desktop budgets increase source-cache capacity;
they are allocated on demand. Existing reservations drain safely when lowering
the budget. Android retains conservative mobile headroom and concurrency limits.

Each task has one atomic, versioned `task.json` master record. It keeps source
hashes, grid and lock provenance, reconciled native poses/intrinsics/local warps,
neighbor diagnostics, output associations and timing. Old task files remain
readable. Uncomputed geometry stays null; color/brightness adjustments are marked
not applied because the renderer does not currently compute them. Removing a
task removes its master record and retains imported photos and exported results.

In the output viewer, click **Inspect pixel source**, then click a panorama
location to see geometrically covering source photographs and
their neighbor diagnostics. This does not infer the renderer's final blend owner.
PNG/TIFF dimensions are checked directly; JPEG XL tracing requires a verified
native producer receipt. Inspection and source status remain collapsed by default.
See the [performance and geometry evidence](docs/gigascan/evidence/DWARF-PERFORMANCE-2026-10-06.md)
for measured limits and the distinction between local crops and full-panorama acceptance.

## Source and build

| Path | Purpose |
| --- | --- |
| `Apps/Flutter/stitch_app` | Shared application and Windows/macOS/Android/iOS runners |
| `native/core` | Vendored independent Rust/OpenCV stitching and export engine |
| `scripts/build-dwarf-stitch-windows.ps1` | Source build, verification and complete Windows ZIP |
| `scripts/build-stitch-macos.sh` | Apple silicon source build, offline model and test ZIP verification |
| `scripts/build-stitch-android-core.ps1` | Pinned ARM64/optional x86_64 native source build and license staging |
| `justfile` | Current product build/check recipes |
| `branding` | Original icon source and generator |
| `docs` | Build, tests, scope and validation records |

[Build instructions](docs/BUILD.md) · [Tests](docs/gigascan/STITCH-TESTING.md) · [Architecture and platform boundaries](docs/RESTRUCTURE.md)

The application is licensed under Apache-2.0. Current Flutter, Rust, native-codec and model notices are documented in [third-party notices](THIRD-PARTY-NOTICES.md) and included by the platform packaging workflows. Remote camera capture/control is outside its scope. Android camera transfer is documented in [PG-062 evidence](docs/gigascan/evidence/DWARF-MOBILE-IMPORT-2026-10-07.md); the shared iOS transfer flow has not been physically qualified, and iOS stitching remains unlinked.
