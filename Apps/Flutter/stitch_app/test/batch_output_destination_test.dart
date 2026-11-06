import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/batch_folder_importer.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';

class _MemoryQueueRepository extends BatchQueueRepository {
  _MemoryQueueRepository(Iterable<BatchQueue> initial)
    : values = {for (final queue in initial) queue.id: queue};

  final Map<String, BatchQueue> values;
  String? failQueueId;
  String? blockNextSaveQueueId;
  Completer<void>? blockedSaveStarted;
  Completer<void>? releaseBlockedSave;

  @override
  Future<List<BatchQueue>> loadAll() async => values.values.toList();

  @override
  Future<void> save(BatchQueue queue) async {
    if (queue.id == blockNextSaveQueueId) {
      blockNextSaveQueueId = null;
      blockedSaveStarted?.complete();
      await releaseBlockedSave!.future;
    }
    if (queue.id == failQueueId) {
      failQueueId = null;
      throw FileSystemException('simulated queue persistence failure');
    }
    values[queue.id] = queue;
  }
}

class _MemoryTaskRepository extends TaskRepository {
  _MemoryTaskRepository(Iterable<StitchTask> initial)
    : values = {for (final task in initial) task.id: task};

  final Map<String, StitchTask> values;
  String? failTaskId;

  @override
  Future<StitchTask?> loadById(String id) async => values[id];

  @override
  Future<List<StitchTask>> loadAll() async => values.values.toList();

  @override
  Future<void> save(StitchTask task) async {
    if (task.id == failTaskId) {
      failTaskId = null;
      throw FileSystemException('simulated task persistence failure');
    }
    values[task.id] = task;
  }

  @override
  Future<Directory> directoryFor(String id) async => Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}batch-destination-$id',
  );
}

class _DestinationApi implements JobApi {
  _DestinationApi({this.blockExport = false});

  final bool blockExport;
  final exportStarted = Completer<void>();
  final releaseExport = Completer<void>();
  String? selectedExportPath;
  int starts = 0;

  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'jpegXlAvailable': true,
      'logicalCpuCount': 4,
      'maxWorkersPerJob': 4,
      'maxConcurrentJobs': 2,
      'totalCpuWorkers': 4,
      'totalMemoryBudgetMiB': 4096,
      'activeJobs': 0,
      'reservedWorkers': 0,
      'reservedMemoryMiB': 0,
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
  }) async {
    starts++;
    return {'jobId': 'job-test', 'state': 'running', 'operation': 'render'};
  }

  @override
  Future<Map<String, Object?>> status(String jobId) async => {
    'jobId': jobId,
    'state': 'completed',
    'operation': 'render',
    'memoryBudgetMiB': 512,
  };

  @override
  Future<Map<String, Object?>> pause(String jobId) async => {'state': 'paused'};
  @override
  Future<Map<String, Object?>> resume(String jobId) async => {
    'state': 'running',
  };
  @override
  Future<Map<String, Object?>> cancel(String jobId) async => {
    'state': 'cancelled',
  };

  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async {
    selectedExportPath = destination;
    if (!exportStarted.isCompleted) exportStarted.complete();
    if (blockExport) await releaseExport.future;
    return {
      'jobId': jobId,
      'state': 'running',
      'operation': 'export',
      'exportDestination': destination,
    };
  }
}

class _StaticImporter extends BatchFolderImporter {
  _StaticImporter(this.directory);
  final String directory;

  @override
  Future<List<BatchFolderSnapshot>> snapshot(String parentPath) async => [
    BatchFolderSnapshot(directory: directory, files: const []),
  ];

  @override
  Future<BatchImportedFolder> importFolder(
    BatchFolderSnapshot snapshot,
    String taskDirectory,
  ) async => BatchImportedFolder(
    photos: const [],
    inputDirectory: snapshot.directory,
    grid: const GridOptions(),
    hasIndexedGrid: false,
    needsLayout: true,
    estimatedLayout: true,
    cameraVerified: false,
    fovDegrees: null,
    cameraProfileId: null,
  );
}

