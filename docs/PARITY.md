# PocketGigaScan processing parity

This ledger describes the standalone DWARF stitcher. Retired camera-control
shells and their historical platform claims are not the current product.

| Surface | Shared behavior | Platform boundary and verification |
| --- | --- | --- |
| Import and grid | All selected JPEG originals, neighbor registration, center horizontal/vertical overlap, texture refinement and checked complete-grid validation | Windows filesystem selection; Android system file/tree picker with private streamed copies. No fixed photo or axis cap. Android confirms rows > 6, columns > 6 or photos > 36 before new processing. |
| Tasks and batches | Persisted queue, pause/recovery, resource admission, record-only deletion preserving inputs and exports | Android uses current CPU/RAM/storage/thermal readings and a foreground-service adapter. Process death requires checkpoint recovery. Charger state is advisory. |
| Exports | Automatic lossless PNG/TIFF/BigTIFF or lossy JPEG XL (distance 1.0, exact alpha); TIFF default for new jobs | Choose before processing; completed tasks require a new copy to edit settings. Export failure recovery remains available. Android saves via the system destination picker or shares an app-owned file with the matching MIME type. Desktop export paths remain supported. |
| Huge viewer | Task-bound pyramid tiles, visible-region decoding, cache eviction, fit/zoom/pan and initially collapsed output information | Desktop supports wheel/drag; Android supports pinch/drag and narrow layouts. Viewing completed task outputs is separate from decoding an arbitrary external image without its pyramid. |
| Language and branding | PocketGigaScan icon/title and `com.lumiaiq.pocketgigascan` identity; English default and Chinese system locale, including auto-export and task phases | Completed processing controls/progress are hidden; information/logs open on demand. Windows retains legacy task lookup. Android's new package has separate private storage. Native service notification strings have locale resources. |
| iOS exception | The shared models, controller, viewer and portable core C ABI are retained for future adoption | The user requested Android now and iOS later. No current iOS shell, static native package, document/runtime adapter or physical iOS qualification is claimed. |

Windows baseline qualification and Android implementation/package/device results
are separate evidence tiers. PG-049 remains physically pending while the
connected phone is absent from ADB. See the [roadmap](gigascan/ROADMAP.md),
[Android design](gigascan/ANDROID-STITCH-DESIGN.md) and
[Android qualification](gigascan/evidence/ANDROID-STITCH-2026-10-05.md).
The subsequent shared presentation/export/identity corrections are recorded in
[PG-050 evidence](gigascan/evidence/EXPORT-UI-IDENTITY-2026-10-06.md).
