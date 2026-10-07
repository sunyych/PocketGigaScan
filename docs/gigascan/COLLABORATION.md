# PocketGigaScan collaboration ledger

## PG-061 Windows import and local-storage diagnosis

The user reported a native file-dialog crash and errno-5 failures creating tasks
and writing removal tombstones. Luna picker coder owns the platform-dialog
adapter, dependency/localized folder prompts and adapter tests. Luna workflow
coder owns the injectable importer and host/Windows-engine workflow tests. Luna
storage coder owns deletion ordering and its failure/retry test. Codex owns
independent review, read-only Windows token/ACL investigation, serial SDK checks,
ordinary-directory test staging, release packages and the existing PR #5 update.

The observed workspace EXE inherits Low Mandatory Level and starts with integrity
RID 4096; the user's existing AppData root still grants their account FullControl.
A fresh copy of the same 1.3.3 binary in Downloads inherits normal permissions,
starts at RID 8192, and opens/cancels the native picker successfully. No Windows
security settings, existing directory ACLs, originals or exports are changed.
This storage diagnosis is separate from historical ucrtbase fatal-exit events.

The replacement Windows path uses Flutter's endorsed file-selector native
Common Item Dialog; Android continues its streamed file-picker/SAF behavior.
Task removal commits its tombstone before removing durable batch references;
an errno-5 write failure leaves task and queue ownership available for retry.
Independent review rejected an invalid JPEG fixture and a duplicate translation
key, and required real selector-adapter tests and wall-clock filesystem waits.
Host analysis is clean; all 284 Flutter tests and the final 33-test deletion
controller suite pass. Independent review also required queue-save-before-publish
and repeated snapshot rebasing; both tombstone and queue-write errno-5 retries
retain originals and exports. Host copied-photo checks use a real-clock service
test, with cancel/error/count widget coverage separate from native import UI.
Release/UI qualification remains in progress; see the
[PG-061 evidence record](evidence/WINDOWS-IMPORT-2026-10-07.md).

## PG-060 renderer hot path and recovery performance

The user reports roughly thirty minutes and requests faster stitching. Luna
renderer owns exact output-f32 sRGB conversion, bounded f64 geometry reuse and
coarse instrumentation/tests. Luna registration owns guarded bounded recovery
feature extraction and precise retry timings/counters; its narrow plumbing spans
sift_bridge.cpp, register.rs, pipeline/mod.rs, spherical.rs and job.rs. Codex owns
independent review, this [scope](HOTPATH-SPEEDUP-DESIGN.md), serial SDK execution,
same-input ROI/full benchmark comparisons, packages and the existing MR update.
No hard lock, source, resolution, accepted-edge or quality-threshold changes are
part of this task. Cancellation, old-task ownership and per-job/app memory limits
remain. The separate DeepSeek bilingual patch is still pending its actual path.

The new fully unlocked 0.6 MP failure is a separate correctness investigation.
Luna geometry owns a bounded precision-recovery wrapper/tests and cache version;
Luna precision UI owns narrow request/timeline translations/tests. Codex owns
real 2.0 MP replay, preserved task evidence and independent gating review. No
quality limit is raised and no source or weak edge is silently discarded.

Luna handoffs and independent review are complete. Codex corrected the checked
cache-reservation boundary through the renderer coder and required local-only
performance counters instead of per-pixel atomics. The exact full-layout pair
retains all 7742 decoded level-zero tiles with 21.2% lower render/pyramid/TIFF
time. The packaged-engine 364-source replay reproduces the unlocked 124.29 px
coarse failure and recovers exactly once at 2.0 MP to 11.94 px against the same
12 px gate, with unchanged rendering geometry relative to the precise replay.
Verified task records retain requested/actual precision and recovery attempts.

Product source `f2c7c82` passes 212 native tests, 271 Flutter tests/clean analysis,
32 Python checks, both builder contracts and normal Windows Release packaging.
Android source build/APK integrity, seven Kotlin tests and Release lint also
pass; ADB lists no device. Both hosted Windows jobs pass for that source. See
the [PG-060 qualification record](evidence/HOTPATH-RECOVERY-2026-10-07.md) for
checksums, timing caveats and explicit device/visual boundaries. No separate
DeepSeek patch was found, and it is not claimed as incorporated.

