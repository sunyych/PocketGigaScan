# PocketGigaScan processing parity

This ledger describes the standalone DWARF stitcher. Retired camera-control
shells and their historical platform claims are not the current product.

| Surface | Shared behavior | Platform boundary and verification |
| --- | --- | --- |
| Import and grid | All selected JPEG originals, neighbor registration, center horizontal/vertical overlap, texture refinement and checked complete-grid validation | Windows filesystem selection; Android system file/tree picker with private streamed copies. No fixed photo or axis cap. Android confirms rows > 6, columns > 6 or photos > 36 before new processing. |
| Tasks and batches | Persisted queue, pause/recovery, resource admission, record-only deletion preserving inputs and exports | Android uses current CPU/RAM/storage/thermal readings and a foreground-service adapter. Process death requires checkpoint recovery. Charger state is advisory. |
| Exports | Automatic PNG, TIFF/BigTIFF or JPEG XL; TIFF default for new Android jobs | Android saves via the system destination picker or shares an app-owned file with the matching MIME type. Desktop export paths remain supported. |
| Huge viewer | Task-bound pyramid tiles, visible-region decoding, cache eviction, fit/zoom/pan and initially collapsed output information | Desktop supports wheel/drag; Android supports pinch/drag and narrow layouts. Viewing completed task outputs is separate from decoding an arbitrary external image without its pyramid. |
| Language and branding | PocketGigaScan icon/title; English default and Chinese system locale | Flutter localization is shared; Android service notification strings have native locale resources. |
| iOS exception | The shared models, controller, viewer and portable core C ABI are retained for future adoption | The user requested Android now and iOS later. No current iOS shell, static native package, document/runtime adapter or physical iOS qualification is claimed. |

Windows baseline qualification and Android implementation/package/device results
are separate evidence tiers. PG-049 remains physically pending while the
connected phone is absent from ADB. See the [roadmap](gigascan/ROADMAP.md),
[Android design](gigascan/ANDROID-STITCH-DESIGN.md) and
[Android qualification](gigascan/evidence/ANDROID-STITCH-2026-10-05.md).
