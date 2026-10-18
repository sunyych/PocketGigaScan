import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/native_job_api.dart';

class _NavigationApi implements JobApi {
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
  }) async => throw StateError('Opening a task must not start a job');
  @override
  Future<Map<String, Object?>> status(String jobId) async =>
      throw StateError('Opening a task must not poll a job');
  @override
  Future<Map<String, Object?>> pause(String jobId) async =>
      throw StateError('Opening a task must not pause a job');
  @override
  Future<Map<String, Object?>> resume(String jobId) async =>
      throw StateError('Opening a task must not resume a job');
  @override
  Future<Map<String, Object?>> cancel(String jobId) async =>
      throw StateError('Opening a task must not cancel a job');
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      throw StateError('Opening a task must not export a job');
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => const {};
}

class _NavigationController extends BatchQueueController {
  _NavigationController(this.fixture) : super(api: _NavigationApi());

  final BatchQueue fixture;
  int retryCalls = 0;
  int pauseCalls = 0;
  int cancelCalls = 0;

  @override
  List<BatchQueue> get queues => [fixture];
  @override
  bool get loading => false;
  @override
  Future<void> retry(String queueId, String itemId) async => retryCalls++;
  @override
  Future<void> pause(String queueId, String itemId) async => pauseCalls++;
  @override
  Future<void> cancel(String queueId, String itemId) async => cancelCalls++;
}

BatchQueue _fixtureQueue(BatchItemState state) => BatchQueue(
  id: 'queue-1',
  createdAt: DateTime.utc(2026),
  parentDirectory: '/scans',
  outputDirectory: '/scans_stitched',
  items: [
    BatchQueueItem(
      id: 'item-failed',
      name: 'Saved panorama',
      sourceDirectory: '/scans/panorama',
      state: state,
      taskId: 'task-saved',
      message: 'Stitch failed',
    ),
  ],
);

void main() {
  for (final locale in const [Locale('en'), Locale('zh')]) {
    for (final state in const [BatchItemState.failed, BatchItemState.running]) {
      testWidgets('opens $state queue task and returns its ID ($locale)', (
        tester,
      ) async {
        final controller = _NavigationController(_fixtureQueue(state));
        addTearDown(controller.dispose);
        String? openedTaskId;
        final api = _NavigationApi();
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: StitchLocalizations.supportedLocales,
            localizationsDelegates: const [
              StitchLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () async {
                      openedTaskId = await Navigator.of(context).push<String>(
                        MaterialPageRoute<String>(
                          builder: (_) => BatchQueuePage(
                            api: api,
                            controller: controller,
                            mobileOverride: false,
                          ),
                        ),
                      );
                    },
                    child: const Text('Open queue'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open queue'));
        await tester.pumpAndSettle();

        final localizedOpen = locale.languageCode == 'zh'
            ? '打开合成任务'
            : 'Open stitch task';
        final isChinese = locale.languageCode == 'zh';
        final title = find.descendant(
          of: find.byKey(const Key('batch-item-item-failed')),
          matching: find.text('Saved panorama'),
        );
        expect(find.byTooltip(localizedOpen), findsOneWidget);

        if (state == BatchItemState.failed) {
          await tester.tap(
            find.byTooltip(isChinese ? '重试或继续' : 'Retry or resume'),
          );
          await tester.pumpAndSettle();
          expect(openedTaskId, isNull);
          expect(controller.retryCalls, 1);
        } else {
          await tester.tap(find.byTooltip(isChinese ? '暂停任务' : 'Pause task'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip(isChinese ? '取消任务' : 'Cancel task'));
          await tester.pumpAndSettle();
          expect(openedTaskId, isNull);
          expect(controller.pauseCalls, 1);
          expect(controller.cancelCalls, 1);
        }

        await tester.tap(title);
        await tester.pumpAndSettle();

        expect(openedTaskId, 'task-saved');
        expect(controller.retryCalls, state == BatchItemState.failed ? 1 : 0);
        expect(controller.pauseCalls, state == BatchItemState.running ? 1 : 0);
        expect(controller.cancelCalls, state == BatchItemState.running ? 1 : 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
