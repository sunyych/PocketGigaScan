import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/mobile_runtime_service.dart';
import 'package:stitch_app/services/mobile_storage_service.dart';

const _jpeg = <int>[
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0x01,
  0x11,
  0x00,
];

class _MemoryTasks extends TaskRepository {
  _MemoryTasks(this.taskRoot);
  final Directory taskRoot;
  final Map<String, StitchTask> values = {};
  final Set<String> removed = {};
  int duplicateCount = 0;

  @override
  Future<Directory> directoryFor(String id) async =>
      Directory('${taskRoot.path}${Platform.pathSeparator}$id');

  @override
  Future<void> save(StitchTask task) async {
    if (!removed.contains(task.id)) values[task.id] = task;
  }

  @override
  Future<StitchTask?> loadById(String id) async => values[id];

  @override
  Future<List<StitchTask>> loadAll() async => values.values.toList();

  @override
  Future<void> removeTaskRecord(String id) async {
    removed.add(id);
    values.remove(id);
  }

  @override
  Future<StitchTask> duplicateForNewRun(
    StitchTask old, {
    bool autoExportOnCompletion = true,
  }) async {
    final id = '900-${(++duplicateCount).toRadixString(16)}';
    final task = StitchTask.fromJson({
      ...old.toJson(),
      'id': id,
      'outputDirectory':
          '${taskRoot.path}${Platform.pathSeparator}$id${Platform.pathSeparator}render',
      'phase': StitchPhase.imported.name,
      'nativeJobId': null,
      'exportPath': null,
      'progress': 0,
      'stage': 'ready',
      'autoExportOnCompletion': autoExportOnCompletion,
      'error': null,
      'pauseReason': null,
    });
    await save(task);
    return task;
  }
}

class _GatedTaskLoads extends _MemoryTasks {
  _GatedTaskLoads(super.taskRoot);

  final entered = Completer<void>();
  final release = Completer<void>();
  bool blockReads = false;

  @override
  Future<StitchTask?> loadById(String id) async {
    if (blockReads) {
      blockReads = false;
      entered.complete();
      await release.future;
    }
    return super.loadById(id);
  }
}

class _Job {
  _Job(this.id, this.workers, this.memory);
  final String id;
  final int workers;
  final int memory;
  String state = 'running';
  String operation = 'render';
  String? destination;
  Object? error;
  double progress = 0.1;
  final List<Map<String, Object?>> events = [];
}

class _FakeApi implements JobApi {
  _FakeApi({this.cpu = 18, this.memory = 1024, this.slots = 2});
  final int cpu;
  final int memory;
  final int slots;
  final Map<String, _Job> jobs = {};
  int starts = 0;
  int exports = 0;
  int maxActive = 0;
  int resumeCalls = 0;
  DateTime Function()? timelineClock;
  bool failCancel = false;
  bool failPause = false;
  bool completeExportWithoutOutput = false;
  int get active => jobs.values
      .where((job) => job.state == 'running' || job.state == 'queued')
      .length;

  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;

  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'backend': 'cpu-rust-tiled',
      'gpuAvailable': false,
      'logicalCpuCount': cpu,
      'maxWorkersPerJob': 32,
      'maxConcurrentJobs': slots,
      'totalCpuWorkers': cpu,
      'totalMemoryBudgetMiB': memory,
      'activeJobs': active,
      'reservedWorkers': jobs.values
          .where((job) => job.state == 'running' || job.state == 'queued')
          .fold<int>(
            0,
            (sum, job) => sum + (job.operation == 'export' ? 1 : job.workers),
          ),
      'reservedMemoryMiB': jobs.values
          .where((job) => job.state == 'running' || job.state == 'queued')
          .fold<int>(0, (sum, job) => sum + job.memory),
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
  }) async {
    starts++;
    final tiles = request['tiles']! as List<Object?>;
    if (workers > tiles.length) throw StateError('workers exceed tile count');
    if (active >= slots ||
        jobs.values
                    .where(
                      (job) => job.state == 'running' || job.state == 'queued',
                    )
                    .fold<int>(0, (sum, job) => sum + job.memory) +
                memoryBudgetMiB >
            memory) {
      throw const NativeJobException('pool full', code: 'RESOURCE_BUSY');
    }
    final job = _Job(outputDirectory, workers, memoryBudgetMiB);
    jobs[job.id] = job;
    if (active > maxActive) maxActive = active;
    return {
      'ok': true,
      'jobId': job.id,
      'state': 'running',
      'operation': 'render',
      'workersEffective': workers,
    };
  }

  @override
  Future<Map<String, Object?>> status(String jobId) async {
    final job = jobs[jobId]!;
    return {
      'ok': true,
      'jobId': jobId,
      'state': job.state,
      'operation': job.operation,
      'stage': job.operation == 'export' ? 'export' : 'register',
      'progress': job.progress,
      'workersEffective': job.workers,
      'operationWorkers': job.operation == 'export' ? 1 : job.workers,
      'memoryBudgetMiB': job.memory,
      'exportDestination': job.destination,
      'events': job.events,
      if (job.error != null) 'error': job.error,
    };
  }

  @override
  Future<Map<String, Object?>> pause(String jobId) async {
    if (failPause) throw const NativeJobException('pause failed');
    final job = jobs[jobId]!;
    if (job.state != 'completed') job.state = 'paused';
    return {'ok': true, 'jobId': jobId, 'state': job.state};
  }

  @override
  Future<Map<String, Object?>> resume(String jobId) async {
    resumeCalls++;
    if (active >= slots) {
      throw const NativeJobException('pool full', code: 'RESOURCE_BUSY');
    }
    jobs[jobId]!.state = 'running';
    return {'ok': true, 'jobId': jobId, 'state': 'running'};
  }

  @override
  Future<Map<String, Object?>> cancel(String jobId) async {
    if (failCancel) throw const NativeJobException('stop failed');
    jobs[jobId]!.state = 'cancelled';
    return {'ok': true, 'jobId': jobId, 'state': 'cancelled'};
  }

  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async {
    exports++;
    final job = jobs[jobId]!;
    job.operation = 'export';
    job.destination = destination;
    job.events.add({
      'id': job.events.length + 1,
      'timestampUtc': (timelineClock?.call() ?? DateTime.now())
          .toUtc()
          .millisecondsSinceEpoch,
      'kind': 'transition',
      'stage': 'export',
      'state': 'running',
      'operation': 'export',
    });
    if (completeExportWithoutOutput) {
      job.state = 'completed';
      job.progress = 1;
      return {
        'ok': true,
        'jobId': jobId,
        'state': 'completed',
        'operation': 'export',
        'exportDestination': destination,
        'events': job.events,
      };
    }
    job.state = 'running';
    job.progress = 0.92;
    return {
      'ok': true,
      'jobId': jobId,
      'state': 'running',
      'operation': 'export',
      'exportDestination': destination,
      'events': job.events,
    };
  }

  Future<void> finishRender(String jobId) async {
    jobs[jobId]!
      ..state = 'completed'
      ..progress = 0.92;
  }

  Future<void> finishExport(String jobId) async {
    final job = jobs[jobId]!;
    await File(job.destination!).writeAsBytes([137, 80, 78, 71]);
    job.events.add({
      'id': job.events.length + 1,
      'timestampUtc': (timelineClock?.call() ?? DateTime.now())
          .toUtc()
          .millisecondsSinceEpoch,
      'kind': 'transition',
      'stage': 'export',
      'state': 'completed',
      'operation': 'export',
    });
    job
      ..state = 'completed'
      ..progress = 1;
  }
}

