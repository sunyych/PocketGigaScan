import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
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

class _CountingForegroundLock implements ForegroundWorkLock {
  int enableCount = 0;
  int disableCount = 0;

  @override
  Future<void> enable() async => enableCount++;

  @override
  Future<void> disable() async => disableCount++;
}

class _EnglishTestApp extends StatelessWidget {
  const _EnglishTestApp({required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: const Locale('en'),
    supportedLocales: StitchLocalizations.supportedLocales,
    localizationsDelegates: const [
      StitchLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
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

class _RecoveringWidgetJobApi extends _WidgetJobApi {
  int statusCalls = 0;

  @override
  Future<Map<String, Object?>> status(String jobId) async {
    statusCalls++;
    return {'state': 'running', 'progress': 0.25, 'stage': 'render'};
  }
}

class _MemoryTaskRepository extends TaskRepository {
  _MemoryTaskRepository({this.saveGate, this.loadAllGate});

  final Completer<void>? saveGate;
  final Completer<void>? loadAllGate;
  final saveStarted = Completer<void>();
  final loadAllStarted = Completer<void>();
  StitchTask? saved;
  StitchTask? duplicate;
  final Map<String, StitchTask> records = {};

  @override
  Future<List<StitchTask>> loadAll() async {
    if (!loadAllStarted.isCompleted) loadAllStarted.complete();
    await loadAllGate?.future;
    return records.values.toList();
  }

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
      maxEdgeReprojectionRmsPixels: old.maxEdgeReprojectionRmsPixels,
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

Future<Finder> _lazyChildVisibleAfterScroll(
  WidgetTester tester,
  Finder target, {
  double delta = 300,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find
        .descendant(
          of: find.byType(ListView).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pump(const Duration(milliseconds: 350));
  final visible = target.hitTestable();
  expect(visible, findsOneWidget);
  return visible;
}

void main() {
  testWidgets(
    'task progress is static before stitching in English and Chinese',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final language in ['en', 'zh']) {
        final imported = StitchTask(
          id: 'progress-imported-$language',
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
        final repository = _MemoryTaskRepository();
        final api = _WidgetJobApi();
        await tester.pumpWidget(
          LumiaStitchApp(
            key: ValueKey('$language-imported'),
            locale: Locale(language),
            home: StitchHomePage(
              initialTask: imported,
              jobApi: api,
              repository: repository,
              batchQueueController: EmptyBatchQueueController(
                api: api,
                taskRepository: repository,
              ),
              foregroundWorkLock: _TestForegroundLock(),
              mobileOverride: false,
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));

        final progress = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator).first,
        );
        expect(progress.value, 0, reason: '$language imported task');
        expect(
          find.text(
            language == 'zh' ? 'ready · 0% · 已导入' : 'ready · 0% · Imported',
          ),
          findsOneWidget,
        );

        final running = imported.copyWith(phase: StitchPhase.running);
        final runningRepository = _MemoryTaskRepository();
        await tester.pumpWidget(
          LumiaStitchApp(
            key: ValueKey('$language-running'),
            locale: Locale(language),
            home: StitchHomePage(
              initialTask: running,
              jobApi: api,
              repository: runningRepository,
              batchQueueController: EmptyBatchQueueController(
                api: api,
                taskRepository: runningRepository,
              ),
              foregroundWorkLock: _TestForegroundLock(),
              mobileOverride: false,
            ),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator).first,
              )
              .value,
          isNull,
          reason: '$language running task at zero progress stays indeterminate',
        );

        final queued = imported.copyWith(phase: StitchPhase.queued);
        final queuedRepository = _MemoryTaskRepository();
        await tester.pumpWidget(
          LumiaStitchApp(
            key: ValueKey('$language-queued'),
            locale: Locale(language),
            home: StitchHomePage(
              initialTask: queued,
              jobApi: api,
              repository: queuedRepository,
              batchQueueController: EmptyBatchQueueController(
                api: api,
                taskRepository: queuedRepository,
              ),
              foregroundWorkLock: _TestForegroundLock(),
              mobileOverride: false,
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator).first,
              )
              .value,
          0,
          reason: '$language queued task remains static at zero progress',
        );

        final paused = queued.copyWith(phase: StitchPhase.paused);
        final pausedRepository = _MemoryTaskRepository();
        await tester.pumpWidget(
          LumiaStitchApp(
            key: ValueKey('$language-paused'),
            locale: Locale(language),
            home: StitchHomePage(
              initialTask: paused,
              jobApi: api,
              repository: pausedRepository,
              batchQueueController: EmptyBatchQueueController(
                api: api,
                taskRepository: pausedRepository,
              ),
              foregroundWorkLock: _TestForegroundLock(),
              mobileOverride: false,
            ),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator).first,
              )
              .value,
          0,
          reason: '$language paused task is static at zero progress',
        );

        final progressedPaused = paused.copyWith(progress: 0.42);
        final progressedPausedRepository = _MemoryTaskRepository();
        await tester.pumpWidget(
          LumiaStitchApp(
            key: ValueKey('$language-paused-progress'),
            locale: Locale(language),
            home: StitchHomePage(
              initialTask: progressedPaused,
              jobApi: api,
              repository: progressedPausedRepository,
              batchQueueController: EmptyBatchQueueController(
                api: api,
                taskRepository: progressedPausedRepository,
              ),
              foregroundWorkLock: _TestForegroundLock(),
              mobileOverride: false,
            ),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator).first,
              )
              .value,
          0.42,
          reason: '$language paused task retains completed progress',
        );
      }
    },
  );

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

  testWidgets('mobile registration threshold is available in English', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _MemoryTaskRepository();
    final task = StitchTask(
      id: 'threshold-mobile-en',
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
      maxEdgeReprojectionRmsPixels: 14,
    );
    await tester.pumpWidget(
      _EnglishTestApp(
        home: StitchHomePage(
          initialTask: task,
          jobApi: _WidgetJobApi(),
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: _WidgetJobApi(),
            taskRepository: repository,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    final thresholdExpansion = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('registration-threshold-expansion')),
    );
    await tester.tap(thresholdExpansion);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.text('Neighbor registration RMS limit (pixels): 14.0'),
      findsOneWidget,
    );
    expect(find.textContaining('Values above 12 pixels'), findsOneWidget);
    final slider = tester.widget<Slider>(
      find.byKey(const Key('max-edge-reprojection-rms-slider')),
    );
    expect(slider.label, contains('Neighbor registration RMS limit (pixels)'));
    expect(slider.semanticFormatterCallback!(12), '12.0 pixels');
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup restores saved task options without initialTask', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loadGate = Completer<void>();
    final repository = _MemoryTaskRepository(loadAllGate: loadGate);
    final task = StitchTask(
      id: 'threshold-startup-restore',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'input',
      outputDirectory: 'output',
      photos: [
        ImportedPhoto(
          originalName: 'one.jpg',
          storedPath: 'one.jpg',
          sha256: 'a',
          width: 100,
          height: 80,
          originalOrder: 0,
          exifMake: 'test-camera',
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.imported,
      exportFormat: ExportFormat.tiff,
      maxEdgeReprojectionRmsPixels: 13,
    );
    repository.records[task.id] = task;

    await tester.pumpWidget(
      _EnglishTestApp(
        home: StitchHomePage(
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
    await tester.pump();
    expect(repository.loadAllStarted.isCompleted, isTrue);
    loadGate.complete();
    await tester.pump();
    await tester.pump();
    final expansion = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('registration-threshold-expansion')),
    );
    await tester.tap(expansion);
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      find.text('Neighbor registration RMS limit (pixels): 13.0'),
      findsOneWidget,
    );
    expect(find.textContaining('Values above 12 pixels'), findsOneWidget);
    await _lazyChildVisibleAfterScroll(
      tester,
      find.byKey(const Key('export-format-option')),
      delta: -300,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<ExportFormat>>(
            find.byKey(const Key('export-format-option')),
          )
          .initialValue,
      ExportFormat.tiff,
    );
    await _lazyChildVisibleAfterScroll(
      tester,
      find.textContaining('Photo-to-grid mapping (1/1)'),
    );
    expect(find.textContaining('Photo-to-grid mapping (1/1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup resumes native polling for a saved active task', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loadGate = Completer<void>();
    final repository = _MemoryTaskRepository(loadAllGate: loadGate);
    final api = _RecoveringWidgetJobApi();
    final foregroundLock = _CountingForegroundLock();
    final task = StitchTask(
      id: 'active-task-startup-recovery',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'input',
      outputDirectory: 'output',
      photos: const [],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.running,
      nativeJobId: 'native-running-job',
    );
    repository.records[task.id] = task;

    await tester.pumpWidget(
      _EnglishTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          foregroundWorkLock: foregroundLock,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump();
    expect(repository.loadAllStarted.isCompleted, isTrue);
    loadGate.complete();
    await tester.pump();
    await tester.pump();
    expect(api.statusCalls, 1); // Immediate native-state reconciliation.
    expect(foregroundLock.enableCount, 1);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(
      api.statusCalls,
      greaterThanOrEqualTo(2),
    ); // Periodic polling resumed.
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'registration threshold restores and locks for a running mobile task',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _MemoryTaskRepository();
      final task = StitchTask(
        id: 'threshold-running',
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
        phase: StitchPhase.running,
        nativeJobId: 'native-job',
        maxEdgeReprojectionRmsPixels: 17.5,
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
            mobileOverride: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final thresholdExpansion = await _visibleAfterScroll(
        tester,
        find.byKey(const Key('registration-threshold-expansion')),
      );
      await tester.tap(thresholdExpansion);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('相邻配准误差上限 RMS（像素）: 17.5'), findsOneWidget);
      expect(find.text('17.5'), findsOneWidget);
      expect(find.text('高于 12 像素会放宽配准误差上限，可能接受更不准确的相邻匹配。'), findsOneWidget);
      expect(find.textContaining('请先点“新建副本重新合成”再调整'), findsOneWidget);
      expect(
        tester
            .widget<Slider>(
              find.byKey(const Key('max-edge-reprojection-rms-slider')),
            )
            .onChanged,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

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

    final thresholdExpansion = await _visibleAfterScroll(
      tester,
      find.byKey(const Key('registration-threshold-expansion')),
    );
    await tester.tap(thresholdExpansion);
    await tester.pumpAndSettle();
    final sliderFinder = find.byKey(
      const Key('max-edge-reprojection-rms-slider'),
    );
    await _visibleAfterScroll(tester, sliderFinder);
    final slider = tester.widget<Slider>(sliderFinder);
    expect(slider.onChanged, isNotNull);
    expect(slider.label, contains('相邻配准误差上限 RMS（像素）'));
    expect(slider.semanticFormatterCallback!(12), '12.0 像素');
    await tester.drag(sliderFinder, const Offset(180, 0));
    await tester.pump();
    expect(repository.saved?.maxEdgeReprojectionRmsPixels, greaterThan(12));
    expect(find.textContaining('高于 12 像素会放宽配准误差上限'), findsOneWidget);
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