## PG-058 versioned task traceability

The user explicitly adds a versioned per-task master file containing source
identity, actual placement/correction models, diagnostics, outputs and timing,
with atomic writes and old-task resume. Parameters absent from the renderer
remain null/notApplied. Task removal deletes records without deleting photographs
or exported images. Viewer tracing remains optional and collapsed by default.

Luna renderer owns TaskRepository and the task record service/tests; Luna geometry
owns output-source location and viewer diagnostics/tests; Luna UI integrates the
viewer context. Codex owns independent review and serial qualification. See the
[implementation plan](../superpowers/plans/2026-10-06-task-traceability.md).

Independent real-file review catches two integration gaps before qualification:
persisted Rust Snapshot fields use snake_case rather than API camelCase, and
Windows canonical source paths can use extended drive/UNC prefixes. Luna adds
normalization and actual-storage-shape fixtures. Native layout_hash must agree
with the owned layout bytes before output geometry is reconciled. PNG/TIFF do
not incur a full encoded-file SHA scan during task saves; the verified JXL
producer receipt retains that scan because dimensions cannot be decoded here.
Failure correspondence files stay opaque and are referenced by hash/size.

## PG-057 explicit placement locks and 09_13 investigation

On 2026-10-07 the user confirms that the remaining reported misalignment was
caused by their pixel placement lock and that unlocking resolves it. The proposed
additional pre-warp calibration scope is withdrawn. Luna native stops edits;
Codex archives its draft locally and restores spherical.rs/job.rs to the already
qualified baseline. Luna test/record reviewers made no corresponding changes.
No extra solver stage, quality-gate change or automatic removal of legacy locks
is included. This confirmation does not establish acceptance of unrelated seams
or physical Android execution. The existing MR builds both completed successfully.

The separately authorized DeepSeek bilingual patch is still absent from this
shared worktree. It must be reviewed against its actual changes before a combined
commit; baseline localization review is not a substitute for patch review.

The user supplies a real DWARF photo and requests eight-neighbor texture
matching, joint global pose optimization, bounded local correction and final
fusion. The existing pipeline already follows that order. The preserved task
contains a per-photo hard grid flag, which excludes its eight incident visual
constraints; storage does not establish the flag's origin.

Luna perf_neighbors owns typed native placement constraints and synthetic tests.
Luna neighbor_audit owns Flutter lock provenance, migration, explicit lock
controls and EN/ZH tests. Luna perf_renderer owns an ignored real-crop helper.
Codex independently reviews changes and owns serial real-photo registrations,
pixel/crop inspection and release qualification. Production geometry is frozen
until the PG-056 performance runtime is copied, keeping measurements stable.

Original tasks retain their hard locks. A diagnostic copy alone clears the
central flag. Grid priors continue visual matching; only hard locks suppress it.
No quality gate is weakened and no all-pairs matching or feather-only remedy
is introduced. Nine-photo evidence and complete-panorama evidence are separate.

Full 364-photo diagnostic registration passes the unchanged 12px edge gate;
all eight incident center constraints are accepted. Spatially held-out center
cardinal RMS drops from 18–21px to 1.1–1.5px. Codex checks paired unscaled crops
from a full-layout ROI at four edges and four corners and sees improvement in
the right building frames. The sky reference still requires grid bridges; the
center has direct visual evidence without reference connectivity. This is not
all-seam or full new exported-panorama acceptance. Originals and legacy lock
storage remain unchanged.

## PG-056 fixed-eight DWARF performance and memory budget

The user explicitly forwards an implementation scope from a side discussion:
fixed eight immediate neighbors, faster full-resolution rendering/cache/decode,
bounded ROI retries and controlled measurements. An additional request adds a
persistent whole-app auto/manual memory slider, actual total/available memory,
resource-dependent large desktop budgets and preserved mobile/aggregate limits.
The idle-progress repair and current PR remain intact.

