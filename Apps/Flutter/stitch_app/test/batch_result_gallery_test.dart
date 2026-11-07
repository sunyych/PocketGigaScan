import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/result_gallery_page.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/mobile_storage_service.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/result_library_service.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/widgets/result_deletion_dialog.dart';

class _GalleryApi implements JobApi {
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Map<String, Object?>> capabilities() async => const {};
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => const {};
  @override
  Future<Map<String, Object?>> status(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> pause(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> resume(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> cancel(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      const {};
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => const {};
}

class _MemoryTaskRepository extends TaskRepository {
  _MemoryTaskRepository([Iterable<StitchTask> tasks = const []]) {
    for (final task in tasks) {
      records[task.id] = task;
    }
  }

  final Map<String, StitchTask> records = {};
  int loadCalls = 0;

  @override
  Future<List<StitchTask>> loadAll() async {
    loadCalls++;
    return records.values.toList();
  }

  void saveTask(StitchTask task) => records[task.id] = task;
}

class _GalleryService extends ResultLibraryService {
  _GalleryService(_MemoryTaskRepository repository)
    : memoryRepository = repository,
      super(repository: repository);

  final _MemoryTaskRepository memoryRepository;
  String? renamedTo;
  String? exportedTo;
  int renameCalls = 0;
  int exportCalls = 0;

  @override
  Future<StitchTask> renameResult(StitchTask task, String newBaseName) async {
    renameCalls++;
    renamedTo = newBaseName;
    final updated = task.copyWith(displayName: newBaseName);
    memoryRepository.saveTask(updated);
    return updated;
  }

  @override
  Future<StitchTask> exportResultToDirectory(
    StitchTask task,
    String directory, {
    void Function(double progress)? onProgress,
  }) async {
    exportCalls++;
    exportedTo = directory;
    onProgress?.call(0.5);
    final updated = task.copyWith(
      exportPath: '$directory/${ResultLibraryService.resultName(task)}.png',
      exportDirectory: directory,
    );
    memoryRepository.saveTask(updated);
    onProgress?.call(1);
    return updated;
  }
}

class _MemorySettingsRepository extends SettingsRepository {
  _MemorySettingsRepository({this.failSave = false});

  final bool failSave;

  @override
  Future<AppSettings> load() async => const AppSettings();
  @override
  Future<void> save(AppSettings settings) async {
    if (failSave) throw StateError('settings save failed');
  }
}

class _OutputQueueController extends BatchQueueController {
  _OutputQueueController(JobApi api) : super(api: api);

  String? destination;
  Object? destinationError;
  int setDestinationCalls = 0;

  @override
  List<BatchQueue> get queues => const [];
  @override
  bool get loading => false;
  @override
  Future<void> setExportDestination(String directory) async {
    setDestinationCalls++;
    if (destinationError case final error?) throw error;
    destination = directory;
  }
}

StitchTask _task(
  String id,
  String name,
  DateTime createdAt, {
  StitchPhase phase = StitchPhase.completed,
  String stage = 'ready',
  String? exportCheckpointPath,
}) => StitchTask(
  id: id,
  createdAt: createdAt,
  sourceDirectory: '/source/$name',
  outputDirectory: '/tasks/$id/output',
  photos: const [],
  grid: const GridOptions(),
  horizontalFovDegrees: 90,
  memoryBudgetMiB: 512,
  workers: 1,
  phase: phase,
  stage: stage,
  exportCheckpointPath: exportCheckpointPath,
  exportPath: '/exports/$name.png',
  exportFormat: ExportFormat.png,
);

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  supportedLocales: StitchLocalizations.supportedLocales,
  localizationsDelegates: const [
    StitchLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

ResultGalleryPage _gallery({
  required _MemoryTaskRepository repository,
  required _GalleryService service,
  required ValueNotifier<int> revision,
  SettingsController? settings,
  Future<String?> Function()? pickDirectory,
  Future<void> Function(StitchTask task)? onTaskUpdated,
  bool Function(String taskId)? isTaskBusy,
  Future<TaskRemovalResult> Function(
    StitchTask task,
    ResultDeletionChoice choice,
  )?
  onDeleteResult,
}) => ResultGalleryPage(
  repository: repository,
  service: service,
  refreshListenable: revision,
  settingsController: settings,
  mobileStorageService: const MobileStorageService(),
  mobileOverride: false,
  androidOverride: false,
  directoryPickerOverride: pickDirectory,
  isTaskBusy: isTaskBusy ?? (_) => false,
  onTaskUpdated: onTaskUpdated ?? (_) async {},
  onOpenViewer: (_) async {},
  onDeleteResult: onDeleteResult,
);

void main() {
  testWidgets('gallery shows completed single and batch task records only', (
    tester,
  ) async {
    final repository = _MemoryTaskRepository([
      _task('single-done', 'Single result', DateTime.utc(2026, 3, 1)),
      _task('batch-done', 'Batch result', DateTime.utc(2026, 3, 2)),
      _task(
        'running',
        'Still processing',
        DateTime.utc(2026, 3, 3),
        phase: StitchPhase.running,
      ),
    ]);
    final service = _GalleryService(repository);
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      _app(
        _gallery(repository: repository, service: service, revision: revision),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('result-card-single-done')), findsOneWidget);
    expect(find.byKey(const Key('result-card-batch-done')), findsOneWidget);
    expect(find.byKey(const Key('result-card-running')), findsNothing);
  });

  testWidgets('empty gallery explains where single and batch results appear', (
    tester,
  ) async {
    final repository = _MemoryTaskRepository();
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      _app(
        _gallery(
          repository: repository,
          service: _GalleryService(repository),
          revision: revision,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No completed stitch results yet'), findsOneWidget);
    expect(
      find.text('Completed single and batch results appear here.'),
      findsOneWidget,
    );
  });

  testWidgets('gallery refreshes newly completed repository records', (
    tester,
  ) async {
    final repository = _MemoryTaskRepository();
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      _app(
        _gallery(
          repository: repository,
          service: _GalleryService(repository),
          revision: revision,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialReads = repository.loadCalls;
    repository.saveTask(_task('newly-done', 'New result', DateTime.utc(2026)));
    revision.value++;
    await tester.pumpAndSettle();
    expect(repository.loadCalls, greaterThan(initialReads));
    expect(find.byKey(const Key('result-card-newly-done')), findsOneWidget);
  });

  testWidgets('gallery keeps a recoverable interrupted result export visible', (
    tester,
  ) async {
    final task = _task(
      'handoff',
      'Recoverable export',
      DateTime.utc(2026),
      phase: StitchPhase.interrupted,
      stage: 'result-library-export',
      exportCheckpointPath: '/checkpoint/export.tmp',
    );
    final repository = _MemoryTaskRepository([task]);
    final service = _GalleryService(repository);
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      _app(
        _gallery(
          repository: repository,
          service: service,
          revision: revision,
          pickDirectory: () async => '/recovered/export',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('result-card-handoff')), findsOneWidget);
    expect(find.text('Export can be resumed'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('result-export-handoff')));
    await tester.tap(find.byKey(const Key('result-export-handoff')));
    await tester.pumpAndSettle();
    expect(service.exportCalls, 1);
  });

  testWidgets('missing result pyramid uses a safe placeholder', (tester) async {
    final repository = _MemoryTaskRepository([
      _task('no-preview', 'Missing preview', DateTime.utc(2026)),
    ]);
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      _app(
        _gallery(
          repository: repository,
          service: _GalleryService(repository),
          revision: revision,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Preview unavailable; click to view details'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final (sort, expectedOrder) in [
    (ResultGallerySort.nameAscending, ['a-first', 'b-middle', 'c-last']),
    (ResultGallerySort.nameDescending, ['c-last', 'b-middle', 'a-first']),
    (ResultGallerySort.newestFirst, ['c-last', 'b-middle', 'a-first']),
    (ResultGallerySort.oldestFirst, ['a-first', 'b-middle', 'c-last']),
  ]) {
    testWidgets('sort order is applied: $sort', (tester) async {
      tester.view.physicalSize = const Size(390, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _MemoryTaskRepository([
        _task('a-first', 'Alpha', DateTime.utc(2026, 1, 1)),
        _task('b-middle', 'Beta', DateTime.utc(2026, 1, 2)),
        _task('c-last', 'Gamma', DateTime.utc(2026, 1, 3)),
      ]);
      final revision = ValueNotifier<int>(0);
      addTearDown(revision.dispose);
      final settings = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: AppSettings(resultGallerySort: sort),
      );
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _app(
          _gallery(
            repository: repository,
            service: _GalleryService(repository),
            revision: revision,
            settings: settings,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final cards = tester.widgetList<Card>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Card &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'result-card-',
              ),
        ),
      );
      final order = cards
          .map((card) => (card.key! as ValueKey<String>).value.substring(12))
          .toList();
      expect(order, expectedOrder);
    });
  }

  testWidgets('rename and export dialogs call the result library service', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _task('editable', 'Editable', DateTime.utc(2026));
    final repository = _MemoryTaskRepository([task]);
    final service = _GalleryService(repository);
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    var updatedTasks = 0;
    await tester.pumpWidget(
      _app(
        _gallery(
          repository: repository,
          service: service,
          revision: revision,
          pickDirectory: () async => '/chosen/export',
          onTaskUpdated: (updated) async {
            updatedTasks++;
            repository.saveTask(updated);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('result-rename-editable')));
    await tester.tap(find.byKey(const Key('result-rename-editable')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('result-rename-field')),
      'Renamed',
    );
    await tester.tap(find.byKey(const Key('result-rename-save')));
    await tester.pumpAndSettle();
    expect(service.renameCalls, 1);
    expect(service.renamedTo, 'Renamed');
    expect(updatedTasks, 1);

    await tester.ensureVisible(find.byKey(const Key('result-export-editable')));
    await tester.tap(find.byKey(const Key('result-export-editable')));
    await tester.pumpAndSettle();
    expect(service.exportCalls, 1);
    expect(service.exportedTo, '/chosen/export');
    expect(updatedTasks, 2);
  });

  testWidgets(
    'batch output setting is distinct and does not alter single default',
    (tester) async {
      final api = _GalleryApi();
      final controller = _OutputQueueController(api);
      addTearDown(controller.dispose);
      final settings = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: const AppSettings(outputDirectory: '/single-output'),
      );
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _app(
          BatchQueuePage(
            api: api,
            controller: controller,
            settingsController: settings,
            mobileOverride: false,
            autoUsbDiscoveryOverride: false,
            outputDirectoryPickerOverride: () async => '/batch-output',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sourcePicker = tester.widget<IconButton>(
        find.byKey(const Key('batch-select-parent-folder')),
      );
      final outputPicker = tester.widget<IconButton>(
        find.byKey(const Key('batch-output-directory')),
      );
      expect(
        (sourcePicker.icon as Icon).icon,
        Icons.create_new_folder_outlined,
      );
      expect((outputPicker.icon as Icon).icon, Icons.drive_file_move_outlined);
      expect(find.byTooltip('Choose batch output folder'), findsOneWidget);
      await tester.tap(find.byKey(const Key('batch-output-directory')));
      await tester.pumpAndSettle();
      expect(controller.destination, '/batch-output');
      expect(settings.settings.batchOutputDirectory, '/batch-output');
      expect(settings.settings.outputDirectory, '/single-output');
      expect(find.text('/batch-output'), findsOneWidget);
    },
  );

  testWidgets('settings save failure does not update queue destination', (
    tester,
  ) async {
    final api = _GalleryApi();
    final controller = _OutputQueueController(api);
    addTearDown(controller.dispose);
    final settings = SettingsController(
      repository: _MemorySettingsRepository(failSave: true),
      initial: const AppSettings(batchOutputDirectory: '/previous'),
    );
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _app(
        BatchQueuePage(
          api: api,
          controller: controller,
          settingsController: settings,
          mobileOverride: false,
          autoUsbDiscoveryOverride: false,
          outputDirectoryPickerOverride: () async => '/new-folder',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-output-directory')));
    await tester.pumpAndSettle();
    expect(controller.setDestinationCalls, 0);
    expect(settings.settings.batchOutputDirectory, '/previous');
  });

  testWidgets('controller failure restores the previous batch preference', (
    tester,
  ) async {
    final api = _GalleryApi();
    final controller = _OutputQueueController(api)
      ..destinationError = StateError('controller failure');
    addTearDown(controller.dispose);
    final settings = SettingsController(
      repository: _MemorySettingsRepository(),
      initial: const AppSettings(batchOutputDirectory: '/previous'),
    );
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _app(
        BatchQueuePage(
          api: api,
          controller: controller,
          settingsController: settings,
          mobileOverride: false,
          autoUsbDiscoveryOverride: false,
          outputDirectoryPickerOverride: () async => '/new-folder',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-output-directory')));
    await tester.pumpAndSettle();
    expect(controller.setDestinationCalls, 1);
    expect(settings.settings.batchOutputDirectory, '/previous');
  });

  testWidgets('result card opens the existing viewer callback', (tester) async {
    final imageFile = await tester.runAsync(() async {
      final file = File('${Directory.systemTemp.path}/gallery-viewer.png');
      await file.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
      return file;
    });
    expect(imageFile, isNotNull);
    addTearDown(() async => imageFile!.delete());
    final repository = _MemoryTaskRepository([
      _task(
        'viewer',
        'Viewer result',
        DateTime.utc(2026),
      ).copyWith(exportPath: imageFile!.path),
    ]);
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    var opened = 0;
    await tester.pumpWidget(
      _app(
        ResultGalleryPage(
          repository: repository,
          service: _GalleryService(repository),
          refreshListenable: revision,
          mobileStorageService: const MobileStorageService(),
          mobileOverride: false,
          androidOverride: false,
          isTaskBusy: (_) => false,
          onTaskUpdated: (_) async {},
          onOpenViewer: (_) async => opened++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-thumbnail-viewer')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('gallery deletion respects keep choices and refreshes records', (
    tester,
  ) async {
    final first = _task('delete-a', 'Result A', DateTime.utc(2026, 1, 1));
    final second = _task('delete-b', 'Result B', DateTime.utc(2026, 1, 2));
    final third = _task('keep-c', 'Keep C', DateTime.utc(2026, 1, 3));
    final repository = _MemoryTaskRepository([first, second, third]);
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    final choices = <ResultDeletionChoice>[];
    await tester.pumpWidget(
      _app(
        _gallery(
          repository: repository,
          service: _GalleryService(repository),
          revision: revision,
          onDeleteResult: (task, choice) async {
            choices.add(choice);
            repository.records.remove(task.id);
            return TaskRemovalResult(
              failures: task.id == first.id
                  ? const ['orphan input retained']
                  : const [],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-selection-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-select-delete-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-select-delete-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-delete-selected')));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 2 items'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('result-delete-keep-inputs')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('result-delete-keep-outputs')),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('result-delete-keep-outputs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-delete-confirm')));
    await tester.pumpAndSettle();

    expect(choices, hasLength(2));
    expect(choices.every((choice) => choice.keepInputs == false), isTrue);
    expect(choices.every((choice) => choice.keepOutputs == true), isTrue);
    expect(find.byKey(const Key('result-card-delete-a')), findsNothing);
    expect(find.byKey(const Key('result-card-delete-b')), findsNothing);
    expect(find.byKey(const Key('result-card-keep-c')), findsOneWidget);
    expect(find.textContaining('File cleanup warnings'), findsOneWidget);
  });

  testWidgets('canceling selection or confirmation never deletes', (
    tester,
  ) async {
    final task = _task('keep-me', 'Keep me', DateTime.utc(2026));
    final repository = _MemoryTaskRepository([task]);
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    var deleteCalls = 0;
    await tester.pumpWidget(
      _app(
        _gallery(
          repository: repository,
          service: _GalleryService(repository),
          revision: revision,
          onDeleteResult: (_, _) async {
            deleteCalls++;
            return const TaskRemovalResult();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-selection-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-select-keep-me')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-delete-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-selection-cancel')));
    await tester.pumpAndSettle();

    expect(deleteCalls, 0);
    expect(find.byKey(const Key('result-card-keep-me')), findsOneWidget);
  });
}
