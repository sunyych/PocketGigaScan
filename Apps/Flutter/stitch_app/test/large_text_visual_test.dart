import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/batch_queue_page.dart';
import 'package:stitch_app/main.dart' show LumiaStitchApp, StitchHomePage;
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/export_fingerprint.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';
import 'package:stitch_app/settings_page.dart';
import 'package:stitch_app/l10n/stitch_localizations.dart';
import 'package:stitch_app/widgets/exported_image_viewer.dart';

import 'support/empty_batch_queue_controller.dart';
import 'support/localization_surface_fakes.dart';

const _captureLargeTextQa = bool.fromEnvironment(
  'CAPTURE_LARGE_TEXT_QA',
  defaultValue: false,
);
const _captureLargeTextExtras = bool.fromEnvironment(
  'CAPTURE_LARGE_TEXT_EXTRAS',
  defaultValue: false,
);
const _captureBoundaryKey = Key('large-text-capture-boundary');

// This opt-in matrix expects the bundled-Python JPEG fixtures and Windows
// fonts that are prepared for manual capture; ordinary CI remains portable.
void main() {
  testWidgets(
    'Chinese and English large text surfaces render without overflow',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _loadRealTestFont(tester);
      // Progress is useful when the opt-in matrix is run on real filesystems.
      // ignore: avoid_print
      print('large-text capture: fonts loaded');
      final (photos, jpegBytesByPath) = await _loadSyntheticJpegPhotos(tester);
      // ignore: avoid_print
      print('large-text capture: synthetic JPEG fixtures loaded');

      for (final locale in const ['zh', 'en']) {
        for (final scale in const [1.5, 2.0]) {
          for (final viewport in const [
            (name: 'desktop', size: Size(1280, 900)),
            (name: 'mobile', size: Size(390, 844)),
          ]) {
            tester.view.physicalSize = viewport.size;
            tester.view.devicePixelRatio = 1;

            await _settingsShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'settings-overview',
              expand: null,
            );
            await _settingsShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'settings-large-text',
              expand: 'text-size',
            );
            await _settingsShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'settings-output-quality',
              expand: 'output-quality',
            );
            await _settingsShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'settings-performance',
              expand: 'performance',
            );
            await _homeShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'home-synthetic-sources',
              photos: photos,
              jpegBytesByPath: jpegBytesByPath,
              expand: null,
            );
            await _homeShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'home-arrangement-expanded',
              photos: photos,
              jpegBytesByPath: jpegBytesByPath,
              expand: 'arrangement',
            );
            await _homeShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'home-output-quality-expanded',
              photos: photos,
              jpegBytesByPath: jpegBytesByPath,
              expand: 'output-quality',
            );
            await _homeShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
              shot: 'home-photo-preview',
              photos: photos,
              jpegBytesByPath: jpegBytesByPath,
              expand: 'photo-preview',
            );
            await _batchShot(
              tester,
              locale: locale,
              scale: scale,
              viewport: viewport.name,
            );
            if (scale == 2.0 && viewport.name == 'mobile') {
              await _homeShot(
                tester,
                locale: locale,
                scale: scale,
                viewport: viewport.name,
                shot: 'home-arrangement-controls-lower',
                photos: photos,
                jpegBytesByPath: jpegBytesByPath,
                expand: 'arrangement-lower',
              );
              await _batchResourcesShot(
                tester,
                locale: locale,
                scale: scale,
                viewport: viewport.name,
              );
            }
            // ignore: avoid_print
            print(
              'large-text capture: $locale ${scale}x ${viewport.name} complete',
            );
          }
        }
      }
    },
    skip: !_captureLargeTextQa,
  );

  testWidgets(
    'Native result viewer renders real export evidence',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _loadRealTestFont(tester);
      for (final locale in const ['en', 'zh']) {
        await _resultShot(
          tester,
          locale: locale,
          scale: 1.5,
          viewport: 'desktop',
          showInformation: false,
        );
        await _resultShot(
          tester,
          locale: locale,
          scale: 2.0,
          viewport: 'mobile',
          showInformation: true,
        );
      }
    },
    skip: !_captureLargeTextQa,
  );

  testWidgets(
    '200% mobile arrangement lower controls and batch resources render',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _loadRealTestFont(tester);
      final (photos, jpegBytesByPath) = await _loadSyntheticJpegPhotos(tester);
      tester.view.devicePixelRatio = 1;
      for (final locale in const ['en', 'zh']) {
        tester.view.physicalSize = const Size(1280, 900);
        await _homeShot(
          tester,
          locale: locale,
          scale: 1.5,
          viewport: 'desktop',
          shot: 'home-arrangement-expanded',
          photos: photos,
          jpegBytesByPath: jpegBytesByPath,
          expand: 'arrangement',
        );
        tester.view.physicalSize = const Size(390, 844);
        await _homeShot(
          tester,
          locale: locale,
          scale: 2.0,
          viewport: 'mobile',
          shot: 'home-arrangement-controls-lower',
          photos: photos,
          jpegBytesByPath: jpegBytesByPath,
          expand: 'arrangement-lower',
        );
        await _batchResourcesShot(
          tester,
          locale: locale,
          scale: 2.0,
          viewport: 'mobile',
        );
      }
    },
    skip: !_captureLargeTextQa || !_captureLargeTextExtras,
  );
}