Luna perf_renderer owns spherical_renderer.rs and renderer tests/helpers;
Luna perf_neighbors owns spherical.rs, pipeline/register.rs and neighbor tests.
The retained Luna neighbor_audit slot is repurposed for resources/settings and
benchmark tooling because a new thread would exceed the retained agent limit;
its old geometry scope is explicitly frozen. Codex owns the authorized scope,
implementation plan, .gitignore allowlists, independent review and serial SDK
execution. No agent runs simultaneous SDK or real-photo benchmarks.

See [scope](DWARF-PERFORMANCE-DESIGN.md) and
[plan](../superpowers/plans/2026-10-06-dwarf-render-performance.md).
Existing 364-photo timing was collected during concurrent verification and must
not be reported as an isolated GigaPan speed comparison. Later isolated runs
below use the same preserved layout and final-output endpoint.

The source-built baseline and frozen candidate replay the same preserved full
layout with four workers at 512MiB. All 7742 decoded tile fingerprints match.
Render time decreases 4.5%, complete render/pyramid/lossless-TIFF pipeline 3.2%,
and source decodes fall from 3762 to 2076. A separate candidate16GiB run changes
only memory budget and is isolated from SDK builds. It decodes each of the 364
sources once but its complete pipeline is 5.6% slower than the new 512MiB run;
all decoded tile pixels remain identical. Larger cache capacity does not establish
a speed multiplier. Final timings, memory observations and TIFF checks appear
in the [qualification record](evidence/DWARF-PERFORMANCE-2026-10-06.md).

Independent UI review verifies the expected eight-neighbor control changes in
desktop, narrow-window and mobile screenshot baselines. Root's targeted 63-test
run covers idle EN/ZH progress, resource admission, duplicate start, automatic
export retry, explicit placement locks and output-source projection. Luna repairs
test-only fake-async filesystem stalls without extending their wall-clock limits
or weakening source/layout/producer-receipt qualification. UI persistence tests
use owned temporary files; resource fixtures use an in-memory settings repository.
Android admission refreshes live readings instead of retaining the startup value.

The supplemental user-authorized audit assigns disjoint test lanes: Luna geometry
adds actual perturbed-camera registration/render truth tests; Luna renderer adds
eight-neighbor checker gates, cache binding and worst/target crop selection; Luna
UI corrects stale lossy-JXL integration assertions, explicit disabled-gate skips,
and Python dependencies/tests in CI. Codex independently catches the analytic
truth frame-gauge error, global-error dilution, missing required-cell neighbor
coverage, testWidgets boolean skip typing and missing hosted Python dependencies.
Thresholds are kept fixed. The new native target passes both tests, including
p95 <=2px / worst <=4px source-boundary checks and same-gate negative controls;
all 32 Python tests pass without skips. Checker-held-out features are not claimed
as never seen by the production optimizer.

Final qualification covers 202 normal-builder native tests plus two new synthetic
integration cases, two ignored external-data cases, 270 Flutter host tests, clean
analysis, both builder contracts and normal Windows Release. Android native/APK
source builds and signature/export/alignment/license inspection pass. Product
source commit is a66a9d9; later additions affect tests/CI/evidence. Final packages
are version 1.3.2+16. ADB has no connected device; external-fixture FFI, Android
execution and every real seam remain separate gates. Exact checksums and evidence
tiers are recorded in the [qualification record](evidence/DWARF-PERFORMANCE-2026-10-06.md).

## PG-055 idle task progress

The user reports an animated progress bar before pressing Start stitching.
Luna owns the shared main.dart progress widget and widget_test.dart regression;
Codex coordinates and independently reviews the small state-only patch. Zero
progress is indeterminate only for running, pausing and exporting. Imported,
queued, paused, interrupted and terminal inactive tasks show static progress;
completed-task presentation stays hidden as before. No core, task storage,
photograph or export ownership behavior changes.

English and Chinese widget coverage checks imported/queued/paused zero progress,
active running zero progress and retained paused 42% progress. Separate keyed
page instances avoid stale state between cases. The focused regression and both
build-script contracts pass. Full analysis/tests and normal Windows Release
qualification are recorded below after execution.

