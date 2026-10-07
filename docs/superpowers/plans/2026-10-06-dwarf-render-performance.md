# DWARF render performance implementation plan

> **For agentic workers:** Use project-required Luna coder subagents for disjoint
> tasks, with coordinator review and serial SDK execution.

**Goal:** Reduce real DWARF final-render and registration work while retaining
all photo evidence, image fidelity and a fixed eight-neighbor matching contract.

**Architecture:** Separate scheduling/cache optimizations from geometry changes
so renderer comparisons can replay the identical persisted layout. Reserve decode,
active-worker and retained-cache memory explicitly; expose honest counters and
use measured desktop availability without overriding stored task settings.

**Tech Stack:** Flutter/Dart, portable Rust, image, OpenCV, Python benchmark host.

**Spec:** [Authorized scope](../../gigascan/DWARF-PERFORMANCE-DESIGN.md).

## Global constraints

- Fixed eight immediate grid neighbors, unordered pairs once, no remote pairs.
- No photo count limit, discarded originals, reduced final resolution or loosened
  quality gate. Preserve nominal/estimated provenance and local texture correction.
- Replace the fixed desktop 4096MiB ceiling with measured device/capability limits
  consistently. Keep checked per-job and aggregate reservations, conservative
  mobile limits and old checkpoint compatibility.
- Default language English; Chinese system locales resolve to Chinese.
- SDK checks run serially under Codex; Luna coders do not invoke SDK builds.
- Preserve old job storage and completed idle-progress repair. Benchmarks use fresh
  ignored directories and never overwrite the preserved job or earlier export.

## Task 1: reproducible baseline and resource recommendations

Owner: Luna resource/benchmark coder.
Files: native/core/examples/benchmark_spherical_layout.rs;
scripts/benchmark-dwarf-render.py and scripts/tests/test_benchmark_dwarf_render.py;
native/core/src/job_resources.rs and job.rs; shared Flutter resource/default
  services, main.dart and batch_queue_controller.dart, app_settings.dart,
  settings_page.dart, settings_controller.dart, stitch_localizations.dart and
  targeted tests. Resource coder owns memory validation/constants in export
  modules; coordinate renderer-owned validation sites with the renderer coder.
Coordinator owns .gitignore allowlists and repository handoff documents.

- [ ] Add a render/pyramid/export benchmark example consuming an unchanged layout,
  workers and memory budget; reject existing output directories and save structured
  timings/counters, exact output geometry and completed export receipt.
- [ ] Add a host runner sampling peak RSS and process CPU seconds/utilization,
  recording binary/input hashes, OS/CPU details and concurrent-process caveats.
- [ ] Test argument validation, failure preservation and controlled comparison
  semantics without personal photographs or timing-dependent performance assertions.
- [ ] Expose measured total/available memory and persist an automatic or explicit
  whole-app memory budget. Add a settings slider with selected capacity and
  recommendation, resource-dependent range and useful high-memory marks. Preserve
  active reservations, saved task values and aggregate admission; new tasks use
  allocated portions rather than each claiming the full setting. Mobile readings
  and fallback budgets remain conservative.
- [ ] Test settings persistence/EN/ZH/ranges, native/render/export budgets above
  4GiB, concurrent aggregate admission, legacy recovery and checked arithmetic.
- [ ] Bump alignment cache version for the fixed-eight contract; do not fake
  renderer RSS guarantees from estimated reservations.

## Task 2: spatial rendering and cache concurrency

Owner: Luna renderer coder.
Files: native/core/src/spherical_renderer.rs, renderer-owned helper modules if
needed, native/core/tests/spherical_render.rs.

- [ ] Add failing tests for spatially local tile scheduling, all tile uniqueness,
  exact serial/parallel pixel equality and resume/cancellation coverage.
- [ ] Process bounded two-dimensional neighborhoods with deterministic source
  iteration and unchanged 512px tile names/manifest/pyramid contracts.
- [ ] Shorten cache-hit locks and decode misses outside the global lock. Use
  per-source in-flight ownership so waiters share success/failure; bound concurrent
  decodes within memory reservation and test errors/cancel without deadlocks.
- [ ] Reserve worker and cache space separately so requested worker growth cannot
  consume every retained source slot; record actual decodes/waits/cache/worker use.
- [ ] Benchmark the unchanged real layout at 512MiB and high budgets including
  16..32GiB when measured device availability permits, with the same
  workers. Keep any scheduling policy only if it improves observed reuse/time.
- [ ] Evaluate larger internal regions and reusable geometry/color paths with
  fidelity tests; ship only independently justified improvements, recording
  rejected or deferred experiments explicitly.

## Task 3: fixed eight-neighbor DWARF registration

Owner: Luna geometry coder.
Files: native/core/src/spherical.rs, pipeline/register.rs and corresponding tests.

- [ ] Enforce fixed eight immediate neighbors for manual and automatic/refined
  paths, accepting old stored option spellings through explicit normalization.
- [ ] Test unordered-pair uniqueness, exact large-grid pair counts, boundaries,
  diagonal evidence and absence of distant pairs across every product entry path.
- [ ] Preserve central cardinal step estimation, reliable texture alignment,
  local warp quality gates and measured-grid provenance.
- [ ] Audit predicted horizontal/vertical/diagonal overlap ROIs and finite retries;
  implement coarse-to-fine/cache reuse only with synthetic and captured evidence
  showing no hidden photo loss, seam deterioration or unbounded retries.

## Task 4: independent qualification and delivery

Owner: Codex coordinator; no overlapping source ownership.

- [ ] Review memory/decode concurrency, source iteration order, fingerprints,
  estimates, legacy recovery and EN/ZH defaults independently.
- [ ] Run formatting, native tests, Flutter analysis/tests, builder contracts and
  normal Windows Release; rebuild/inspect Android source core and package.
- [ ] Compare identical-layout output pixels and representative real seams;
  run full render/pyramid/lossless TIFF with all originals and verify BigTIFF.
- [ ] Report timings, decodes, cache, measured peak memory and CPU data with
  concurrency caveats; do not infer a GigaPan multiplier from unlike endpoints.
- [ ] Record ROADMAP/COLLABORATION/evidence, commit and push the current codex/
  branch, update the existing PR and attach it. Do not merge or claim physical
  Android/iOS acceptance without the respective device/build evidence.
