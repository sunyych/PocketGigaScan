import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'support/empty_batch_queue_controller.dart';
import 'support/chinese_test_app.dart';

class _NoopForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

class _OptionsScreenshotRepository extends TaskRepository {
  _OptionsScreenshotRepository(this.task);
  final StitchTask task;

  @override
  Future<List<StitchTask>> loadAll() async => [task];

  @override
  Future<void> save(StitchTask task) async {}
}

class _OptionsScreenshotApi implements JobApi {
  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'jpegXlAvailable': true,
      'exportFormats': {'png': true, 'tiff': true, 'jxl': true},
    },
  };

  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) => capabilities();

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => throw UnimplementedError();

  @override
  Future<Map<String, Object?>> status(String jobId) async => {
    'ok': true,
    'state': 'paused',
    'operation': 'render',
    'stage': 'paused',
    'progress': 0.5,
  };

  @override
  Future<Map<String, Object?>> pause(String jobId) async =>
      throw UnimplementedError();

  @override
  Future<Map<String, Object?>> resume(String jobId) async =>
      throw UnimplementedError();

  @override
  Future<Map<String, Object?>> cancel(String jobId) async =>
      throw UnimplementedError();

  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      throw UnimplementedError();
}

void main() {
  for (final (size, mode) in [
    (const Size(1280, 900), 'desktop'),
    (const Size(390, 844), 'mobile'),
  ]) {
    for (final profile in ['auto', 'manual', 'locked']) {
      _addOptionsScreenshotTest(size, mode, profile);
    }
  }
}

void _addOptionsScreenshotTest(Size size, String mode, String profile) {
  final locked = profile == 'locked';
  testWidgets('grid overlap options $mode $profile', (tester) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('stitch-force-grid-options-'),
    ))!;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final thumbnail = File('${temp.path}/thumbnail.png');
    await tester.runAsync(
      () => thumbnail.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOIWnAJAAMkAc2CFM/BAAAAAElFTkSuQmCC',
        ),
      ),
    );
    final task = StitchTask(
      id: 'options-$mode-$locked',
      createdAt: DateTime.utc(2026),
      sourceDirectory: temp.path,
      outputDirectory: '${temp.path}/output',
      photos: [
        ImportedPhoto(
          originalName: '00_00.jpg',
          storedPath: thumbnail.path,
          sha256: 'fixture',
          width: 3840,
          height: 2160,
          originalOrder: 0,
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 2.933,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: locked ? StitchPhase.failed : StitchPhase.imported,
      nativeJobId: locked ? 'failed-native-job' : null,
      forceGridFallback: locked,
      autoGridOverlap: profile != 'manual',
      performanceOptions: profile == 'enabled'
          ? const PerformanceOptions(
              fourNeighborFirst: true,
              fastRegistration: true,
              orbFeatures: true,
            )
          : const PerformanceOptions(),
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final api = _OptionsScreenshotApi();
    final repository = _OptionsScreenshotRepository(task);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          initialTask: task,
          jobApi: api,
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          foregroundWorkLock: _NoopForegroundLock(),
          mobileOverride: mode == 'mobile',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.byKey(const Key('stitch-options-card')));
    await tester.pump(const Duration(milliseconds: 100));

    final switchTile = tester.widget<SwitchListTile>(
      find.byKey(const Key('force-grid-option')),
    );
    final autoOverlap = tester.widget<CheckboxListTile>(
      find.byKey(const Key('auto-grid-overlap-option')),
    );
    expect(switchTile.onChanged == null, locked || profile != 'manual');
    expect(switchTile.value, locked);
    expect(autoOverlap.value, profile != 'manual');
    expect(autoOverlap.onChanged == null, locked);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('horizontal-overlap-field')))
          .enabled,
      !locked && profile == 'manual',
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('stitch-options-card')),
      matchesGoldenFile('goldens/grid_overlap_${mode}_$profile.png'),
    );
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