class _GatedStartApi extends _FakeApi {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool resourceBusy = false;
  bool completed = false;

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    entered.complete();
    await release.future;
    if (resourceBusy) {
      completed = true;
      throw const NativeJobException('pool full', code: 'RESOURCE_BUSY');
    }
    final response = await super.start(
      request,
      outputDirectory,
      memoryBudgetMiB: memoryBudgetMiB,
      workers: workers,
    );
    completed = true;
    return response;
  }
}

class _GatedQueueRepository extends BatchQueueRepository {
  _GatedQueueRepository({required super.rootDirectory});

  final entered = Completer<void>();
  final release = Completer<void>();
  bool _firstSave = true;

  @override
  Future<void> save(BatchQueue queue) async {
    if (_firstSave) {
      _firstSave = false;
      entered.complete();
      await release.future;
    }
    await super.save(queue);
  }
}

Future<void> _makeFolder(Directory parent, String name, int count) async {
  final folder = Directory('${parent.path}${Platform.pathSeparator}$name')
    ..createSync();
  for (var index = 0; index < count; index++) {
    await File(
      '${folder.path}${Platform.pathSeparator}image${index + 1}.jpg',
    ).writeAsBytes(_jpeg);
  }
}

Future<void> _waitUntil(bool Function() condition, [String? reason]) async {
  final elapsed = Stopwatch()..start();
  const timeout = Duration(seconds: 20);
  while (elapsed.elapsed < timeout) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    '${reason ?? 'Timed out waiting for batch controller state'} '
    'after ${elapsed.elapsed}',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late Directory parent;
  late _MemoryTasks tasks;
  late BatchQueueRepository queues;
  late _FakeApi api;
  late BatchQueueController controller;
  late DateTime currentTime;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('batch-controller-test-');
    parent = Directory('${temporary.path}${Platform.pathSeparator}source')
      ..createSync();
    tasks = _MemoryTasks(
      Directory('${temporary.path}${Platform.pathSeparator}tasks'),
    );
    queues = BatchQueueRepository(
      rootDirectory: Directory(
        '${temporary.path}${Platform.pathSeparator}queues',
      ),
    );
    api = _FakeApi();
    currentTime = DateTime.utc(2026, 10, 3);
    controller = BatchQueueController(
      api: api,
      queueRepository: queues,
      taskRepository: tasks,
      clock: () => currentTime,
    );
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    await controller.drain();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'runs multiple folders within aggregate slots and memory reservations, then exports each PNG',
    () async {
      await _makeFolder(parent, 'panorama.2026-A', 4);
      await _makeFolder(parent, 'panorama.2026-B', 4);
      await _makeFolder(parent, 'C', 4);
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      for (final item in queue.items) {
        await controller.setSettings(
          queueId: queue.id,
          itemId: item.id,
          rows: 2,
          columns: 2,
          horizontalFovDegrees: 45,
        );
      }
      await _waitUntil(() => api.active == 2);
      expect(api.active, 2);
      expect(api.maxActive, 2);
      expect(api.jobs.values.map((job) => job.workers).toList(), [4, 4]);
      expect(
        api.jobs.values.fold<int>(0, (sum, job) => sum + job.memory),
        1024,
      );

      for (final job in api.jobs.values.toList()) {
        await api.finishRender(job.id);
      }
      await _waitUntil(
        () =>
            api.jobs.values.where((job) => job.operation == 'export').length ==
            2,
      );
      expect(
        api.jobs.values.where((job) => job.operation == 'export'),
        hasLength(2),
      );
      final exportPaths = api.jobs.values
          .where((job) => job.operation == 'export')
          .map((job) => job.destination!)
          .toList();
      expect(exportPaths.toSet(), hasLength(2));
      expect(
        exportPaths.any((path) => path.contains('panorama.2026-')),
        isTrue,
      );
      for (final job
          in api.jobs.values
              .where((job) => job.operation == 'export')
              .toList()) {
        await api.finishExport(job.id);
      }
      await _waitUntil(
        () =>
            controller.queues.single.items
                .where((item) => item.state == BatchItemState.completed)
                .length ==
            2,
      );
      expect(
        controller.queues.single.items.where(
          (item) => item.state == BatchItemState.completed,
        ),
        hasLength(2),
      );
      await _waitUntil(() => api.jobs.length == 3 && api.active == 1);
      final third = api.jobs.values.singleWhere(
        (job) => job.state == 'running',
      );
      await api.finishRender(third.id);
      await _waitUntil(() => third.operation == 'export');
      await api.finishExport(third.id);
      await _waitUntil(
        () => controller.queues.single.items.every(
          (item) => item.state == BatchItemState.completed,
        ),
      );
    },
  );

  test(
    'drain waits for an in-flight queue save before storage cleanup',
    () async {
      final isolated = await Directory.systemTemp.createTemp(
        'batch-controller-drain-test-',
      );
      final isolatedParent = Directory(
        '${isolated.path}${Platform.pathSeparator}source',
      )..createSync();
      await _makeFolder(isolatedParent, 'scene', 4);
      final gatedRepository = _GatedQueueRepository(
        rootDirectory: Directory(
          '${isolated.path}${Platform.pathSeparator}queues',
        ),
      );
      final isolatedApi = _FakeApi();
      final isolatedController = BatchQueueController(
        api: isolatedApi,
        queueRepository: gatedRepository,
        taskRepository: _MemoryTasks(
          Directory('${isolated.path}${Platform.pathSeparator}tasks'),
        ),
      );
      await isolatedController.initialize();
      var released = false;
      var disposed = false;
      try {
        final importing = isolatedController.addParent(isolatedParent.path);
        await gatedRepository.entered.future.timeout(
          const Duration(seconds: 10),
        );
        isolatedController.dispose();
        disposed = true;
        var drained = false;
        final drain = isolatedController.drain().then((_) => drained = true);
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(
          drained,
          isFalse,
          reason: 'The first queue save is still gated.',
        );

        gatedRepository.release.complete();
        released = true;
        await importing;
        await drain;

        expect(await gatedRepository.loadAll(), hasLength(1));
        expect(
          isolatedApi.active,
          0,
          reason: 'dispose prevents new job starts.',
        );
      } finally {
        if (!released) gatedRepository.release.complete();
        if (!disposed) isolatedController.dispose();
        await isolatedController.drain();
        if (await isolated.exists()) await isolated.delete(recursive: true);
      }
    },
  );

  test(
    'dispose during a gated task load prevents a new native start',
    () async {
      final isolated = await Directory.systemTemp.createTemp(
        'batch-controller-dispose-load-',
      );
      final queueRepository = BatchQueueRepository(
        rootDirectory: Directory(
          '${isolated.path}${Platform.pathSeparator}queues',
        ),
      );
      const taskId = '12345-abcd';
      const itemId = 'ready-item';
      final sourceParent = Directory(
        '${isolated.path}${Platform.pathSeparator}source',
      )..createSync();
      final sourceChild = Directory(
        '${sourceParent.path}${Platform.pathSeparator}scene',
      )..createSync();
      final queueOutputDirectory =
          '${isolated.path}${Platform.pathSeparator}source_stitched';
      final outputDirectory =
          '${isolated.path}${Platform.pathSeparator}tasks'
          '${Platform.pathSeparator}$taskId${Platform.pathSeparator}render';
      final tasks = _GatedTaskLoads(
        Directory('${isolated.path}${Platform.pathSeparator}tasks'),
      )..blockReads = true;
      tasks.values[taskId] = StitchTask(
        id: taskId,
        createdAt: DateTime.utc(2026, 10, 5),
        sourceDirectory: sourceChild.path,
        outputDirectory: outputDirectory,
        photos: const [
          ImportedPhoto(
            originalName: 'one.jpg',
            storedPath: 'one.jpg',
            sha256: 'synthetic',
            width: 64,
            height: 48,
            originalOrder: 0,
          ),
        ],
        grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.imported,
      );
      await queueRepository.save(
        BatchQueue(
          id: 'queue',
          createdAt: DateTime.utc(2026, 10, 5),
          parentDirectory: sourceParent.path,
          outputDirectory: queueOutputDirectory,
          items: [
            BatchQueueItem(
              id: itemId,
              name: 'scene',
              sourceDirectory: sourceChild.path,
              taskId: taskId,
              state: BatchItemState.ready,
            ),
          ],
        ),
      );
      expect(await queueRepository.loadAll(), hasLength(1));
      final api = _FakeApi(slots: 1);
      final gatedController = BatchQueueController(
        api: api,
        queueRepository: queueRepository,
        taskRepository: tasks,
      );
      var disposed = false;
      try {
        await gatedController.initialize();
        await tasks.entered.future.timeout(const Duration(seconds: 10));
        gatedController.dispose();
        disposed = true;
        final drain = gatedController.drain();
        tasks.release.complete();
        await drain;

        expect(api.jobs, isEmpty);
        expect(tasks.values[taskId]?.nativeJobId, isNull);
        expect(
          gatedController.queues.single.items.single.state,
          BatchItemState.ready,
        );
      } finally {
        if (!tasks.release.isCompleted) tasks.release.complete();
        if (!disposed) gatedController.dispose();
        await gatedController.drain();
        if (await isolated.exists()) await isolated.delete(recursive: true);
      }
    },
  );

  test(
    'deleting a running local task stops it and removes queue references only',
    () async {
      await _makeFolder(parent, 'delete-me', 4);
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      final item = queue.items.single;
      await controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(() => api.jobs.length == 1);
      final job = api.jobs.values.single;
      final taskId = controller.queues.single.items.single.taskId!;
      await controller.removeTask(taskId);
      await controller.tick();

      expect(job.state, 'cancelled');
      expect(controller.queues.single.items, isEmpty);
      expect(tasks.values.containsKey(taskId), isFalse);
      expect(tasks.removed, contains(taskId));
      expect(
        Directory(
          '${parent.path}${Platform.pathSeparator}delete-me',
        ).existsSync(),
        isTrue,
      );
      expect(api.jobs, hasLength(1));
    },
  );

  test('failed native stop leaves task and queue item intact', () async {
    await _makeFolder(parent, 'keep-me', 4);
    await controller.addParent(parent.path);
    final queue = controller.queues.single;
    final item = queue.items.single;
    await controller.setSettings(
      queueId: queue.id,
      itemId: item.id,
      rows: 2,
      columns: 2,
      horizontalFovDegrees: 45,
    );
    await _waitUntil(() => api.jobs.length == 1);
    final taskId = controller.queues.single.items.single.taskId!;
    api.failCancel = true;

    await expectLater(
      controller.removeTask(taskId),
      throwsA(isA<NativeJobException>()),
    );

    expect(tasks.values.containsKey(taskId), isTrue);
    expect(tasks.removed, isNot(contains(taskId)));
    expect(controller.queues.single.items, hasLength(1));
  });

  test(
    'TIFF batch queue persists format and assigns TIFF export paths',
    () async {
      await _makeFolder(parent, 'tiff-panorama', 4);
      await controller.addParent(parent.path, outputFormat: ExportFormat.tiff);
      final queue = controller.queues.single;
      expect(queue.outputFormat, ExportFormat.tiff);
      for (final item in queue.items) {
        await controller.setSettings(
          queueId: queue.id,
          itemId: item.id,
          rows: 2,
          columns: 2,
          horizontalFovDegrees: 45,
        );
      }
      await _waitUntil(() => api.active == 1);
      final job = api.jobs.values.single;
      await api.finishRender(job.id);
      await _waitUntil(() => job.operation == 'export');
      expect(job.destination, endsWith('.tif'));
      expect(job.destination, contains(queue.items.single.taskId!));
      final restored = await queues.loadAll();
      expect(restored.single.outputFormat, ExportFormat.tiff);
    },
  );

  test(
    'large batch item waits for scoped approval before any native start',
    () async {
      controller.requireLargeJobApproval = true;
      await _makeFolder(parent, 'large-1x7', 7);
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      final item = queue.items.single;
      await controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 7,
        columns: 1,
        horizontalFovDegrees: 45,
      );

      await _waitUntil(
        () =>
            controller.queues.single.items.single.state ==
            BatchItemState.needsApproval,
      );
      expect(
        api.jobs,
        isEmpty,
        reason: 'Approval must precede the FFI start call.',
      );
      final imported = (await tasks.loadById(item.id))!;
      expect(imported.hasCurrentLargeJobApproval, isFalse);
      expect(Directory(imported.outputDirectory).existsSync(), isFalse);

      await controller.approveLargeJob(queue.id, item.id);
      await _waitUntil(() => api.jobs.length == 1);
      final approved = (await tasks.loadById(item.id))!;
      expect(approved.hasCurrentLargeJobApproval, isTrue);
    },
  );

  test(
    'completed large render resumes pending export after approval only',
    () async {
      const channel = MethodChannel('test.batch-completed-approval-export');
      final runtimeEvents = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readResourceBudget') {
              return <String, Object?>{
                'totalMemoryMiB': 4096,
                'availableMemoryMiB': 2048,
                'cpuCount': 8,
                'availableStorageMiB': 4096,
                'thermalStatus': 'none',
              };
            }
            if (call.method == 'setProcessingActive') {
              final args = call.arguments as Map<Object?, Object?>;
              runtimeEvents.add(args['active'] == true ? 'start' : 'stop');
              return true;
            }
            return null;
          });
      final runtime = MobileRuntimeService(channel: channel);
      var guardedController = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        requireLargeJobApproval: true,
        runtimeService: runtime,
      );
      addTearDown(() async {
        guardedController.dispose();
        await guardedController.drain();
        await runtime.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await guardedController.initialize();
      await _makeFolder(parent, 'approval-export-pending', 7);
      await guardedController.addParent(parent.path);
      final queue = guardedController.queues.single;
      final item = queue.items.single;
      await guardedController.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 7,
        columns: 1,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(
        () =>
            guardedController.queues.single.items.single.state ==
            BatchItemState.needsApproval,
      );
      await guardedController.approveLargeJob(queue.id, item.id);
      await _waitUntil(() => api.starts == 1);
      final job = api.jobs.values.single;
      await api.finishRender(job.id);
      guardedController.dispose();
      await guardedController.drain();
      await tasks.save(
        (await tasks.loadById(
          item.id,
        ))!.copyWith(clearLargeJobApprovalScope: true),
      );
      guardedController = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        requireLargeJobApproval: true,
        runtimeService: runtime,
      );
      await guardedController.initialize();
      await _waitUntil(
        () =>
            guardedController.queues.single.items.single.state ==
            BatchItemState.needsApproval,
      );
      var pending = (await tasks.loadById(item.id))!;
      expect(pending.phase, StitchPhase.completed);
      expect(pending.stage, 'export-pending');
      expect(api.starts, 1);
      expect(api.exports, 0);
      expect(runtimeEvents.last, 'stop');

      await guardedController.approveLargeJob(queue.id, item.id);
      await _waitUntil(() => api.exports == 1);
      expect(api.starts, 1, reason: 'Approval must resume export, not render.');
      expect(job.operation, 'export');
      await api.finishExport(job.id);
      await guardedController.tick();
      await _waitUntil(
        () =>
            guardedController.queues.single.items.single.state ==
            BatchItemState.completed,
      );
      pending = (await tasks.loadById(item.id))!;
      expect(pending.phase, StitchPhase.completed);
      expect(api.exports, 1);
      expect(runtimeEvents.last, 'stop');
    },
  );

  test(
    'completed render resumes pending export after thermal deferral',
    () async {
      const channel = MethodChannel('test.batch-completed-thermal-export');
      var thermalStatus = 'none';
      final runtimeEvents = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readResourceBudget') {
              return <String, Object?>{
                'totalMemoryMiB': 4096,
                'availableMemoryMiB': 2048,
                'cpuCount': 8,
                'availableStorageMiB': 4096,
                'thermalStatus': thermalStatus,
              };
            }
            if (call.method == 'setProcessingActive') {
              final args = call.arguments as Map<Object?, Object?>;
              runtimeEvents.add(args['active'] == true ? 'start' : 'stop');
              return true;
            }
            return null;
          });
      final runtime = MobileRuntimeService(channel: channel);
      final guardedController = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        requireLargeJobApproval: true,
        runtimeService: runtime,
      );
      addTearDown(() async {
        guardedController.dispose();
        await guardedController.drain();
        await runtime.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await guardedController.initialize();
      await _makeFolder(parent, 'thermal-export-pending', 4);
      await guardedController.addParent(parent.path);
      final queue = guardedController.queues.single;
      final item = queue.items.single;
      await guardedController.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(() => api.starts == 1);
      final job = api.jobs.values.single;
      thermalStatus = 'moderate';
      await api.finishRender(job.id);
      await guardedController.tick();
      await _waitUntil(
        () =>
            guardedController.queues.single.items.single.state ==
            BatchItemState.ready,
      );
      var pending = (await tasks.loadById(item.id))!;
      expect(pending.phase, StitchPhase.completed);
      expect(pending.stage, 'export-pending');
      expect(api.starts, 1);
      expect(api.exports, 0);
      expect(runtimeEvents.last, 'stop');

      thermalStatus = 'none';
      await guardedController.tick();
      await _waitUntil(() => api.exports == 1);
      expect(api.starts, 1, reason: 'Cooling must resume export, not render.');
      expect(job.operation, 'export');
      await api.finishExport(job.id);
      await guardedController.tick();
      await _waitUntil(
        () =>
            guardedController.queues.single.items.single.state ==
            BatchItemState.completed,
      );
      pending = (await tasks.loadById(item.id))!;
      expect(pending.phase, StitchPhase.completed);
      expect(api.exports, 1);
      expect(runtimeEvents.last, 'stop');
    },
  );

  test(
    'Android runtime guard failure defers a batch start without creating output',
    () async {
      const channel = MethodChannel('test.batch-runtime-guard');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readResourceBudget') {
              return <String, Object?>{
                'totalMemoryMiB': 4096,
                'availableMemoryMiB': 2048,
                'cpuCount': 8,
                'availableStorageMiB': 4096,
                'thermalStatus': 'none',
              };
            }
            if (call.method == 'setProcessingActive') return false;
            return null;
          });
      final runtime = MobileRuntimeService(channel: channel);
      final guardedController = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        requireLargeJobApproval: true,
        runtimeService: runtime,
      );
      addTearDown(() async {
        guardedController.dispose();
        await guardedController.drain();
        await runtime.dispose();
      });
      await guardedController.initialize();
      await _makeFolder(parent, 'guarded-small', 4);
      await guardedController.addParent(parent.path);
      final queue = guardedController.queues.single;
      final item = queue.items.single;
      await guardedController.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(
        () =>
            guardedController.queues.single.items.single.message?.contains(
              '核心任务尚未启动',
            ) ??
            false,
      );
      expect(api.jobs, isEmpty);
      final imported = (await tasks.loadById(item.id))!;
      expect(Directory(imported.outputDirectory).existsSync(), isFalse);
      expect(
        guardedController.queues.single.items.single.state,
        BatchItemState.ready,
      );
    },
  );

  test(
    'Android guard failure does not persist paused while native job stays running',
    () async {
      const channel = MethodChannel('test.batch-runtime-pause-failure');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'setProcessingActive') return false;
            return null;
          });
      final runtime = MobileRuntimeService(channel: channel);
      api.failPause = true;
      final taskId = '202610050001-abcdef12';
      final jobId = 'native-running-guard-failure';
      final sourceDirectory = '${parent.path}${Platform.pathSeparator}running';
      final task = StitchTask(
        id: taskId,
        createdAt: DateTime.utc(2026, 10, 5),
        sourceDirectory: sourceDirectory,
        outputDirectory: '${parent.path}${Platform.pathSeparator}render',
        photos: [
          for (var index = 0; index < 4; index++)
            ImportedPhoto(
              originalName: 'photo$index.jpg',
              storedPath:
                  '${parent.path}${Platform.pathSeparator}photo$index.jpg',
              sha256: 'a' * 64,
              width: 1,
              height: 1,
              originalOrder: index,
            ),
        ],
        grid: const GridOptions(mode: GridMode.sequence, rows: 2, columns: 2),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.running,
        nativeJobId: jobId,
      );
      await tasks.save(task);
      final itemId = '202610050002-abcdef12';
      final queue = BatchQueue(
        id: '202610050003-abcdef12',
        createdAt: DateTime.utc(2026, 10, 5),
        parentDirectory: parent.path,
        outputDirectory:
            '${temporary.path}${Platform.pathSeparator}source_stitched',
        items: [
          BatchQueueItem(
            id: itemId,
            taskId: taskId,
            name: 'running',
            sourceDirectory: sourceDirectory,
            state: BatchItemState.running,
          ),
        ],
      );
      await queues.save(queue);
      api.jobs[jobId] = _Job(jobId, 1, 128);
      final guardedController = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        requireLargeJobApproval: true,
        runtimeService: runtime,
      );
      addTearDown(() async {
        guardedController.dispose();
        await guardedController.drain();
        await runtime.dispose();
      });

      await guardedController.initialize();

      final current = guardedController.queues.single.items.single;
      expect(current.state, BatchItemState.running);
      expect(current.pauseRequested, isTrue);
      expect((await tasks.loadById(taskId))!.phase, StitchPhase.running);
      expect((await api.status(jobId))['state'], 'running');
    },
  );

  test(
    'cold-start runtime timeout does not resume a job when pause is unconfirmed',
    () async {
      api.failPause = true;
      final taskId = '202610050101-abcdef12';
      final itemId = '202610050102-abcdef12';
      final jobId = 'native-timeout-running';
      final sourceDirectory =
          '${parent.path}${Platform.pathSeparator}timeout-child';
      final task = StitchTask(
        id: taskId,
        createdAt: DateTime.utc(2026, 10, 5),
        sourceDirectory: sourceDirectory,
        outputDirectory:
            '${temporary.path}${Platform.pathSeparator}timeout-child_stitched',
        photos: [
          for (var index = 0; index < 4; index++)
            ImportedPhoto(
              originalName: 'photo$index.jpg',
              storedPath:
                  '$sourceDirectory${Platform.pathSeparator}photo$index.jpg',
              sha256: 'a' * 64,
              width: 1,
              height: 1,
              originalOrder: index,
            ),
        ],
        grid: const GridOptions(mode: GridMode.sequence, rows: 2, columns: 2),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.running,
        nativeJobId: jobId,
      );
      await tasks.save(task);
      await queues.save(
        BatchQueue(
          id: '202610050103-abcdef12',
          createdAt: DateTime.utc(2026, 10, 5),
          parentDirectory: parent.path,
          outputDirectory:
              '${temporary.path}${Platform.pathSeparator}source_stitched',
          items: [
            BatchQueueItem(
              id: itemId,
              taskId: taskId,
              name: 'timeout-child',
              sourceDirectory: sourceDirectory,
              state: BatchItemState.running,
            ),
          ],
        ),
      );
      api.jobs[jobId] = _Job(jobId, 1, 128);
      final recovering = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
      );
      recovering.pendingRuntimePauseJobIds.add(jobId);
      addTearDown(() async {
        recovering.dispose();
        await recovering.drain();
      });

      await recovering.initialize();

      final item = recovering.queues.single.items.single;
      expect(item.state, BatchItemState.running);
      expect(item.pauseRequested, isTrue);
      expect(recovering.pendingRuntimePauseJobIds, contains(jobId));
      expect((await tasks.loadById(taskId))!.phase, StitchPhase.running);
      expect((await api.status(jobId))['state'], 'running');
      expect(api.resumeCalls, 0);
      expect(await recovering.pauseJobByNativeId(jobId), isFalse);
      expect((await tasks.loadById(taskId))!.phase, StitchPhase.running);
    },
  );

  test(
    'cold-start timeout holds completed render until explicit retry',
    () async {
      final taskId = '202610050201-abcdef12';
      final itemId = '202610050202-abcdef12';
      final jobId = 'native-timeout-completed-render';
      final sourceDirectory =
          '${parent.path}${Platform.pathSeparator}completed-child';
      final task = StitchTask(
        id: taskId,
        createdAt: DateTime.utc(2026, 10, 5),
        sourceDirectory: sourceDirectory,
        outputDirectory:
            '${temporary.path}${Platform.pathSeparator}completed-child_stitched',
        photos: [
          for (var index = 0; index < 4; index++)
            ImportedPhoto(
              originalName: 'photo$index.jpg',
              storedPath:
                  '$sourceDirectory${Platform.pathSeparator}photo$index.jpg',
              sha256: 'a' * 64,
              width: 1,
              height: 1,
              originalOrder: index,
            ),
        ],
        grid: const GridOptions(mode: GridMode.sequence, rows: 2, columns: 2),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.completed,
        nativeJobId: jobId,
        autoExportOnCompletion: true,
      );
      await tasks.save(task);
      await queues.save(
        BatchQueue(
          id: '202610050203-abcdef12',
          createdAt: DateTime.utc(2026, 10, 5),
          parentDirectory: parent.path,
          outputDirectory:
              '${temporary.path}${Platform.pathSeparator}source_stitched',
          items: [
            BatchQueueItem(
              id: itemId,
              taskId: taskId,
              name: 'completed-child',
              sourceDirectory: sourceDirectory,
              state: BatchItemState.running,
            ),
          ],
        ),
      );
      api.jobs[jobId] = _Job(jobId, 1, 128)..state = 'completed';
      final recovering = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
      );
      recovering.pendingRuntimePauseJobIds.add(jobId);
      addTearDown(() async {
        recovering.dispose();
        await recovering.drain();
      });

      await recovering.initialize();

      expect(
        recovering.queues.single.items.single.state,
        BatchItemState.paused,
      );
      expect(recovering.queues.single.items.single.pauseRequested, isTrue);
      expect(recovering.pendingRuntimePauseJobIds, isEmpty);
      expect((await tasks.loadById(taskId))!.phase, StitchPhase.completed);
      expect((await tasks.loadById(taskId))!.stage, 'export-pending');
      expect((await tasks.loadById(taskId))!.autoExportOnCompletion, isFalse);
      expect(api.exports, 0);
      expect(api.starts, 0);

      await recovering.retry(recovering.queues.single.id, itemId);
      await _waitUntil(() => api.exports == 1);
      expect(api.starts, 0);
      expect(
        recovering.queues.single.items.single.state,
        BatchItemState.exporting,
      );
    },
  );

  test(
    'Android SAF staging is released only after every child was imported',
    () async {
      const channel = MethodChannel('test.batch-staging-release');
      final releasedPaths = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'releaseBatchParent') {
              releasedPaths.add(
                (call.arguments as Map<Object?, Object?>)['path'] as String,
              );
              return true;
            }
            return null;
          });
      final storage = MobileStorageService(channel: channel);
      final storageController = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        storageService: storage,
      );
      var storageControllerDisposed = false;
      addTearDown(() async {
        if (!storageControllerDisposed) {
          storageController.dispose();
          await storageController.drain();
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await storageController.initialize();
      await _makeFolder(parent, 'copyable', 4);
      await storageController.addParent(parent.path);
      expect(releasedPaths, [parent.path]);
      expect(
        storageController.queues.single.items.every(
          (item) => item.taskId != null,
        ),
        isTrue,
      );
      final importedItem = storageController.queues.single.items.single;
      final importedTask = (await tasks.loadById(importedItem.taskId!))!;
      expect(
        importedItem.sourceDirectory,
        '${parent.path}${Platform.pathSeparator}copyable',
      );
      expect(importedItem.durableInputDirectory, importedTask.sourceDirectory);
      expect(await queues.loadAll(), hasLength(1));
      storageController.dispose();
      await storageController.drain();
      storageControllerDisposed = true;
      await parent.delete(recursive: true);

      final reopened = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
      );
      await reopened.initialize();
      final restoredItem = reopened.queues.single.items.single;
      expect(restoredItem.sourceDirectory, importedItem.sourceDirectory);
      expect(
        restoredItem.durableInputDirectory,
        importedItem.durableInputDirectory,
      );
      expect(
        (await reopened.taskForItem(restoredItem))?.sourceDirectory,
        importedTask.sourceDirectory,
      );
      reopened.dispose();
      await reopened.drain();
    },
  );

  test(
    'completed batch export is automatically published after private export finishes',
    () async {
      const channel = MethodChannel('test.batch-export-auto-publish');
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'publishExport');
            attempts++;
            return {
              'uri': 'content://provider/document/automatic',
              'displayName': 'automatic.png',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final publisher = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        storageService: MobileStorageService(channel: channel),
        clock: () => currentTime,
      );
      addTearDown(() async {
        publisher.dispose();
        await publisher.drain();
      });
      await publisher.initialize();
      api.timelineClock = () => currentTime;
      await _makeFolder(parent, 'auto-publish', 4);
      await publisher.addParent(
        parent.path,
        settings: const AppSettings(
          outputDirectory: 'content://provider/tree/output',
        ),
      );
      final importedQueue = publisher.queues.single;
      final importedItem = importedQueue.items.single;
      // Synthetic JPEGs have no camera EXIF, so explicitly confirm the grid
      // and view angle as an operator would before expecting a render to start.
      await publisher.setSettings(
        queueId: importedQueue.id,
        itemId: importedItem.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(() => api.starts == 1, 'batch render to start');
      final jobId = api.jobs.keys.single;
      await api.finishRender(jobId);
      await publisher.tick();
      await _waitUntil(() => api.exports == 1, 'private export to start');
      final exportTask = (await tasks.loadById(
        publisher.queues.single.items.single.taskId!,
      ))!;
      expect(exportTask.phase, StitchPhase.exporting);
      expect(
        exportTask.timeline.events.where(
          (event) => event.operation == 'export' && event.state == 'running',
        ),
        hasLength(1),
      );
      expect(
        exportTask.timeline.events.any(
          (event) =>
              event.id.startsWith('ui:') &&
              event.operation == 'export' &&
              event.state == 'exporting',
        ),
        isFalse,
      );
      await api.finishExport(jobId);
      await publisher.tick();
      await _waitUntil(() => attempts == 1, 'automatic publication to finish');

      final item = publisher.queues.single.items.single;
      final task = (await tasks.loadById(item.taskId!))!;
      expect(item.state, BatchItemState.completed);
      expect(task.exportPath, isNotNull);
      expect(await File(task.exportPath!).exists(), isTrue);
      expect(task.publishedExportPath, 'content://provider/document/automatic');
      expect(
        task.timeline.events.any((event) => event.stage == 'publishing'),
        isTrue,
      );
      expect(
        task.timeline.events.any((event) => event.stage == 'published'),
        isTrue,
      );
      final uiSequenceIds = task.timeline.events
          .where((event) => event.id.startsWith('ui:'))
          .map((event) => int.tryParse(event.id.split(':').last))
          .whereType<int>()
          .toList();
      expect(uiSequenceIds, orderedEquals([...uiSequenceIds]..sort()));
      expect(uiSequenceIds.toSet(), hasLength(uiSequenceIds.length));
      expect(api.exports, 1, reason: 'publishing follows one native export');
    },
  );

  test(
    'task removal during a copy blocks stale metadata writes and preserves both exports',
    () async {
      const channel = MethodChannel('test.batch-export-generation-guard');
      final entered = Completer<void>();
      final release = Completer<void>();
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            attempts++;
            entered.complete();
            await release.future;
            return {
              'uri': 'content://provider/document/completed-copy',
              'displayName': 'private.png',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const taskId = '704-cafe';
      const queueId = '705-cafe';
      final child = Directory('${parent.path}${Platform.pathSeparator}guard')
        ..createSync();
      final privateExport = File(
        '${temporary.path}${Platform.pathSeparator}guard.png',
      )..writeAsBytesSync([5, 6, 7]);
      tasks.values[taskId] = StitchTask(
        id: taskId,
        createdAt: currentTime,
        sourceDirectory: child.path,
        outputDirectory:
            '${temporary.path}${Platform.pathSeparator}guard-render',
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 512,
        workers: 1,
        phase: StitchPhase.completed,
        exportPath: privateExport.path,
        exportDirectory: 'content://provider/tree/output',
        publishError: 'publish failed',
      );
      await queues.save(
        BatchQueue(
          id: queueId,
          createdAt: currentTime,
          parentDirectory: parent.path,
          outputDirectory:
              '${temporary.path}${Platform.pathSeparator}source_stitched',
          exportDestination: 'content://provider/tree/output',
          items: [
            BatchQueueItem(
              id: '706-cafe',
              name: 'guard',
              sourceDirectory: child.path,
              state: BatchItemState.completed,
              taskId: taskId,
            ),
          ],
        ),
      );
      final publisher = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        storageService: MobileStorageService(channel: channel),
        clock: () => currentTime,
      );
      await publisher.initialize();
      final retry = publisher.retryPublish(queueId, '706-cafe');
      await entered.future;
      await publisher.removeTask(taskId);
      release.complete();
      await retry;
      expect(await tasks.loadById(taskId), isNull);
      expect(await privateExport.readAsBytes(), [5, 6, 7]);
      expect(attempts, 1);
      expect(api.exports, 0);
      publisher.dispose();
      await publisher.drain();
    },
  );

  test(
    'new batch tasks snapshot settings defaults and SAF destination',
    () async {
      final controller = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
      );
      addTearDown(() async {
        controller.dispose();
        await controller.drain();
      });
      await controller.initialize();
      await _makeFolder(parent, 'settings-snapshot', 4);
      const settings = AppSettings(
        exportFormat: ExportFormat.png,
        refineGridNeighbors: false,
        seamBlendMode: SeamBlendMode.feather,
        localTextureWarp: false,
        performance: PerformanceOptions(fastRegistration: true),
        outputDirectory: 'content://provider/tree/panoramas',
      );
      await controller.addParent(parent.path, settings: settings);
      final queue = controller.queues.single;
      final task = (await tasks.loadById(queue.items.single.taskId!))!;
      expect(queue.exportDestination, settings.outputDirectory);
      expect(queue.outputFormat, ExportFormat.png);
      expect(task.exportDirectory, settings.outputDirectory);
      expect(task.exportFormat, ExportFormat.png);
      expect(task.refineGridNeighbors, isFalse);
      expect(task.seamBlendMode, SeamBlendMode.feather);
      expect(task.localTextureWarp, isFalse);
      expect(task.performanceOptions.fastRegistration, isTrue);
    },
  );

  test(
    'failed Android publication preserves private export and retries copy only once',
    () async {
      const channel = MethodChannel('test.batch-export-publish');
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'publishExport');
            attempts++;
            if (attempts == 1) {
              throw PlatformException(
                code: 'PUBLISH_FAILED',
                message: 'storage full',
              );
            }
            return {
              'uri': 'content://provider/document/new-copy',
              'displayName': 'panorama.png',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      const taskId = '701-cafe';
      const queueId = '702-cafe';
      final child = Directory('${parent.path}${Platform.pathSeparator}publish')
        ..createSync();
      final privateExport = File(
        '${temporary.path}${Platform.pathSeparator}private.png',
      )..writeAsBytesSync([1, 2, 3, 4]);
      tasks.values[taskId] = StitchTask(
        id: taskId,
        createdAt: currentTime,
        sourceDirectory: child.path,
        outputDirectory: '${temporary.path}${Platform.pathSeparator}render',
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 512,
        workers: 1,
        phase: StitchPhase.completed,
        nativeJobId: 'native-job',
        exportPath: privateExport.path,
        exportDirectory: 'content://provider/tree/output',
        publishedExportPath: 'content://provider/document/previous',
        publishError: 'previous attempt failed',
      );
      await queues.save(
        BatchQueue(
          id: queueId,
          createdAt: currentTime,
          parentDirectory: parent.path,
          outputDirectory:
              '${temporary.path}${Platform.pathSeparator}source_stitched',
          exportDestination: 'content://provider/tree/output',
          items: [
            BatchQueueItem(
              id: '703-cafe',
              name: 'publish',
              sourceDirectory: child.path,
              state: BatchItemState.completed,
              taskId: taskId,
            ),
          ],
        ),
      );

      BatchQueueController makePublisher() => BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        storageService: MobileStorageService(channel: channel),
        clock: () => currentTime,
      );
      final publisher = makePublisher();
      await publisher.initialize();
      await publisher.retryPublish(queueId, '703-cafe');
      var persisted = (await tasks.loadById(taskId))!;
      expect(persisted.exportPath, privateExport.path);
      expect(await privateExport.readAsBytes(), [1, 2, 3, 4]);
      expect(
        persisted.publishedExportPath,
        'content://provider/document/previous',
      );
      expect(persisted.publishError, contains('PUBLISH_FAILED'));
      expect(
        persisted.timeline.events.any(
          (event) => event.kind == 'publish-failed' && event.state == 'failed',
        ),
        isTrue,
      );

      await publisher.retryPublish(queueId, '703-cafe');
      persisted = (await tasks.loadById(taskId))!;
      expect(
        persisted.publishedExportPath,
        'content://provider/document/new-copy',
      );
      expect(persisted.publishError, isNull);
      expect(
        persisted.timeline.events.any(
          (event) => event.kind == 'publish' && event.state == 'completed',
        ),
        isTrue,
      );
      expect(await privateExport.exists(), isTrue);
      expect(attempts, 2);
      expect(
        api.exports,
        0,
        reason: 'publishing retries copy the completed file',
      );
      publisher.dispose();
      await publisher.drain();

      final reopened = makePublisher();
      await reopened.initialize();
      await reopened.retryPublish(queueId, '703-cafe');
      expect(
        attempts,
        2,
        reason: 'a completed publish is not duplicated on reopen',
      );
      reopened.dispose();
      await reopened.drain();
    },
  );

  test(
    'Android SAF staging is retained when a child cannot be imported',
    () async {
      const channel = MethodChannel('test.batch-staging-retained');
      var releases = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'releaseBatchParent') {
              releases++;
              return true;
            }
            return null;
          });
      final storage = MobileStorageService(channel: channel);
      final storageController = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        storageService: storage,
      );
      addTearDown(() async {
        storageController.dispose();
        await storageController.drain();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await storageController.initialize();
      await _makeFolder(parent, 'copyable', 4);
      Directory('${parent.path}${Platform.pathSeparator}empty').createSync();
      await storageController.addParent(parent.path);
      expect(releases, 0);
      expect(
        storageController.queues.single.items.any(
          (item) => item.taskId == null,
        ),
        isTrue,
      );
      expect(
        Directory('${parent.path}${Platform.pathSeparator}empty').existsSync(),
        isTrue,
      );
      final recoveredSource = Directory(
        '${parent.path}${Platform.pathSeparator}empty',
      );
      for (var index = 0; index < 4; index++) {
        await File(
          '${recoveredSource.path}${Platform.pathSeparator}image${index + 1}.jpg',
        ).writeAsBytes(_jpeg);
      }
      final queue = storageController.queues.single;
      final failed = queue.items.singleWhere((item) => item.taskId == null);
      await storageController.retry(queue.id, failed.id);
      expect(releases, 1);
      final retried = storageController.queues.single.items.singleWhere(
        (item) => item.id == failed.id,
      );
      expect(retried.taskId, isNotNull);
      final task = (await tasks.loadById(retried.taskId!))!;
      expect(task.sourceDirectory, isNot(contains(parent.path)));
      expect(
        task.photos.every((photo) => !photo.storedPath.contains(parent.path)),
        isTrue,
      );
      expect(
        Directory('${parent.path}${Platform.pathSeparator}empty').existsSync(),
        isTrue,
      );
    },
  );

  test(
    'native completed export without a file is not recorded as success',
    () async {
      api.completeExportWithoutOutput = true;
      await _makeFolder(parent, 'missing-export', 4);
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      final item = queue.items.single;
      await controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(() => api.active == 1);
      final job = api.jobs.values.single;
      await api.finishRender(job.id);
      await _waitUntil(
        () =>
            controller.queues.single.items.single.state ==
            BatchItemState.failed,
      );
      final task = tasks.values[item.taskId]!;
      expect(task.exportPath, isNull);
      expect(task.exportFingerprint, isNull);
      expect(task.exportCheckpointPath, isNull);
      expect(controller.queues.single.items.single.message, contains('不存在或为空'));
    },
  );

  test(
    'nine-photo grid requests at most nine workers when the pool allows it',
    () async {
      api = _FakeApi(cpu: 9, memory: 512, slots: 1);
      controller.dispose();
      await controller.drain();
      controller = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
      );
      await controller.initialize();
      await _makeFolder(parent, 'nine', 9);
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      final item = queue.items.single;
      await controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 3,
        columns: 3,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(
        () => api.jobs.length == 1 && api.jobs.values.first.workers == 9,
      );
      expect(api.jobs.values.single.workers, 9);
    },
  );

  test(
    'extended UNC native job paths normalize to their network share paths',
    () {
      expect(
        nativeJobPathsMatch(
          r'\\?\UNC\server\share\scan\job-state.json',
          r'\\server\share\scan\job-state.json',
        ),
        isTrue,
      );
      expect(
        nativeJobPathsMatch(
          r'\\?\C:\scan\job-state.json',
          r'C:\scan\job-state.json',
        ),
        isTrue,
      );
    },
  );

  test(
    'pause survives repository reload and explicit intent does not auto-resume',
    () async {
      await _makeFolder(parent, 'pause', 4);
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      final item = queue.items.single;
      await controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      await _waitUntil(() => api.active == 1);
      currentTime = currentTime.add(const Duration(seconds: 15));
      await controller.tick();
      await _waitUntil(
        () => controller.queues.single.items.single.elapsedSeconds >= 15,
      );
      await controller.pause(queue.id, item.id);
      expect(
        controller.queues.single.items.single.state,
        BatchItemState.paused,
      );
      final pausedElapsed =
          controller.queues.single.items.single.elapsedSeconds;
      expect(controller.queues.single.items.single.lastTickAt, isNull);
      expect(controller.queues.single.items.single.etaSeconds, isNull);
      currentTime = currentTime.add(const Duration(hours: 1));
      final reopened = BatchQueueController(
        api: api,
        queueRepository: queues,
        taskRepository: tasks,
        clock: () => currentTime,
      );
      controller.dispose();
      await controller.drain();
      controller = reopened;
      await reopened.initialize();
      expect(reopened.queues.single.items.single.state, BatchItemState.paused);
      expect(reopened.queues.single.items.single.elapsedSeconds, pausedElapsed);
      expect(api.active, 0);
    },
  );

  test(
    'cancel during gated start acknowledgement cannot resurrect the item',
    () async {
      await _makeFolder(parent, 'gated-start', 4);
      final gated = _GatedStartApi();
      controller.dispose();
      await controller.drain();
      controller = BatchQueueController(
        api: gated,
        queueRepository: queues,
        taskRepository: tasks,
      );
      await controller.initialize();
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      final item = queue.items.single;
      final pendingStart = controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      try {
        await gated.entered.future.timeout(const Duration(seconds: 10));
        await controller.cancel(queue.id, item.id);
      } finally {
        if (!gated.release.isCompleted) gated.release.complete();
      }
      await pendingStart;
      await _waitUntil(() => gated.completed);
      await _waitUntil(
        () => gated.jobs.values.any((job) => job.state == 'cancelled'),
      );
      expect(
        controller.queues.single.items.single.state,
        BatchItemState.cancelled,
      );
      expect(gated.jobs.values.single.state, 'cancelled');
    },
  );

  test(
    'RESOURCE_BUSY arriving after cancel preserves cancelled state',
    () async {
      await _makeFolder(parent, 'gated-busy', 4);
      final gated = _GatedStartApi()..resourceBusy = true;
      controller.dispose();
      await controller.drain();
      controller = BatchQueueController(
        api: gated,
        queueRepository: queues,
        taskRepository: tasks,
      );
      await controller.initialize();
      await controller.addParent(parent.path);
      final queue = controller.queues.single;
      final item = queue.items.single;
      final pendingStart = controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: 2,
        columns: 2,
        horizontalFovDegrees: 45,
      );
      try {
        await gated.entered.future.timeout(const Duration(seconds: 10));
        await controller.cancel(queue.id, item.id);
      } finally {
        if (!gated.release.isCompleted) gated.release.complete();
      }
      await pendingStart;
      await _waitUntil(() => gated.completed);
      expect(
        controller.queues.single.items.single.state,
        BatchItemState.cancelled,
      );
      expect(gated.jobs, isEmpty);
    },
  );

  test('maps nested native errors and retries as a fresh job', () async {
    await _makeFolder(parent, 'failed-retry', 4);
    await controller.addParent(parent.path);
    final queue = controller.queues.single;
    final item = queue.items.single;
    await controller.setSettings(
      queueId: queue.id,
      itemId: item.id,
      rows: 2,
      columns: 2,
      horizontalFovDegrees: 45,
    );
    await _waitUntil(() => api.jobs.length == 1);
    final first = api.jobs.values.single;
    first
      ..state = 'failed'
      ..error = {'code': 'STITCH_FAILED', 'message': 'weak overlap'};
    await controller.tick();
    await _waitUntil(
      () =>
          controller.queues.single.items.single.state == BatchItemState.failed,
    );
    expect(
      controller.queues.single.items.single.message,
      contains('STITCH_FAILED: weak overlap'),
    );
    final oldResumeCalls = api.resumeCalls;
    await controller.retry(queue.id, item.id);
    await _waitUntil(() => api.jobs.length == 2);
    final retriedTask = await tasks.loadById(
      controller.queues.single.items.single.taskId!,
    );
    expect(retriedTask?.autoExportOnCompletion, isFalse);
    expect(api.jobs.keys, contains(first.id));
    expect(api.jobs.keys.where((id) => id != first.id), hasLength(1));
    expect(api.resumeCalls, oldResumeCalls);
  });

  test('reopening an exporting item resumes its saved destination', () async {
    await _makeFolder(parent, 'export-reopen', 4);
    await controller.addParent(parent.path);
    final queue = controller.queues.single;
    final item = queue.items.single;
    await controller.setSettings(
      queueId: queue.id,
      itemId: item.id,
      rows: 2,
      columns: 2,
      horizontalFovDegrees: 45,
    );
    await _waitUntil(() => api.jobs.length == 1);
    final job = api.jobs.values.single;
    await api.finishRender(job.id);
    await _waitUntil(() => job.operation == 'export');
    final destination = job.destination;
    job.state = 'paused';
    controller.dispose();
    await controller.drain();

    final reopened = BatchQueueController(
      api: api,
      queueRepository: queues,
      taskRepository: tasks,
      clock: () => currentTime,
    );
    controller = reopened;
    await reopened.initialize();
    await _waitUntil(() => job.state == 'running');
    expect(job.operation, 'export');
    expect(job.destination, destination);
    expect(reopened.queues.single.items.single.state, BatchItemState.exporting);
  });

  test('warms render and export ETA samples independently', () async {
    await _makeFolder(parent, 'eta', 4);
    await controller.addParent(parent.path);
    final queue = controller.queues.single;
    final item = queue.items.single;
    await controller.setSettings(
      queueId: queue.id,
      itemId: item.id,
      rows: 2,
      columns: 2,
      horizontalFovDegrees: 45,
    );
    await _waitUntil(() => api.jobs.length == 1);
    final job = api.jobs.values.single;
    await _waitUntil(
      () =>
          controller.queues.single.items.single.progressOperation == 'render' &&
          controller.queues.single.items.single.progressSamples.isNotEmpty,
      'first render sample: ${controller.queues.single.items.single.toJson()}',
    );
    job.progress = 0.2;
    currentTime = currentTime.add(const Duration(seconds: 3));
    await controller.tick();
    await _waitUntil(
      () => controller.queues.single.items.single.progressSamples.length >= 2,
      'render sample 2: ${controller.queues.single.items.single.toJson()}',
    );
    job.progress = 0.4;
    currentTime = currentTime.add(const Duration(seconds: 3));
    await controller.tick();
    await _waitUntil(
      () => controller.queues.single.items.single.etaSeconds != null,
      'render ETA: ${controller.queues.single.items.single.toJson()}',
    );
    expect(controller.queues.single.items.single.progressOperation, 'render');

    await api.finishRender(job.id);
    await _waitUntil(() => job.operation == 'export');
    await _waitUntil(
      () =>
          controller.queues.single.items.single.progressOperation == 'export' &&
          controller.queues.single.items.single.progressSamples.isNotEmpty,
      'first export sample: ${controller.queues.single.items.single.toJson()}',
    );
    expect(controller.queues.single.items.single.etaSeconds, isNull);
    job.progress = 0.96;
    currentTime = currentTime.add(const Duration(seconds: 3));
    await controller.tick();
    await _waitUntil(
      () => controller.queues.single.items.single.progressSamples.length >= 2,
      'export sample 2: ${controller.queues.single.items.single.toJson()}',
    );
    job.progress = 0.98;
    currentTime = currentTime.add(const Duration(seconds: 3));
    await controller.tick();
    await _waitUntil(
      () => controller.queues.single.items.single.etaSeconds != null,
      'export ETA: ${controller.queues.single.items.single.toJson()}',
    );
    expect(controller.queues.single.items.single.progressOperation, 'export');
    expect(controller.queues.single.items.single.progress, greaterThan(0.9));
  });
}