The first full suite detects three intended screenshot changes for TIFF, PNG
and JPEG XL before starting. Codex inspects the generated screenshot and diff;
all three pixel-difference bounds are exactly (505,138)-(1169,142), confined to
the former animated progress stripe. Luna updates only those three baselines
from the generated screenshots, with matching SHA-256 checks. Other screenshot
baselines and source behavior stay unchanged.

A subsequent complete suite passes the refreshed goldens but exposes an existing
TIFF queue persistence race in its test: native export starts before an atomic
queue publication is necessarily readable. Luna changes only the test helper to
await a bounded sync/async predicate and captures the first persisted snapshot;
the assertion uses that same snapshot rather than racing another load. The
20-second timeout and format assertions remain. Codex reviews the fix and the
focused TIFF test passes; no queue product logic changes.

Final qualified source is 332c13f, with Dart formatting, clean Flutter analysis,
all 214 Flutter tests, Rust formatting, 186 native tests (two local fixture tests
ignored), and Windows/Android builder contracts passing. The normal Windows
Release builder finishes its source-core, runtime/license and ZIP checks. Android
Release is rebuilt with the unchanged previously source-built ARM64 core; APK
inspection verifies FFI/dependencies, 16KiB ELF/ZIP alignment, signature and all
135 hashed license files. This is shared-widget and package evidence, with no
new physical-phone or native-window interaction claim.

Version stays 1.3.1+15. Ignored deliverables are
`PocketGigaScan-Windows-x64-v1.3.1-15-idle-progress-fix.zip` (20,607,254 bytes,
SHA-256 `81e0752e13ae1b11946dcec3d8b24ca11034a65e9fb4ea58701b8552411b054f`)
and `PocketGigaScan-Android-arm64-v1.3.1-15-idle-progress-fix.apk` (38,877,431
bytes, SHA-256 `a9400b59927df5b3a85cc43f0b0da242e9bee260476f36360834f80adeb27ce5`).
Android package remains `com.lumiaiq.pocketgigascan`, ARM64, minimum API29,
target API36 and development signing. Local logs are in ignored
`.local/idle-progress-20261007/`. The completed Luna handoff is independently
reviewed by Codex and extends existing PR #5 without merging it.

## PG-054 stitching loop and neighbor regression

User reports 1.3 appears to loop in retry extraction/matching while 1.2 completes
with occasional seams. Codex located preserved 364- and 384-photo failures and
a completed 364-photo task. The initial automatic-overlap failure differs from
the completed manual task; the subsequently reported manual failure matches its
scalar parameters. Controlled replay of the actual older 1.2.1 engine succeeds
on that manual request. The alternating log rows represent finite per-neighbor
work, while the original progress remains at 2% and hides that work.

Luna native owns job timeline/progress/failure diagnostics; Luna Flutter owns
timeline/localized stages and targeted controller tests; Luna geometry audits
actual correspondence evidence before any matching change. Codex owns a fresh
full-resolution replay, independent review, serial SDK checks and packages.
Originals, task records and exports remain untouched. See the
[repair plan](LOOP-REGRESSION-PLAN.md).

The exact automatic-overlap 364-photo request fails identically in 1.3 and 1.2.2
engines: global RMS 1.9555px, worst edge 55.0134px. Elapsed times are 417.688s
and 479.391s on a machine also running user jobs; these are not isolated speed
benchmarks. Actual bad cardinal edges 76->77 and 50->76 have only 8 and 9 unique
inliers, narrow support on both images, and cycle disagreements over 500px.
Luna geometry excludes only low-support, narrow, severely cycle-inconsistent
matches before component/grid-bridge construction; all original vertices and
ordinary reprojection limits remain. Exclusions carry explicit diagnostics and
visual-review warnings. Final native cache version 17 prevents reuse of older
alignment results.

