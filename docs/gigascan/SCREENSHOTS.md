# Current UI screenshot gate

The project has not yet added the GigaScan UI or its screenshot tests. This is
intentionally recorded as pending rather than inferred from the upstream app.
The Swift/Kotlin Core bindings added under PG-006 are non-visual and do not
create a screenshot obligation.

Every operator-visible screen introduced by LumiaPocketGigaScan must have an
automated screenshot test that covers the current supported size and state.
Store only the current approved screenshots; update the baseline when the UI
changes and remove superseded images. The test index must name each screen,
platform, state, and baseline path.

Initial coverage to register when shell work starts: camera
connection/preview, GigaScan wide preview and ROI selection, scan settings,
active scan, paused/resume job, processing/stitching progress, completed
result, panorama modes, Gallery, and Settings. iOS and Android parity or a
documented exception belongs in `docs/PARITY.md`.
