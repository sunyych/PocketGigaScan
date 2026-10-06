import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/material.dart' as material;
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/main.dart' show LumiaStitchApp, StitchHomePage;
import 'package:stitch_app/l10n/localized_text.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/widgets/exported_image_viewer.dart';

import 'support/empty_batch_queue_controller.dart';
import 'support/localization_surface_fakes.dart';

void main() {
  test('elapsed-time templates are fully localized', () {
    const english = StitchLocalizations(Locale('en'));

    expect(english.text('已用 12 秒'), 'Elapsed 12 sec');
    expect(english.text('已用 2 分 12 秒'), 'Elapsed 2 min 12 sec');
    expect(
      english.text('网格为估算值，尚未校准；row 2, column 3'),
      'Grid positions are estimated and are not calibrated; row 2, column 3',
    );
    expect(english.text('ready · 0% · 已导入'), 'ready · 0% · Imported');
    expect(
      english.text('完成后自动导出：PNG'),
      'Automatic export after stitching: PNG',
    );
    for (final format in const ['PNG', 'TIFF', 'JPEG XL']) {
      expect(
        english.text('完成后自动导出：$format'),
        'Automatic export after stitching: $format',
      );
    }
    expect(
      english.text('文件名需为 row_column.jpg；可切换到顺序模式'),
      'Filenames must use row_column.jpg; switch to sequence mode.',
    );
    expect(
      english.text(
        '重叠率由照片实测；未知镜头的视角仍需填写。当前视角用于球面投影，默认 45° 不是照片测量值。最多检查 24 组中心相邻照片，结果仍需目视检查接缝。',
      ),
      contains('Overlap is measured from the photos.'),
    );
  });

  test('dynamic task summaries and export labels follow English and Chinese', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh', 'CN'));

    const phases = <String, (String, String)>{
      'imported': ('Imported', '已导入'),
      'queued': ('Queued', '排队中'),
      'running': ('Stitching', '合成中'),
      'pausing': ('Pausing', '正在暂停'),
      'paused': ('Paused', '已暂停'),
      'interrupted': ('Interrupted', '已中断'),
      'exporting': ('Exporting', '正在导出'),
      'completed': ('Completed', '已完成'),
      'failed': ('Failed', '失败'),
      'cancelled': ('Cancelled', '已取消'),
    };
    for (final entry in phases.entries) {
      expect(english.phaseLabel(entry.key), entry.value.$1);
      expect(chinese.phaseLabel(entry.key), entry.value.$2);
    }
    for (final format in const ['PNG', 'TIFF', 'JPEG XL']) {
      expect(
        english.taskSummary(
          photoCount: 7,
          phase: 'completed',
          format: format,
        ),
        '7 photos · Completed · $format',
      );
      expect(
        chinese.taskSummary(
          photoCount: 7,
          phase: 'completed',
          format: format,
        ),
        '7 张 · 已完成 · $format',
      );
    }
    expect(
      english.text('7 张 · completed · JPEG XL'),
      '7 photos · Completed · JPEG XL',
    );
    expect(chinese.text('7 张 · completed · JPEG XL'), '7 张 · 已完成 · JPEG XL');
    expect(english.text('整图输出'), 'Full image output');
    expect(english.text('完成后自动导出格式'), 'Format for automatic export after stitching');
    expect(english.text('JPEG XL（有损）'), 'JPEG XL (lossy)');
    expect(english.text('TIFF（无损，大图自动 BigTIFF）'), 'TIFF (lossless; BigTIFF for large images)');
    const formatDescriptions = <ExportFormat, String>{
      ExportFormat.png: 'PNG (lossless)',
      ExportFormat.tiff: 'TIFF (lossless; BigTIFF for large images)',
      ExportFormat.jpegXl: 'JPEG XL (lossy)',
    };
    for (final entry in formatDescriptions.entries) {
      final source = '整图格式：${entry.key.label}';
      expect(english.text(source), 'Full image format: ${entry.value}');
      expect(chinese.text(source), source);
    }
    expect(english.compositionInfoLogs, 'Stitch details / log');
    expect(english.duplicateBeforeEditingSettings, 'Create a copy before changing settings');
    expect(chinese.compositionInfoLogs, '合成信息 / 日志');
    expect(chinese.duplicateBeforeEditingSettings, '先新建副本，再修改设置');
  });

  Widget fixture(Locale? locale) => LumiaStitchApp(
    locale: locale,
    home: const Scaffold(body: Text('强制网格合成')),
  );

  testWidgets('English locale shows the English grid control label', (
    tester,
  ) async {
    await tester.pumpWidget(fixture(const Locale('en')));

    expect(find.text('Force grid placement'), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'PocketGigaScan',
    );
  });

  testWidgets('Chinese locales show Chinese copy and the current brand', (
    tester,
  ) async {
    for (final locale in const [Locale('zh', 'CN'), Locale('zh', 'TW')]) {
      await tester.pumpWidget(fixture(locale));
      expect(find.text('强制网格合成'), findsOneWidget);
      expect(find.byType(MaterialApp), findsOneWidget);
    }
  });

  testWidgets('changing the app locale updates existing widgets', (
    tester,
  ) async {
    await tester.pumpWidget(fixture(const Locale('en')));
    expect(find.text('Force grid placement'), findsOneWidget);

    await tester.pumpWidget(fixture(const Locale('zh', 'CN')));
    await tester.pump();
    expect(find.text('强制网格合成'), findsOneWidget);
  });

  testWidgets(
    'uses Chinese and English system locales when no override is set',
    (tester) async {
      tester.binding.platformDispatcher.localesTestValue = const [
        Locale('zh', 'CN'),
      ];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(fixture(null));
      expect(find.text('强制网格合成'), findsOneWidget);

      tester.binding.platformDispatcher.localesTestValue = const [
        Locale('en', 'US'),
      ];
      await tester.pump();
      expect(find.text('Force grid placement'), findsOneWidget);
    },
  );

  testWidgets('English main screen options contain no untranslated Chinese', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = LocalizationSurfaceJobApi();
    final repository = LocalizationSurfaceTaskRepository();
    final queue = EmptyBatchQueueController(
      api: api,
      taskRepository: repository,
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('en'),
        home: StitchHomePage(
          initialTask: localizationTask(),
          jobApi: api,
          repository: repository,
          batchQueueController: queue,
          foregroundWorkLock: LocalizationSurfaceLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(
      find.byKey(const Key('stitch-quality-expansion')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('stitch-quality-expansion')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.ensureVisible(find.text('Reduce seam ghosting'));
    await tester.pump(const Duration(milliseconds: 300));
    final remainingChinese = _visibleChinese(tester);

    expect(find.text('Force grid placement'), findsOneWidget);
    expect(find.text('Reduce seam ghosting'), findsOneWidget);
    expect(remainingChinese, isEmpty, reason: remainingChinese.join('\n'));
  });

  testWidgets('English batch queue has no untranslated Chinese copy', (
    tester,
  ) async {
    final api = LocalizationSurfaceJobApi();
    final queue = EmptyBatchQueueController(
      api: api,
      taskRepository: LocalizationSurfaceTaskRepository(),
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('en'),
        home: BatchQueuePage(api: api, controller: queue),
      ),
    );
    await tester.pump();
    final remainingChinese = _visibleChinese(tester);

    expect(find.text('Batch queue'), findsOneWidget);
    expect(remainingChinese, isEmpty, reason: remainingChinese.join('\n'));
  });

  testWidgets('English queue translates a running item and elapsed status', (
    tester,
  ) async {
    final api = LocalizationSurfaceJobApi();
    final queue = EmptyBatchQueueController(
      api: api,
      taskRepository: LocalizationSurfaceTaskRepository(),
      initialQueues: [
        BatchQueue(
          id: 'synthetic-queue',
          createdAt: DateTime.utc(2026),
          parentDirectory: 'synthetic-parent',
          outputDirectory: 'synthetic-output',
          outputFormat: ExportFormat.png,
          items: const [
            BatchQueueItem(
              id: 'synthetic-item',
              name: 'synthetic scene',
              sourceDirectory: 'synthetic-parent/scene',
              state: BatchItemState.running,
              progress: 0.25,
              elapsedSeconds: 12,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('en'),
        home: BatchQueuePage(api: api, controller: queue),
      ),
    );
    await tester.pump();

    final remainingChinese = _visibleChinese(tester);
    expect(find.text('Stitching · Elapsed 12 sec'), findsOneWidget);
    expect(remainingChinese, isEmpty, reason: remainingChinese.join('\n'));
  });

  testWidgets('English viewer missing-preview state is fully translated', (
    tester,
  ) async {
    final temp = await tester.runAsync(
      () => Directory.systemTemp.createTemp('viewer-localization-'),
    );
    expect(temp, isNotNull);
    final directory = temp!;
    addTearDown(() => directory.delete(recursive: true));
    final output = File('${directory.path}/stitched.tif')
      ..writeAsBytesSync([1]);
    final tiles = Directory('${directory.path}/tiles')..createSync();
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('en'),
        home: ExportedImageViewer(
          exportFilePath: output.path,
          pyramidDirectory: tiles.path,
          expectedExportFingerprint: null,
          legacyTaskAssociationPresent: true,
          legacyTaskBindingVerified: true,
        ),
      ),
    );
    for (
      var attempt = 0;
      attempt < 50 &&
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    await tester.pump();
    final remainingChinese = _visibleChinese(tester);

    expect(
      find.text('This task has no tile preview manifest.'),
      findsOneWidget,
    );
    expect(remainingChinese, isEmpty, reason: remainingChinese.join('\n'));
  });
}

List<String> _visibleChinese(WidgetTester tester) => tester
    .widgetList<material.Text>(find.byType(material.Text))
    .map((widget) => widget.data ?? '')
    .where((text) => RegExp(r'[\u3400-\u9fff]').hasMatch(text))
    .toList();
