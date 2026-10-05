import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'support/chinese_test_app.dart';

class _ScreenshotApi implements JobApi {
  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  Never _unexpected() => throw StateError('Screenshot must not invoke JobApi');

  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => _unexpected();

  @override
  Future<Map<String, Object?>> status(String jobId) async => _unexpected();

  @override
  Future<Map<String, Object?>> pause(String jobId) async => _unexpected();

  @override
  Future<Map<String, Object?>> resume(String jobId) async => _unexpected();

  @override
  Future<Map<String, Object?>> cancel(String jobId) async => _unexpected();

  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      _unexpected();

  @override
  Future<Map<String, Object?>> capabilities() async => _unexpected();

  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => _unexpected();
}

class _ScreenshotController extends BatchQueueController {
  _ScreenshotController({required this.fixtureQueues})
    : super(api: _ScreenshotApi());

  final List<BatchQueue> fixtureQueues;

  @override
  List<BatchQueue> get queues => fixtureQueues;

  @override
  bool get loading => false;
}

const _states = <BatchItemState>[
  BatchItemState.ready,
  BatchItemState.running,
  BatchItemState.exporting,
  BatchItemState.paused,
  BatchItemState.failed,
  BatchItemState.completed,
  BatchItemState.needsSettings,
  BatchItemState.skipped,
];

BatchQueue _fixtureQueue() => BatchQueue(
  id: 'queue-screenshot',
  createdAt: DateTime.utc(2026, 10, 3),
  parentDirectory: r'C:\Scans\AutumnTrip',
  outputDirectory: r'C:\Scans\AutumnTrip_stitched',
  items: [
    for (var index = 0; index < _states.length; index++)
      BatchQueueItem(
        id: 'item-$index',
        name: [
          '01_Lakeside',
          '02_ForestTrail',
          '03_CliffView',
          '04_Campground',
          '05_Waterfall',
          '06_Sunset',
          '07_InteriorRoom',
          '08_BlurrySet',
        ][index],
        sourceDirectory: r'C:\Scans\AutumnTrip\set',
        state: _states[index],
        message: switch (_states[index]) {
          BatchItemState.failed => '纹理不足，无法可靠配准',
          BatchItemState.needsSettings => '需要设置行列与相机视角',
          BatchItemState.skipped => '未检测到可用照片',
          _ => null,
        },
        estimatedLayout: index == 0,
        progress: index == 1
            ? 0.63
            : index == 2
            ? 0.9
            : index == 3
            ? 0.4
            : 0,
        etaSeconds: index == 1 ? 42 : null,
        elapsedSeconds: index == 1 || index == 2 ? 76 : 0,
      ),
  ],
);

void main() {
  testWidgets('batch queue desktop states at 1280x900', (tester) async {
    _setSize(tester, const Size(1280, 900));
    await tester.pumpWidget(_desktopPage([_fixtureQueue()]));
    await tester.pump();

    expect(find.text('01_Lakeside'), findsOneWidget);
    expect(find.text('02_ForestTrail'), findsOneWidget);
    expect(find.text('03_CliffView'), findsOneWidget);
    expect(find.text('04_Campground'), findsOneWidget);
    expect(find.text('AutumnTrip'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/batch_queue_desktop_top.png'),
    );

    await tester.scrollUntilVisible(find.text('08_BlurrySet'), 300);
    await tester.pump();
    expect(find.text('05_Waterfall'), findsOneWidget);
    expect(find.text('06_Sunset'), findsOneWidget);
    expect(find.text('07_InteriorRoom'), findsOneWidget);
    expect(find.text('08_BlurrySet'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/batch_queue_desktop_bottom.png'),
    );
  });

  testWidgets('batch queue adapts to a 1000px desktop width', (tester) async {
    _setSize(tester, const Size(1000, 900));
    await tester.pumpWidget(_desktopPage([_fixtureQueue()]));
    await tester.pump();

    expect(find.text('批处理队列'), findsOneWidget);
    expect(find.text('01_Lakeside'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/batch_queue_desktop_1000.png'),
    );
  });

  testWidgets('batch queue empty state', (tester) async {
    _setSize(tester, const Size(1280, 900));
    await tester.pumpWidget(_desktopPage(const []));
    await tester.pump();

    expect(find.text('选择一个母目录；每个直接子目录会成为独立全景任务。'), findsOneWidget);
    expect(find.text('选择母目录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/batch_queue_empty.png'),
    );
  });

  testWidgets('mobile batch queue explains its disabled entry', (tester) async {
    _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_mobilePage());
    await tester.pump();

    expect(find.text('批处理仅在 Windows 桌面版开放。移动版仍可使用单任务合成。'), findsOneWidget);
    final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
    expect(
      buttons.singleWhere((button) => button.tooltip == '批处理资源设置').onPressed,
      isNull,
    );
    expect(
      buttons.singleWhere((button) => button.tooltip == '选择母目录').onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/batch_queue_mobile.png'),
    );
  });
}

Widget _desktopPage(List<BatchQueue> queues) {
  final controller = _ScreenshotController(fixtureQueues: queues);
  addTearDown(controller.dispose);
  return ChineseTestApp(
    home: BatchQueuePage(api: _ScreenshotApi(), controller: controller),
  );
}

Widget _mobilePage() {
  final controller = _ScreenshotController(fixtureQueues: const []);
  addTearDown(controller.dispose);
  return ChineseTestApp(
    home: BatchQueuePage(
      api: _ScreenshotApi(),
      controller: controller,
      mobileOverride: true,
    ),
  );
}

void _setSize(WidgetTester tester, Size size) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
}
