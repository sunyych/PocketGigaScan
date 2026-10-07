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
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/widgets/exported_image_viewer.dart';

import 'support/empty_batch_queue_controller.dart';
import 'support/localization_surface_fakes.dart';

void main() {
  test('quality repair descriptions are localized in both supported locales', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh'));

    const registration = '结合八个方向相邻照片的可靠匹配校正位置；匹配不可靠时会降低其影响，可能需要更长时间。';
    const deghost = '重叠区域优先采用更清晰的照片来源以减少重影；没有更清晰的邻图时仍会保留原片。关闭可与传统羽化结果对照。';

    expect(chinese.text(registration), registration);
    expect(chinese.text(deghost), deghost);
    expect(
      english.timelineStage('precision-recovery-start'),
      'Retry registration at higher precision',
    );
    expect(chinese.timelineStage('precision-recovery-start'), '提高配准精度后重试');
    expect(
      english.text(registration),
      'Refines placement from reliable matches in all eight neighboring directions; unreliable matches have less influence. This may take longer.',
    );
    expect(
      english.text(deghost),
      'Prefers sharper photo sources in overlaps to reduce ghosting; original coverage is kept when no sharper neighbor exists. Turn off to compare feather blending.',
    );
    expect(
      chinese.neighborReliabilitySummary(adjustedEdges: 2, ambiguousEdges: 1),
      '相邻匹配权重调整：2 条；存在闭环不一致的边：1 条。',
    );
    expect(
      english.neighborReliabilitySummary(adjustedEdges: 2, ambiguousEdges: 1),
      'Neighbor match weights adjusted: 2; edges in inconsistent loops: 1.',
    );
    expect(
      chinese.memoryBudgetAdmission('启动任务', 16 * 1024, 32 * 1024, 16 * 1024),
      '启动任务需要16384MiB；当前共享预算32768MiB中已有16384MiB被占用。',
    );
    expect(
      english.memoryBudgetAdmission(
        'Start task',
        16 * 1024,
        32 * 1024,
        16 * 1024,
      ),
      'Start task needs 16384 MiB; 16384 MiB of the 32768 MiB shared budget is already reserved.',
    );
    expect(
      chinese.memoryConcurrencyAdmission('启动任务', 3, 1),
      '启动任务暂缓：共享并发上限为 1 个任务，当前已有 3 个原生任务占用名额。',
    );
    expect(
      english.memoryConcurrencyAdmission('Start task', 3, 1),
      'Start task is deferred: the shared concurrency limit is 1 jobs, with 3 native job(s) currently using a slot.',
    );
    expect(
      english.resourceBudgetStatusFailed('Resume task', 'unavailable'),
      'Could not verify the resource budget for Resume task: unavailable',
    );
  });

  test('hard grid lock warning and controls are localized', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh'));
    const warning =
        '照片不会从网格移除；使用照片上的锁定按钮可固定其网格位置。锁定会跳过该照片的相邻纹理匹配，仅适用于顺序已确认的原片。点按照片不会更改锁定；长按可查看完整文件名。';

    expect(chinese.text(warning), warning);
    expect(
      english.text(warning),
      'Photos stay in the grid. Use the lock button on a photo to fix its grid position. A lock skips neighbor texture matching for that photo, so use it only when the photo order is known. Tapping the photo itself does not change the lock; long-press to see the full filename.',
    );
    expect(english.text('锁定网格位置'), 'Lock grid position');
    expect(english.text('解除网格位置锁定'), 'Unlock grid position');
    expect(
      english.text('旧任务锁定位置来源未知；点按可解除锁定'),
      'Legacy grid lock; origin unknown. Tap to unlock.',
    );
    expect(
      chinese.pendingLegacyGridLocks(2),
      '有 2 个旧网格锁定位置无法关联到当前照片；它们不会固定其他照片。请检查照片映射，并使用锁定按钮明确固定正确原片。',
    );
    expect(
      english.pendingLegacyGridLocks(2),
      '2 legacy grid lock position(s) cannot be matched to a photo. They will not lock another photo. Review the mapping and use the lock button on the intended source photo.',
    );
  });

  test(
    'renderer algorithm guard directs Chinese users to copy and restitch',
    () {
      const english = StitchLocalizations(Locale('en'));
      const chinese = StitchLocalizations(Locale('zh'));
      const message =
          'renderer algorithm changed; create a task copy and restitch';

      const fullMessage = '$message to avoid mixing tiles';
      const nativeFullMessage = 'invalid input: $fullMessage';
      const codedNativeFullMessage = 'JOB_FAILED: $nativeFullMessage';

      expect(english.text(nativeFullMessage), nativeFullMessage);
      expect(
        chinese.text(nativeFullMessage),
        '输入无效：渲染算法已更改；请新建任务副本并重新合成，以避免瓦片混用。',
      );
      expect(
        chinese.text(codedNativeFullMessage),
        'JOB_FAILED: 输入无效：渲染算法已更改；请新建任务副本并重新合成，以避免瓦片混用。',
      );
      expect(
        chinese.text('RENDERER_ALGORITHM_CHANGED: $fullMessage'),
        'RENDERER_ALGORITHM_CHANGED: 渲染算法已更改；请新建任务副本并重新合成，以避免瓦片混用。',
      );
    },
  );

  test('elapsed-time templates are fully localized', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh'));

    expect(english.text('已用 12 秒'), 'Elapsed 12 sec');
    expect(english.text('已用 2 分 12 秒'), 'Elapsed 2 min 12 sec');
    expect(
      english.text('网格为估算值，尚未校准；row 2, column 3'),
      'Grid positions are estimated and are not calibrated; row 2, column 3',
    );
    expect(
      english.text('网格为估算值，尚未校准；置信度 0.83 · estimated-grid-not-calibrated'),
      'Grid positions are estimated and are not calibrated; Confidence 0.83 · estimated-grid-not-calibrated',
    );
    expect(
      chinese.text('网格为估算值，尚未校准；置信度 0.83 · estimated-grid-not-calibrated'),
      '网格为估算值，尚未校准；置信度 0.83 · estimated-grid-not-calibrated',
    );
    expect(
      english.text(
        '已按照片 EXIF 识别 DWARFLAB / DWARF3 / TELE；使用名义 150 mm 配置 fx=75000 px（随图像宽度缩放），未校准。实际 EXIF 焦距：未记录 mm。',
      ),
      'DWARFLAB / DWARF3 / TELE identified from photo EXIF. Using nominal 150 mm profile fx=75000 px (scaled to image width), not calibrated. EXIF focal length: not recorded mm.',
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

  test('retry and registration failure stages are localized by family', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh'));

    for (final stage in const [
      'retry-neighbor-matching',
      'retry-matching',
      'retry-feature-extraction',
      'clahe-retry',
    ]) {
      expect(english.timelineStage(stage), 'Retry neighbor matching');
      expect(chinese.timelineStage(stage), '重试相邻照片匹配');
    }
    expect(english.timelineStage('registration-failed'), 'Registration failed');
    expect(chinese.timelineStage('registration-failed'), '配准失败');
    expect(
      english.timelineStage('registration-complete'),
      'Registration complete',
    );
    expect(chinese.timelineStage('registration-complete'), '配准完成');
    for (final stage in const [
      'retry-matching-progress:42/209',
      'clahe-retry-progress:42/209',
    ]) {
      expect(english.timelineStage(stage), 'Retry neighbor matching (42/209)');
      expect(chinese.timelineStage(stage), '重试相邻照片匹配（42/209）');
    }
    expect(
      english.timelineStage('retry-matching-progress:bad/209'),
      'Retry neighbor matching',
    );
    expect(chinese.timelineStage('clahe-retry-progress:210/209'), '重试相邻照片匹配');
  });

  test(
    'full image export and retry actions preserve Chinese and translate all formats',
    () {
      const english = StitchLocalizations(Locale('en'));
      const chinese = StitchLocalizations(Locale('zh'));
      const expected = <String, (String, String)>{
        'PNG': ('导出完整 PNG', '重试完整 PNG'),
        'TIFF': ('导出完整 TIFF', '重试完整 TIFF'),
        'JPEG XL': ('导出完整 JPEG XL', '重试完整 JPEG XL'),
      };

      for (final entry in expected.entries) {
        for (final (source, translated) in [
          (entry.value.$1, 'Export full ${entry.key}'),
          (entry.value.$2, 'Retry full ${entry.key}'),
        ]) {
          expect(chinese.text(source), source);
          expect(english.text(source), translated);
        }
      }
    },
  );

  test(
    'dynamic task summaries and export labels follow English and Chinese',
    () {
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
      expect(
        english.text('完成后自动导出格式'),
        'Format for automatic export after stitching',
      );
      expect(english.text('JPEG XL（有损）'), 'JPEG XL (lossy)');
      expect(
        english.text('TIFF（无损，大图自动 BigTIFF）'),
        'TIFF (lossless; BigTIFF for large images)',
      );
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
      expect(english.stitchDetails, 'Stitch details');
      expect(english.stitchingLog, 'Stitching log');
      expect(
        english.duplicateBeforeEditingSettings,
        'Create a copy before changing settings',
      );
      expect(chinese.stitchDetails, '合成详情');
      expect(chinese.stitchingLog, '合成日志');
      expect(chinese.duplicateBeforeEditingSettings, '先新建副本，再修改设置');
    },
  );

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

  testWidgets(
    'home localizes overlap guidance for generic, nominal, and touched calibration states',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const genericChinese =
          '重叠率由照片实测；未知镜头的视角仍需填写。当前视角用于球面投影，默认 45° 不是照片测量值。最多检查 24 组中心相邻照片，结果仍需目视检查接缝。';
      const genericEnglish =
          'Overlap is measured from the photos. Enter the field of view for unknown lenses. The current field of view is used for spherical projection; the default 45° is not measured from the photos. Up to 24 neighboring photo pairs around the center are checked, and the result still requires visual seam inspection.';
      const estimatedChinese = '最多检查 24 组中心相邻照片；结果是网格估算值，尚未校准，仍需目视检查接缝。';
      const estimatedEnglish =
          'Checks up to 24 neighboring photo pairs around the center; grid positions are estimates and are not calibrated. Visually inspect the seams.';
      const estimateDetailsChinese =
          '网格为估算值，尚未校准；方法 SIFT/BF · 置信度 0.83 · estimated-grid-not-calibrated';
      const estimateDetailsEnglish =
          'Grid positions are estimated and are not calibrated; Method SIFT/BF · Confidence 0.83 · estimated-grid-not-calibrated';

      final photo = ImportedPhoto(
        originalName: 'synthetic.jpg',
        storedPath: 'synthetic-input/synthetic.jpg',
        sha256: 'synthetic-hash',
        width: 3840,
        height: 2160,
        originalOrder: 0,
        exifFocalLengthMm: 150,
      );
      for (final locale in const [Locale('en'), Locale('zh', 'CN')]) {
        for (final state in ['generic', 'nominal', 'touched']) {
          await tester.pumpWidget(const SizedBox.shrink());
          final api = LocalizationSurfaceJobApi();
          final repository = LocalizationSurfaceTaskRepository();
          final queue = EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          );
          final task = localizationTask().copyWith(
            photos: [photo],
            cameraProfileId: state == 'nominal'
                ? 'dwarf3-tele-nominal-150mm'
                : null,
            resultStats: const {
              'alignment': {
                'gridOverlapEstimate': {
                  'method': 'SIFT/BF',
                  'confidence': 0.83,
                  'provenance': 'estimated-grid-not-calibrated',
                },
              },
            },
          );
          await tester.pumpWidget(
            LumiaStitchApp(
              locale: locale,
              home: StitchHomePage(
                initialTask: task,
                jobApi: api,
                repository: repository,
                batchQueueController: queue,
                foregroundWorkLock: LocalizationSurfaceLock(),
                mobileOverride: false,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final overlapOption = find.byKey(
            const Key('auto-grid-overlap-option'),
          );
          await tester.ensureVisible(overlapOption);
          await tester.pump(const Duration(milliseconds: 100));
          final homeScrollPosition = Scrollable.of(
            tester.element(overlapOption),
          ).position;
          final homeScrollOffset = homeScrollPosition.pixels;

          final isEstimatedInitially = state == 'nominal';
          final expectedChinese = isEstimatedInitially
              ? estimatedChinese
              : genericChinese;
          final expectedEnglish = isEstimatedInitially
              ? estimatedEnglish
              : genericEnglish;
          expect(
            find.text(
              locale.languageCode == 'zh' ? expectedChinese : expectedEnglish,
            ),
            findsOneWidget,
            reason: '$state overlap subtitle in ${locale.languageCode}',
          );

          if (state == 'touched') {
            final shortcut = find.text(
              locale.languageCode == 'zh'
                  ? 'DWARF 固定视角（名义值）'
                  : 'DWARF nominal field of view',
            );
            await tester.ensureVisible(shortcut);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            final shortcutRect = tester.getRect(shortcut);
            final viewportCenterY = tester.view.physicalSize.height / 2;
            if ((shortcutRect.center.dy - viewportCenterY).abs() > 300) {
              homeScrollPosition.jumpTo(
                (homeScrollPosition.pixels +
                        shortcutRect.center.dy -
                        viewportCenterY)
                    .clamp(
                      homeScrollPosition.minScrollExtent,
                      homeScrollPosition.maxScrollExtent,
                    )
                    .toDouble(),
              );
              await tester.pump();
            }
            expect(shortcut.hitTestable(), findsOneWidget);
            await tester.tap(shortcut);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            homeScrollPosition.jumpTo(homeScrollOffset);
            await tester.pump();
            expect(
              find.text(
                locale.languageCode == 'zh'
                    ? estimatedChinese
                    : estimatedEnglish,
              ),
              findsOneWidget,
              reason: 'touched calibration subtitle in ${locale.languageCode}',
            );
          }

          if (state == 'generic') {
            homeScrollPosition.jumpTo(0);
            await tester.pump();
            final diagnosticsTitle = find.text(
              locale.languageCode == 'zh' ? '合成详情' : 'Stitch details',
            );
            await tester.tap(diagnosticsTitle);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              find.text(
                locale.languageCode == 'zh'
                    ? estimateDetailsChinese
                    : estimateDetailsEnglish,
              ),
              findsOneWidget,
              reason: 'overlap estimate diagnostics in ${locale.languageCode}',
            );
            homeScrollPosition.jumpTo(homeScrollOffset);
            await tester.pump();
          }

          for (final (key, label, helper) in const [
            (
              'horizontal-overlap-field',
              'Manual horizontal overlap %',
              '15–80; ignored in automatic mode. See measured values in the report.',
            ),
            (
              'vertical-overlap-field',
              'Manual vertical overlap %',
              '15–80; ignored in automatic mode. See measured values in the report.',
            ),
          ]) {
            final field = find.byKey(Key(key));
            await tester.ensureVisible(field);
            await tester.pump(const Duration(milliseconds: 50));
            final fieldLabel = locale.languageCode == 'zh'
                ? (key.startsWith('horizontal') ? '手动水平重叠率 %' : '手动垂直重叠率 %')
                : label;
            expect(
              find.descendant(of: field, matching: find.text(fieldLabel)),
              findsOneWidget,
            );
            final fieldHelper = locale.languageCode == 'zh'
                ? '15–80；自动模式忽略此值，实测结果见报告'
                : helper;
            expect(
              find.descendant(of: field, matching: find.text(fieldHelper)),
              findsOneWidget,
            );
          }

          if (locale.languageCode == 'en') {
            final remainingChinese = _visibleChinese(tester);
            expect(
              remainingChinese,
              isEmpty,
              reason: remainingChinese.join('\n'),
            );
          }
        }
      }
    },
  );

  testWidgets(
    'home export and recovery actions are localized for every format',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const formats = <ExportFormat, String>{
        ExportFormat.png: 'PNG',
        ExportFormat.tiff: 'TIFF',
        ExportFormat.jpegXl: 'JPEG XL',
      };
      for (final locale in const [Locale('en'), Locale('zh', 'CN')]) {
        for (final entry in formats.entries) {
          for (final stage in const ['ready', 'export-failed']) {
            await tester.pumpWidget(const SizedBox.shrink());
            final api = LocalizationSurfaceJobApi();
            final repository = LocalizationSurfaceTaskRepository();
            final queue = EmptyBatchQueueController(
              api: api,
              taskRepository: repository,
            );
            final task = localizationTask().copyWith(
              phase: StitchPhase.completed,
              stage: stage,
              nativeJobId: 'synthetic-job',
              exportFormat: entry.key,
            );
            await tester.pumpWidget(
              LumiaStitchApp(
                locale: locale,
                home: StitchHomePage(
                  initialTask: task,
                  jobApi: api,
                  repository: repository,
                  batchQueueController: queue,
                  foregroundWorkLock: LocalizationSurfaceLock(),
                  mobileOverride: false,
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 100));
            final action = find.byKey(const Key('export-task-action'));
            await tester.ensureVisible(action);
            await tester.pump(const Duration(milliseconds: 50));

            final retry = stage == 'export-failed';
            final expected = locale.languageCode == 'zh'
                ? '${retry ? '重试' : '导出'}完整 ${entry.value}'
                : '${retry ? 'Retry' : 'Export'} full ${entry.value}';
            expect(
              find.descendant(of: action, matching: find.text(expected)),
              findsOneWidget,
            );
            if (locale.languageCode == 'en') {
              final remainingChinese = _visibleChinese(tester);
              expect(
                remainingChinese,
                isEmpty,
                reason: remainingChinese.join('\n'),
              );
            }
          }
        }
      }
    },
  );

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
