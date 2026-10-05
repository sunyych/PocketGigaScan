import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/empty_batch_queue_controller.dart';
import 'package:stitch_app/services/power_service.dart';
import 'support/chinese_test_app.dart';

class _TestForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

class _WidgetJobApi implements JobApi {
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
  Future<Map<String, Object?>> status(String jobId) async =>
      throw UnimplementedError();

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

class _MemoryTaskRepository extends TaskRepository {
  _MemoryTaskRepository({this.saveGate});

  final Completer<void>? saveGate;
  final saveStarted = Completer<void>();
  StitchTask? saved;
  StitchTask? duplicate;
  final Map<String, StitchTask> records = {};

  @override
  Future<List<StitchTask>> loadAll() async => records.values.toList();

  @override
  Future<void> save(StitchTask task) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await saveGate?.future;
    saved = task;
    records[task.id] = task;
  }

  @override
  Future<StitchTask> duplicateForNewRun(
    StitchTask old, {
    bool autoExportOnCompletion = true,
  }) async {
    duplicate = StitchTask(
      id: 'fresh-${old.id}',
      createdAt: DateTime.utc(2026, 1, 2),
      sourceDirectory: old.sourceDirectory,
      outputDirectory: 'fresh-output',
      photos: old.photos,
      grid: old.grid,
      horizontalFovDegrees: old.horizontalFovDegrees,
      memoryBudgetMiB: old.memoryBudgetMiB,
      workers: old.workers,
      phase: StitchPhase.imported,
      forceGridFallback: old.forceGridFallback,
      autoGridOverlap: old.autoGridOverlap,
      gridHorizontalOverlap: old.gridHorizontalOverlap,
      gridVerticalOverlap: old.gridVerticalOverlap,
      cameraProfileId: old.cameraProfileId,
      cameraCalibrationOverridden: old.cameraCalibrationOverridden,
      performanceOptions: old.performanceOptions,
      exportFormat: old.exportFormat,
      autoExportOnCompletion: autoExportOnCompletion,
      refineGridNeighbors: old.refineGridNeighbors,
      seamBlendMode: old.seamBlendMode,
      localTextureWarp: old.localTextureWarp,
    );
    return duplicate!;
  }
}

Future<Finder> _visibleAfterScroll(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  final visible = target.hitTestable();
  expect(visible, findsOneWidget);
  return visible;
}