Future<void> _settingsShot(
  WidgetTester tester, {
  required String locale,
  required double scale,
  required String viewport,
  required String shot,
  required String? expand,
}) async {
  final controller = _settingsController(locale, scale);
  await _pumpCapture(
    tester,
    LumiaStitchApp(
      locale: Locale(locale),
      settingsController: controller,
      home: SettingsPage(controller: controller),
    ),
  );
  if (expand != null) {
    final finder = switch (expand) {
      'text-size' => find.byKey(const Key('text-size-settings')),
      'output-quality' => find.text(
        StitchLocalizations.of(
          tester.element(find.byType(SettingsPage)),
        ).outputQuality,
      ),
      'performance' => find.text(
        StitchLocalizations.of(
          tester.element(find.byType(SettingsPage)),
        ).performanceDefaults,
      ),
      _ => throw StateError('Unknown settings expansion: $expand'),
    };
    await tester.scrollUntilVisible(
      finder,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    if (expand == 'text-size') {
      await tester.ensureVisible(find.byKey(const Key('text-size-preview')));
      await tester.pump();
    } else if (expand == 'performance') {
      final label = StitchLocalizations.of(
        tester.element(find.byType(SettingsPage)),
      ).parallelMatching;
      await tester.ensureVisible(find.text(label));
      await tester.pump();
    } else if (expand == 'output-quality') {
      final formatLabel = StitchLocalizations.of(
        tester.element(find.byType(SettingsPage)),
      ).outputFormat;
      await tester.ensureVisible(find.text(formatLabel));
      await tester.pump();
    }
  }
  _expectNoException(tester, '$locale $scale $viewport $shot');
  await _saveScreenshot(tester, locale, scale, viewport, shot);
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

Future<void> _homeShot(
  WidgetTester tester, {
  required String locale,
  required double scale,
  required String viewport,
  required String shot,
  required List<ImportedPhoto> photos,
  required Map<String, Uint8List> jpegBytesByPath,
  required String? expand,
}) async {
  final api = LocalizationSurfaceJobApi();
  final repository = LocalizationSurfaceTaskRepository();
  final queue = EmptyBatchQueueController(api: api, taskRepository: repository);
  final settings = _settingsController(locale, scale);
  final task = _syntheticTask(photos);
  await _primeSyntheticPhotoImages(
    tester,
    photos,
    jpegBytesByPath,
    previewEdge: viewport == 'desktop' ? 1280 : 844,
  );
  await _pumpCapture(
    tester,
    LumiaStitchApp(
      locale: Locale(locale),
      settingsController: settings,
      home: StitchHomePage(
        initialTask: task,
        initialManifest: null,
        jobApi: api,
        repository: repository,
        batchQueueController: queue,
        foregroundWorkLock: LocalizationSurfaceLock(),
        powerGate: _NoOpPowerGate(),
        settingsController: settings,
        registrationIssueLoader: (_) async => const [],
        mobileOverride: false,
      ),
    ),
  );
  Rect? horizontalOverlapLabelBounds;
  double? horizontalOverlapFieldWidth;
  bool? horizontalOverlapLabelExceededMaxLines;
  bool? horizontalOverlapHelperExceededMaxLines;
  bool? focalLengthLabelExceededMaxLines;
  if (expand == 'arrangement') {
    final finder = find.byKey(const Key('stitch-arrangement-expansion'));
    await _scrollHomeTo(tester, finder);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    await _scrollHomeTo(tester, find.byType(DropdownButton<TraversalAxis>));
    await Scrollable.ensureVisible(
      tester.element(find.byType(DropdownButton<TraversalAxis>)),
      alignment: 0.2,
    );
    await tester.pump();
    if (locale == 'en') {
      final label = StitchLocalizations.of(
        tester.element(find.byType(StitchHomePage)),
      ).text('焦距像素（可选）');
      final labelFinder = find.text(label);
      expect(labelFinder, findsOneWidget);
      focalLengthLabelExceededMaxLines = tester
          .renderObject<RenderParagraph>(labelFinder)
          .didExceedMaxLines;
    }
  } else if (expand == 'arrangement-lower') {
    final arrangement = find.byKey(const Key('stitch-arrangement-expansion'));
    await _scrollHomeTo(tester, arrangement);
    await tester.ensureVisible(arrangement);
    await tester.tap(arrangement);
    await tester.pumpAndSettle();
    final lowerControl = find.byKey(const Key('horizontal-overlap-field'));
    await _scrollHomeTo(tester, lowerControl);
    await Scrollable.ensureVisible(
      tester.element(lowerControl),
      alignment: 0.2,
    );
    await tester.pump();
    final localizations = StitchLocalizations.of(
      tester.element(find.byType(StitchHomePage)),
    );
    final labelFinder = find.descendant(
      of: lowerControl,
      matching: find.text(localizations.text('手动水平重叠率 %')),
    );
    final helperFinder = find.descendant(
      of: lowerControl,
      matching: find.text(localizations.text('15–80；自动模式忽略此值，实测结果见报告')),
    );
    expect(labelFinder, findsOneWidget);
    expect(helperFinder, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(labelFinder);
    final helperParagraph = tester.renderObject<RenderParagraph>(helperFinder);
    final field = tester.renderObject<RenderBox>(lowerControl);
    final topLeft = field.globalToLocal(paragraph.localToGlobal(Offset.zero));
    final bottomRight = field.globalToLocal(
      paragraph.localToGlobal(
        Offset(paragraph.size.width, paragraph.size.height),
      ),
    );
    horizontalOverlapLabelBounds = Rect.fromPoints(topLeft, bottomRight);
    horizontalOverlapFieldWidth = field.size.width;
    horizontalOverlapLabelExceededMaxLines = paragraph.didExceedMaxLines;
    horizontalOverlapHelperExceededMaxLines = helperParagraph.didExceedMaxLines;
  } else if (expand == 'output-quality') {
    final arrangement = find.byKey(const Key('stitch-arrangement-expansion'));
    await _scrollHomeTo(tester, arrangement);
    await tester.ensureVisible(arrangement);
    await tester.tap(arrangement);
    await tester.pumpAndSettle();
    final quality = find.byKey(const Key('stitch-quality-expansion'));
    await _scrollHomeTo(tester, quality);
    await tester.ensureVisible(quality);
    await tester.tap(quality);
    await tester.pumpAndSettle();
    await _scrollHomeTo(
      tester,
      find.byKey(const Key('deghost-blending-option')),
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('deghost-blending-option'))),
      alignment: 0.2,
    );
    await tester.pump();
  } else if (expand == 'photo-preview') {
    final photo = find.byKey(const ValueKey('grid-photo-select-0-0'));
    await _scrollHomeTo(tester, photo);
    await tester.ensureVisible(photo);
    await tester.tap(photo);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(photo);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-grid-preview-dialog')), findsOneWidget);
  }
  _expectNoException(tester, '$locale $scale $viewport $shot');
  await _saveScreenshot(tester, locale, scale, viewport, shot);
  final labelBounds = horizontalOverlapLabelBounds;
  final fieldWidth = horizontalOverlapFieldWidth;
  if (labelBounds != null && fieldWidth != null) {
    expect(horizontalOverlapLabelExceededMaxLines, isFalse);
    expect(horizontalOverlapHelperExceededMaxLines, isFalse);
    expect(labelBounds.height, greaterThan(20));
    expect(labelBounds.left, greaterThanOrEqualTo(0));
    expect(
      labelBounds.right,
      lessThanOrEqualTo(fieldWidth + 1),
      reason: 'The floating label should paint within the overlap field width.',
    );
  }
  if (focalLengthLabelExceededMaxLines != null) {
    expect(focalLengthLabelExceededMaxLines, isFalse);
  }
  await tester.pumpWidget(const SizedBox.shrink());
  settings.dispose();
}

Future<void> _scrollHomeTo(WidgetTester tester, Finder finder) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const Key('stitch-main-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(finder, 350, scrollable: scrollable);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.ensureVisible(finder);
  await tester.pump();
  expect(finder.hitTestable(), findsOneWidget);
}

Future<void> _batchShot(
  WidgetTester tester, {
  required String locale,
  required double scale,
  required String viewport,
}) async {
  final api = LocalizationSurfaceJobApi();
  final repository = LocalizationSurfaceTaskRepository();
  final queue = EmptyBatchQueueController(api: api, taskRepository: repository);
  final settings = _settingsController(locale, scale);
  await _pumpCapture(
    tester,
    LumiaStitchApp(
      locale: Locale(locale),
      settingsController: settings,
      home: BatchQueuePage(
        api: api,
        controller: queue,
        settingsController: settings,
        mobileOverride: false,
      ),
    ),
  );
  _expectNoException(tester, '$locale $scale $viewport batch-empty');
  await _saveScreenshot(tester, locale, scale, viewport, 'batch-empty-queue');
  await tester.pumpWidget(const SizedBox.shrink());
  settings.dispose();
}

Future<void> _batchResourcesShot(
  WidgetTester tester, {
  required String locale,
  required double scale,
  required String viewport,
}) async {
  final api = LocalizationSurfaceJobApi();
  final repository = LocalizationSurfaceTaskRepository();
  final queue = EmptyBatchQueueController(api: api, taskRepository: repository);
  final settings = _settingsController(locale, scale);
  await _pumpCapture(
    tester,
    LumiaStitchApp(
      locale: Locale(locale),
      settingsController: settings,
      home: BatchQueuePage(
        api: api,
        controller: queue,
        settingsController: settings,
        mobileOverride: false,
      ),
    ),
  );
  final label = StitchLocalizations.of(
    tester.element(find.byType(BatchQueuePage)),
  ).text('批处理资源设置');
  await tester.tap(find.byTooltip(label));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  _expectNoException(tester, '$locale $scale $viewport batch-resources-dialog');
  await _saveScreenshot(
    tester,
    locale,
    scale,
    viewport,
    'batch-resources-dialog',
  );
  await tester.pumpWidget(const SizedBox.shrink());
  settings.dispose();
}

Future<void> _resultShot(
  WidgetTester tester, {
  required String locale,
  required double scale,
  required String viewport,
  required bool showInformation,
}) async {
  final repositoryRoot = Directory(
    p.normalize(p.join(Directory.current.path, '..', '..', '..')),
  );
  final outputDirectory = Directory(
    p.join(repositoryRoot.path, '.local', 'manual-capture', 'native-result'),
  );
  final outputFile = File(p.join(outputDirectory.path, 'export.png'));
  final stat = await tester.runAsync(outputFile.stat);
  if (stat == null ||
      stat.type != FileSystemEntityType.file ||
      stat.size <= 0) {
    throw StateError('Native result export is unavailable: ${outputFile.path}');
  }
  final pyramidFiles = await tester.runAsync(
    () => outputDirectory
        .list(recursive: true, followLinks: false)
        .where(
          (entry) => entry is File && entry.path.toLowerCase().endsWith('.png'),
        )
        .cast<File>()
        .toList(),
  );
  if (pyramidFiles == null || pyramidFiles.isEmpty) {
    throw StateError('Native result pyramid has no PNG tiles.');
  }
  final relativeOutput = p.relative(
    outputFile.path,
    from: Directory.current.path,
  );
  final relativePyramid = p.relative(
    outputDirectory.path,
    from: Directory.current.path,
  );
  final fingerprint = ExportFileFingerprint(
    sizeBytes: stat.size,
    modifiedAtMicros: stat.modified.microsecondsSinceEpoch,
  );
  final viewerImages = <(File, Uint8List)>[];
  for (final file in pyramidFiles) {
    final bytes = await tester.runAsync(file.readAsBytes);
    if (bytes == null) throw StateError('Could not read native result tile.');
    viewerImages.add((file, bytes));
  }
  final cache = PaintingBinding.instance.imageCache;
  for (final (file, bytes) in viewerImages) {
    final provider = ResizeImage(FileImage(file), width: 512, height: 512);
    await _cacheDecodedImage(
      tester,
      cache,
      provider,
      bytes,
      targetWidth: 512,
      targetHeight: 512,
    );
  }

  tester.view.physicalSize = viewport == 'desktop'
      ? const Size(1280, 900)
      : const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  final settings = _settingsController(locale, scale);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureBoundaryKey,
      child: LumiaStitchApp(
        locale: Locale(locale),
        settingsController: settings,
        home: ExportedImageViewer(
          exportFilePath: relativeOutput,
          pyramidDirectory: relativePyramid,
          expectedExportFingerprint: fingerprint,
          legacyTaskAssociationPresent: false,
          legacyTaskBindingVerified: false,
        ),
      ),
    ),
  );
  await tester.pump();
  await _pumpRealFilesystemSurface(tester);
  await _pumpViewerTiles(tester);
  if (showInformation) {
    final label = StitchLocalizations.of(
      tester.element(find.byType(ExportedImageViewer)),
    ).text('查看输出信息');
    await tester.tap(find.byTooltip(label));
    await tester.pumpAndSettle();
  }
  _expectNoException(
    tester,
    '$locale $scale $viewport result${showInformation ? '-info-expanded' : ''}',
  );
  final shot = showInformation ? 'result-info-expanded' : 'result';
  await _saveScreenshot(tester, locale, scale, viewport, shot);
  await tester.pumpWidget(const SizedBox.shrink());
  settings.dispose();
}

