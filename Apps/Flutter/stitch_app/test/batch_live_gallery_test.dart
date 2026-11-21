import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';

class _LiveGalleryApi implements JobApi {
  bool completed = false;

  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Map<String, Object?>> capabilities() async => const {
    'ok': true,
    'capabilities': {
      'logicalCpuCount': 4,
      'maxWorkersPerJob': 4,
      'maxConcurrentJobs': 1,
      'totalCpuWorkers': 4,
      'totalMemoryBudgetMiB': 2048,
      'reservedMemoryMiB': 2048,
      'gpuAvailable': false,
    },
  };
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => throw StateError('This fixture starts with a persisted job');
  @override
  Future<Map<String, Object?>> status(String jobId) async => {
    'ok': true,
    'jobId': jobId,
    'state': completed ? 'completed' : 'running',
    'operation': 'render',
    'stage': completed ? 'render' : 'matching',
    'progress': completed ? 0.92 : 0.4,
  };
  @override
  Future<Map<String, Object?>> pause(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> resume(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> cancel(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      throw StateError('JPEG size approval should defer export');
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => const {};
}

class _MemoryTasks extends TaskRepository {
  _MemoryTasks(this.records);
  final Map<String, StitchTask> records;

  @override
  Future<List<StitchTask>> loadAll() async => records.values.toList();
  @override
  Future<StitchTask?> loadById(String id) async => records[id];
  @override
  Future<void> save(StitchTask task) async => records[task.id] = task;
}

class _MemoryQueues extends BatchQueueRepository {
  _MemoryQueues(this.queues);
  final Map<String, BatchQueue> queues;

  @override
  Future<List<BatchQueue>> loadAll() async => queues.values.toList();
  @override
  Future<void> save(BatchQueue queue) async => queues[queue.id] = queue;
}

class _NoopPowerGate implements PowerGate {
  @override
  Future<PowerState> readState() async => PowerState.notRequired;
}

class _NoopForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

void main() {
  testWidgets(
    'open gallery updates when a live batch render completes before export',
    (tester) async {
      Future<void> pumpUi() async {
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      const taskId = 'live-gallery-task';
      const queueId = 'live-gallery-queue';
      const itemId = 'live-gallery-item';
      final task = StitchTask(
        id: taskId,
        createdAt: DateTime.utc(2026, 11, 20),
        sourceDirectory: '/memory/source',
        outputDirectory: '/memory/output',
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 90,
        memoryBudgetMiB: 512,
        workers: 1,
        phase: StitchPhase.running,
        nativeJobId: 'live-gallery-native-job',
        exportFormat: ExportFormat.png,
      );
      final importedTask = StitchTask(
        id: 'unrelated-imported-task',
        createdAt: DateTime.utc(2026, 11, 19),
        sourceDirectory: '/memory/other',
        outputDirectory: '/memory/other-output',
        photos: const [],
        grid: const GridOptions(),
        horizontalFovDegrees: 90,
        memoryBudgetMiB: 512,
        workers: 1,
        phase: StitchPhase.imported,
      );
      final queue = BatchQueue(
        id: queueId,
        createdAt: DateTime.utc(2026, 11, 20),
        parentDirectory: '/memory',
        outputDirectory: '/memory/output',
        started: true,
        items: const [
          BatchQueueItem(
            id: itemId,
            name: 'Panorama',
            sourceDirectory: '/memory/source',
            taskId: taskId,
            state: BatchItemState.running,
          ),
        ],
      );
      final api = _LiveGalleryApi();
      final repository = _MemoryTasks({
        taskId: task,
        importedTask.id: importedTask,
      });
      final controller = BatchQueueController(
        api: api,
        queueRepository: _MemoryQueues({queueId: queue}),
        taskRepository: repository,
      );

      try {
        await tester.pumpWidget(
          MaterialApp(
            supportedLocales: StitchLocalizations.supportedLocales,
            localizationsDelegates: const [
              StitchLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: StitchHomePage(
              showModeSelection: true,
              jobApi: api,
              repository: repository,
              batchQueueController: controller,
              initialTask: importedTask,
              powerGate: _NoopPowerGate(),
              foregroundWorkLock: _NoopForegroundLock(),
              mobileOverride: false,
            ),
          ),
        );
        await pumpUi();

        await tester.tap(find.byKey(const Key('selection-results')));
        await pumpUi();
        expect(find.text('No completed stitch results yet'), findsOneWidget);

        // Initialization has adopted the persisted running job. Its subsequent
        // render completion is saved as a completed task while the shared
        // memory budget keeps its queue item from reaching terminal completion.
        api.completed = true;
        await controller.tick();
        await pumpUi();

        expect(
          controller.queues.single.items.single.state,
          BatchItemState.ready,
        );
        expect(
          (await repository.loadById(taskId))?.phase,
          StitchPhase.completed,
        );
        expect(
          find.byKey(const Key('result-card-live-gallery-task')),
          findsOneWidget,
          reason:
              'The open gallery should show the persisted render result without a manual refresh or route reopen.',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );
}
