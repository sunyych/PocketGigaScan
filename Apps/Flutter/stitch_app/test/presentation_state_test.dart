import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/mobile_runtime_service.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/empty_batch_queue_controller.dart';

class _Api implements JobApi {
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

class _Lock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

class _Repository extends TaskRepository {
  _Repository(this.task);
  final StitchTask task;
  StitchTask? duplicate;
  final saved = <StitchTask>[];
  @override
  Future<List<StitchTask>> loadAll() async => [task];
  @override
  Future<void> save(StitchTask value) async => saved.add(value);
  @override
  Future<StitchTask> duplicateForNewRun(
    StitchTask old, {
    bool autoExportOnCompletion = true,
  }) async {
    duplicate = StitchTask(
      id: 'copy-${old.id}',
      createdAt: DateTime.utc(2026, 10, 6),
      sourceDirectory: old.sourceDirectory,
      outputDirectory: 'copy-output',
      photos: old.photos,
      grid: old.grid,
      horizontalFovDegrees: old.horizontalFovDegrees,
      memoryBudgetMiB: old.memoryBudgetMiB,
      workers: old.workers,
      phase: StitchPhase.imported,
      exportFormat: old.exportFormat,
      autoExportOnCompletion: autoExportOnCompletion,
    );
    return duplicate!;
  }
}

class _TestApp extends StatelessWidget {
  const _TestApp({required this.locale, required this.home});
  final Locale locale;
  final Widget home;
  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: locale,
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

StitchTask _task(StitchPhase phase, {String? nativeJobId}) => StitchTask(
  id: 'presentation-${phase.name}',
  createdAt: DateTime.utc(2026, 10, 6),
  sourceDirectory: 'input',
  outputDirectory: 'output',
  photos: const [
    ImportedPhoto(
      originalName: 'one.jpg',
      storedPath: 'one.jpg',
      sha256: 'fixture',
      width: 100,
      height: 80,
      originalOrder: 0,
    ),
  ],
  grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 128,
  workers: 1,
  phase: phase,
  nativeJobId: nativeJobId,
  progress: 1,
  stage: 'done',
  resultStats: const {
    'phaseTimesMs': {'total': 1234},
  },
  exportPath: phase == StitchPhase.completed ? 'output/result.tif' : null,
  exportFormat: ExportFormat.tiff,
);

void main() {
  for (final locale in [const Locale('en'), const Locale('zh')]) {
    for (final platform in ['Windows', 'Android']) {
      testWidgets(
        '$platform ${locale.languageCode}: pre-render format is available',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = _Api();
          final task = _task(StitchPhase.imported);
          final repository = _Repository(task);
          final mobile = platform == 'Android';
          final runtimeChannel = const MethodChannel('presentation/runtime');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(runtimeChannel, (call) async {
                if (call.method == 'readResourceBudget') {
                  return {
                    'totalMemoryMiB': 4096,
                    'availableMemoryMiB': 2048,
                    'cpuCount': 8,
                    'availableStorageMiB': 2048,
                    'thermalStatus': 'normal',
                  };
                }
                if (call.method == 'readPendingTimeoutJobs') return <String>[];
                if (call.method == 'acknowledgeTimeoutJobs') return true;
                return null;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(runtimeChannel, null),
          );
          await tester.pumpWidget(
            _TestApp(
              locale: locale,
              home: StitchHomePage(
                initialTask: task,
                jobApi: api,
                repository: repository,
                batchQueueController: EmptyBatchQueueController(
                  api: api,
                  taskRepository: repository,
                ),
                foregroundWorkLock: _Lock(),
                mobileOverride: mobile,
                androidOverride: mobile,
                mobileRuntimeService: mobile
                    ? MobileRuntimeService(channel: runtimeChannel)
                    : null,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byKey(const Key('export-format-card')), findsOneWidget);
          expect(find.byKey(const Key('export-format-option')), findsOneWidget);
          expect(find.byKey(const Key('stitch-options-card')), findsOneWidget);
        },
      );

      testWidgets(
        '$platform ${locale.languageCode}: completed presentation and copy workflow',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = _Api();
          final repository = _Repository(_task(StitchPhase.completed));
          final mobile = platform == 'Android';
          final runtimeChannel = const MethodChannel('presentation/runtime');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(runtimeChannel, (call) async {
                if (call.method == 'readResourceBudget') {
                  return {
                    'totalMemoryMiB': 4096,
                    'availableMemoryMiB': 2048,
                    'cpuCount': 8,
                    'availableStorageMiB': 2048,
                    'thermalStatus': 'normal',
                  };
                }
                if (call.method == 'readPendingTimeoutJobs') return <String>[];
                if (call.method == 'acknowledgeTimeoutJobs') return true;
                return null;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(runtimeChannel, null),
          );
          await tester.pumpWidget(
            _TestApp(
              locale: locale,
              home: StitchHomePage(
                initialTask: _task(StitchPhase.completed),
                jobApi: api,
                repository: repository,
                batchQueueController: EmptyBatchQueueController(
                  api: api,
                  taskRepository: repository,
                ),
                foregroundWorkLock: _Lock(),
                mobileOverride: mobile,
                androidOverride: mobile,
                mobileRuntimeService: mobile
                    ? MobileRuntimeService(channel: runtimeChannel)
                    : null,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));

          expect(find.byKey(const Key('export-format-card')), findsNothing);
          expect(find.byKey(const Key('stitch-options-card')), findsNothing);
          expect(find.byKey(const Key('open-exported-image')), findsOneWidget);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          expect(find.byKey(const Key('pause-task-action')), findsNothing);
          expect(find.byKey(const Key('cancel-task-action')), findsNothing);
          expect(find.byKey(const Key('export-task-action')), findsNothing);
          expect(find.textContaining('Core timing'), findsNothing);
          expect(find.textContaining('核心计时'), findsNothing);
          expect(find.byKey(const Key('new-run-copy-action')), findsOneWidget);
          final rail = find.byKey(const Key('task-row-presentation-completed'));
          expect(rail, findsOneWidget);
          expect(
            find.textContaining(
              locale.languageCode == 'zh' ? '已完成' : 'Completed',
            ),
            findsOneWidget,
          );

          final localizations = StitchLocalizations(locale);
          final infoLabel = localizations.stitchDetails;
          await tester.tap(find.text(infoLabel));
          await tester.pumpAndSettle();
          expect(
            find.textContaining(
              locale.languageCode == 'zh' ? '核心计时' : 'Engine timing',
            ),
            findsOneWidget,
          );
          final diagnosticsFinder = find.ancestor(
            of: find.text(infoLabel),
            matching: find.byType(ExpansionTile),
          );
          final diagnostics = tester.widget<ExpansionTile>(diagnosticsFinder);
          expect(diagnostics.initiallyExpanded, isFalse);
          expect(diagnostics.expandedAlignment, Alignment.centerLeft);
          expect(
            diagnostics.expandedCrossAxisAlignment,
            CrossAxisAlignment.start,
          );
          final logTile = tester.widget<ExpansionTile>(
            find.ancestor(
              of: find.text(localizations.stitchingLog),
              matching: find.byType(ExpansionTile),
            ),
          );
          expect(logTile.initiallyExpanded, isFalse);
          final statusLine = find.text(localizations.text('原生合成核心已加载'));
          final timingLine = find.text(localizations.text('核心计时 · 总耗时：1.2 秒'));
          expect(statusLine, findsOneWidget);
          expect(timingLine, findsOneWidget);
          expect(
            tester.getTopLeft(statusLine).dx,
            closeTo(tester.getTopLeft(timingLine).dx, 0.01),
          );
          expect(
            tester
                .getTopLeft(find.text(localizations.text('水平参考：以网格中心照片为准')))
                .dx,
            closeTo(tester.getTopLeft(statusLine).dx, 0.01),
          );

          await tester.tap(find.byKey(const Key('new-run-copy-action')));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          expect(repository.duplicate?.phase, StitchPhase.imported);
          expect(repository.duplicate?.exportFormat, ExportFormat.tiff);
          expect(find.byKey(const Key('export-format-card')), findsOneWidget);
          expect(find.byKey(const Key('stitch-options-card')), findsOneWidget);
          final selector = tester.widget<DropdownButtonFormField<ExportFormat>>(
            find.byKey(const Key('export-format-option')),
          );
          expect(selector.initialValue, ExportFormat.tiff);
        },
      );
    }
  }
}
