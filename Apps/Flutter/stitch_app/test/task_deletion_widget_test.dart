import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';

class _DeletionApi implements JobApi {
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

class _DeletionController extends BatchQueueController {
  _DeletionController(List<BatchQueue> queues)
    : _queues = List.of(queues),
      super(api: _DeletionApi());

  final List<BatchQueue> _queues;
  final List<({String itemId, bool deleteFiles})> removals = [];

  @override
  List<BatchQueue> get queues => List.unmodifiable(_queues);

  @override
  bool get loading => false;

  @override
  Future<TaskRemovalResult> removeQueueItem(
    String queueId,
    String itemId, {
    bool deleteOwnedFiles = false,
  }) async {
    removals.add((itemId: itemId, deleteFiles: deleteOwnedFiles));
    final index = _queues.indexWhere((queue) => queue.id == queueId);
    if (index >= 0) {
      final queue = _queues[index];
      _queues[index] = queue.copyWith(
        items: [
          for (final item in queue.items)
            if (item.id != itemId) item,
        ],
      );
      notifyListeners();
    }
    return const TaskRemovalResult();
  }
}

BatchQueue _queue({bool includeFailed = true}) => BatchQueue(
  id: 'queue-test',
  createdAt: DateTime.utc(2026),
  parentDirectory: '/scans',
  outputDirectory: '/stitched',
  items: [
    if (includeFailed)
      const BatchQueueItem(
        id: 'failed-item',
        name: 'Failed panorama',
        sourceDirectory: '/scans/failed',
        state: BatchItemState.failed,
        taskId: 'failed-task',
      ),
    const BatchQueueItem(
      id: 'completed-item',
      name: 'Completed panorama',
      sourceDirectory: '/scans/completed',
      state: BatchItemState.completed,
      taskId: 'completed-task',
    ),
  ],
);

Future<void> _pumpQueue(
  WidgetTester tester,
  _DeletionController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: StitchLocalizations.supportedLocales,
      localizationsDelegates: const [
        StitchLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: BatchQueuePage(
        api: _DeletionApi(),
        controller: controller,
        mobileOverride: false,
        autoUsbDiscoveryOverride: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('successful task checkbox starts off and can be checked', (
    tester,
  ) async {
    final controller = _DeletionController([_queue(includeFailed: false)]);
    addTearDown(controller.dispose);
    await _pumpQueue(tester, controller);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('batch-item-completed-item')),
        matching: find.byTooltip('删除本地任务记录'),
      ),
    );
    await tester.pumpAndSettle();
    final checkbox = find.byType(CheckboxListTile);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);

    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除任务'));
    await tester.pumpAndSettle();

    expect(controller.removals, [
      (itemId: 'completed-item', deleteFiles: true),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed task checkbox starts checked and can be unchecked', (
    tester,
  ) async {
    final controller = _DeletionController([_queue()]);
    addTearDown(controller.dispose);
    await _pumpQueue(tester, controller);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('batch-item-failed-item')),
        matching: find.byTooltip('删除本地任务记录'),
      ),
    );
    await tester.pumpAndSettle();
    final checkbox = find.byType(CheckboxListTile);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);

    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除任务'));
    await tester.pumpAndSettle();

    expect(controller.removals, [(itemId: 'failed-item', deleteFiles: false)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'clear failed queue removes only failed items and defaults to cleanup',
    (tester) async {
      final controller = _DeletionController([_queue()]);
      addTearDown(controller.dispose);
      await _pumpQueue(tester, controller);

      await tester.tap(find.byKey(const Key('clear-failed-queue-items')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('清空失败任务').last);
      await tester.pumpAndSettle();

      expect(controller.removals, [(itemId: 'failed-item', deleteFiles: true)]);
      expect(controller.queues.single.items.map((item) => item.id), [
        'completed-item',
      ]);
      expect(
        find.byKey(const Key('batch-item-completed-item')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('batch-item-failed-item')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