Luna native batches retry matching within the existing worker limit, preserving
endpoint caching/order and cancellation. Extraction remains serial under the
native OpenCV lock. Retry counts now advance real batch progress; Flutter groups
these substages without merging different jobs or pause boundaries. Failure
diagnostics persist to a job-owned file rather than being discarded. Independent
review fixed fixture intrinsics, the cache-version contract and an overly broad
UI-history assertion. A first repair still correctly fails the manual request at
12.0857px after eight accepted local-warp rounds. Luna geometry then implements
at most four additional rounds only when worst-edge quality is still improving,
retaining the 12px gate, RMS descent and strain/displacement limits. Real manual
registration now passes after two additional rounds at 11.9464px, all 364 photos
retained. Actual solver regressions cover success, bounded exhaustion and cancel.

Final source is a6a5868. Codex independently reviews the patches and verifies
Rust formatting, 186 native tests, clean Flutter analysis, 213 Flutter tests and
both builder contracts. Normal Windows x64 Release and Android ARM64 Release
packages build the vendored core from source and pass runtime/license/archive
checks; Android also passes signature, FFI and 16 KiB alignment inspection.
Seven Kotlin tests pass; lint has zero errors and nine existing warnings.
The full real-photo replay uses a byte-identical copy of the production Windows
DLL in an isolated runtime directory. ADB has no connected device. See the
[PG-054 evidence](evidence/LOOP-REGRESSION-2026-10-06.md) for full rendering/export
qualification and the remaining forced-grid, sky-reference and seam limits.

The final isolated 364-photo replay completes full 80855x25050 rendering, its
18-level viewer pyramid and automatically queued lossless BigTIFF export in
1,864.641 seconds including export. The 8,101,804,932-byte result passes
independent strip-range, >4GiB offset and sampled exact-pixel checks. Codex
inspects the final overview and matched old/new high-resolution tree crops;
all-seam and physical Android acceptance remain unclaimed. Luna source handoffs
are complete and the coordinator records the evidence and updates existing PR #5.

## PG-051 blurred-photo alignment and overlap repair

Final coordinator qualification: source commit `2deabdc` passes pinned Rust
formatting and 169 native tests (two historical real-data tests ignored),
Flutter analysis and 177 tests, Windows builder contracts, 14 independent
seam-checker tests, and the standard Windows source Release/package checks.
Version `1.2.2+13` is delivered as the complete ZIP documented in
[the evidence report](evidence/BLUR-REPAIR-2026-10-06.md). Original-photo visual
acceptance remains pending; synthetic evidence does not establish its repair.

The user approved the algorithm proposal and requested implementation on
2026-10-06. Luna registration coder owns spherical alignment and neighboring
matching; Luna renderer coder owns local sharpness selection and rendered
fixtures; Luna Flutter coder owns localized quality descriptions and diagnostics.
The coordinator owns cache invalidation, independent review, qualification,
build/package evidence and this ledger. Work uses `codex/blur-aware-stitch`.

Review requires source-pixel-aware loop thresholds, ambiguity disclosure,
reliability in both pose and pixel optimization, normalized high-frequency
sharpness rather than scene variance, preserved sole coverage, and updated
tiled memory accounting. See [implementation plan](BLUR-REPAIR-PLAN.md).
The attached finished panorama is diagnostic context; its source photo set
has not been supplied, so real four-border acceptance is pending.

## Retained processing baseline

PG-046: Luna geometry/renderer/UI coders; coordinator independent review. Actual384 registration, original-resolution repaired corner crops, main-scene heldout checks,103 Flutter tests,154 core tests and four Windows native suites qualified Windows1.0.8 within the documented visual limits.

PG-047: Luna test coder, coordinator assertion review. Tests-only commitbff2a66 adds rendered texture seam errors, horizontal/vertical displacement negative controls and nominal grid source retention. Full release-mode core tests:156 pass, two real-data tests ignored by default and previously run separately.

## PG-048 independent product and publishing

- Luna localization coder: application strings/delegates, English/Chinese system locale tests, product version and Flutter description.
- Luna build coder: Windows runner/branding icon, verified native dependency builder, workflow, ZIP/checksum and script contracts.
- Coordinator: vendor native source, confirmed retired-directory cleanup, legal/scope/docs, serial SDK verification, independent review, commit/push and remote pipeline checks.

