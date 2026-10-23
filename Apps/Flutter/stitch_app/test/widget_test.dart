import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show ByteData;
import 'dart:ui' show ImageByteFormat, PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show FontLoader, LogicalKeyboardKey;
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
import 'package:stitch_app/services/registration_issues.dart';
import 'package:stitch_app/services/spherical_request.dart';
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

class _StartingWidgetJobApi extends _WidgetJobApi {
  final startedRequests = <Map<String, Object?>>[];
  int statusCalls = 0;

  @override
  Future<Map<String, Object?>> status(String jobId) async {
    statusCalls++;
    if (startedRequests.isEmpty) {
      return {
        'state': 'failed',
        'stage': 'registration-failed',
        'error': {
          'code': 'REGISTRATION_FAILED',
          'message': 'registration failed in polling regression',
        },
      };
    }
    return {'state': 'running', 'stage': 'register', 'progress': 0.1};
  }

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    startedRequests.add(request);
    return {
      'jobId': 'native-registration-repair',
      'state': 'running',
      'stage': 'register',
      'progress': 0,
    };
  }
}

class _MemoryTaskRepository extends TaskRepository {
  _MemoryTaskRepository({
    this.saveGate,
    this.loadAllGate,
    this.duplicateOutput,
    this.skipOutputCreation = false,
  });

  final Completer<void>? saveGate;
  final Completer<void>? loadAllGate;
  final String? duplicateOutput;
  final bool skipOutputCreation;
  final saveStarted = Completer<void>();
  final loadAllStarted = Completer<void>();
  StitchTask? saved;
  StitchTask? duplicate;
  int saveCount = 0;
  int duplicateCount = 0;
  final Map<String, StitchTask> records = {};

  @override
  Future<List<StitchTask>> loadAll() async {
    if (!loadAllStarted.isCompleted) loadAllStarted.complete();
    await loadAllGate?.future;
    return records.values.toList();
  }

  @override
  Future<void> save(StitchTask task) async {
    saveCount++;
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
    duplicateCount++;
    duplicate = StitchTask(
      id: 'fresh-${old.id}',
      createdAt: DateTime.utc(2026, 1, 2),
      sourceDirectory: old.sourceDirectory,
      outputDirectory: duplicateOutput ?? 'fresh-output',
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
      registrationRepairOffered: old.registrationRepairOffered,
    );
    records[duplicate!.id] = duplicate!;
    return duplicate!;
  }