Future<void> _pumpRealFilesystemSurface(WidgetTester tester) async {
  final deadline = Stopwatch()..start();
  while (deadline.elapsed < const Duration(seconds: 8) &&
      find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    find.byType(CircularProgressIndicator),
    findsNothing,
    reason: 'native result viewer source checks should settle',
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _pumpViewerTiles(WidgetTester tester) async {
  Finder unsettledTiles() => find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        (key.value.startsWith('viewer-tile-pending-') ||
            key.value.startsWith('viewer-tile-decoding-'));
  });
  for (
    var attempt = 0;
    attempt < 80 && unsettledTiles().evaluate().isNotEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
  expect(
    unsettledTiles(),
    findsNothing,
    reason: 'native pyramid tiles should load',
  );
}

Future<void> _pumpCapture(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(
    RepaintBoundary(key: _captureBoundaryKey, child: app),
  );
  await tester.pumpAndSettle();
}

void _expectNoException(WidgetTester tester, String surface) {
  expect(
    tester.takeException(),
    isNull,
    reason: 'Unexpected layout, rendering, or widget error in $surface',
  );
}

Future<void> _saveScreenshot(
  WidgetTester tester,
  String locale,
  double scale,
  String viewport,
  String shot,
) async {
  if (!_captureLargeTextQa) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureBoundaryKey),
  );
  final encoded = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes?.buffer.asUint8List();
  });
  if (encoded == null) throw StateError('Could not encode screenshot: $shot');

  final packageRoot = Directory.current;
  final repositoryRoot = Directory(
    p.normalize(p.join(packageRoot.path, '..', '..', '..')),
  );
  final qaDirectory = Directory(
    p.join(repositoryRoot.path, '.local', 'manual-capture', 'qa-widget'),
  );
  final fileName = '${locale}_${(scale * 100).round()}_${viewport}_$shot.png';
  await tester.runAsync(() async {
    await qaDirectory.create(recursive: true);
    await File(
      p.join(qaDirectory.path, fileName),
    ).writeAsBytes(encoded, flush: true);
  });

  // The bilingual manual receives one 150% desktop set. The complete viewport
  // and scale matrix remains in the QA directory for overflow review.
  if (scale == 1.5 && viewport == 'desktop') {
    final manualDirectory = Directory(
      p.join(repositoryRoot.path, 'docs', 'user-manual', 'screenshots'),
    );
    final manualPage = _manualPageForShot(shot);
    if (manualPage == null) return;
    await tester.runAsync(() async {
      await manualDirectory.create(recursive: true);
      await File(
        p.join(manualDirectory.path, '$locale-$manualPage.png'),
      ).writeAsBytes(encoded, flush: true);
    });
  }
}