Disjoint file ownership is required. A compile or synthetic fixture result is distinct from real-image seam, mobile-package or physical-device evidence. Future Android stitching is a shared architecture goal; current Windows verification does not qualify Android binaries.

Coordinator review: 117 Flutter tests and 156 core tests pass; current title-only
screenshot changes reviewed independently. Full local Windows builder and enabled
three-format native automatic-export integration pass. Clean CI exposed the
official libjxl SDK's newer Microsoft STL requirement; the Luna build coder owns
the VS 2026 runner/preflight repair. [Current evidence](evidence/DWARF-STANDALONE-2026-10-05.md).

Clean-run follow-up: Luna localization coder repaired canonical task paths for
Windows short-name aliases and made the missing-output screenshot fixture
machine-independent. Coordinator reviewed the containment checks and the sole
changed screenshot. All 121 application tests and analysis pass. Luna build
coder added app-local x64 VC runtime packaging, version/hash provenance and
failure screenshot uploads; coordinator tested actual VS runtime copying as
well as the positive/missing-DLL/wrong-architecture contracts.

Final coordinator handoff: the clean hosted build passed; its downloaded ZIP,
source commit, manifest, runtime/core hashes and dependency licenses were
independently checked. The final local builder and repeated native real-photo
automatic exports also pass. A later main build exposed an asynchronous queue
test teardown race before release publication.

Queue lifecycle follow-up: Luna localization coder tracks active scheduler work
and serialized persistence; owners can drain writes before releasing storage.
The coordinator reviewed disposal across pre-start awaits and preservation of
already-started native jobs. Gated persistence and gated task-load regressions
cover both boundaries. Test teardown waits for completion instead of a fixed
sleep; state polling uses a bounded monotonic deadline. Current rerun and hosted
publication evidence is recorded in the linked qualification report.

## PG-049 Android shared processing

- Luna native coder: unrestricted structural grid validation, sparse normal
  matrices with true-residual acceptance, portable JPEG XL paths, pinned Android
  core builder, ABI/alignment/provenance and license staging.
- Luna platform coder: streamed SAF storage, app-owned export sharing,
  foreground-service acknowledgments/timeouts, resource readings and policies,
  launcher branding and fail-closed Gradle packaging checks.
- Luna shared UI coder: scoped large-grid confirmation, task/queue parity,
  resource admission, touch viewer, localization and automated regression and
  connected-device integration harness.
- Coordinator: serial SDK execution, real fixture copies with source hashes,
  independent code/screenshot review, numerical and Windows regressions,
  Android packaging inspection and device qualification.

Native Windows regression passes 161 tests (two real-data tests ignored).
ARM64 production core and a separate native test executable build successfully;
the test executable is excluded from the APK. Gradle validates native hashes,
ABI metadata and the complete license inventory; an altered core hash was
independently rejected and the original manifest restored. Phone disconnection
currently prevents physical qualification. Current application/package results
and remaining boundaries are recorded in [Android evidence](evidence/ANDROID-STITCH-2026-10-05.md).

Final shared-app analysis is clean and the normal complete Flutter suite passes
159 tests, including existing desktop screenshot baselines. The normal Gradle
JVM/lint gate passes 5 tests with zero lint errors (9 warnings). Review repairs
covered scoped input-copy recovery, export-pending scheduling, timeout-to-export
races and persisted acknowledgement failure before standalone resume. The
coordinator records APK inspection independently from these host tests; PG-049
is not physically complete while ADB reports no connected phone.

## PG-050 export, presentation and application identity

Luna native coder owns JPEG XL mode/metadata and decoder-quality regressions.
Luna UI coder owns shared home/queue presentation, completed-state controls and
collapsed diagnostic panels. Luna localization/platform coder owns localized
formats and task phases, Android application/channel identities and Windows
application identity with legacy task-storage lookup. The coordinator reviews
these disjoint changes and runs native, Flutter, Windows and Android SDK commands
serially. User-approved scope and executed evidence are recorded in the linked
PG-050 report; synthetic, package and physical evidence remain separate.

