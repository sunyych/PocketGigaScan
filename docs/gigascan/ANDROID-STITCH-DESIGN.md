# PocketGigaScan Android stitching design

User-authorized scope, 2026-10-05: implement desktop processing features on the
connected Android phone; retain an extensible iOS boundary. No artificial photo
or grid count ceiling. Require confirmation for more than 6 rows, 6 columns,
or 36 photos. Do not implement camera control or revive retired camera code.

## Shared processing and policy

Flutter task/queue models and Rust/OpenCV registration, tiling and PNG/TIFF/JPEG
XL exports remain common to Windows and Android. Positive dimensions, complete
grids, unique coordinates and checked arithmetic remain validated. Resource
errors are based on actual allocation, storage and execution budgets, not a
fixed photo count. Neighbor-only matching and all original inputs are retained.

Large-job approval precedes native start and output creation. Persist approval
against task ID, photo identities and grid shape; changed grids/inputs and new
runs invalidate it. Batch ready items awaiting approval cannot auto-start,
including after reloading. Cancellation makes no native start call. Existing
jobs retain checkpoint ownership and resumability.

Large normal equations use sparse/block storage and PCG rather than allocating
an unbounded dense matrix. Small-case behavior is preserved; accepted solves
require a true-residual check. Solver breakdown is reported, never disguised
as successful texture registration or zero residual.

## Android adapters

Use application ID `com.lumiaiq.pocketgigascan`, including native bridge channels;
operator branding is PocketGigaScan. This new package can coexist with the old
Android package, whose private storage cannot be automatically accessed by it.
No uninstall or data clearing is part of this identity change. Windows retains
lookup of legacy task directories after the company identity change.
Native core comes from `native/core`, built
for ARM64 with NDK 28.2.13676358 and minimum API 29. Include JPEG XL support from
fixed official source/dependency archives, not a previous Android binary.

Folder batch import uses the system Storage Access Framework. Granted document
URIs are streamed to private staging and never handed to OpenCV as filesystem
paths. Export save uses the system destination picker and bounded streaming;
sharing supplies the actual PNG/TIFF/JXL MIME type. External originals are never
deleted. Native path ownership is checked before modifying private storage.

Runtime service APIs isolate foreground notifications, wake locks and device
resource reads from Flutter processing. Active sessions may run in background
when the guard succeeds. If it cannot start, preserve state and pause safely.
Process death still requires durable checkpoint recovery; a foreground service
is not a guarantee of uninterrupted work. Charger status is advisory, not a
photo-count or small-job prerequisite.

Service timeout requests survive Activity destruction in private preferences.
The next attached engine reads them before queue admission and requests pause;
only confirmed quiescent jobs are acknowledged. Without an attached engine,
persisting the request does not immediately pause native threads. Qualification
must include Activity recreation and recovery as well as ordinary backgrounding.

## Huge-file viewer

Completed PNG, TIFF/BigTIFF and JPEG XL jobs use their persisted multiresolution
pyramids. Load and decode visible tiles only, with bounded cache/in-flight work;
never decode the complete gigapixel image into a Flutter bitmap. Preserve
desktop wheel/drag and add Android pinch/drag/fit gestures, responsive narrow
layouts, and collapsed diagnostic status by default.

## iOS boundary

Shared models, policy, viewer and core C ABI stay portable. A later iOS adapter
reserves the same `com.lumiaiq.pocketgigascan` bundle identity and
will implement document picking/saving, resource and lifecycle APIs and static
native linkage (`DynamicLibrary.process`). iOS packaging and device execution
require a Mac/iOS toolchain and separate qualification; they are not claimed here.

## Qualification

Run unit/widget tests, existing strict screenshots and Windows/core regressions.
Build and verify the ARM64 APK's native symbols, runtime dependencies, signatures
and ELF/ZIP alignment. Install on the connected Moto g play (2024), Android 14
API 34; execute automated real-FFI format, queue, confirmation and viewer tests
in isolated app storage. Exercise SAF selection/save/share and foreground/reload
on that device. Preserve originals and existing user data. Report synthetic,
copied-real-image, physical-device and 16 KB structural checks separately.

Platform references: [SAF](https://developer.android.com/training/data-storage/shared/documents-files),
[foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types),
[native alignment](https://developer.android.com/guide/practices/page-sizes),
[JPEG XL build sources](https://github.com/libjxl/libjxl/blob/v0.12.0/BUILDING.md).
