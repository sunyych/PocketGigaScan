import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';

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
}

class _FakeApi implements JobApi {
  _FakeApi({this.cpu = 18, this.memory = 1024, this.slots = 2});
  final int cpu;
  final int memory;
  final int slots;
  final Map<String, _Job> jobs = {};
  int maxActive = 0;
  int resumeCalls = 0;
  bool failCancel = false;
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
      if (job.error != null) 'error': job.error,
    };
  }

  @override
  Future<Map<String, Object?>> pause(String jobId) async {
    jobs[jobId]!.state = 'paused';
    return {'ok': true, 'jobId': jobId, 'state': 'paused'};
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
    final job = jobs[jobId]!;
    job.operation = 'export';
    job.destination = destination;
    if (completeExportWithoutOutput) {
      job.state = 'completed';
      job.progress = 1;
      return {
        'ok': true,
        'jobId': jobId,
        'state': 'completed',
        'operation': 'export',
        'exportDestination': destination,
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
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason ?? 'Timed out waiting for batch controller state');
}

void main() {
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
    await Future<void>.delayed(const Duration(milliseconds: 40));
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
      controller = BatchQueueController(
        api: gated,
        queueRepository: queues,
        taskRepository: tasks,
      );
      await controller.initialize();
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
      final pendingStart = controller.tick();
      await gated.entered.future;
      await controller.cancel(queue.id, item.id);
      gated.release.complete();
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
      controller = BatchQueueController(
        api: gated,
        queueRepository: queues,
        taskRepository: tasks,
      );
      await controller.initialize();
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
      final pendingStart = controller.tick();
      await gated.entered.future;
      await controller.cancel(queue.id, item.id);
      gated.release.complete();
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
