import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_record_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/widgets/exported_image_viewer.dart';

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

class _GalleryController extends BatchQueueController {
  _GalleryController(BatchQueue initial, this.tasks)
    : _queues = [initial],
      super(api: _GalleryApi());

  final Map<String, StitchTask> tasks;
  List<BatchQueue> _queues;
  int taskLoads = 0;

  @override
  List<BatchQueue> get queues => _queues;
  @override
  bool get loading => false;
  @override
  String? get error => null;
  @override
  Future<StitchTask?> taskForItem(BatchQueueItem item) async {
    taskLoads++;
    return tasks[item.taskId];
  }

  @override
  Future<TaskRecordSnapshot?> taskRecordFor(String taskId) async => null;

  void replaceQueue(BatchQueue queue) {
    _queues = [queue];
    notifyListeners();
  }
}

class _MemoryTaskRepository extends TaskRepository {
  _MemoryTaskRepository([this.tasks = const []]);
  final List<StitchTask> tasks;
  int loadCalls = 0;

  @override
  Future<List<StitchTask>> loadAll() async {
    loadCalls++;
    return tasks;
  }
}

BatchQueue _queue(List<BatchQueueItem> items) => BatchQueue(
  id: 'queue',
  createdAt: DateTime.utc(2026),
  parentDirectory: '/scans',
  outputDirectory: '/results',
  items: items,
);

BatchQueueItem _item(String id, BatchItemState state) => BatchQueueItem(
  id: id,
  name: 'Panorama $id',
  sourceDirectory: '/scans/$id',
  state: state,
  taskId: 'task-$id',
);

StitchTask _task(String id) => StitchTask(
  id: 'task-$id',
  createdAt: DateTime.utc(2026),
  sourceDirectory: '/scans/$id',
  outputDirectory: '/missing/$id',
  photos: const [],
  grid: const GridOptions(),
  horizontalFovDegrees: 90,
  memoryBudgetMiB: 512,
  workers: 1,
  phase: StitchPhase.completed,
  exportPath: '/missing/$id.png',
  exportFormat: ExportFormat.png,
);

