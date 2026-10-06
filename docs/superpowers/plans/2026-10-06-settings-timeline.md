# Settings and Stitching Timeline Implementation Plan

> For agentic workers: use Luna coder subagents with disjoint ownership and
> coordinator review, as required by AGENTS.md. User selected this execution
> approach. Follow the tasks below without resetting the existing dirty patch.

**Goal:** Deliver persistent shared settings and a separately expandable,
timestamped stitching log with complete duration, then build Windows/Android
and submit a GitHub PR.

**Architecture:** Shared Flutter preferences/controller and task timeline;
source-captured Rust job events; Android SAF output adapter. Existing job
ownership, resource limits, pause/resume, preview/final and huge viewer remain.

## 1. Settings and shared application integration — Luna settings coder

- [x] Add `models/app_settings.dart`, `services/settings_repository.dart`,
  `services/settings_controller.dart` and `settings_page.dart`. Persist a
  versioned JSON document through a serial write queue with recoverable replacement; tolerate
  absent/unknown fields and report failed saves. Reuse path_provider support
  storage and existing folder picker rather than adding a preferences package.
- [x] Add a settings scope and injectable controller to `LumiaStitchApp`; preserve
  explicit test `locale`/`home`. Implement live system/en/zh, brightness and accent.
- [x] Own `main.dart`/l10n changes: settings entry; new-task snapshot of defaults;
  chosen export destination and Android publication; two independent collapsed
  detail/log panels. Connect the timeline APIs from task 2 and output APIs from
  task 3. Keep old completed tasks' settings immutable and task controls working.
- [x] Test settings roundtrip/corruption/write races and EN/ZH settings controls,
  theme/locale updates, single-task defaults and existing-task isolation. Extend
  presentation tests to assert separately collapsed panels and left geometry.

## 2. Native event capture and portable timeline — Luna timeline coder

- [x] Own `native/core/src/job.rs`: backwards-compatible `events` snapshot field,
  UTC millisecond timestamps, ordered IDs and stage/state/operation transitions;
  record from updates/checkpoints, not from the polling consumer. Deduplicate
  repeated progress and preserve resumed snapshots. Expose events via JSON ABI.
- [x] Own `models/stitch_task.dart`, new `models/stitch_timeline.dart` and
  `widgets/stitching_log.dart`: backward-compatible timeline/destination fields,
  immutable transition/merge helpers, localized time-left/text-right rows and
  honest total-time summary. Send exact integration APIs to both other coders.
- [x] Test legacy JSON, ordered/deduplicated events, render-to-export continuity,
  pause/retry semantics and legacy unknown times. Native tests verify multiple
  fast transitions survive one status query and snapshot serialization/resume.

## 3. Android output folder and batch integration — Luna platform coder

- [x] Own Android Kotlin storage adapter, `services/mobile_storage_service.dart`,
  batch models/controller/page: pick and retain a writable document-tree URI,
  copy only a completed export, preserve source/private export on failure and
  support a retry. Never convert content URIs into fictitious filesystem paths.
- [x] Apply settings snapshots to new batch tasks/queue destinations; record UI
  lifecycle and merge native events through task 2 APIs at guarded saves/status.
  Preserve generation guards, resource scheduling, approval and task ownership.
- [x] Test picker/copy channel contracts, cancellation/failure handling, single
  and batch destinations, stored queue compatibility and default-option snapshots.
  Include JVM storage policy tests where pure policy can be separated from SAF.

## 4. Coordinator review, qualification and PR

- [x] Review all diffs and cross-coder contracts; keep operator text localized.
  Run Dart formatting, analysis and complete Flutter tests; inspect intentional
  screenshot differences only before accepting baselines. Run native formatting,
  tests and build-script contracts using the pinned toolchain.
- [x] Bump version after implementation; run normal Windows source Release
  builder and Android ARM64 core/APK build, JVM tests/lint and package checks.
  Inspect connected ADB devices and use available hardware; report if absent.
- [x] Record evidence and ownership in ROADMAP/COLLABORATION, create a codex/
  branch, conventional commits including prior pending patch, push to origin,
  create a reviewable PR with validation and attach it to this task. Preserve
  historical notices/licenses; exclude .local, builds and personal data.
