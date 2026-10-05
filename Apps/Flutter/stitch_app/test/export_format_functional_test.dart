import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/export_fingerprint.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/empty_batch_queue_controller.dart';
import 'support/chinese_test_app.dart';

class _RecordingRepository extends TaskRepository {
  _RecordingRepository(this.task, {List<StitchTask>? tasks})
    : tasks = tasks ?? [task];
  final StitchTask task;
  final List<StitchTask> tasks;
  final List<StitchTask> saved = [];

  @override
  Future<List<StitchTask>> loadAll() async => tasks;

  @override
  Future<void> save(StitchTask value) async => saved.add(value);
}

class _DelayedFingerprintRepository extends _RecordingRepository {
  _DelayedFingerprintRepository(super.task, {super.tasks});

  final fingerprintStarted = Completer<void>();
  final releaseFingerprint = Completer<void>();

  @override
  Future<ExportFileFingerprint?> fingerprintFile(String path) async {
    if (!fingerprintStarted.isCompleted) fingerprintStarted.complete();
    await releaseFingerprint.future;
    return const ExportFileFingerprint(sizeBytes: 12, modifiedAtMicros: 345);
  }
}

class _MemoryBatchQueueRepository extends BatchQueueRepository {
  _MemoryBatchQueueRepository(this.queues);
  final List<BatchQueue> queues;

  @override
  Future<List<BatchQueue>> loadAll() async => queues;

  @override
  Future<void> save(BatchQueue queue) async {
    final index = queues.indexWhere((item) => item.id == queue.id);
    if (index < 0) {
      queues.add(queue);
    } else {
      queues[index] = queue;
    }
  }
}

class _DelayedBatchQueueRepository extends BatchQueueRepository {
  final loaded = Completer<List<BatchQueue>>();

  @override
  Future<List<BatchQueue>> loadAll() => loaded.future;

  @override
  Future<void> save(BatchQueue queue) async {}
}

class _FormatApi implements JobApi {
  _FormatApi({required this.jpegXlAvailable});
  final bool jpegXlAvailable;

  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'jpegXlAvailable': jpegXlAvailable,
      'exportFormats': {'png': true, 'tiff': true, 'jxl': jpegXlAvailable},
    },
  };

  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => capabilities();

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

class _AutoExportApi extends _FormatApi {
  _AutoExportApi({
    required super.jpegXlAvailable,
    this.renderState = 'completed',
    this.writeExportFile = true,
    this.failExport = false,
  });

  String renderState;
  String operation = 'render';
  String? destination;
  int exports = 0;
  bool writeExportFile;
  bool failExport;
  int resumes = 0;
  int starts = 0;
  int pauses = 0;
  int cancels = 0;

  @override
  Future<Map<String, Object?>> status(String jobId) async => {
    'ok': true,
    'state': operation == 'export' ? 'completed' : renderState,
    'operation': operation,
    'stage': operation,
    'progress': 1.0,
    if (destination != null) 'exportDestination': destination,
  };

  @override
  Future<Map<String, Object?>> resume(String jobId) async {
    resumes++;
    return {'ok': true, 'state': 'running', 'operation': 'render'};
  }

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    starts++;
    return {'ok': true, 'jobId': 'unexpected-start', 'state': 'running'};
  }

  @override
  Future<Map<String, Object?>> pause(String jobId) async {
    pauses++;
    return {'ok': true, 'state': 'paused'};
  }

  @override
  Future<Map<String, Object?>> cancel(String jobId) async {
    cancels++;
    return {'ok': true, 'state': 'cancelled'};
  }

  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async {
    exports++;
    this.destination = destination;
    if (failExport) throw StateError('fixture export failure');
    operation = 'export';
    if (writeExportFile) await File(destination).writeAsBytes([1, 2, 3]);
    return {
      'ok': true,
      'state': 'completed',
      'operation': 'export',
      'exportDestination': destination,
    };
  }
}

class _BatchQueueSlotsOccupiedApi extends _AutoExportApi {
  _BatchQueueSlotsOccupiedApi() : super(jpegXlAvailable: true);

