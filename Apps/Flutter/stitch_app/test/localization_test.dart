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
  test('folder dialog messages are localized in both supported locales', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh'));

    expect(
      english.chooseBatchParentFolder,
      'Choose a parent folder containing panorama subfolders',
    );
    expect(english.chooseFolder, 'Choose folder');
    expect(
      english.folderSelectionFailed('test failure'),
      'Could not choose a folder: test failure',
    );
    expect(chinese.chooseBatchParentFolder, '选择包含多个全景子目录的母目录');
    expect(chinese.chooseFolder, '选择文件夹');
    expect(
      chinese.folderSelectionFailed('test failure'),
      '无法选择文件夹：test failure',
    );
  });

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
        '照片不会从网格移除；照片上的锁定按钮可固定其网格位置。点按照片可选中一张，Shift+点按可添加或移除多张；“锁定所选照片的网格位置”可批量锁定。锁定会跳过该照片的相邻纹理匹配，仅适用于顺序已确认的原片。长按可查看完整文件名。';

    expect(chinese.text(warning), warning);
    expect(
      english.text(warning),
      'Photos stay in the grid. Use a photo lock button to fix its grid position. Click a photo to select it; Shift+click adds or removes individual photos. Use “Lock selected photos to grid” to lock them together. A lock skips neighbor texture matching for that photo, so use it only when the photo order is known. Long-press to see the full filename.',
    );
    expect(english.text('上次配准的超标匹配关系'), 'Previous registration matches over the limit');
    expect(chinese.text('上次配准的超标匹配关系'), '上次配准的超标匹配关系');
    expect(english.text('不匹配'), 'Not match');
    expect(chinese.text('不匹配'), '不匹配');
    expect(english.text('上次诊断，已按网格锁定，待重算'), 'Previous diagnosis; locked to grid, pending restitch');
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

  test('registration quality failure translates coded and plain messages', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh'));
    const body =
        'global matched-ray reprojection is 2.34px RMS '
        '(global limit 12.0px; worst edge 29.96px, selected edge limit '
        '20.0px); supplied intrinsics or scene parallax may be unsuitable';
    const codedSource = 'REGISTRATION_FAILED: $body';
    const translated =
        '配准失败：整体重投影均方根误差为 2.34 px RMS（全局上限 '
        '12.0 px；最差相邻照片对误差 29.96 px，设置上限 '
        '20.0 px）。相机参数不匹配，或近景与远景视差过大，可能导致无法对齐。';

    expect(english.text(codedSource), codedSource);
    expect(english.text(body), body);
    expect(chinese.text(codedSource), translated);
    expect(chinese.text(body), translated);
  });

  testWidgets(
    'Chinese task failure displays localized registration diagnosis',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const body =
          'global matched-ray reprojection is 2.34px RMS '
          '(global limit 12.0px; worst edge 29.96px, selected edge limit '
          '20.0px); supplied intrinsics or scene parallax may be unsuitable';
      const codedSource = 'REGISTRATION_FAILED: $body';
      const translated =
          '配准失败：整体重投影均方根误差为 2.34 px RMS（全局上限 '
          '12.0 px；最差相邻照片对误差 29.96 px，设置上限 '
          '20.0 px）。相机参数不匹配，或近景与远景视差过大，可能导致无法对齐。';
      final api = LocalizationSurfaceJobApi();
      final repository = LocalizationSurfaceTaskRepository();
      final queue = EmptyBatchQueueController(
        api: api,
        taskRepository: repository,
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          locale: const Locale('zh', 'CN'),
          home: StitchHomePage(
            initialTask: localizationTask().copyWith(
              phase: StitchPhase.failed,
              error: codedSource,
            ),
            jobApi: api,
            repository: repository,
            batchQueueController: queue,
            foregroundWorkLock: LocalizationSurfaceLock(),
            mobileOverride: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.text(translated), findsOneWidget);
      expect(find.text(codedSource), findsNothing);
    },
  );

  test(
    'bilingual audit: prefix and regex fallbacks translate dynamic messages',
    () {
      const english = StitchLocalizations(Locale('en'));
      const chinese = StitchLocalizations(Locale('zh'));

      const cases = <String, String>{
        // Colon-terminated prefix keys; the remainder is preserved verbatim.
        '无法启动：timeout': 'Could not start: timeout',
        '无法启用前台任务锁：denied':
            'Could not enable the foreground task lock: denied',
        '前台任务锁不可用，正在请求暂停：denied':
            'Foreground task lock unavailable; requesting pause: denied',
        '无法创建新任务副本：oops': 'Could not create a task copy: oops',
        '恢复任务状态失败：boom': 'Failed to restore task state: boom',
        '无法读取移动端后台暂停记录；启动、恢复与导出已暂缓：err':
            'Could not read mobile background pause records; '
            'start, resume and export are deferred: err',
        '移动端后台暂停任务仍待安全核对：err':
            'A mobile background-paused task still needs a safety check: err',
        '无法读取移动端后台暂停记录；批处理任务保持待核对：err':
            'Could not read mobile background pause records; '
            'the batch task stays pending verification: err',
        '无法重新读取母目录：err': 'Could not re-read the parent directory: err',
        '无法读取子目录：err': 'Could not read the subdirectory: err',
        '仅支持 JPEG 原片：a.jpg':
            'Only original JPEG photos are supported: a.jpg',
        '无法读取所选文件：a.jpg': 'Could not read the selected file: a.jpg',
        '文件不是有效 JPEG：a.jpg': 'The file is not a valid JPEG: a.jpg',
        'JPEG marker 顺序无效：a.jpg': 'Invalid JPEG marker order: a.jpg',
        'JPEG 头中找不到图像尺寸：a.jpg':
            'No image size found in the JPEG header: a.jpg',
        '本地合成核心不可用：err': 'The local stitching core is unavailable: err',
        '调用原生合成核心失败：err':
            'Failed to call the native stitching core: err',
        '启动失败：err': 'Failed to start: err',
        '取消失败：err': 'Failed to cancel: err',
        '无法读取核心资源：err': 'Could not read core resources: err',
        '读取批处理队列失败：err': 'Failed to read the batch queue: err',
        '导入批次失败：err': 'Failed to import the batch: err',
        '原生任务已创建，正在重新连接：err':
            'The native job was created; reconnecting: err',
        '状态暂时不可用，保留原任务并重试：err':
            'State temporarily unavailable; keeping the original task '
            'and retrying: err',
        '恢复状态暂不可用，将自动重试：err':
            'Recovery state temporarily unavailable; retrying automatically: err',
        '等待原生导出状态：err': 'Waiting for the native export state: err',
        '设备全景导入失败：boom': 'Device panorama import failed: boom',
        '等待连接原生任务：err': 'Waiting to connect to the native job: err',
        // Regex fallbacks added by the bilingual audit.
        '原生任务状态为 running；停止确认前保留本地任务':
            'Native job state is running; '
            'the local task is kept until stop is confirmed',
        '原生任务状态为 failed': 'Native job state is failed',
        '未找到原生库 opencv_core.dll：The specified module was not found.':
            'Native library opencv_core.dll not found: '
            'The specified module was not found.',
        '不兼容的原生核心 ABI：1.2（需要 1.3）':
            'Incompatible native core ABI: 1.2 (requires 1.3)',
        '新整图导出failed；保留了此前成功的导出文件。':
            'New full-image export failed; '
            'the previously successful export file is preserved.',
        '整图导出failed。': 'Full image export failed.',
        '完整PNG（无损）尚未生成。': 'The full PNG has not been generated yet.',
        '完整图像尚未生成。': 'The full image has not been generated yet.',
        '合成完成，等待 TIFF（无损，大图自动 BigTIFF） 导出':
            'Composition complete; waiting for '
            'TIFF (lossless; BigTIFF for large images) export',
        '合成完成，正在导出整图 JPEG XL（有损）':
            'Composition complete; exporting the full JPEG XL',
        '合成完成，正在导出 PNG': 'Composition complete; exporting PNG',
        '导出整图 TIFF（无损，大图自动 BigTIFF）': 'Exporting the full TIFF',
        '重试完整 JPEG XL': 'Retry full JPEG XL',
        '导出完整 TIFF': 'Export full TIFF',
        '已请求暂停；等待核心确认（等待当前操作完成）':
            'Pause requested; waiting for the engine to confirm '
            '(waiting for the current operation to finish)',
        '操作完成后已提交暂停请求（等待当前操作完成）':
            'Operation completed. Pause request submitted. '
            '(waiting for the current operation to finish)',
        '按文件名识别 3×2': 'Identified a 3×2 grid from filenames',
        '估算为 4×2，按行排列': 'Estimated as 4×2, arranged by rows',
        '已确认文件名中的 3×2 网格与相机视角':
            'Confirmed the 3×2 grid and camera angles from filenames',
        '已确认 3×2 顺序排列与相机视角':
            'Confirmed the 3×2 sequential layout and camera angles',
        '75% · 本阶段预计剩余 2 分 5 秒':
            '75% · 2 min 5 sec remaining in this phase',
        '42% · 本阶段预计剩余 30 秒':
            '42% · 30 sec remaining in this phase',
        '合成中 · 估算排列，建议检查':
            'Stitching · estimated arrangement, review it',
        '估算布局 · 估算排列，建议检查':
            'Estimated layout · estimated arrangement, review it',
        '2 分 5 秒': '2 min 5 sec',
        '30 秒': '30 sec',
        '5 张原片 · 3840×2160': '5 source photos · 3840×2160',
        '5 张原片 · ': '5 source photos',
      };

      for (final entry in cases.entries) {
        final translated = english.text(entry.key);
        expect(translated, entry.value, reason: entry.key);
        expect(
          RegExp(r'[\u3400-\u9fff]').hasMatch(translated),
          isFalse,
          reason: 'CJK leaked into English: $translated',
        );
      }
      for (final source in const [
        '合成失败',
        '整图导出已完成',
        '母目录不存在',
        '合成完成，等待整图导出',
        '估算布局',
        '无法启动：timeout',
        '30 秒',
      ]) {
        expect(chinese.text(source), source);
      }
    },
  );

  test('bilingual audit: service and UI status keys are localized', () {
    const english = StitchLocalizations(Locale('en'));
    const chinese = StitchLocalizations(Locale('zh'));

    const cases = <String, String>{
      '合成失败': 'Stitching failed',
      '合成已开始': 'Stitching started',
      '合成已完成': 'Composition completed',
      '合成完成，等待整图导出':
          'Composition complete; waiting for the full image export',
      '整图导出失败': 'Full image export failed',
      '整图导出已开始': 'Full image export started',
      '整图导出已完成': 'Full image export completed',
      '整图导出已暂停，点击恢复继续':
          'The full image export is paused. Tap Resume to continue',
      '恢复': 'Resume',
      '恢复整图导出': 'Resume full image export',
      '继续导出整图': 'Continue the full image export',
      '等待核心资源': 'Waiting for engine resources',
      '等待核心资源以恢复原任务':
          'Waiting for engine resources to restore the original task',
      '等待核心资源后自动导出':
          'Waiting for engine resources, then exporting automatically',
      '母目录不存在': 'The parent directory does not exist',
      '母目录中没有直接子目录': 'No direct subdirectory in the parent directory',
      '没有原片': 'No source photos',
      '没有选中照片': 'No photos selected',
      '子目录中没有直接 JPEG 原片':
          'No direct JPEG source photos in the subdirectory',
      '全景目录没有可导入的 JPEG 原片':
          'The panorama directory has no importable JPEG source photos',
      '原片尺寸不一致': 'The source photos have inconsistent dimensions',
      '缺少已导入原片': 'Imported source photos are missing',
      '请先导入原片': 'Import the source photos first',
      '需要设置行列': 'Set the rows and columns first',
      '需要设置相机视角': 'Set the camera field of view first',
      '行列数必须与原片数量一致':
          'Rows and columns must match the number of source photos',
      '文件名行列编号超出支持范围':
          'Filename row/column numbers exceed the supported range',
      '检测到重复行列文件；请改用顺序模式，全部原片都会保留':
          'Duplicate row/column files detected; use sequence mode. '
          'All source photos are kept.',
      '原片内容已变化；请重新导入以创建新任务':
          'The source photo content changed; re-import to create a new task',
      '已有处理目录；请创建新任务，避免覆盖或误恢复旧参数':
          'A processing directory already exists; create a new task '
          'to avoid overwriting or accidentally restoring old settings',
      '任务输入目录已存在，拒绝覆盖':
          'The task input directory already exists; refusing to overwrite',
      '任务渲染目录已有内容，拒绝覆盖':
          'The task render directory already has content; refusing to overwrite',
      '任务记录丢失': 'Task record is missing',
      '找不到本地任务记录': 'No local task record found',
      '找不到该队列任务': 'The queue task was not found',
      '找不到原始子目录': 'The original subdirectory was not found',
      '任务仍在处理中；停止后才能删除队列项目':
          'The task is still processing; stop it before removing the queue item',
      '队列正在恢复或导入，请稍后再删除':
          'The queue is recovering or importing; try removing it again later',
      '队列正在恢复或导入，请稍后再删除任务':
          'The queue is recovering or importing; '
          'try removing the task again later',
      '此队列项目不需要大型任务确认':
          'This queue item does not need a large-job confirmation',
      '大型任务需要确认后才会导出':
          'The large job needs confirmation before exporting',
      '大型任务需要重新确认后才能导出':
          'The large job needs to be re-confirmed before exporting',
      '大型任务尚未安全暂停，确认后不能继续':
          'The large job is not safely paused yet; it cannot continue '
          'after confirmation',
      '后台时间到；整图导出已暂停，点击恢复继续':
          'Background time limit reached; the full image export is paused. '
          'Tap Resume to continue',
      '后台运行已暂停；等待手动恢复导出':
          'Background run paused; waiting for a manual export resume',
      'Android 后台运行时限已到；等待手动恢复导出':
          'The Android background run limit was reached; '
          'export waits for a manual resume',
      'Android 无法启动后台运行保护，任务已安全暂停':
          'Android could not start background protection; the task is safely paused',
      '无法启动 Android 后台运行保护；导出保持暂停':
          'Could not start Android background protection; the export stays paused',
      '共享资源预算已变化，等待释放后再导出整图':
          'The shared resource budget changed; waiting for it to be released '
          'before exporting the full image',
      '等待共享内存预算释放后再导出整图':
          'Waiting for the shared memory budget to be released before '
          'exporting the full image',
      '无法分配不冲突的整图文件名':
          'Could not assign a non-conflicting full image filename',
      '原生合成核心不可用': 'The native stitching engine is unavailable',
      '原生响应不是 JSON 对象': 'The native response is not a JSON object',
      '原生核心返回空响应': 'The native engine returned an empty response',
      '本地处理失败': 'Local processing failed',
      '原生任务的导出状态缺失': 'The native job export state is missing',
      '原生任务状态路径与渲染目录不匹配':
          'The native job state path does not match the render directory',
      '任务缺少原生作业编号；无法确认已停止':
          'The task is missing its native job ID; stop could not be confirmed',
      '核心报告导出完成，但找不到整图文件':
          'The engine reported a completed export, '
          'but the full image file is missing',
      '核心报告导出完成，但找不到非空整图文件':
          'The engine reported a completed export, '
          'but no non-empty full image file was found',
      '核心报告导出完成，但输出文件不存在或为空':
          'The engine reported a completed export, '
          'but the output file is missing or empty',
      '核心未报告可用的 JPEG XL 编码器':
          'The engine did not report an available JPEG XL encoder',
      '核心未报告可用的 JPEG XL 无损编码器；已阻止启动。':
          'The engine did not report an available lossless JPEG XL encoder; '
          'startup was blocked.',
      '此原生核心未报告内置 JPEG XL 编码器，已阻止导出。':
          'This native engine did not report a built-in JPEG XL encoder; '
          'export was blocked.',
      'JPEG XL（编码器未加载）': 'JPEG XL (encoder not loaded)',
      '水平视角需介于 1° 与 179°':
          'Horizontal field of view must be between 1° and 179°',
      '已提交暂停请求': 'Pause request submitted',
      '已请求暂停，等待核心确认':
          'Pause requested; waiting for the engine to confirm',
      '已请求暂停；等待核心确认':
          'Pause requested; waiting for the engine to confirm',
      '已恢复原生任务': 'Restored the native job',
      '已连接正在运行的原生任务': 'Connected to the running native job',
      '应用未运行期间的原生状态不会自动恢复':
          'Native state from while the app was closed is not restored automatically',
      '删除本地任务记录': 'Delete local task record',
      '估算布局': 'Estimated layout',
    };

    for (final entry in cases.entries) {
      final translated = english.text(entry.key);
      expect(translated, entry.value, reason: entry.key);
      expect(
        RegExp(r'[\u3400-\u9fff]').hasMatch(translated),
        isFalse,
        reason: 'CJK leaked into English: $translated',
      );
      expect(chinese.text(entry.key), entry.key);
    }
  });

  testWidgets(
    'English queue marks a publish failure without Chinese and offers retry',
    (tester) async {
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
                state: BatchItemState.completed,
                publishFailed: true,
                message: '发布失败：boom。私有整图已保留，可重试发布。',
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
      expect(find.byTooltip('Retry publishing export'), findsOneWidget);
      expect(find.byTooltip('Open panorama viewer'), findsOneWidget);
      expect(
        find.text(
          'Publishing failed: boom. The private full image is preserved; '
          'retry publishing.',
        ),
        findsOneWidget,
      );
      expect(find.text('1/1 exported · 0 in progress'), findsOneWidget);
      expect(remainingChinese, isEmpty, reason: remainingChinese.join('\n'));
    },
  );

  testWidgets(
    'Chinese queue still shows the publish failure message and retry action',
    (tester) async {
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
                state: BatchItemState.completed,
                publishFailed: true,
                message: '发布失败：boom。私有整图已保留，可重试发布。',
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        LumiaStitchApp(
          locale: const Locale('zh', 'CN'),
          home: BatchQueuePage(api: api, controller: queue),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('重试发布整图'), findsOneWidget);
      expect(
        find.text('发布失败：boom。私有整图已保留，可重试发布。'),
        findsOneWidget,
      );
      expect(find.text('1/1 已导出 · 0 项处理中'), findsOneWidget);
    },
  );

  testWidgets('English viewer source panel translates the output file line', (
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

    await tester.tap(find.byTooltip('View output information'));
    await tester.pump();

    final selectableLines = tester
        .widgetList<material.SelectableText>(
          find.byType(material.SelectableText),
        )
        .map((widget) => widget.data ?? '')
        .toList();
    expect(
      selectableLines.where((line) => line.startsWith('Output file: ')),
      isNotEmpty,
      reason: 'SelectableText lines: $selectableLines',
    );
    final remainingChinese = _visibleChinese(tester);
    expect(remainingChinese, isEmpty, reason: remainingChinese.join('\n'));
  });
}

List<String> _visibleChinese(WidgetTester tester) {
  final data = <String>[
    ...tester
        .widgetList<material.Text>(find.byType(material.Text))
        .map((widget) => widget.data ?? ''),
    ...tester
        .widgetList<material.SelectableText>(
          find.byType(material.SelectableText),
        )
        .map((widget) => widget.data ?? ''),
  ];
  return data
      .where((text) => RegExp(r'[\u3400-\u9fff]').hasMatch(text))
      .toList();
}
