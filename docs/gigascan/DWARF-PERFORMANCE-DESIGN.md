# DWARF performance scope

The user confirmed this scope in a side discussion and authorized delivery to
the main task. Preserve the completed idle-progress fix and existing PR work.

Use exactly the eight immediate grid neighbors: row and column differences are
at most one, excluding self. Process each unordered pair once. Manual and
automatic-overlap/refined-grid paths must agree; cardinal center samples may
still estimate horizontal and vertical steps. Keep texture evidence, coordinate
optimization, geometric quality gates and estimated-placement provenance.

Optimize final full-resolution rendering first: local two-dimensional tile
scheduling, fewer repeated decodes, short shared-cache locks with per-source
single-flight loading, and independent worker/cache reservations within existing
job and aggregate limits. The user additionally requests a persistent settings
Memory budget slider for the whole application's shared upper bound. Show selected
capacity, measured total/available memory and a recommendation; offer automatic
allocation and useful 16/32/64GiB marks where the device supports them. Do not
preallocate the selected capacity or apply the same amount to every concurrent
job. Remove the desktop 4GiB cap consistently across APIs, rendering, pyramids,
exports and UI validation. Use checked MiB/GiB arithmetic. Saved tasks/checkpoints
stay readable; changing settings must not invalidate active reservations.
Desktop memory recommendations use actual available
memory; mobile keeps measured resource limits. Evaluate larger rendering regions
and reused pixel geometry/color conversion only when output fidelity and bounded
memory can be demonstrated. Do not lower final resolution or blend quality.

Then reduce registration work through DWARF overlap-region matching and bounded
coarse-to-fine retries. Do not guess camera calibration or disable quality gates.

Measure the same input, layout, output dimensions, quality and export endpoint.
Record phase time, source decodes, cache hits, process peak memory and CPU use;
separate scheduler/cache comparisons from changed registration evidence. Existing
364-photo timings were collected during concurrent verification, so they are
observations rather than an isolated speed baseline. Do not promise the reported
GigaPan 3-4x comparison without controlled measurements.

Keep all originals and prior outputs, separate preview/final export, resumable
ownership, cancellation, EN/ZH presentation and Windows/Android budgets. Report
synthetic, real-pixel/crop, complete-export and physical-device evidence separately.