  @override
  Future<Map<String, Object?>> capabilities() async {
    final response = await super.capabilities();
    final capabilities = Map<String, Object?>.from(
      response['capabilities'] as Map,
    );
    return {
      ...response,
      'capabilities': {
        ...capabilities,
        'activeJobs': 1,
        'maxConcurrentJobs': 1,
      },
    };
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  final deadline = Stopwatch()..start();
  while (!condition() && deadline.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue, reason: '$reason (5 second deadline)');
}

Future<void> _pumpUntilExportPersisted(
  WidgetTester tester,
  _AutoExportApi api,
  _RecordingRepository repository,
) async {
  bool isPersisted() =>
      api.exports > 0 &&
      repository.saved.any(
        (task) =>
            task.stage == 'export-failed' ||
            (task.stage == 'done' && task.exportPath == api.destination),
      );

  await _pumpUntil(
    tester,
    isPersisted,
    'Automatic export did not persist a terminal result',
  );
}

Future<Directory> _createTempDirectory(
  WidgetTester tester,
  String prefix,
) async {
  final directory = await tester.runAsync(
    () => Directory.systemTemp.createTemp(prefix),
  );
  if (directory == null) {
    throw StateError('Could not create a temporary directory for $prefix');
  }
  return directory;
}

void _deleteTempDirectory(WidgetTester tester, Directory directory) {
  addTearDown(() async {
    await tester.runAsync(() => directory.delete(recursive: true));
  });
}

class _ExternalPower implements PowerGate {
  @override
  Future<PowerState> readState() async => PowerState.externalPower;
}

class _NoopForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

StitchTask _task({
  StitchPhase phase = StitchPhase.imported,
  String id = 'format-functional-task',
}) => StitchTask(
  id: id,
  createdAt: DateTime.utc(2026, 10, 4),
  sourceDirectory: 'source',
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
  phase: phase,
  nativeJobId: phase == StitchPhase.paused ? 'paused-job' : null,
  exportFormat: ExportFormat.tiff,
);

void main() {
  for (final format in ExportFormat.values) {
    testWidgets('single-task completion auto-exports ${format.shortLabel}', (
      tester,
    ) async {
      final documents = await _createTempDirectory(
        tester,
        'stitch-auto-export-',
      );
      _deleteTempDirectory(tester, documents);
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );

      final task = _task(phase: StitchPhase.running).copyWith(
        nativeJobId: 'auto-export-job',
        autoExportOnCompletion: true,
        exportFormat: format,
      );
      final api = _AutoExportApi(jpegXlAvailable: true);
      final repository = _RecordingRepository(task);
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            jobApi: api,
            repository: repository,
            batchQueueController: EmptyBatchQueueController(
              api: api,
              taskRepository: repository,
            ),
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopForegroundLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await _pumpUntilExportPersisted(tester, api, repository);
      await tester.pump();

      expect(api.exports, 1);
      expect(api.destination, endsWith('.${format.extension}'));
      expect(repository.saved.last.exportPath, api.destination);
      expect(repository.saved.last.phase, StitchPhase.completed);
      expect(repository.saved.last.autoExportOnCompletion, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(
        api.exports,
        1,
        reason: 'A repeated poll must not queue a second export.',
      );
    });
  }

  for (final terminal in ['failed', 'cancelled']) {
    testWidgets('single-task $terminal does not start an export', (
      tester,
    ) async {
      final task = _task(phase: StitchPhase.running).copyWith(
        nativeJobId: '$terminal-auto-export-job',
        autoExportOnCompletion: true,
      );
      final api = _AutoExportApi(jpegXlAvailable: true, renderState: terminal);
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            jobApi: api,
            repository: _RecordingRepository(task),
            batchQueueController: EmptyBatchQueueController(
              api: api,
              taskRepository: _RecordingRepository(task),
            ),
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopForegroundLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(api.exports, 0);
    });
  }

  for (final failure in ['throws', 'missing-output']) {
    testWidgets('automatic export $failure is saved as a task failure', (
      tester,
    ) async {
      final documents = await _createTempDirectory(
        tester,
        'stitch-auto-export-failure-',
      );
      _deleteTempDirectory(tester, documents);
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );

      final task = _task(phase: StitchPhase.running).copyWith(
        nativeJobId: '$failure-auto-export-job',
        autoExportOnCompletion: true,
      );
      final api = _AutoExportApi(
        jpegXlAvailable: true,
        failExport: failure == 'throws',
        writeExportFile: failure != 'missing-output',
      );
      final repository = _RecordingRepository(task);
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            jobApi: api,
            repository: repository,
            batchQueueController: EmptyBatchQueueController(
              api: api,
              taskRepository: repository,
            ),
            powerGate: _ExternalPower(),
            foregroundWorkLock: _NoopForegroundLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await _pumpUntilExportPersisted(tester, api, repository);
      await tester.pump();

      expect(api.exports, 1);
      expect(repository.saved.last.phase, StitchPhase.completed);
      expect(repository.saved.last.exportPath, isNull);
      expect(repository.saved.last.autoExportOnCompletion, isFalse);
      expect(repository.saved.last.stage, 'export-failed');
      expect(repository.saved.last.error, contains('整图导出失败'));
      expect(find.textContaining('整图导出失败'), findsWidgets);
    });
  }

