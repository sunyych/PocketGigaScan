import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/stitch_timeline.dart';
import 'package:stitch_app/models/stitch_task.dart';

void main() {
  test('native batches deduplicate and retain timestamp order', () {
    const empty = StitchTimeline();
    final batch = <Map<String, Object?>>[
      {
        'id': 2,
        'timestampUtc': 2000,
        'stage': 'render-level-0',
        'state': 'running',
        'operation': 'render',
      },
      {
        'id': 1,
        'timestampUtc': 1000,
        'stage': 'register',
        'state': 'running',
        'operation': 'render',
      },
    ];
    final merged = empty
        .mergeNativeBatch(batch, jobId: 'job-a')
        .mergeNativeBatch(batch, jobId: 'job-a');
    expect(merged.events, hasLength(2));
    expect(merged.events.map((event) => event.stage), [
      'register',
      'render-level-0',
    ]);
    expect(merged.events.first.id, 'native:job-a:1');
  });

  test('timeline and task metadata round trip with legacy defaults', () {
    final taskJson = <String, Object?>{
      'id': 'legacy',
      'createdAt': '2026-01-01T00:00:00Z',
      'sourceDirectory': '/input',
      'outputDirectory': '/output',
      'photos': <Object?>[],
      'grid': <String, Object?>{'rows': 1, 'columns': 1},
      'phase': 'completed',
      'horizontalFovDegrees': 45,
      'memoryBudgetMiB': 128,
      'workers': 2,
    };
    final legacy = StitchTask.fromJson(taskJson);
    expect(legacy.timeline.events, isEmpty);
    expect(legacy.exportDirectory, isNull);
    final event = StitchTimelineEvent(
      id: 'ui:started',
      timestampUtc: DateTime.utc(2026),
      kind: 'started',
    );
    final populated = legacy.copyWith(
      timeline: StitchTimeline(events: [event]),
      exportDirectory: 'content://tree',
      publishedExportPath: '/published/out.png',
    );
    final restored = StitchTask.fromJson(populated.toJson());
    expect(restored.timeline.events.single.timestampUtc, DateTime.utc(2026));
    expect(restored.exportDirectory, 'content://tree');
    expect(restored.publishedExportPath, '/published/out.png');
  });

  test(
    'UI lifecycle events merge and clearable publication fields round trip',
    () {
      const timeline = StitchTimeline();
      final started = timeline.mergeUiEvent(
        id: 'started',
        kind: 'started',
        timestampUtc: DateTime.utc(2026),
      );
      final done = started.mergeUiEvent(
        id: 'finished',
        kind: 'finished',
        timestampUtc: DateTime.utc(2026, 1, 1, 0, 1),
      );
      expect(done.events.map((event) => event.id), ['started', 'finished']);
      final task = StitchTask.fromJson(<String, Object?>{
        'id': 'legacy',
        'createdAt': '2026-01-01T00:00:00Z',
        'sourceDirectory': '/input',
        'outputDirectory': '/output',
        'photos': <Object?>[],
        'grid': <String, Object?>{},
        'phase': 'completed',
      }).copyWith(publishedExportPath: '/out', publishError: 'copy failed');
      expect(
        task
            .copyWith(clearPublishedExportPath: true, clearPublishError: true)
            .publishedExportPath,
        isNull,
      );
    },
  );

  StitchTimelineEvent event(
    String id,
    int second,
    String state,
    String operation, {
    String? stage,
  }) => StitchTimelineEvent(
    id: id,
    timestampUtc: DateTime.utc(2026, 1, 1).add(Duration(seconds: second)),
    kind: 'native-transition',
    state: state,
    operation: operation,
    stage: stage,
  );

  test('duration includes pause and resume as elapsed wall clock', () {
    final timeline = StitchTimeline(
      events: [
        event('1', 0, 'running', 'render', stage: 'validate'),
        event('1b', 4, 'running', 'render', stage: 'register'),
        event('1c', 9, 'running', 'render', stage: 'render-level-0'),
        event('2', 10, 'paused', 'render'),
        event('3', 15, 'running', 'render', stage: 'render-level-0'),
        event('3b', 18, 'running', 'render', stage: 'pyramid'),
        event('4', 20, 'completed', 'render'),
      ],
    );
    final summary = timeline.summary(now: DateTime.utc(2026, 1, 1, 0, 0, 30));
    expect(summary.startedAtUtc, DateTime.utc(2026, 1, 1));
    expect(summary.finishedAtUtc, DateTime.utc(2026, 1, 1, 0, 0, 20));
    expect(summary.wallClockDuration, const Duration(seconds: 20));
    expect(summary.latestOperationDuration, const Duration(seconds: 20));
    expect(summary.isInProgress, isFalse);
  });

  test(
    'render completion waits for automatic export and manual retry extends latest cycle',
    () {
      final rendered = StitchTimeline(
        events: [
          event('1', 0, 'running', 'render'),
          event('2', 20, 'completed', 'render'),
        ],
      );
      final waiting = rendered.summary(
        autoExportExpected: true,
        now: DateTime.utc(2026, 1, 1, 0, 0, 22),
      );
      expect(waiting.isInProgress, isTrue);
      expect(waiting.finishedAtUtc, isNull);
      expect(waiting.wallClockDuration, const Duration(seconds: 22));
      final uiExporting =
          StitchTimeline(
            events: [
              ...rendered.events,
              StitchTimelineEvent(
                id: 'ui-exporting',
                timestampUtc: DateTime.utc(2026, 1, 1, 0, 0, 21),
                kind: 'export-started',
                state: 'exporting',
                operation: 'export',
              ),
            ],
          ).summary(
            autoExportExpected: true,
            now: DateTime.utc(2026, 1, 1, 0, 0, 23),
          );
      expect(uiExporting.isInProgress, isTrue);
      expect(uiExporting.wallClockDuration, const Duration(seconds: 23));

      final autoExported = StitchTimeline(
        events: [
          ...rendered.events,
          event('3', 21, 'running', 'export'),
          event('4', 25, 'completed', 'export'),
        ],
      );
      final automatic = autoExported.summary(autoExportExpected: true);
      expect(automatic.isInProgress, isFalse);
      expect(automatic.finishedAtUtc, DateTime.utc(2026, 1, 1, 0, 0, 25));
      expect(automatic.latestOperationDuration, const Duration(seconds: 4));

      final retry = StitchTimeline(
        events: [
          ...autoExported.events,
          event('5a', 80, 'running', 'export'),
          event('5b', 90, 'failed', 'export'),
          event('5', 100, 'running', 'export'),
          event('6', 105, 'completed', 'export'),
        ],
      );
      final retried = retry.summary();
      expect(retried.finishedAtUtc, DateTime.utc(2026, 1, 1, 0, 1, 45));
      expect(retried.wallClockDuration, const Duration(seconds: 105));
      expect(retried.latestOperationDuration, const Duration(seconds: 5));
    },
  );

  test(
    'legacy timestamps stay unknown and malformed native event is skipped',
    () {
      final legacy = const StitchTimeline().summary();
      expect(legacy.hasKnownStart, isFalse);
      expect(legacy.startedAtUtc, isNull);
      expect(legacy.finishedAtUtc, isNull);
      expect(legacy.wallClockDuration, isNull);
      final parsed = const StitchTimeline().mergeNativeBatch([
        {'id': 1, 'timestampUtc': 'not-a-date', 'state': 'running'},
        {
          'id': 2,
          'timestampUtc': 1000,
          'state': 'running',
          'operation': 'render',
        },
      ], jobId: 'safe');
      expect(parsed.events, hasLength(1));
      expect(parsed.events.single.id, 'native:safe:2');
    },
  );

  test(
    'merging stale candidates preserves distinct transitions sharing an ID and timestamp',
    () {
      final at = DateTime.utc(2026);
      final cached = StitchTimeline(
        events: [
          StitchTimelineEvent(
            id: 'ui:transition',
            timestampUtc: at,
            kind: 'pause',
            state: 'paused',
          ),
        ],
      );
      final staleCandidate = StitchTimeline(
        events: [
          StitchTimelineEvent(
            id: 'ui:transition',
            timestampUtc: at,
            kind: 'resume',
            state: 'running',
          ),
        ],
      );
      final merged = cached.merge(staleCandidate);
      expect(merged.events, hasLength(2));
      expect(merged.events.map((event) => event.state).toSet(), {
        'paused',
        'running',
      });
      expect(merged.merge(staleCandidate).events, hasLength(2));
    },
  );
}
