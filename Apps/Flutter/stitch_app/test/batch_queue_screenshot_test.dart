import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'support/chinese_test_app.dart';
import 'support/platform_golden.dart';

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
  parentDirectory: p.join('Scans', 'AutumnTrip'),
  outputDirectory: p.join('Scans', 'AutumnTrip_stitched'),
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
        sourceDirectory: p.join('Scans', 'AutumnTrip', 'set'),
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
  testWidgets('completed batch cards show no progress or setup controls', (
    tester,
  ) async {
    _setSize(tester, const Size(1280, 1200));
    await tester.pumpWidget(_desktopPage([_fixtureQueue()]));
    await tester.pump();

    final card = find.byKey(const Key('batch-item-item-5'));
    await tester.ensureVisible(card);
    await tester.pump();
    expect(
      find.descendant(of: card, matching: find.byType(LinearProgressIndicator)),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.tune)),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.byTooltip('打开全景查看器')),
      findsOneWidget,
    );
  });

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
      platformGoldenFile('goldens/batch_queue_desktop_top.png'),
    );

    final lastQueueItem = find.text('08_BlurrySet');
    final queueList = find.byType(ListView);
    expect(queueList, findsOneWidget);
    await tester.scrollUntilVisible(
      lastQueueItem,
      300,
      scrollable: find
          .descendant(of: queueList, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.ensureVisible(lastQueueItem);
    await tester.pump();
    expect(find.text('05_Waterfall'), findsOneWidget);
    expect(find.text('06_Sunset'), findsOneWidget);
    expect(find.text('07_InteriorRoom'), findsOneWidget);
    expect(find.text('08_BlurrySet'), findsOneWidget);
    for (final name in [
      '05_Waterfall',
      '06_Sunset',
      '07_InteriorRoom',
      '08_BlurrySet',
    ]) {
      expect(find.text(name).hitTestable(), findsOneWidget, reason: name);
    }
    final lastItemRect = tester.getRect(lastQueueItem);
    final queueViewportRect = tester.getRect(queueList);
    final visibleIntersection = lastItemRect.intersect(queueViewportRect);
    expect(visibleIntersection.width, greaterThan(0));
    expect(visibleIntersection.height, greaterThan(0));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      platformGoldenFile('goldens/batch_queue_desktop_bottom.png'),
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
      platformGoldenFile('goldens/batch_queue_desktop_1000.png'),
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
      platformGoldenFile('goldens/batch_queue_empty.png'),
    );
  });

  testWidgets('mobile batch queue exposes folder import and settings', (
    tester,
  ) async {
    _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_mobilePage());
    await tester.pump();

    expect(find.text('批处理队列'), findsOneWidget);
    final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
    expect(
      buttons.singleWhere((button) => button.tooltip == '批处理资源设置').onPressed,
      isNotNull,
    );
    expect(
      buttons.singleWhere((button) => button.tooltip == '选择母目录').onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      platformGoldenFile('goldens/batch_queue_mobile.png'),
    );
  });

  testWidgets('large text format dialog scrolls to choices and actions', (
    tester,
  ) async {
    _setSize(tester, const Size(390, 844));
    final originalSelector = FileSelectorPlatform.instance;
    final selector = _DialogFileSelector()..directory = 'Scans/Parent';
    FileSelectorPlatform.instance = selector;
    addTearDown(() => FileSelectorPlatform.instance = originalSelector);
    await tester.pumpWidget(_largeTextDialogPage(const []));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('选择母目录').first);
    await tester.pumpAndSettle();

    expect(find.text('批量整图格式'), findsOneWidget);
    for (final label in [
      'PNG（无损）',
      'TIFF（无损，大图自动 BigTIFF）',
      'JPEG（有损，质量 90）',
      'JPEG XL（有损）',
    ]) {
      final choice = find.text(label);
      expect(choice, findsOneWidget);
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      expect(choice.hitTestable(), findsOneWidget, reason: label);
    }
    await tester.ensureVisible(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('继续').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('large text task grid dialog scrolls through every field', (
    tester,
  ) async {
    _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      _largeTextDialogPage([_fixtureQueue()], locale: const Locale('en')),
    );
    await tester.pumpAndSettle();

    final itemCard = find.byKey(const Key('batch-item-item-6'));
    await tester.scrollUntilVisible(
      itemCard,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(itemCard);
    await tester.pumpAndSettle();
    final settings = find.descendant(
      of: itemCard,
      matching: find.byTooltip('Set grid and camera field of view'),
    );
    await tester.tap(settings);
    await tester.pumpAndSettle();

    expect(find.text('Settings 07_InteriorRoom'), findsOneWidget);
    for (var index = 0; index < 3; index++) {
      final label = [
        'Rows',
        'Columns',
        'Horizontal field of view (degrees)',
      ][index];
      final field = find.text(label);
      expect(field, findsOneWidget);
      final input = find.byType(TextField).at(index);
      await tester.ensureVisible(input);
      await tester.pumpAndSettle();
      expect(input.hitTestable(), findsOneWidget, reason: label);
      _expectCompleteFieldLabel(tester, input, label);
    }
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Save').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'large text resource dialog keeps all fields and actions reachable',
    (tester) async {
      _setSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        _largeTextDialogPage(const [], locale: const Locale('en')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Batch resource settings'));
      await tester.pumpAndSettle();
      expect(find.text('Batch resources'), findsOneWidget);
      for (var index = 0; index < 3; index++) {
        final label = [
          'Total CPU worker threads',
          'Total memory budget (MiB)',
          'Concurrent tasks (max 8)',
        ][index];
        final field = find.text(label);
        expect(field, findsOneWidget);
        final input = find.byType(TextField).at(index);
        await tester.ensureVisible(input);
        await tester.pumpAndSettle();
        expect(input.hitTestable(), findsOneWidget, reason: label);
        _expectCompleteFieldLabel(tester, input, label);
      }
      await tester.ensureVisible(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Apply').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
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
      androidOverride: true,
    ),
  );
}

Widget _largeTextDialogPage(
  List<BatchQueue> queues, {
  Locale locale = const Locale('zh'),
}) {
  final controller = _DialogController(fixtureQueues: queues);
  addTearDown(controller.dispose);
  return MaterialApp(
    locale: locale,
    supportedLocales: StitchLocalizations.supportedLocales,
    localizationsDelegates: const [
      StitchLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(390, 844),
        textScaler: TextScaler.linear(2),
      ),
      child: BatchQueuePage(api: _DialogApi(), controller: controller),
    ),
  );
}

void _expectCompleteFieldLabel(
  WidgetTester tester,
  Finder field,
  String label,
) {
  final labelFinder = find.text(label);
  expect(labelFinder, findsOneWidget, reason: 'complete label: $label');
  final paragraph = tester.renderObject<RenderParagraph>(labelFinder);
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: 'label must not be ellipsized: $label',
  );
  final valueFinder = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  expect(valueFinder, findsOneWidget, reason: 'editable value: $label');
  final labelRect = tester.getRect(labelFinder);
  final valueRect = tester.getRect(valueFinder);
  expect(
    labelRect.bottom + 4,
    lessThanOrEqualTo(valueRect.top),
    reason: 'label and editable value must have 4 dp clearance: $label',
  );
}

class _DialogController extends _ScreenshotController {
  _DialogController({required super.fixtureQueues});

  @override
  Future<(int, int, double)> settingsFor(String queueId, String itemId) async =>
      (2, 4, 45.0);
}

class _DialogApi extends _ScreenshotApi {
  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'jpegXlAvailable': true,
      'totalCpuWorkers': 8,
      'totalMemoryBudgetMiB': 8192,
      'maxConcurrentJobs': 4,
    },
  };
}

class _DialogFileSelector extends FileSelectorPlatform {
  String? directory;

  @override
  Future<String?> getDirectoryPathWithOptions(
    FileDialogOptions options,
  ) async => directory;
}

void _setSize(WidgetTester tester, Size size) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
}
