# DWARF 3 mobile import implementation

User authorized implementation on 2026-10-07 following the device-import research. Target Android and iOS; camera selection, transfer and stitching run entirely on the phone. Coordinator reviews Luna implementations and owns validation.

## Design

Use a small shared Dart HTTP client for device identity, paged album metadata and original-directory discovery. Preserve the distinction between album thumbnails and the complete original-photo set. Unsupported directory enumeration is a visible failure, never a fabricated success. The default camera address is 192.168.88.1 and is editable. Users connect through system Wi-Fi settings.

Stream files into application-owned durable intake folders, keeping partial files and a versioned manifest. Resume only after validating HTTP Range responses and remote identity. Restart a partial file safely when Range is unsupported. Reject changed source identity rather than mixing old and new bytes. Retry transient errors with a bound; expose pause/retry after exhaustion. Keep originals on camera untouched. Persist completed file hashes and verify JPEG metadata before admitting a batch into the existing queue. Interrupted batches cannot be stitched. Task and queue storage remain compatible.

Use the current mobile batch queue for local stitching, maintaining original names, ordering, source provenance, existing grid confirmation and preview/final separation. Shared UI exposes connection status, selection, transfer progress and recovery in English and Chinese. Downloaded batches can be stitched after disconnecting from the camera.

iOS receives local-network configuration and storage/resource/lifecycle source adapters. Native library packaging and real iOS execution require the user's later macOS build. No unconditional background-execution guarantee is made; durable recovery is required.

## Owned tasks

- [x] Luna protocol coder: new device client, download models/service, HTTP fixture tests covering discovery, interrupted streams, Range 200/206/416, identity changes, cancellation and durable reload.
- [x] Luna UI coder: device page, transfer controller, batch queue admission and localized UI tests. Depend on the protocol coder's explicit interfaces.
- [x] Luna platform coder: Android Wi-Fi access and iOS platform source adapters, build handoff and channel contract tests.
- [x] Coordinator: independent correctness review, repository-visible handoffs, source tracking, Flutter analysis/tests, core format/tests, build contracts, normal Windows Release build and ARM64 Android APK.
- [x] Coordinator: connected Android fixture integration checks for transfer/resume, queue reload/deduplication, hashes and native ABI. Release installed without clearing user data.
- [ ] Real DWARF identity/listing/original download and camera/optical acceptance: pending camera network access. iOS Xcode/device validation: pending macOS.

## Validation boundaries

Local HTTP fixtures establish protocol behavior only. An APK build establishes packaging only. The connected Android phone is the requested runtime validation target; Wireless ADB now passes the phone fixture integration test for interruption/resume, hashes, durable queue admission and native ABI loading. Real camera enumeration, full originals, firmware compatibility and optical stitching quality require distinct evidence. iOS builds cannot be executed on this Windows host.
