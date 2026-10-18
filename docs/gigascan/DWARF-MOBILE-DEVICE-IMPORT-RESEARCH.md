# DWARF camera media import for Android and iOS

## Research question

Can PocketGigaScan use the community DWARF SDK to select a panorama on the camera, copy its source photos directly to a phone, then queue and stitch locally on Android or iOS, with no computer in the workflow?

## Finding at the research date (2026-10-05)

This is a plausible mobile workflow, but the current SDK evidence does not yet prove that selecting a *panorama* exposes every original constituent photo. The public HTTP API exposes album media counts and paged media metadata. `MediaInfo` exposes `filePath`; `fileUrl` is a helper that constructs the SD-card URL on port 80. The inspected documentation/source confirms thumbnail use more clearly than raw original download. The API call that lists album entries must not be treated as proof that one panorama entry expands into its complete source-photo set. No documented recursive “panorama originals” API was found in the inspected source. `fitsList` is for astrophotography.

The TypeScript community SDK is not a native Android/iOS library. Flutter would need a small Dart client for the verified HTTP subset, plus camera discovery/connection handling and explicit response/error validation. Whether raw `fileUrl` retrieval works for full-resolution originals, and how album panorama records map to source sets, require protocol and physical-camera validation before committing to the UX contract.

## App evidence and subsequent implementation

At the time of this research, the app used local file pickers and had no DWARF
camera client. The proposed flow below recorded the API and protocol questions
that required implementation and physical validation.

- Single-task import opened the platform document/file picker for multiple JPEGs and copied selected files into an app-owned task input directory, recording hashes and JPEG metadata. See `lib/services/platform_file_dialogs.dart` and `lib/services/photo_importer.dart`.
- Batch import selected a local folder tree, staged direct child folders through Android SAF into private app storage, then imported each child as a queue item. See `android/.../SafBatchStager.kt`, `services/mobile_storage_service.dart`, and `services/batch_folder_importer.dart`.
- The persistent batch model/repository/controller and Android stitching path already provide a place to queue downloaded source sets and process them offline after import. Queue records and task-owned copies are app-private and survive app restarts; inputs must remain retained. See `services/batch_queue_repository.dart`, `services/batch_queue_controller.dart`, and `models/batch_queue.dart`.
- Android has SAF and foreground-runtime adapters. The design explicitly treats interruption recovery as durable checkpoint work; a foreground service does not guarantee an uninterrupted render.

PG-062 subsequently implemented the shared Dart DWARF client, album/package
listing, original-photo download and queue admission. Android phone tests
verified transfer interruption/resume, hashes, queue recovery, actual camera
identity and album enumeration; later evidence includes an actual original
download. These results do not qualify full camera-origin reconstruction or
optical seams. See the [PG-062 implementation evidence](evidence/DWARF-MOBILE-IMPORT-2026-10-07.md)
and the [iOS build instructions](../../Apps/Flutter/stitch_app/APPLE-BUILD.md).

The shared iOS transfer code and platform adapters are present, but physical iOS
camera-transfer behavior is not qualified. The hosted iOS build does not link
the Rust stitching engine, so native iOS processing is also unqualified.

## Proposed flow at the research date

1. Connect to the DWARF camera over its supported local network; detect and explain connection state and camera model.
2. Fetch `/album/list/mediaCounts`, then page `/album/list/mediaInfos` using `mediaType`, `pageIndex`, and `pageSize`. Present camera album entries and distinguish thumbnails/metadata from downloadable original sets.
3. After selecting a verified panorama/source set, download each original as a stream into a temporary app-owned intake directory. Verify completion, size and available camera-provided identity/checksum; never delete or modify camera originals.
4. Convert the completed intake into the existing immutable task input copies, preserve stable source ordering and original filenames, identify or request grid/layout metadata, and create one persistent batch item per selected panorama.
5. Queue items for local stitching. The queue should remain usable without the camera after the copies and task records are durable; interrupted downloads should be resumable or safely retried and must not become ready queue items.

The research left open the mapping between a camera “panorama” album row and the photos required by this stitcher. PG-062 later added package enumeration, thumbnail filtering, original transfer and queue admission. Phone evidence confirms actual camera identity, album listing and an original-file download, but does not establish complete camera-origin reconstruction or visual seam quality.

## Platform boundaries and validation

The implemented Android client uses Dart over the DWARF local network and reuses
the existing storage/queue pipeline. Phone evidence covers connection, package
listing and selected original transfer. Remaining validation includes
interrupted real-camera transfers, complete camera-origin reconstruction and
visual seam quality.

iOS shares the Dart protocol/client and queue models and has local-network
permission and lifecycle/storage adapters. Background execution is best-effort
under iOS and can be suspended or terminated; durable download state and restart
recovery are required. The current hosted build only validates compilation of
the native-free runner; it does not qualify camera-transfer behavior on an iOS
device or native stitching.

The no-computer goal is compatible with this architecture: phone app connects to camera, copies originals into phone-owned storage, and runs stitching on that phone. It does not imply cloud processing or continued operation after the OS terminates the app.

## References

- [DWARF community SDK HTTP API](https://raw.githubusercontent.com/alikh31/dwarflab-sdk/main/docs/http-api.md)
- [SDK album HTTP implementation](https://raw.githubusercontent.com/alikh31/dwarflab-sdk/main/packages/sdk/src/http/album.ts)
- Current app design: [Android stitching design](ANDROID-STITCH-DESIGN.md)
- Current mobile qualification and limits: [Android evidence](evidence/ANDROID-STITCH-2026-10-05.md)