StitchTask _task(
  String id, {
  required String exportDirectory,
  StitchPhase phase = StitchPhase.imported,
  String stage = 'ready',
  String? exportPath,
  String? exportCheckpointPath,
}) => StitchTask(
  id: id,
  createdAt: DateTime.utc(2026),
  sourceDirectory: '/source/$id',
  outputDirectory: '/render/$id',
  photos: const [],
  grid: const GridOptions(),
  horizontalFovDegrees: 90,
  memoryBudgetMiB: 512,
  workers: 1,
  phase: phase,
  stage: stage,
  nativeJobId: phase == StitchPhase.imported ? null : 'job-$id',
  exportDirectory: exportDirectory,
  exportPath: exportPath,
  exportCheckpointPath: exportCheckpointPath,
  exportFormat: ExportFormat.png,
);

BatchQueue _queue({
  required String id,
  required String outputDirectory,
  required List<BatchQueueItem> items,
  String? exportDestination,
  bool started = false,
}) => BatchQueue(
  id: id,
  createdAt: DateTime.utc(2026),
  parentDirectory: '/source-parent',
  outputDirectory: outputDirectory,
  items: items,
  outputFormat: ExportFormat.png,
  exportDestination: exportDestination,
  started: started,
);

BatchQueueItem _item(String id, String taskId, BatchItemState state) =>
    BatchQueueItem(
      id: 'item-$id',
      name: id,
      sourceDirectory: '/source-parent/$id',
      taskId: taskId,
      state: state,
    );