Independent review repaired lossy-alpha metadata, preserved actionable pause
messages outside the info panel, kept historical outputs neutral about codec
mode, and removed clean-CI dependencies on ignored local iOS scaffolding.
The coordinator reviewed six intended screenshot changes and ran the normal
Windows source builder: 162 native tests pass (2 real-data tests ignored), clean
Flutter analysis and 175 tests pass. Android ARM64 core/APK build and actual
package inspection pass, with 5 JVM tests and zero lint errors (9 warnings).
The new identity is `com.lumiaiq.pocketgigascan`; legacy Windows lookup remains.
ADB has no connected phone, so physical Android execution remains pending.
PR #3 was already merged by the time of the final sync; this correction uses
the separate `codex/export-ui-identity-fixes` branch from the identical main tree.

## PG-052 overlap/export translation and log alignment

User-reported English UI leakage occurs in the calibrated/nominal center-neighbor
overlap subtitle and the full JPEG XL export action. Luna localization coder owns
the shared translation table and real-home EN/ZH regressions covering generic,
nominal and manually touched calibration, all export/retry formats and related
diagnostic labels. Luna UI coder owns task/technical-log expansion alignment and
geometry regressions. The coordinator independently reviews and runs Flutter
analysis/tests serially. Existing geometry, defaults, collapsed-log behavior,
originals and task ownership remain intact.

The user explicitly deferred commits and all platform builds until their further
edits are complete. This patch remains in the working tree without a version
bump, commit, push, Windows build or Android package build. Host widget evidence
does not claim physical-device validation.

Independent review kept translation rules narrow and checked actual log text
positions, not only layout properties. The coordinator repaired test-fixture
scrolling through the owning Luna coder, then verified 25 focused tests and all
182 Flutter tests, including the unchanged screenshot baselines. Flutter analysis
reports no issues; the six changed Dart files are formatted. Logs are retained
locally under `.local/translation-log-fixes-20261006/` and are not committed.
No native stitching code changed; no platform build or device run was performed.

## PG-053 settings and timestamped timeline

User approved the shared settings/timeline design, Windows and Android rebuilds,
and a GitHub PR. Settings Luna owns main.dart, l10n and isolated preferences UI;
timeline Luna owns native job events, task/timeline models and log widget;
platform Luna owns Android output-folder access and batch integration. Codex
owns the plan, independent review, serial SDK checks, packages and PR handoff.
Existing pending PG-052 repairs are preserved and included in the eventual PR.
Defaults apply only to new tasks; native/private exports and originals remain
owned by their existing jobs. Actual device evidence is reported separately.

Luna handoffs are complete. Independent review corrected source-event versus UI
observation deduplication, export-state labels, settings-save races, legacy time
handling and stale publication ownership. Successful stale copies are retained;
only a newly created partial SAF document is removed after a copy failure.
Synthetic batch tests explicitly confirm grid/FOV, and widget export tests yield
for real filesystem operations and wait for the final destination receipt.
Reviewed screenshot changes cover the settings action and separate collapsed
panels. SDK checks and Windows/Android Release qualification are run serially by
the coordinator; results are recorded in the PG-053 evidence document.

Final review also required proof of an original render start: legacy recovery
or a later export cannot fabricate the old task's total duration. The final
shared source is a2b7045. All 208 Flutter tests and 172 native tests pass (two
real-photo fixture tests intentionally ignored). Seven Android Kotlin tests pass;
lint has zero errors and nine existing warnings. Normal Windows x64 ZIP and
Android ARM64 Release APK packages pass their integrity/license checks. ADB lists
no devices. See [PG-053 evidence](evidence/SETTINGS-TIMELINE-2026-10-06.md).

The qualified branch is committed and pushed. [PR #5](https://github.com/sunyych/PocketGigaScan/pull/5)
is open and attached to the Codex task. Default-branch latest downloads update
only after merge and a successful publishing build; this handoff does not merge.
