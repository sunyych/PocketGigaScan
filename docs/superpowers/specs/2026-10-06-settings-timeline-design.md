# Settings and timestamped stitching timeline

User approved this design on 2026-10-06, including Windows/Android rebuilds and
a GitHub PR. The previous untranslated export/overlap and log-alignment patch
is included. No existing originals, exports or task records are removed.

Persist app preferences independently of task metadata: system/English/Chinese
language, system/light/dark appearance, selectable accent palette, output quality
and performance defaults, and output folder. Output quality and performance
options are expandable dropdown panels containing the existing controls. They
are defaults for newly imported single and batch tasks; existing tasks retain
their saved processing options. Locale/theme changes apply immediately.

Keep two separately collapsed panels: Stitch details contains diagnostics and
timings; Stitching log contains timestamped lifecycle/stage events, with time on
the left and localized step text on the right. Capture native transitions at
their source, so polling does not lose fast steps. Persist the timeline in job
and task metadata; deduplicate repeated progress observations. Display start,
finish and total wall-clock time including automatic export. Pause time is
included and labeled; unknown legacy timestamps are never invented.

On Windows new task exports use the selected filesystem folder. Android uses
the system document-tree picker with persistable write access; native encoding
continues into app-private storage before copying the successful export into
the chosen folder. Keep the private export for the huge viewer and recovery.
Copy failures preserve the successful export and provide a visible retry path.
The selected destination is snapshotted into the new task/queue for resume.

Regression evidence includes old task/settings JSON compatibility, restart,
single/batch defaults, locale/theme changes, independent panel expansion,
timestamp ordering/deduplication, fast native transitions, pause/resume/export
timing, folder selection/cancellation/copy failure, and unchanged all-photo
neighbor-only processing. Host/device/package evidence are recorded separately.
