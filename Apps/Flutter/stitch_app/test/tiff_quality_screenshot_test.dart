import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/empty_batch_queue_controller.dart';
import 'support/chinese_test_app.dart';

class _ScreenshotApi implements JobApi {
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
    'progress': 1.0,
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

class _NoopForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}
}

class _ScreenshotRepository extends TaskRepository {
  _ScreenshotRepository(this.task);
  final StitchTask task;

  @override
  Future<List<StitchTask>> loadAll() async => [task];

  @override
  Future<void> save(StitchTask task) async {}
}

void main() {
  for (final entry in {
    'default-tiff': ExportFormat.tiff,
    'png': ExportFormat.png,
    'jpeg-xl': ExportFormat.jpegXl,
  }.entries) {
    testWidgets('visible export format card: ${entry.key}', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final task = StitchTask(
        id: 'export-format-${entry.key}',
        createdAt: DateTime.utc(2026, 10, 4),
        sourceDirectory: 'input',
        outputDirectory: 'output',
        photos: const [
          ImportedPhoto(
            originalName: '00_00.jpg',
            storedPath: '00_00.jpg',
            sha256: 'fixture',
            width: 3840,
            height: 2160,
            originalOrder: 0,
          ),
        ],
        grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 512,
        workers: 4,
        phase: StitchPhase.imported,
        exportFormat: entry.value,
      );

      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            initialTask: task,
            jobApi: _ScreenshotApi(),
            repository: _ScreenshotRepository(task),
            batchQueueController: EmptyBatchQueueController(
              api: _ScreenshotApi(),
              taskRepository: _ScreenshotRepository(task),
            ),
            foregroundWorkLock: _NoopForegroundLock(),
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      final formatCard = find
          .byKey(const Key('export-format-card'))
          .hitTestable();
      expect(formatCard, findsOneWidget);
      expect(find.text('单任务合成完成后自动导出全分辨率整图。'), findsOneWidget);
      final selector = tester.widget<DropdownButtonFormField<ExportFormat>>(
        find.byKey(const Key('export-format-option')),
      );
      expect(selector.initialValue, entry.value);
      expect(selector.onChanged, isNotNull);
      final dropdown = tester.widget<DropdownButton<ExportFormat>>(
        find.descendant(
          of: find.byKey(const Key('export-format-option')),
          matching: find.byType(DropdownButton<ExportFormat>),
        ),
      );
      expect(
        dropdown.items!
            .singleWhere((item) => item.value == ExportFormat.jpegXl)
            .enabled,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile(
          'goldens/export_format_card_desktop_${entry.key}.png',
        ),
      );
    });
  }

  for (final state in [
    'default-tiff',
    'png-feather',
    'local-warp-off',
    'paused-locked',
  ]) {
    testWidgets('TIFF and seam quality controls: $state', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final paused = state == 'paused-locked';
      final task = StitchTask(
        id: 'quality-$state',
        createdAt: DateTime.utc(2026, 10, 4),
        sourceDirectory: 'input',
        outputDirectory: 'output',
        photos: const [
          ImportedPhoto(
            originalName: '00_00.jpg',
            storedPath: '00_00.jpg',
            sha256: 'fixture',
            width: 3840,
            height: 2160,
            originalOrder: 0,
          ),
        ],
        grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 512,
        workers: 4,
        phase: paused ? StitchPhase.paused : StitchPhase.imported,
        nativeJobId: paused ? 'native-paused-job' : null,
        exportFormat: state == 'png-feather'
            ? ExportFormat.png
            : ExportFormat.tiff,
        refineGridNeighbors: state != 'png-feather',
        seamBlendMode: state == 'png-feather'
            ? SeamBlendMode.feather
            : SeamBlendMode.deghost,
        localTextureWarp: state != 'local-warp-off',
      );

      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            initialTask: task,
            jobApi: _ScreenshotApi(),
            repository: _ScreenshotRepository(task),
            batchQueueController: EmptyBatchQueueController(
              api: _ScreenshotApi(),
              taskRepository: _ScreenshotRepository(task),
            ),
            foregroundWorkLock: _NoopForegroundLock(),
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      DropdownButtonFormField<ExportFormat>? format;
      if (paused) {
        expect(find.byKey(const Key('export-format-card')), findsNothing);
        expect(find.byKey(const Key('export-format-option')), findsNothing);
      } else {
        await tester.ensureVisible(find.byKey(const Key('export-format-card')));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        expect(find.byKey(const Key('export-format-card')), findsOneWidget);
        final selectedFormat = tester
            .widget<DropdownButtonFormField<ExportFormat>>(
              find.byKey(const Key('export-format-option')),
            );
        format = selectedFormat;
        expect(selectedFormat.initialValue, task.exportFormat);
      }

      await tester.ensureVisible(
        find.byKey(const Key('stitch-quality-expansion')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      await tester.tap(find.byKey(const Key('stitch-quality-expansion')));
      await tester.pump(const Duration(milliseconds: 350));

      final neighbors = tester.widget<CheckboxListTile>(
        find.byKey(const Key('refine-grid-neighbors-option')),
      );
      final deghost = tester.widget<CheckboxListTile>(
        find.byKey(const Key('deghost-blending-option')),
      );
      final localTextureWarp = tester.widget<CheckboxListTile>(
        find.byKey(const Key('local-texture-warp-option')),
      );
      expect(neighbors.value, task.refineGridNeighbors);
      expect(deghost.value, task.seamBlendMode == SeamBlendMode.deghost);
      expect(localTextureWarp.value, task.localTextureWarp);
      if (!paused) {
        expect(format!.onChanged, isNotNull);
      }
      expect(neighbors.onChanged == null, paused);
      expect(deghost.onChanged == null, paused);
      expect(neighbors.onChanged != null, !paused);
      expect(deghost.onChanged != null, !paused);
      expect(localTextureWarp.onChanged == null, paused);
      expect(localTextureWarp.onChanged != null, !paused);
      expect(find.byTooltip('在相邻重叠区域限制局部变形，减少纹理错位'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byKey(const Key('stitch-quality-expansion')),
        matchesGoldenFile('goldens/tiff_quality_desktop_$state.png'),
      );
    });
  }
}
