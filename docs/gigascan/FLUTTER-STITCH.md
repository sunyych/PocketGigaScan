# PocketGigaScan operator guide

Windows and Android DWARF photo-grid stitching. Android device qualification is pending. Product UI follows the system language (Chinese or English). Camera control and original retrieval are separate from stitching.

1. Import a single photo folder or queue each child folder of a parent folder.
2. Confirm grid rows, columns and order. Automatic overlap uses horizontal and vertical central neighbor evidence; sky-only rows are unreliable. Review estimated or forced placement explicitly.
3. Choose lossless PNG or TIFF/BigTIFF, or lossy JPEG XL before starting. New Windows jobs default to TIFF and automatically export after rendering completes.
4. Let the resource-bounded queue run, or pause/cancel through its owner. Queue-owned jobs cannot be independently started/exported on the single-task page.
5. Open a completed output; wheel zoom and drag (pinch/drag on Android) to inspect details. Processing settings/progress disappear on completion. Stitch information/logs and viewer status start collapsed; click to open them. Create a copy to choose another format and stitch again.

Copies and new processing runs preserve original photographs and prior outputs. Removing a task only removes its records. Pause/resume reuses its saved checkpoint and output path. A failed new export retains the previous successful result.

Old completed geometry requires a task copy and fresh registration; re-export alone cannot improve seams. Nominal grids retain photos but do not establish visual correspondence. Unsupported source obstructions remain rather than being filled with invented content.

## Storage compatibility

The application identity is `com.lumiaiq.pocketgigascan`. Windows checks existing
Lumia task directories before using the new company directory, preserving old
jobs without moving or deleting them. Android's new package has separate private
storage and can coexist with the old package. Repository cleanup does not affect
AppData tasks, original source folders or panorama exports.