  @override
  Future<Directory> prepareOutput(StitchTask task) async {
    final output = Directory(task.outputDirectory);
    if (!skipOutputCreation) await output.create(recursive: true);
    return output;
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
  testWidgets('failed native registration issues select and lock only chosen photos', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('photo-grid-issues-'),
    ))!;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final imageBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOIWnAJAAMkAc2CFM/BAAAAAElFTkSuQmCC',
    );
    final photos = <ImportedPhoto>[];
    for (var i = 0; i < 6; i++) {
      final path = '${temp.path}/photo-$i.png';
      await tester.runAsync(() => File(path).writeAsBytes(imageBytes));
      photos.add(
        ImportedPhoto(
          originalName: [
            '08_20.jpg',
            '08_21.jpg',
            '09_22.jpg',
            '10_22.jpg',
            '11_22.jpg',
            '12_22.jpg',
          ][i],
          storedPath: path,
          sha256: 'hash-$i',
          width: 3840,
          height: 2160,
          originalOrder: i,
          exifMake: 'fixture',
        ),
      );
    }
    final original = StitchTask(
      id: 'failed-registration-task',
      createdAt: DateTime.utc(2026),
      sourceDirectory: temp.path,
      outputDirectory: '${temp.path}/old-output',
      photos: photos,
      grid: const GridOptions(mode: GridMode.sequence, rows: 2, columns: 3),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 512,
      workers: 4,
      phase: StitchPhase.failed,
      nativeJobId: 'native-old-job',
      registrationRepairOffered: true,
      error:
          'REGISTRATION_FAILED: global matched-ray reprojection is 2.34px RMS',
    );
    final repository = _MemoryTaskRepository()..records[original.id] = original;
    final issue = RegistrationIssue(
      fromPhotoPath: photos[0].storedPath,
      toPhotoPath: photos[1].storedPath,
      fromName: photos[0].originalName,
      toName: photos[1].originalName,
      rmsPx: 29.96,
      limitPx: 20,
    );
    final verticalIssue = RegistrationIssue(
      fromPhotoPath: photos[0].storedPath,
      toPhotoPath: photos[3].storedPath,
      fromName: photos[0].originalName,
      toName: photos[3].originalName,
      rmsPx: 23.1,
      limitPx: 20,
    );
    final previewFontPath = Platform.environment['GRID_PREVIEW_FONT'];
    ThemeData? previewTheme;
    if (previewFontPath != null && previewFontPath.isNotEmpty) {
      final fontBytes = await tester.runAsync(
        () => File(previewFontPath).readAsBytes(),
      );
      final fontLoader = FontLoader('GridPreviewFont')
        ..addFont(Future.value(ByteData.sublistView(fontBytes!)));
      await tester.runAsync(fontLoader.load);
      previewTheme = ThemeData(fontFamily: 'GridPreviewFont');
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('photo-grid-visual-validation'),
        child: MaterialApp(
          locale: const Locale('zh'),
          theme: previewTheme,
          supportedLocales: StitchLocalizations.supportedLocales,
          localizationsDelegates: const [
            StitchLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: StitchHomePage(
            initialTask: original,
            jobApi: _WidgetJobApi(),
            repository: repository,
            registrationIssueLoader: (task) async =>
                task.id == original.id ? [issue, verticalIssue] : const [],
            batchQueueController: EmptyBatchQueueController(
              api: _WidgetJobApi(),
              taskRepository: repository,
            ),
            foregroundWorkLock: _TestForegroundLock(),
            mobileOverride: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _lazyChildVisibleAfterScroll(
      tester,
      find.textContaining('照片与网格映射'),
      delta: 800,
    );
    final firstTile = find.byKey(const Key('grid-photo-select-0-0'));
    final secondTile = find.byKey(const Key('grid-photo-select-0-1'));
    await tester.ensureVisible(firstTile);
    await tester.tap(firstTile);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.ensureVisible(secondTile);
    await tester.tap(secondTile);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('已选照片：2'), findsOneWidget);
    expect(find.textContaining('RMS 29.96 像素 / 上限 20.00 像素'), findsOneWidget);
    expect(
      find.byKey(
        Key('photo-grid-issue-${photos[0].storedPath}-${photos[1].storedPath}'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('grid-lock-selected-action')),
          )
          .onPressed,
      isNotNull,
    );

    // Preserve a screenshot fixture for review of both neighbor orientations.
    final issueHitTarget = find.byKey(
      Key('photo-grid-issue-${photos[0].storedPath}-${photos[1].storedPath}'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(10, 10));
    await mouse.moveTo(tester.getCenter(issueHitTarget));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 250));
    tester
        .state<TooltipState>(
          find.byKey(
            Key(
              'photo-grid-issue-tooltip-${photos[0].storedPath}-${photos[1].storedPath}',
            ),
          ),
        )
        .ensureTooltipVisible();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('08_20.jpg ↔ 08_21.jpg') &&
            widget.text.toPlainText().contains('不匹配'),
      ),
      findsOneWidget,
    );

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('photo-grid-visual-validation')),
    );
    final screenshotPath =
        '${Directory.current.path}/.local/photo-grid-issues.png';
    await tester.runAsync(() async {
      final screenshot = await boundary.toImage(pixelRatio: 1);
      final png = await screenshot.toByteData(format: ImageByteFormat.png);
      await Directory(
        '${Directory.current.path}/.local',
      ).create(recursive: true);
      await File(screenshotPath).writeAsBytes(png!.buffer.asUint8List());
      screenshot.dispose();
    });

    await tester.tap(find.byKey(const Key('grid-lock-selected-action')));
    await tester.pumpAndSettle();
    expect(repository.duplicate, isNotNull);
    expect(original.grid.forceGridCells, isEmpty);
    final initialCopy = repository.duplicate!;
    expect(find.text('上次配准的超标匹配关系'), findsOneWidget);
    final verticalPair = find.byKey(
      Key(
        'photo-grid-issue-list-${photos[0].storedPath}-${photos[3].storedPath}',
      ),
    );
    expect(verticalPair, findsOneWidget);
    await tester.ensureVisible(verticalPair);
    await tester.tap(verticalPair);
    await tester.pumpAndSettle();
    expect(find.text('已选照片：2'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('grid-lock-selected-action')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('grid-lock-selected-action')));
    await tester.pumpAndSettle();
    final copied = repository.saved!;
    expect(copied.id, initialCopy.id);
    expect(copied.phase, StitchPhase.imported);
    expect(copied.nativeJobId, isNull);
    expect(copied.grid.forceGridCells, {
      const GridCell(0, 0),
      const GridCell(0, 1),
      const GridCell(1, 0),
    });
    expect(
      copied.grid.lockedPhotoOrigins[photos[0].storedPath],
      GridConstraintOrigin.operatorAction,
    );
    expect(
      copied.grid.lockedPhotoOrigins[photos[1].storedPath],
      GridConstraintOrigin.operatorAction,
    );
    expect(
      copied.grid.lockedPhotoOrigins[photos[3].storedPath],
      GridConstraintOrigin.operatorAction,
    );
    expect(copied.forceGridFallback, isFalse);
    expect(copied.autoGridOverlap, isTrue);
    final request = buildSphericalRequest(copied);
    final tiles = request['tiles']! as List<Object?>;
    final placementKinds = tiles
        .map(
          (tile) =>
              ((tile! as Map<String, Object?>)['placementConstraint']!
                  as Map<String, Object?>)['kind'],
        )
        .toList();
    expect(placementKinds[0], 'hardGridLock');
    expect(placementKinds[1], 'hardGridLock');
    expect(placementKinds[2], 'gridPrior');
    expect(placementKinds[3], 'hardGridLock');
    expect(placementKinds.skip(4), everyElement('gridPrior'));
    final placements = tiles
        .map(
          (tile) =>
              (tile! as Map<String, Object?>)['placementConstraint']!
                  as Map<String, Object?>,
        )
        .toList();
    expect(placements[0]['origin'], 'operator');
    expect(placements[1]['origin'], 'operator');
    expect(placements[2]['origin'], 'systemFallback');
    expect(placements[3]['origin'], 'operator');
    expect(
      placements.skip(4).map((p) => p['origin']),
      everyElement('systemFallback'),
    );
  });

  testWidgets('running task shows issues but disables grid lock mutations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final photos = [
      const ImportedPhoto(
        originalName: '08_20.jpg',
        storedPath: '08_20.jpg',
        sha256: 'a',
        width: 3840,
        height: 2160,
        originalOrder: 0,
        exifMake: 'fixture',
      ),
      const ImportedPhoto(
        originalName: '08_21.jpg',
        storedPath: '08_21.jpg',
        sha256: 'b',
        width: 3840,
        height: 2160,
        originalOrder: 1,
        exifMake: 'fixture',
      ),
    ];
    final task = StitchTask(
      id: 'running-grid-task',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'input',
      outputDirectory: 'output',
      photos: photos,
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 2),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 512,
      workers: 2,
      phase: StitchPhase.running,
      nativeJobId: 'native-running-job',
    );
    final repository = _MemoryTaskRepository()..records[task.id] = task;
    final issue = RegistrationIssue(
      fromPhotoPath: photos[0].storedPath,
      toPhotoPath: photos[1].storedPath,
      fromName: photos[0].originalName,
      toName: photos[1].originalName,
      rmsPx: 29.96,
      limitPx: 20,
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          initialTask: task,
          jobApi: _RecoveringWidgetJobApi(),
          repository: repository,
          registrationIssueLoader: (_) async => [issue],
          batchQueueController: EmptyBatchQueueController(
            api: _WidgetJobApi(),
            taskRepository: repository,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final savesBeforeInteraction = repository.saveCount;
    final duplicatesBeforeInteraction = repository.duplicateCount;
    await _lazyChildVisibleAfterScroll(
      tester,
      find.textContaining('照片与网格映射'),
      delta: 800,
    );
    await tester.tap(find.byKey(const Key('grid-photo-select-0-0')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const Key('grid-photo-select-0-1')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    final lockButton = tester.widget<FilledButton>(
      find.byKey(const Key('grid-lock-selected-action')),
    );
    expect(lockButton.onPressed, isNull);
    expect(repository.duplicateCount, duplicatesBeforeInteraction);
    expect(repository.saveCount, savesBeforeInteraction);
  });

  testWidgets('registration repair prompt locks issue endpoints and starts copy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('registration-repair-accept-'),
    ))!;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final photos = [
      for (var i = 0; i < 4; i++)
        ImportedPhoto(
          originalName: 'photo-$i.jpg',
          storedPath: '${temp.path}/photo-$i.jpg',
          sha256: 'hash-$i',
          width: 3840,
          height: 2160,
          originalOrder: i,
          exifMake: 'fixture',
        ),
    ];
    final task = StitchTask(
      id: 'auto-repair-source',
      createdAt: DateTime.utc(2026),
      sourceDirectory: temp.path,
      outputDirectory: '${temp.path}/old-output',
      photos: photos,
      grid: const GridOptions(mode: GridMode.sequence, rows: 2, columns: 2),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.running,
      stage: 'register',
      nativeJobId: 'native-initial-registration',
    );
    final repo = _MemoryTaskRepository(
      duplicateOutput: '${temp.path}/fresh-output',
      skipOutputCreation: true,
    )..records[task.id] = task;
    final api = _StartingWidgetJobApi();
    final issues = [
      RegistrationIssue(
        fromPhotoPath: photos[0].storedPath,
        toPhotoPath: photos[1].storedPath,
        fromName: photos[0].originalName,
        toName: photos[1].originalName,
        rmsPx: 29.96,
        limitPx: 20,
      ),
      RegistrationIssue(
        fromPhotoPath: photos[1].storedPath,
        toPhotoPath: photos[2].storedPath,
        fromName: photos[1].originalName,
        toName: photos[2].originalName,
        rmsPx: 23.1,
        limitPx: 20,
      ),
    ];
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          initialTask: task,
          jobApi: api,
          repository: repo,
          registrationIssueLoader: (_) async => issues,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repo,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 20 &&
          find
              .byKey(const Key('registration-repair-confirmation'))
              .evaluate()
              .isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      find.byKey(const Key('registration-repair-confirmation')),
      findsOneWidget,
    );
    expect(find.textContaining('photo-0.jpg ↔ photo-1.jpg'), findsOneWidget);
    expect(find.textContaining('photo-1.jpg ↔ photo-2.jpg'), findsOneWidget);
    await tester.tap(find.byKey(const Key('registration-repair-accept')));
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 20 && api.startedRequests.isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    expect(repo.duplicateCount, 1);
    final startDetails =
        '${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().join(' | ')} | '
        'start-button-enabled=${tester.widgetList<FilledButton>(find.byType(FilledButton)).map((button) => button.onPressed != null).toList()} | '
        'saved=${repo.saved?.phase}/${repo.saved?.id}';
    expect(api.startedRequests, hasLength(1), reason: startDetails);
    expect(api.statusCalls, greaterThanOrEqualTo(1));
    expect(repo.duplicate, isNotNull);
    expect(repo.duplicate!.outputDirectory, '${temp.path}/fresh-output');
    expect(repo.duplicate!.nativeJobId, isNull);
    expect(repo.duplicate!.registrationRepairOffered, isTrue);
    expect(repo.duplicate!.grid.forceGridCells, {
      const GridCell(0, 0),
      const GridCell(0, 1),
      const GridCell(1, 0),
    });
    expect(repo.duplicate!.grid.lockedPhotoOrigins, {
      photos[0].storedPath: GridConstraintOrigin.operatorAction,
      photos[1].storedPath: GridConstraintOrigin.operatorAction,
      photos[2].storedPath: GridConstraintOrigin.operatorAction,
    });
    expect(repo.duplicate!.forceGridFallback, isFalse);
    expect(repo.duplicate!.autoGridOverlap, isTrue);
    final tiles = api.startedRequests.single['tiles']! as List<Object?>;
    final constraints = tiles
        .map(
          (tile) =>
              (tile! as Map<String, Object?>)['placementConstraint']!
                  as Map<String, Object?>,
        )
        .toList();
    expect(
      constraints.take(3).map((tile) => tile['kind']),
      everyElement('hardGridLock'),
    );
    expect(constraints.skip(3).single['kind'], 'gridPrior');
    expect(
      constraints.take(3).map((tile) => tile['origin']),
      everyElement('operator'),
    );
    expect(constraints.skip(3).single['origin'], 'systemFallback');
    expect(repo.records[task.id]!.grid.forceGridCells, isEmpty);
    expect(repo.records[task.id]!.phase, StitchPhase.failed);
  });

  testWidgets('declining registration repair does not copy or start', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = StitchTask(
      id: 'auto-repair-decline',
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
        ImportedPhoto(
          originalName: 'two.jpg',
          storedPath: 'two.jpg',
          sha256: 'b',
          width: 100,
          height: 80,
          originalOrder: 1,
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 2),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 256,
      workers: 1,
      phase: StitchPhase.failed,
      error: 'REGISTRATION_FAILED: no consistent alignment',
    );
    final repo = _MemoryTaskRepository()..records[task.id] = task;
    final api = _StartingWidgetJobApi();
    final issue = RegistrationIssue(
      fromPhotoPath: 'one.jpg',
      toPhotoPath: 'two.jpg',
      fromName: 'one.jpg',
      toName: 'two.jpg',
      rmsPx: 24,
      limitPx: 20,
    );
    await tester.pumpWidget(
      _EnglishTestApp(
        home: StitchHomePage(
          initialTask: task,
          jobApi: api,
          repository: repo,
          registrationIssueLoader: (_) async => [issue],
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repo,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('registration-repair-confirmation')),
      findsOneWidget,
    );
    expect(
      find.text('Adjacent photo registration errors are over the limit'),
      findsOneWidget,
    );
    expect(
      find.text('one.jpg ↔ two.jpg · RMS 24.00 px / limit 20.00 px'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Lock the following problem positions to the capture grid and restitch now? The original task and photos will be kept.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('registration-repair-decline')));
    await tester.pumpAndSettle();
    expect(repo.duplicateCount, 0);
    expect(api.startedRequests, isEmpty);
    expect(repo.records[task.id]!.registrationRepairOffered, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final reopened = repo.records[task.id]!;
    await tester.pumpWidget(
      _EnglishTestApp(
        home: StitchHomePage(
          initialTask: reopened,
          jobApi: api,
          repository: repo,
          registrationIssueLoader: (_) async => [issue],
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repo,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('registration-repair-confirmation')),
      findsNothing,
    );
    expect(repo.duplicateCount, 0);
    expect(api.startedRequests, isEmpty);
  });

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