  testWidgets('legacy active task defaults to no automatic export', (
    tester,
  ) async {
    final task = _task(
      phase: StitchPhase.running,
    ).copyWith(nativeJobId: 'legacy-active-job');
    final api = _AutoExportApi(jpegXlAvailable: true);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: _RecordingRepository(task),
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: _RecordingRepository(task),
          ),
          powerGate: _ExternalPower(),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(api.exports, 0);
  });

  testWidgets('persisted completed auto-export intent resumes on selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final documents = await _createTempDirectory(
      tester,
      'stitch-recovered-auto-export-',
    );
    _deleteTempDirectory(tester, documents);
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );

    final task = _task(phase: StitchPhase.completed).copyWith(
      nativeJobId: 'recovered-auto-export-job',
      autoExportOnCompletion: true,
    );
    final api = _AutoExportApi(jpegXlAvailable: true);
    final repository = _RecordingRepository(task);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          foregroundWorkLock: _NoopForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final taskRow = find
        .byKey(const Key('task-row-format-functional-task'))
        .hitTestable();
    expect(taskRow, findsOneWidget);
    await tester.ensureVisible(taskRow);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(taskRow, findsOneWidget);
    await tester.tap(taskRow);
    await tester.pump();
    await _pumpUntilExportPersisted(tester, api, repository);
    await tester.pump();

    expect(api.exports, 1);
    expect(api.destination, endsWith('.tif'));
    expect(repository.saved.last.exportPath, api.destination);
    expect(repository.saved.last.autoExportOnCompletion, isFalse);
  });

  testWidgets('pending auto-export recovery reuses its checkpoint path', (
    tester,
  ) async {
    final documents = await _createTempDirectory(
      tester,
      'stitch-auto-export-checkpoint-',
    );
    _deleteTempDirectory(tester, documents);
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final checkpoint =
        '${documents.path}${Platform.pathSeparator}LumiaStitch${Platform.pathSeparator}pending.tif';
    final task = _task(phase: StitchPhase.exporting).copyWith(
      nativeJobId: 'checkpoint-auto-export-job',
      stage: 'auto-export',
      autoExportOnCompletion: true,
      exportCheckpointPath: checkpoint,
    );
    final api = _AutoExportApi(jpegXlAvailable: true);
    final repository = _RecordingRepository(task);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          powerGate: _ExternalPower(),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await _pumpUntilExportPersisted(tester, api, repository);
    await tester.pump();

    expect(api.exports, 1);
    expect(api.destination, checkpoint);
    expect(repository.saved.last.exportPath, checkpoint);
    expect(repository.saved.last.autoExportOnCompletion, isFalse);
  });

  testWidgets('batch render completion with an export checkpoint stays owned', (
    tester,
  ) async {
    final task = _task(phase: StitchPhase.exporting).copyWith(
      nativeJobId: 'batch-render-complete-job',
      stage: 'export',
      autoExportOnCompletion: false,
      exportCheckpointPath: r'C:\batch-output\pending.tif',
    );
    final api = _AutoExportApi(jpegXlAvailable: true);
    final repository = _RecordingRepository(task);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await _pumpUntil(
      tester,
      () => repository.saved.any(
        (saved) => saved.id == task.id && saved.phase == StitchPhase.completed,
      ),
      'Batch render completion was not recorded',
    );

    expect(api.exports, 0);
    expect(repository.saved.last.autoExportOnCompletion, isFalse);
    expect(
      repository.saved.last.exportCheckpointPath,
      task.exportCheckpointPath,
    );
  });

  testWidgets('cold start blocks controls until paused batch ownership loads', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _task(phase: StitchPhase.paused);
    final api = _AutoExportApi(jpegXlAvailable: true);
    final repository = _RecordingRepository(task);
    final queueRepository = _DelayedBatchQueueRepository();
    final queueController = BatchQueueController(
      api: api,
      queueRepository: queueRepository,
      taskRepository: repository,
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: queueController,
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '恢复'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '暂停'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '取消'))
          .onPressed,
      isNull,
    );

    queueRepository.loaded.complete([
      BatchQueue(
        id: 'cold-start-batch',
        createdAt: DateTime.utc(2026, 10, 4),
        parentDirectory: r'C:\batch-input',
        outputDirectory: r'C:\batch-input_stitched',
        items: [
          BatchQueueItem(
            id: 'cold-start-item',
            name: 'paused task',
            sourceDirectory: r'C:\batch-input\task',
            state: BatchItemState.paused,
            taskId: task.id,
          ),
        ],
      ),
    ]);
    await _pumpUntil(
      tester,
      () =>
          !queueController.loading &&
          queueController.queues.any(
            (queue) => queue.items.any(
              (item) =>
                  item.taskId == task.id && item.state == BatchItemState.paused,
            ),
          ),
      'Paused batch ownership was not loaded',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '恢复'))
          .onPressed,
      isNull,
    );
    expect(api.resumes, 0);
    expect(api.pauses, 0);
    expect(api.cancels, 0);
  });

  testWidgets('cold start unlocks unowned controls after queue load', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _task();
    final api = _AutoExportApi(jpegXlAvailable: true);
    final repository = _RecordingRepository(task);
    final queueRepository = _DelayedBatchQueueRepository();
    final queueController = BatchQueueController(
      api: api,
      queueRepository: queueRepository,
      taskRepository: repository,
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: queueController,
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    final start = find.widgetWithText(FilledButton, '开始合成');
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(
      tester
          .widget<DropdownButtonFormField<ExportFormat>>(
            find.byKey(const Key('export-format-option')),
          )
          .onChanged,
      isNull,
    );

    queueRepository.loaded.complete(const []);
    await _pumpUntil(
      tester,
      () =>
          queueController.queues.isEmpty &&
          tester.widget<FilledButton>(start).onPressed != null &&
          tester
                  .widget<DropdownButtonFormField<ExportFormat>>(
                    find.byKey(const Key('export-format-option')),
                  )
                  .onChanged !=
              null,
      'Unowned controls did not unlock after queue initialization',
    );
    expect(api.starts, 0);
  });

  testWidgets('ready batch owned task locks format and quality settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _task();
    final api = _AutoExportApi(jpegXlAvailable: true);
    final repository = _RecordingRepository(task);
    final queueController = BatchQueueController(
      api: _BatchQueueSlotsOccupiedApi(),
      queueRepository: _MemoryBatchQueueRepository([
        BatchQueue(
          id: 'ready-batch',
          createdAt: DateTime.utc(2026, 10, 4),
          parentDirectory: r'C:\batch-input',
          outputDirectory: r'C:\batch-input_stitched',
          items: [
            BatchQueueItem(
              id: 'ready-item',
              name: 'imported task',
              sourceDirectory: r'C:\batch-input\task',
              state: BatchItemState.ready,
              taskId: task.id,
            ),
          ],
        ),
      ]),
      taskRepository: repository,
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: queueController,
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          !queueController.loading &&
          queueController.queues.any(
            (queue) => queue.items.any(
              (item) =>
                  item.taskId == task.id && item.state == BatchItemState.ready,
            ),
          ),
      'Ready batch task ownership was not loaded',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始合成'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<ExportFormat>>(
            find.byKey(const Key('export-format-option')),
          )
          .onChanged,
      isNull,
    );

    final qualityExpansion = find.byKey(const Key('stitch-quality-expansion'));
    await tester.ensureVisible(qualityExpansion);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.tap(qualityExpansion);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('refine-grid-neighbors-option')),
          )
          .onChanged,
      isNull,
    );
    expect(api.starts, 0);
    expect(api.exports, 0);
  });

  testWidgets(
    'active export locks task switching until fingerprint persistence',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const destination = r'C:\batch-output\completed.tif';
      final exporting = _task(phase: StitchPhase.exporting).copyWith(
        nativeJobId: 'late-fingerprint-job',
        stage: 'export',
        exportCheckpointPath: destination,
      );
      final otherTask = _task(phase: StitchPhase.failed, id: 'other-task');
      final api = _AutoExportApi(jpegXlAvailable: true);
      api.operation = 'export';
      api.destination = destination;
      final repository = _DelayedFingerprintRepository(
        exporting,
        tasks: [exporting, otherTask],
      );
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            jobApi: api,
            repository: repository,
            batchQueueController: EmptyBatchQueueController(
              api: api,
              taskRepository: repository,
            ),
            foregroundWorkLock: _NoopForegroundLock(),
            initialTask: exporting,
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await _pumpUntil(
        tester,
        () => repository.fingerprintStarted.isCompleted,
        'Poll did not reach the delayed export fingerprint',
      );

      final otherRow = find
          .byKey(const Key('task-row-other-task'))
          .hitTestable();
      expect(otherRow, findsOneWidget);
      expect(tester.widget<ListTile>(otherRow).onTap, isNull);
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const Key('task-row-format-functional-task')),
            )
            .selected,
        isTrue,
      );

      repository.releaseFingerprint.complete();
      await _pumpUntil(
        tester,
        () => repository.saved.any(
          (saved) =>
              saved.id == exporting.id && saved.phase == StitchPhase.completed,
        ),
        'Export fingerprint was not persisted',
      );
      await _pumpUntil(
        tester,
        () => tester.widget<ListTile>(otherRow).onTap != null,
        'Task history stayed locked after export completed',
      );
      await tester.tap(otherRow);
      await _pumpUntil(
        tester,
        () => tester.widget<ListTile>(otherRow).selected,
        'A task could not be selected after export completed',
      );
      expect(api.exports, 0);
      expect(tester.widget<ListTile>(otherRow).selected, isTrue);
    },
  );

  testWidgets(
    'active paused batch task cannot be controlled from single task',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final task = _task(phase: StitchPhase.paused).copyWith(
        autoExportOnCompletion: false,
        exportCheckpointPath: r'C:\batch-output\pending.tif',
      );
      final api = _AutoExportApi(jpegXlAvailable: true);
      final repository = _RecordingRepository(task);
      final queueController = BatchQueueController(
        api: api,
        queueRepository: _MemoryBatchQueueRepository([
          BatchQueue(
            id: 'active-batch',
            createdAt: DateTime.utc(2026, 10, 4),
            parentDirectory: r'C:\batch-input',
            outputDirectory: r'C:\batch-input_stitched',
            items: [
              BatchQueueItem(
                id: 'active-item',
                name: 'paused task',
                sourceDirectory: r'C:\batch-input\task',
                state: BatchItemState.paused,
                taskId: task.id,
              ),
            ],
          ),
        ]),
        taskRepository: repository,
      );
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            jobApi: api,
            repository: repository,
            batchQueueController: queueController,
            foregroundWorkLock: _NoopForegroundLock(),
            initialTask: task,
            mobileOverride: false,
          ),
        ),
      );
      bool controlsDisabled() {
        final resume = find.widgetWithText(FilledButton, '恢复');
        final pause = find.widgetWithText(OutlinedButton, '暂停');
        final cancel = find.widgetWithText(OutlinedButton, '取消');
        return !queueController.loading &&
            queueController.queues.any(
              (queue) => queue.items.any(
                (item) =>
                    item.taskId == task.id &&
                    item.state == BatchItemState.paused,
              ),
            ) &&
            resume.evaluate().isNotEmpty &&
            pause.evaluate().isNotEmpty &&
            cancel.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(resume).onPressed == null &&
            tester.widget<OutlinedButton>(pause).onPressed == null &&
            tester.widget<OutlinedButton>(cancel).onPressed == null;
      }

      await _pumpUntil(
        tester,
        controlsDisabled,
        'Batch ownership was not reflected in single-task controls',
      );
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '恢复'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '暂停'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '取消'))
            .onPressed,
        isNull,
      );
      expect(api.resumes, 0);
      expect(api.starts, 0);
      expect(api.pauses, 0);
      expect(api.cancels, 0);
      expect(api.exports, 0);
    },
  );

  testWidgets('completed task can change format and manually re-export', (
    tester,
  ) async {
    final documents = await _createTempDirectory(tester, 'stitch-re-export-');
    _deleteTempDirectory(tester, documents);
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );

    final task = _task(phase: StitchPhase.completed).copyWith(
      nativeJobId: 'legacy-completed-job',
      exportPath: r'C:\old-output\previous.tif',
      exportFormat: ExportFormat.tiff,
    );
    final api = _AutoExportApi(jpegXlAvailable: true);
    final repository = _RecordingRepository(task);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: api,
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final selector = tester.widget<DropdownButtonFormField<ExportFormat>>(
      find.byKey(const Key('export-format-option')),
    );
    expect(selector.onChanged, isNotNull);
    selector.onChanged!(ExportFormat.png);
    await tester.pump();
    expect(repository.saved.last.exportFormat, ExportFormat.png);
    expect(find.byKey(const Key('export-format-card')), findsOneWidget);
    expect(find.textContaining('上次成功整图 TIFF'), findsOneWidget);

    await tester.tap(find.text('导出完整 PNG'));
    await _pumpUntilExportPersisted(tester, api, repository);
    await tester.pump();

    expect(api.exports, 1);
    expect(api.destination, endsWith('.png'));
    expect(repository.saved.last.exportPath, api.destination);
    expect(
      repository.saved.any(
        (saved) =>
            saved.stage == 'export' &&
            saved.exportCheckpointPath == api.destination &&
            saved.autoExportOnCompletion,
      ),
      isTrue,
      reason:
          'Single-task export intent must be durable before native export starts.',
    );
  });

  testWidgets('desktop JXL is enabled only when the native core reports it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final task = _task();
    final repository = _RecordingRepository(task);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: _FormatApi(jpegXlAvailable: true),
          repository: repository,
          batchQueueController: EmptyBatchQueueController(
            api: _FormatApi(jpegXlAvailable: true),
            taskRepository: repository,
          ),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('export-format-card')), findsOneWidget);

    final selector = tester.widget<DropdownButtonFormField<ExportFormat>>(
      find.byKey(const Key('export-format-option')),
    );
    expect(selector.onChanged, isNotNull);

    selector.onChanged!(ExportFormat.jpegXl);
    await tester.pump();
    expect(repository.saved.last.exportFormat, ExportFormat.jpegXl);
  });

  testWidgets('unavailable JXL and mobile formats fail closed', (tester) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final task = _task();
    final unavailableRepository = _RecordingRepository(task);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: _FormatApi(jpegXlAvailable: false),
          repository: unavailableRepository,
          batchQueueController: EmptyBatchQueueController(
            api: _FormatApi(jpegXlAvailable: false),
            taskRepository: unavailableRepository,
          ),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('export-format-card')), findsOneWidget);
    // The UI callback must reject a format the native capability does not
    // report, even if a stale selection or accessibility action reaches it.
    final unavailableSelector = tester
        .widget<DropdownButtonFormField<ExportFormat>>(
          find.byKey(const Key('export-format-option')),
        );
    unavailableSelector.onChanged!(ExportFormat.jpegXl);
    await tester.pump();
    expect(unavailableRepository.saved, isEmpty);

    final mobileTask = _task().copyWith(exportFormat: ExportFormat.jpegXl);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: _FormatApi(jpegXlAvailable: true),
          repository: _RecordingRepository(mobileTask),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: mobileTask,
          mobileOverride: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('export-format-option')), findsNothing);
    expect(find.byKey(const Key('stitch-quality-expansion')), findsNothing);
  });

  testWidgets('paused desktop task locks output format changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _task(phase: StitchPhase.paused);
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          jobApi: _FormatApi(jpegXlAvailable: true),
          repository: _RecordingRepository(task),
          batchQueueController: EmptyBatchQueueController(
            api: _FormatApi(jpegXlAvailable: true),
            taskRepository: _RecordingRepository(task),
          ),
          foregroundWorkLock: _NoopForegroundLock(),
          initialTask: task,
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('export-format-card')), findsOneWidget);
    final selector = tester.widget<DropdownButtonFormField<ExportFormat>>(
      find.byKey(const Key('export-format-option')),
    );
    expect(selector.onChanged, isNull);
  });
}