void main() {
  testWidgets(
    'desktop shell shows local import affordance and explicit unavailable core',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const LumiaStitchApp());
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.text('PocketGigaScan'), findsOneWidget);
      expect(
        find.text('Import photos to create a local panorama task'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Photos are copied to a local task folder and are never uploaded.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('mobile shell provides task drawer and no layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const LumiaStitchApp());
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.byTooltip('Local tasks'), findsOneWidget);
    expect(find.byKey(const Key('stitch-quality-expansion')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop quality choices persist on the editable task', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _MemoryTaskRepository();
    final task = StitchTask(
      id: 'quality-task',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'input',
      outputDirectory: 'output',
      photos: const [
        ImportedPhoto(
          originalName: 'one.jpg',
          storedPath: 'one.jpg',
          sha256: 'a',
          width: 100,
          height: 80,
          originalOrder: 0,
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.imported,
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          initialTask: task,
          jobApi: _WidgetJobApi(),
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: _WidgetJobApi(),
            taskRepository: repository,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final exportFormat = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('export-format-option')),
    );
    final formatSelector = tester.widget<DropdownButtonFormField<ExportFormat>>(
      find.byKey(const Key('export-format-option')),
    );
    expect(formatSelector.onChanged, isNotNull);
    await tester.tap(exportFormat);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final tiffChoice = find.text(ExportFormat.tiff.label).hitTestable();
    expect(tiffChoice, findsOneWidget);
    await tester.tap(tiffChoice);
    await tester.pump();
    final qualityExpansion = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('stitch-quality-expansion')),
    );
    await tester.tap(qualityExpansion);
    await tester.pump(const Duration(milliseconds: 350));
    final neighborsOption = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('refine-grid-neighbors-option')),
    );
    await tester.tap(neighborsOption);
    await tester.pump();
    final deghostOption = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('deghost-blending-option')),
    );
    await tester.tap(deghostOption);
    await tester.pump();
    final textureWarpOption = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('local-texture-warp-option')),
    );
    await tester.tap(textureWarpOption);
    await tester.pump();

    expect(repository.saved?.exportFormat, ExportFormat.tiff);
    expect(repository.saved?.refineGridNeighbors, isTrue);
    expect(repository.saved?.seamBlendMode, SeamBlendMode.deghost);
    expect(repository.saved?.localTextureWarp, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-overlap switch saves task setting and enables manual rates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('stitch-force-grid-widget-'),
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
    final repository = _MemoryTaskRepository();
    final task = StitchTask(
      id: 'grid-task',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'input',
      outputDirectory: 'output',
      photos: [
        ImportedPhoto(
          originalName: 'one.jpg',
          storedPath: thumbnail.path,
          sha256: 'hash',
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
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          key: ValueKey(task.id),
          initialTask: task,
          jobApi: _WidgetJobApi(),
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: _WidgetJobApi(),
            taskRepository: repository,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final tile = tester.widget<SwitchListTile>(
      find.byKey(const Key('force-grid-option')),
    );
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    final autoOptionTile = tester.widget<CheckboxListTile>(
      find.byKey(const Key('auto-grid-overlap-option')),
    );
    expect(autoOptionTile.value, isTrue);
    expect(autoOptionTile.onChanged, isNotNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('horizontal-overlap-field')))
          .enabled,
      isFalse,
    );
    final autoOptionFinder = find.byKey(const Key('auto-grid-overlap-option'));
    final visibleAutoOption = await _visibleAfterScroll(
      tester,
      autoOptionFinder,
    );
    await tester.tap(visibleAutoOption);
    await tester.pump(const Duration(milliseconds: 100));
    final saveButton = await _visibleAfterScroll(tester, find.text('保存任务设置'));
    await tester.tap(saveButton);
    await tester.pump(const Duration(milliseconds: 100));

    expect(repository.saved?.forceGridFallback, isFalse);
    expect(repository.saved?.autoGridOverlap, isFalse);
    expect(repository.saved?.gridHorizontalOverlap, 0.3);
    expect(repository.saved?.gridVerticalOverlap, 0.3);
  });

  testWidgets('performance settings persist and ORB disables FLANN', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _MemoryTaskRepository();
    final task = StitchTask(
      id: 'performance-task',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'input',
      outputDirectory: 'output',
      photos: const [
        ImportedPhoto(
          originalName: 'one.jpg',
          storedPath: 'one.jpg',
          sha256: 'x',
          width: 100,
          height: 80,
          originalOrder: 0,
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 512,
      workers: 4,
      phase: StitchPhase.imported,
      autoGridOverlap: false,
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          initialTask: task,
          jobApi: _WidgetJobApi(),
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: _WidgetJobApi(),
            taskRepository: repository,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final orbOption = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('orb-features-option')),
    );
    await tester.tap(orbOption);
    await tester.pump();
    final flann = tester.widget<CheckboxListTile>(
      find.byKey(const Key('flann-matching-option')),
    );
    expect(flann.onChanged, isNull);
    expect(find.text('ORB 使用 BF 匹配；FLANN 已关闭。'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    final reloaded = StitchTask.fromJson(
      (await repository.loadAll()).single.toJson(),
    );
    expect(reloaded.performanceOptions.orbFeatures, isTrue);
    expect(reloaded.performanceOptions.matcherType, 'bf');
  });

  testWidgets(
    'manual task save locks all options until the full task is persisted',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = Completer<void>();
      final repository = _MemoryTaskRepository(saveGate: gate);
      final task = StitchTask(
        id: 'gated-save-task',
        createdAt: DateTime.utc(2026),
        sourceDirectory: 'input',
        outputDirectory: 'output',
        photos: const [
          ImportedPhoto(
            originalName: 'one.jpg',
            storedPath: 'one.jpg',
            sha256: 'x',
            width: 100,
            height: 80,
            originalOrder: 0,
          ),
        ],
        grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 512,
        workers: 4,
        phase: StitchPhase.imported,
        autoGridOverlap: false,
      );
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            initialTask: task,
            jobApi: _WidgetJobApi(),
            repository: repository,
            batchQueueController: EmptyBatchQueueController(
              api: _WidgetJobApi(),
              taskRepository: repository,
            ),
            foregroundWorkLock: _TestForegroundLock(),
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final saveButton = await _visibleAfterScroll(tester, find.text('保存任务设置'));
      await tester.tap(saveButton);
      await tester.pump();
      await repository.saveStarted.future;
      final parallelOption = await _visibleAfterScroll(
        tester,
        find.byKey(const Key('parallel-matching-option')),
      );
      final option = tester.widget<CheckboxListTile>(parallelOption);
      expect(option.onChanged, isNull);

      gate.complete();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repository.saved?.id, task.id);
      expect(repository.saved?.horizontalFovDegrees, 45);
      expect(repository.saved?.performanceOptions.parallelMatching, isTrue);
      final unlocked = tester.widget<CheckboxListTile>(
        find.byKey(const Key('parallel-matching-option')),
      );
      expect(unlocked.onChanged, isNotNull);
    },
  );

  testWidgets('failed task force-grid retry creates a new editable output task', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('stitch-force-grid-retry-'),
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
    final repository = _MemoryTaskRepository();
    final failed = StitchTask(
      id: 'failed-grid-task',
      createdAt: DateTime.utc(2026),
      sourceDirectory: temp.path,
      outputDirectory: '${temp.path}/old-output',
      photos: [
        ImportedPhoto(
          originalName: 'one.jpg',
          storedPath: thumbnail.path,
          sha256: 'hash',
          width: 3840,
          height: 2160,
          originalOrder: 0,
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 512,
      workers: 4,
      phase: StitchPhase.failed,
      nativeJobId: 'failed-native-job',
      localTextureWarp: false,
      gridHorizontalOverlap: 0.4,
      gridVerticalOverlap: 0.25,
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          initialTask: failed,
          jobApi: _WidgetJobApi(),
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: _WidgetJobApi(),
            taskRepository: repository,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final lockedTile = tester.widget<SwitchListTile>(
      find.byKey(const Key('force-grid-option')),
    );
    expect(lockedTile.onChanged, isNull);
    expect(find.text('按手动参数强制网格重试'), findsOneWidget);
    final retryButton = await _visibleAfterScroll(
      tester,
      find.text('按手动参数强制网格重试'),
    );
    await tester.tap(retryButton);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final fresh = repository.saved;
    expect(fresh?.id, 'fresh-failed-grid-task');
    expect(fresh?.outputDirectory, 'fresh-output');
    expect(fresh?.nativeJobId, isNull);
    expect(fresh?.phase, StitchPhase.imported);
    expect(fresh?.forceGridFallback, isTrue);
    expect(fresh?.autoGridOverlap, isFalse);
    expect(fresh?.gridHorizontalOverlap, 0.4);
    expect(fresh?.gridVerticalOverlap, 0.25);
    expect(fresh?.localTextureWarp, isFalse);
    expect(failed.outputDirectory, '${temp.path}/old-output');
  });
}