Widget _app(Widget child) => MaterialApp(
  supportedLocales: StitchLocalizations.supportedLocales,
  localizationsDelegates: const [
    StitchLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

void main() {
  testWidgets(
    'gallery shows only completed batch items with missing preview placeholder',
    (tester) async {
      final controller = _GalleryController(
        _queue([
          _item('done', BatchItemState.completed),
          _item('running', BatchItemState.running),
          _item('failed', BatchItemState.failed),
        ]),
        {'task-done': _task('done')},
      );
      addTearDown(controller.dispose);
      final repository = _MemoryTaskRepository();
      await tester.pumpWidget(
        _app(
          BatchQueuePage(
            api: _GalleryApi(),
            controller: controller,
            taskRepository: repository,
            mobileOverride: false,
            autoUsbDiscoveryOverride: false,
            showResultsInitially: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('batch-result-task-done')), findsOneWidget);
      expect(find.byKey(const Key('batch-result-running')), findsNothing);
      expect(find.byKey(const Key('batch-result-failed')), findsNothing);
      expect(
        find.text('Preview unavailable; click to view details'),
        findsOneWidget,
      );
      // One load per item, even when format-capability completion rebuilds the page.
      expect(controller.taskLoads, 1);
    },
  );

  testWidgets('empty gallery provides queue and add batch entry points', (
    tester,
  ) async {
    final controller = _GalleryController(_queue(const []), const {});
    addTearDown(controller.dispose);
    final repository = _MemoryTaskRepository();
    await tester.pumpWidget(
      _app(
        BatchQueuePage(
          api: _GalleryApi(),
          controller: controller,
          taskRepository: repository,
          mobileOverride: false,
          autoUsbDiscoveryOverride: false,
          showResultsInitially: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No completed stitch results yet'), findsOneWidget);
    expect(find.byKey(const Key('batch-empty-open-queue')), findsOneWidget);
    expect(find.text('Add batch'), findsOneWidget);
  });

  testWidgets('queue and result gallery can be switched in both directions', (
    tester,
  ) async {
    final controller = _GalleryController(_queue(const []), const {});
    addTearDown(controller.dispose);
    final repository = _MemoryTaskRepository();
    await tester.pumpWidget(
      _app(
        BatchQueuePage(
          api: _GalleryApi(),
          controller: controller,
          taskRepository: repository,
          mobileOverride: false,
          autoUsbDiscoveryOverride: false,
          showResultsInitially: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-open-queue')));
    await tester.pumpAndSettle();
    expect(find.text('Batch queue'), findsOneWidget);
    await tester.tap(find.byKey(const Key('batch-open-results')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('batch-result-gallery')), findsOneWidget);
    expect(repository.loadCalls, 2);
  });

  testWidgets(
    'pending and running queue changes do not reload history; completion does',
    (tester) async {
      final pending = _item('pending', BatchItemState.pending);
      final controller = _GalleryController(_queue([pending]), {
        'task-pending': _task('pending'),
      });
      addTearDown(controller.dispose);
      final repository = _MemoryTaskRepository();
      await tester.pumpWidget(
        _app(
          BatchQueuePage(
            api: _GalleryApi(),
            controller: controller,
            taskRepository: repository,
            mobileOverride: false,
            autoUsbDiscoveryOverride: false,
            showResultsInitially: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, 1);

      controller.replaceQueue(
        _queue([
          pending.copyWith(state: BatchItemState.running, progress: 0.25),
        ]),
      );
      await tester.pumpAndSettle();
      controller.replaceQueue(
        _queue([
          pending.copyWith(state: BatchItemState.pending),
          _item('pending-2', BatchItemState.pending),
        ]),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, 1);

      controller.replaceQueue(
        _queue([_item('pending', BatchItemState.completed)]),
      );
      await tester.pumpAndSettle();
      expect(repository.loadCalls, 2);
    },
  );

  testWidgets('new completed items appear after controller notification', (
    tester,
  ) async {
    final controller = _GalleryController(_queue(const []), {
      'task-new': _task('new'),
    });
    addTearDown(controller.dispose);
    final repository = _MemoryTaskRepository();
    await tester.pumpWidget(
      _app(
        BatchQueuePage(
          api: _GalleryApi(),
          controller: controller,
          taskRepository: repository,
          mobileOverride: false,
          autoUsbDiscoveryOverride: false,
          showResultsInitially: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('batch-result-task-new')), findsNothing);
    controller.replaceQueue(_queue([_item('new', BatchItemState.completed)]));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('batch-result-task-new')), findsOneWidget);
    controller.replaceQueue(_queue(const []));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('batch-result-task-new')), findsNothing);
  });

  testWidgets('saved completed tasks appear when the batch queue is empty', (
    tester,
  ) async {
    final repository = _MemoryTaskRepository([_task('stored')]);
    final controller = _GalleryController(_queue(const []), const {});
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        BatchQueuePage(
          api: _GalleryApi(),
          controller: controller,
          taskRepository: repository,
          mobileOverride: false,
          autoUsbDiscoveryOverride: false,
          showResultsInitially: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();

    expect(find.byKey(const Key('batch-result-task-stored')), findsOneWidget);
    expect(find.text('stored'), findsOneWidget);
  });

  testWidgets('tapping a result opens the exported image viewer', (
    tester,
  ) async {
    final controller = _GalleryController(
      _queue([_item('done', BatchItemState.completed)]),
      {'task-done': _task('done')},
    );
    addTearDown(controller.dispose);
    final emptyRepository = _MemoryTaskRepository();
    await tester.pumpWidget(
      _app(
        BatchQueuePage(
          api: _GalleryApi(),
          controller: controller,
          taskRepository: emptyRepository,
          mobileOverride: false,
          autoUsbDiscoveryOverride: false,
          showResultsInitially: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('batch-result-task-done')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ExportedImageViewer), findsOneWidget);
  });
}
