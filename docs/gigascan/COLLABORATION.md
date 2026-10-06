# PocketGigaScan collaboration ledger

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