String? _manualPageForShot(String shot) => switch (shot) {
  'home-synthetic-sources' => '01-home',
  'result' => '05-result',
  'home-arrangement-expanded' => '02-arrangement',
  'home-output-quality-expanded' => '03-output',
  'home-photo-preview' => '04-preview',
  'batch-empty-queue' => '06-queue',
  'settings-overview' => '07-settings',
  'settings-performance' => '08-performance',
  'settings-large-text' => '09-large-text',
  _ => null,
};

SettingsController _settingsController(String locale, double scale) =>
    SettingsController(
      repository: _NoOpSettingsRepository(),
      initial: AppSettings.defaults(mobile: false).copyWith(
        language: locale == 'en' ? AppLanguage.en : AppLanguage.zh,
        textSizeMode: TextSizeMode.custom,
        textScale: scale,
      ),
    );

class _NoOpSettingsRepository extends SettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();

  @override
  Future<void> save(AppSettings settings) async {}
}

class _NoOpPowerGate implements PowerGate {
  @override
  Future<PowerState> readState() async => PowerState.notRequired;
}

StitchTask _syntheticTask(List<ImportedPhoto> photos) => StitchTask(
  id: 'large-text-visual-fixture',
  createdAt: DateTime.utc(2026),
  sourceDirectory: 'synthetic-sources',
  outputDirectory: 'synthetic-output',
  photos: photos,
  grid: const GridOptions(mode: GridMode.sequence, rows: 2, columns: 3),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 512,
  workers: 4,
  phase: StitchPhase.imported,
  exportFormat: ExportFormat.png,
);