Future<BatchQueueController> _controller({
  required Iterable<BatchQueue> queues,
  required Iterable<StitchTask> tasks,
  required _DestinationApi api,
  BatchFolderImporter? importer,
}) async {
  final controller = BatchQueueController(
    api: api,
    queueRepository: _MemoryQueueRepository(queues),
    taskRepository: _MemoryTaskRepository(tasks),
    importer: importer,
  );
  await controller.initialize();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  final controllers = <BatchQueueController>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('batch-output-dest-');
    controllers.clear();
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
      await controller.drain();
    }
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<BatchQueueController> makeController({
    required Iterable<BatchQueue> queues,
    required Iterable<StitchTask> tasks,
    required _DestinationApi api,
    BatchFolderImporter? importer,
  }) async {
    final value = await _controller(
      queues: queues,
      tasks: tasks,
      api: api,
      importer: importer,
    );
    controllers.add(value);
    return value;
  }

  test(
    'updates existing queue and unfinished task, and empty selection resets to queue output',
    () async {
      final task = _task('pending-task', exportDirectory: '/old');
      final queue = _queue(
        id: 'queue-pending',
        outputDirectory: '/default-output',
        exportDestination: '/old',
        items: [_item('pending', task.id, BatchItemState.ready)],
      );
      final controller = await makeController(
        queues: [queue],
        tasks: [task],
        api: _DestinationApi(),
      );

      await controller.setExportDestination('/new-output');
      expect(controller.queues.single.exportDestination, '/new-output');
      expect(
        (await controller.taskForItem(
          controller.queues.single.items.single,
        ))?.exportDirectory,
        '/new-output',
      );

      await controller.setExportDestination('');
      expect(controller.queues.single.exportDestination, isNull);
      expect(
        (await controller.taskForItem(
          controller.queues.single.items.single,
        ))?.exportDirectory,
        '/default-output',
      );
    },
  );

  test(
    'new queues prefer explicit batch destination then batch setting fallback',
    () async {
      final controller = await makeController(
        queues: const [],
        tasks: const [],
        api: _DestinationApi(),
        importer: _StaticImporter('/source-parent/panorama'),
      );
      final explicit = '/explicit-batch-output';
      await controller.setExportDestination(explicit);
      await controller.addParent(
        '/source-parent',
        settings: AppSettings.defaults(mobile: false).copyWith(
          batchOutputDirectory: '/batch-setting',
          outputDirectory: '/single-output',
        ),
      );
      expect(controller.queues.single.exportDestination, explicit);
      final imported = await controller.taskForItem(
        controller.queues.single.items.single,
      );
      expect(imported?.exportDirectory, explicit);
    },
  );

  test(
    'new queues fall back to the batch setting before single output',
    () async {
      final controller = await makeController(
        queues: const [],
        tasks: const [],
        api: _DestinationApi(),
        importer: _StaticImporter('/source-parent/panorama'),
      );
      await controller.addParent(
        '/source-parent',
        settings: AppSettings.defaults(mobile: false).copyWith(
          batchOutputDirectory: '/batch-setting',
          outputDirectory: '/single-output',
        ),
      );
      expect(controller.queues.single.exportDestination, '/batch-setting');
      final imported = await controller.taskForItem(
        controller.queues.single.items.single,
      );
      expect(imported?.exportDirectory, '/batch-setting');
    },
  );

  test(
    'completed exports keep their old path and files are never moved',
    () async {
      final folder = Directory('${temporary.path}/old-results')..createSync();
      final export = File('${folder.path}/completed.png')
        ..writeAsBytesSync([1, 2, 3]);
      final task = _task(
        'completed-task',
        exportDirectory: folder.path,
        phase: StitchPhase.completed,
        exportPath: export.path,
      );
      final queue = _queue(
        id: 'queue-completed',
        outputDirectory: '/default-output',
        exportDestination: folder.path,
        items: [_item('completed', task.id, BatchItemState.completed)],
      );
      final controller = await makeController(
        queues: [queue],
        tasks: [task],
        api: _DestinationApi(),
      );

      await controller.setExportDestination('/new-results');
      final updated = await controller.taskForItem(
        controller.queues.single.items.single,
      );
      expect(controller.queues.single.exportDestination, '/new-results');
      expect(updated?.exportDirectory, folder.path);
      expect(updated?.exportPath, export.path);
      expect(await export.exists(), isTrue);
      expect(
        await File('${temporary.path}/new-results/completed.png').exists(),
        isFalse,
      );
    },
  );

  test(
    'destination changes wait for in-flight export and preserve its path',
    () async {
      final oldOutput = Directory('${temporary.path}/old-output');
      final task = _task(
        'exporting-task',
        exportDirectory: oldOutput.path,
        phase: StitchPhase.completed,
        stage: 'export-pending',
      );
      final queue = _queue(
        id: 'queue-exporting',
        outputDirectory: oldOutput.path,
        exportDestination: oldOutput.path,
        items: [_item('exporting', task.id, BatchItemState.ready)],
        started: true,
      );
      final api = _DestinationApi(blockExport: true);
      final controller = await makeController(
        queues: [queue],
        tasks: [task],
        api: api,
      );
      await api.exportStarted.future.timeout(const Duration(seconds: 5));
      final destinationUpdate = controller.setExportDestination(
        '${temporary.path}/new-output',
      );
      api.releaseExport.complete();
      await destinationUpdate;

      expect(api.selectedExportPath, startsWith(oldOutput.path));
      expect(
        controller.queues.single.exportDestination,
        '${temporary.path}/new-output',
      );
      final updated = await controller.taskForItem(
        controller.queues.single.items.single,
      );
      expect(updated?.exportDirectory, oldOutput.path);
      expect(updated?.exportCheckpointPath, api.selectedExportPath);
    },
  );

  test(
    'pause waits for destination persistence and keeps the paused state',
    () async {
      final task = _task('pause-task', exportDirectory: '/old');
      final queue = _queue(
        id: 'queue-pause-race',
        outputDirectory: '/default-output',
        exportDestination: '/old',
        items: [_item('pause', task.id, BatchItemState.ready)],
      );
      final queueRepository = _MemoryQueueRepository([queue]);
      final controller = BatchQueueController(
        api: _DestinationApi(),
        queueRepository: queueRepository,
        taskRepository: _MemoryTaskRepository([task]),
      );
      controllers.add(controller);
      await controller.initialize();
      queueRepository
        ..blockNextSaveQueueId = queue.id
        ..blockedSaveStarted = Completer<void>()
        ..releaseBlockedSave = Completer<void>();

      final destinationChange = controller.setExportDestination('/new');
      await queueRepository.blockedSaveStarted!.future.timeout(
        const Duration(seconds: 5),
      );
      var pauseFinished = false;
      final pause = controller.pause(queue.id, queue.items.single.id).then((_) {
        pauseFinished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(pauseFinished, isFalse);

      queueRepository.releaseBlockedSave!.complete();
      await destinationChange;
      await pause;

      expect(controller.queues.single.exportDestination, '/new');
      expect(
        controller.queues.single.items.single.state,
        BatchItemState.paused,
      );
      expect(
        queueRepository.values[queue.id]?.items.single.state,
        BatchItemState.paused,
      );
      expect(
        (await controller.taskForItem(
          controller.queues.single.items.single,
        ))?.exportDirectory,
        '/new',
      );
    },
  );

  test(
    'queue persistence failure rolls back task metadata and memory state',
    () async {
      final task = _task('rollback-task', exportDirectory: '/old');
      final queue = _queue(
        id: 'queue-rollback',
        outputDirectory: '/default-output',
        exportDestination: '/old',
        items: [_item('rollback', task.id, BatchItemState.ready)],
      );
      final queueRepository = _MemoryQueueRepository([queue]);
      final taskRepository = _MemoryTaskRepository([task]);
      final controller = BatchQueueController(
        api: _DestinationApi(),
        queueRepository: queueRepository,
        taskRepository: taskRepository,
      );
      controllers.add(controller);
      await controller.initialize();
      queueRepository.failQueueId = queue.id;

      await expectLater(
        controller.setExportDestination('/new'),
        throwsA(isA<StateError>()),
      );
      expect(controller.queues.single.exportDestination, '/old');
      expect(queueRepository.values[queue.id]?.exportDestination, '/old');
      expect(taskRepository.values[task.id]?.exportDirectory, '/old');
      expect(
        (await controller.taskForItem(
          controller.queues.single.items.single,
        ))?.exportDirectory,
        '/old',
      );
    },
  );

  test(
    'task persistence failure does not update queue or later tasks',
    () async {
      final first = _task('first-task', exportDirectory: '/old');
      final second = _task('second-task', exportDirectory: '/old');
      final queue = _queue(
        id: 'queue-task-failure',
        outputDirectory: '/default-output',
        exportDestination: '/old',
        items: [
          _item('first', first.id, BatchItemState.ready),
          _item('second', second.id, BatchItemState.ready),
        ],
      );
      final repository = _MemoryTaskRepository([first, second])
        ..failTaskId = second.id;
      final queues = _MemoryQueueRepository([queue]);
      final controller = BatchQueueController(
        api: _DestinationApi(),
        queueRepository: queues,
        taskRepository: repository,
      );
      controllers.add(controller);
      await controller.initialize();

      await expectLater(
        controller.setExportDestination('/new'),
        throwsA(isA<StateError>()),
      );
      expect(controller.queues.single.exportDestination, '/old');
      expect(queues.values[queue.id]?.exportDestination, '/old');
      expect(repository.values[first.id]?.exportDirectory, '/old');
      expect(repository.values[second.id]?.exportDirectory, '/old');
    },
  );

  test('refresh updates result cache but leaves busy task protected', () async {
    final task = _task(
      'finished-task',
      exportDirectory: '/old',
      phase: StitchPhase.completed,
      exportPath: '/old/final.png',
    );
    final busyTask = _task(
      'busy-task',
      exportDirectory: '/busy-old',
      phase: StitchPhase.exporting,
      stage: 'export',
      exportPath: '/busy-old/final.png',
    );
    final queue = _queue(
      id: 'queue-finished',
      outputDirectory: '/default-output',
      items: [
        _item('finished', task.id, BatchItemState.completed),
        _item('busy', busyTask.id, BatchItemState.ready),
      ],
    );
    final repository = _MemoryTaskRepository([task, busyTask]);
    final controller = BatchQueueController(
      api: _DestinationApi(),
      queueRepository: _MemoryQueueRepository([queue]),
      taskRepository: repository,
    );
    controllers.add(controller);
    await controller.initialize();
    final item = controller.queues.single.items.first;
    final cached = await controller.taskForItem(item);
    expect(cached?.exportPath, '/old/final.png');
    expect(controller.isResultTaskBusy(task.id), isFalse);
    final busyCached = await controller.taskForItem(
      controller.queues.single.items[1],
    );
    expect(busyCached?.exportPath, '/busy-old/final.png');

    final renamed = task.copyWith(
      exportDirectory: '/new',
      exportPath: '/new/renamed.png',
    );
    await repository.save(renamed);
    await controller.refreshResultTask(renamed);
    expect(
      (await controller.taskForItem(item))?.exportPath,
      '/new/renamed.png',
    );

    expect(controller.isResultTaskBusy(busyTask.id), isTrue);
    final busyRename = busyTask.copyWith(
      exportDirectory: '/busy-new',
      exportPath: '/busy-new/renamed.png',
    );
    await repository.save(busyRename);
    await controller.refreshResultTask(busyRename);
    final stillCached = await controller.taskForItem(
      controller.queues.single.items[1],
    );
    expect(stillCached?.exportPath, '/busy-old/final.png');
  });
}
