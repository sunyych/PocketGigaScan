# DWARF camera media import for Android and iOS

## Research question

Can PocketGigaScan use the community DWARF SDK to select a panorama on the camera, copy its source photos directly to a phone, then queue and stitch locally on Android or iOS, with no computer in the workflow?

## Finding

This is a plausible mobile workflow, but the current SDK evidence does not yet prove that selecting a *panorama* exposes every original constituent photo. The public HTTP API exposes album media counts and paged media metadata. `MediaInfo` exposes `filePath`; `fileUrl` is a helper that constructs the SD-card URL on port 80. The inspected documentation/source confirms thumbnail use more clearly than raw original download. The API call that lists album entries must not be treated as proof that one panorama entry expands into its complete source-photo set. No documented recursive “panorama originals” API was found in the inspected source. `fitsList` is for astrophotography.

The TypeScript community SDK is not a native Android/iOS library. Flutter would need a small Dart client for the verified HTTP subset, plus camera discovery/connection handling and explicit response/error validation. Whether raw `fileUrl` retrieval works for full-resolution originals, and how album panorama records map to source sets, require protocol and physical-camera validation before committing to the UX contract.

## Current app evidence

The active product is `Apps/Flutter/stitch_app`, using shared Flutter UI/task models and `native/core`; `Apps/Android/` is ignored and absent from this checkout. Repo guidance says historical camera apps are retired. Do not revive those apps or make them a dependency.

- Single-task import opens the platform document/file picker for multiple JPEGs and copies selected files into an app-owned task input directory, recording hashes and JPEG metadata. It cannot browse the DWARF camera album or initiate a camera download. See `lib/services/platform_file_dialogs.dart` and `lib/services/photo_importer.dart`.
- Batch import currently selects a local folder tree, stages direct child folders through Android SAF into private app storage, then imports each child as a queue item. This assumes photos are already visible through a document provider; it is not a DWARF camera client. See `android/.../SafBatchStager.kt`, `services/mobile_storage_service.dart`, and `services/batch_folder_importer.dart`.
- The persistent batch model/repository/controller and Android stitching path already provide a place to queue downloaded source sets and process them offline after import. Queue records and task-owned copies are app-private and survive app restarts; inputs must remain retained. See `services/batch_queue_repository.dart`, `services/batch_queue_controller.dart`, and `models/batch_queue.dart`.
- Android has SAF and foreground-runtime adapters. The design explicitly treats interruption recovery as durable checkpoint work; a foreground service does not guarantee an uninterrupted render.
- iOS is currently only a portability boundary: the Android design document says later iOS work needs document picking/saving, resource/lifecycle adapters and static native linkage. An iOS runner exists. The coordinator reports its current AppDelegate has power/share channels and Info.plist lacks local-network/ATS setup. The shared native bridge already uses `DynamicLibrary.process` (`lib/services/native_job_api.dart`), but static linked engine packaging is not qualified. iOS camera connection, local network permission, file staging, background policy and device qualification remain to be implemented.

## Candidate mobile flow

1. Connect to the DWARF camera over its supported local network; detect and explain connection state and camera model.
2. Fetch `/album/list/mediaCounts`, then page `/album/list/mediaInfos` using `mediaType`, `pageIndex`, and `pageSize`. Present camera album entries and distinguish thumbnails/metadata from downloadable original sets.
3. After selecting a verified panorama/source set, download each original as a stream into a temporary app-owned intake directory. Verify completion, size and available camera-provided identity/checksum; never delete or modify camera originals.
4. Convert the completed intake into the existing immutable task input copies, preserve stable source ordering and original filenames, identify or request grid/layout metadata, and create one persistent batch item per selected panorama.
5. Queue items for local stitching. The queue should remain usable without the camera after the copies and task records are durable; interrupted downloads should be resumable or safely retried and must not become ready queue items.

The missing product decision is the mapping between a camera “panorama” album row and the photos required by this stitcher. It should be settled from API/protocol evidence and a device trial, because simply importing the rendered panorama JPEG would not provide the original overlapping frames needed for this stitcher.

## Platform boundaries and validation

Android can first use a small Dart HTTP client over the DWARF local network and reuse the current storage/queue pipeline. Validate network permission/discovery, connection loss during paged listing and streaming, large-file resume/retry, source hashes, and real camera album-to-original mapping. No hardware protocol validation is claimed here.

iOS can share the Dart protocol/client and queue models, but requires its own local-network permission UX and lifecycle/storage adapter. Background execution is best-effort under iOS and can be suspended or terminated; durable download state and restart recovery are required. Core Rust/OpenCV linkage is another separate iOS build/qualification task. No iOS implementation or device validation is claimed.

The no-computer goal is compatible with this architecture: phone app connects to camera, copies originals into phone-owned storage, and runs stitching on that phone. It does not imply cloud processing or continued operation after the OS terminates the app.

## References

- [DWARF community SDK HTTP API](https://raw.githubusercontent.com/alikh31/dwarflab-sdk/main/docs/http-api.md)
- [SDK album HTTP implementation](https://raw.githubusercontent.com/alikh31/dwarflab-sdk/main/packages/sdk/src/http/album.ts)
- Current app design: [Android stitching design](ANDROID-STITCH-DESIGN.md)
- Current mobile qualification and limits: [Android evidence](evidence/ANDROID-STITCH-2026-10-05.md)