Future<void> _loadRealTestFont(WidgetTester tester) async {
  final fontBytes = await tester.runAsync(
    () => File(r'C:\Windows\Fonts\simhei.ttf').readAsBytes(),
  );
  if (fontBytes == null) {
    throw StateError('Could not load the Windows SimHei test font');
  }
  final loader = FontLoader('Roboto')
    ..addFont(SynchronousFuture<ByteData>(ByteData.sublistView(fontBytes)));
  await tester.runAsync(() async {
    await loader.load();
    return true;
  });
  final iconBytes = await tester.runAsync(
    () => File(
      r'D:\Flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
    ).readAsBytes(),
  );
  if (iconBytes == null) {
    throw StateError('Could not load the Flutter Material Icons font');
  }
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(SynchronousFuture<ByteData>(ByteData.sublistView(iconBytes)));
  await tester.runAsync(() async {
    await iconLoader.load();
    return true;
  });
}

Future<void> _primeSyntheticPhotoImages(
  WidgetTester tester,
  List<ImportedPhoto> photos,
  Map<String, Uint8List> jpegBytesByPath, {
  required int previewEdge,
}) async {
  final cache = PaintingBinding.instance.imageCache;
  for (final photo in photos) {
    final fileImage = FileImage(File(photo.storedPath));
    final bytes = jpegBytesByPath[photo.storedPath];
    if (bytes == null) {
      throw StateError('Missing synthetic JPEG bytes: ${photo.storedPath}');
    }
    await _cacheDecodedImage(
      tester,
      cache,
      fileImage,
      bytes,
      targetWidth: photo.width,
      targetHeight: photo.height,
    );
    await _cacheDecodedImage(
      tester,
      cache,
      ResizeImage(fileImage, width: 256),
      bytes,
      targetWidth: 256,
    );
    await _cacheDecodedImage(
      tester,
      cache,
      ResizeImage(
        fileImage,
        width: previewEdge,
        height: previewEdge,
        policy: ResizeImagePolicy.fit,
        allowUpscaling: false,
      ),
      bytes,
      targetWidth: photo.width,
      targetHeight: photo.height,
    );
  }
}

Future<void> _cacheDecodedImage(
  WidgetTester tester,
  ImageCache cache,
  ImageProvider<Object> provider,
  Uint8List jpegBytes, {
  required int targetWidth,
  int? targetHeight,
}) async {
  final key = await provider.obtainKey(ImageConfiguration.empty);
  if (cache.containsKey(key)) return;
  final decoded = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(
      jpegBytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  });
  if (decoded == null) {
    throw StateError('Could not decode synthetic JPEG image data');
  }
  cache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: decoded)),
    ),
  );
}

Future<(List<ImportedPhoto>, Map<String, Uint8List>)> _loadSyntheticJpegPhotos(
  WidgetTester tester,
) async {
  final repositoryRoot = Directory(
    p.normalize(p.join(Directory.current.path, '..', '..', '..')),
  );
  final originalRoot = Directory(
    p.join(repositoryRoot.path, '.local', 'manual-capture', 'originals'),
  );
  final loaded = await tester.runAsync(() async {
    final result = <ImportedPhoto>[];
    final bytesByPath = <String, Uint8List>{};
    for (var row = 1; row <= 2; row++) {
      for (var column = 1; column <= 3; column++) {
        final name =
            'row_${row.toString().padLeft(2, '0')}_col_${column.toString().padLeft(2, '0')}.jpg';
        final file = File(p.join(originalRoot.path, name));
        final bytes = await file.readAsBytes();
        if (bytes.length < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) {
          throw StateError('Synthetic sample is not a JPEG: ${file.path}');
        }
        result.add(
          ImportedPhoto(
            originalName: name,
            storedPath: file.path,
            sha256: sha256.convert(bytes).toString(),
            width: 640,
            height: 400,
            originalOrder: result.length,
          ),
        );
        bytesByPath[file.path] = bytes;
      }
    }
    return (result, bytesByPath);
  });
  if (loaded == null) {
    throw StateError('Could not load synthetic JPEG fixtures');
  }
  return loaded;
}
