import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/export_fingerprint.dart';
import 'package:stitch_app/services/mobile_storage_service.dart';
import 'package:stitch_app/widgets/exported_image_viewer.dart';
import 'support/chinese_test_app.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOIWnAJAAMkAc2CFM/BAAAAAElFTkSuQmCC',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExportedImageViewer', () {
    late Directory root;
    late File output;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('export-viewer-');
      _testRoot = root;
      await Directory('${root.path}/level-0').create(recursive: true);
      await Directory('${root.path}/level-1').create(recursive: true);
      await Directory('${root.path}/level-2').create(recursive: true);
      output = File('${root.path}/panorama.jxl');
      _testOutput = output;
      await output.writeAsBytes([1, 2, 3, 4]);
      await _writePyramid(root);
    });

    tearDown(() async {
      await root.delete(recursive: true);
      _testRoot = null;
      _testOutput = null;
    });

    testWidgets('export details stay hidden until opened and can be closed', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      await tester.pumpWidget(_viewer());
      await _pumpViewer(tester);
      await _pumpTileImages(tester);

      expect(find.textContaining('panorama.jxl'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      final visibleText = find
          .byType(Text)
          .evaluate()
          .map((element) => (element.widget as Text).data)
          .whereType<String>()
          .join(' | ');
      expect(visibleText, isNot(contains('旧任务没有导出指纹')));
      expect(visibleText, isNot(contains('预览来自任务金字塔')));
      expect(find.text('4096 × 2048 px'), findsOneWidget);

      await tester.tap(find.byTooltip('查看输出信息'));
      await tester.pumpAndSettle();
      expect(find.textContaining('输出格式：JPEG XL'), findsOneWidget);
      expect(find.textContaining('输出文件：${output.path}'), findsOneWidget);
      expect(find.textContaining('旧任务没有导出指纹'), findsOneWidget);
      expect(find.textContaining('预览来自任务金字塔'), findsOneWidget);

      await tester.tap(find.byTooltip('收起输出信息'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      expect(find.textContaining('旧任务没有导出指纹'), findsNothing);

      await tester.tap(find.byTooltip('查看输出信息'));
      await tester.pumpAndSettle();
      final nextOutput = File('${root.path}/next-panorama.tif');
      await _fileIo(tester, () => nextOutput.writeAsBytes([5, 6, 7, 8]));
      await tester.pumpWidget(
        ChineseTestApp(
          home: ExportedImageViewer(
            exportFilePath: nextOutput.path,
            pyramidDirectory: root.path,
            expectedExportFingerprint: null,
            legacyTaskAssociationPresent: true,
            legacyTaskBindingVerified: true,
          ),
        ),
      );
      await _pumpViewer(tester);
      expect(find.text('next-panorama.tif'), findsOneWidget);
      expect(find.byTooltip('查看输出信息'), findsOneWidget);
      expect(find.byTooltip('收起输出信息'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('narrow mobile layout supports maximum pyramid dimensions', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await _fileIo(tester, () => _writeMaximumPyramid(root));
      await tester.pumpWidget(_viewer());
      await _pumpViewer(tester);
      await _pumpTileImages(tester);

      expect(find.text('131072 × 131072 px'), findsOneWidget);
      expect(find.byTooltip('查看输出信息'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/128-128.png')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/0-0.png')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/255-255.png')),
        findsOneWidget,
      );

      await tester.tap(find.text('100%'));
      await _pumpViewer(tester);
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/128-128.png')),
        findsOneWidget,
        reason: 'zooming into a 131072-square panorama retains center tiles',
      );
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/0-0.png')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/255-255.png')),
        findsNothing,
      );

      final viewer = find.byType(InteractiveViewer);
      var edgePan = await tester.startGesture(
        tester.getCenter(viewer),
        pointer: 81,
      );
      await edgePan.moveBy(const Offset(100000, 100000));
      await edgePan.up();
      await _pumpViewer(tester);
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/0-0.png')),
        findsOneWidget,
        reason: 'panning to the image origin reveals its corner tile',
      );
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/128-128.png')),
        findsNothing,
        reason: 'the previous center tile leaves the instantiated tile cache',
      );

      edgePan = await tester.startGesture(
        tester.getCenter(viewer),
        pointer: 82,
      );
      await edgePan.moveBy(const Offset(-200000, -200000));
      await edgePan.up();
      await _pumpViewer(tester);
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/255-255.png')),
        findsOneWidget,
        reason: 'panning to the opposite image boundary reveals the far tile',
      );
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/0-0.png')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('mobile save and share forward PNG TIFF and JXL MIME types', (
      tester,
    ) async {
      const channel = MethodChannel('test/exported-image-storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const formats = <(String, String)>[
        ('.png', 'image/png'),
        ('.tif', 'image/tiff'),
        ('.jxl', 'image/jxl'),
      ];

      for (final (extension, mimeType) in formats) {
        final formatOutput = File('${root.path}/mobile$extension');
        await _fileIo(tester, () => formatOutput.writeAsBytes([1, 2, 3]));
        await tester.pumpWidget(
          ChineseTestApp(
            home: ExportedImageViewer(
              exportFilePath: formatOutput.path,
              pyramidDirectory: root.path,
              expectedExportFingerprint: null,
              legacyTaskAssociationPresent: true,
              legacyTaskBindingVerified: true,
              mobileStorageService: const MobileStorageService(
                channel: channel,
              ),
              exportMimeType: mimeType,
            ),
          ),
        );
        await _pumpViewer(tester);
        expect(find.textContaining('输出文件：'), findsNothing);
        expect(find.byType(SelectableText), findsNothing);
        await tester.tap(find.byTooltip('保存整图'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('分享整图'));
        await tester.pumpAndSettle();
      }

      expect(calls.map((call) => call.arguments['mimeType']), [
        'image/png',
        'image/png',
        'image/tiff',
        'image/tiff',
        'image/jxl',
        'image/jxl',
      ]);
    });

    testWidgets('rejects a missing output file', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final missing = File('${root.path}/missing.tif');
      await tester.pumpWidget(
        ChineseTestApp(
          home: ExportedImageViewer(
            exportFilePath: missing.path,
            pyramidDirectory: root.path,
            expectedExportFingerprint: null,
            legacyTaskAssociationPresent: true,
            legacyTaskBindingVerified: true,
          ),
        ),
      );
      await _pumpViewer(tester);

      expect(find.textContaining('导出文件不存在'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('rejects output modified since fingerprint capture', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final fingerprint = (await _fileIo(tester, () => _fingerprint(output)))!;
      await _fileIo(tester, () => output.writeAsBytes([5, 6, 7, 8, 9]));
      await tester.pumpWidget(_viewer(fingerprint: fingerprint));
      await _pumpViewer(tester);

      expect(find.textContaining('导出文件的大小或修改时间已变化'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('rejects unbound legacy output and manifest traversal', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(
        _viewer(legacyBound: false, legacyPresent: false),
      );
      await _pumpViewer(tester);
      expect(find.textContaining('无法确认导出文件与此任务的关联'), findsOneWidget);

      await _fileIo(
        tester,
        () => _writePyramid(root, tilePath: '../../outside.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_viewer());
      await _pumpViewer(tester);
      expect(find.textContaining('预览瓦片路径或坐标无效'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('shows unverified legacy association without blocking it', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpWidget(_viewer(legacyBound: false, legacyPresent: true));
      await _pumpViewer(tester);
      expect(find.textContaining('核心未核验导出记录'), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('查看输出信息'));
      await tester.pumpAndSettle();
      expect(find.textContaining('核心未核验导出记录'), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('accepts sparse levels used for transparent image areas', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final manifestFile = File('${root.path}/manifest.json');
      final manifestText = (await _fileIo(tester, manifestFile.readAsString))!;
      final manifest = Map<String, Object?>.from(
        jsonDecode(manifestText) as Map,
      );
      final levels = (manifest['levels'] as List)
          .map((value) => Map<String, Object?>.from(value as Map))
          .toList();
      levels.first['occupied'] = List<Object?>.from(
        levels.first['occupied'] as List,
      )..removeLast();
      manifest['levels'] = levels;
      await _fileIo(
        tester,
        () => manifestFile.writeAsString(jsonEncode(manifest)),
      );

      await tester.pumpWidget(_viewer());
      await _pumpViewer(tester);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.textContaining('预览瓦片覆盖范围不完整'), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('fit and 100 percent change scale and visible LOD', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final fingerprint = (await _fileIo(tester, () => _fingerprint(output)))!;
      await tester.pumpWidget(_viewer(fingerprint: fingerprint));
      await _pumpViewer(tester);

      expect(
        _visibleText(tester),
        contains('预览层级 2'),
        reason: 'initial fit LOD: ${_visibleText(tester)}',
      );
      await tester.tap(find.text('100%'));
      await _pumpViewer(tester);
      expect(find.textContaining('预览层级 0'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.byTooltip('适合窗口'));
      await _pumpViewer(tester);
      await _pumpTileImages(tester);
      expect(
        _visibleText(tester),
        contains('预览层级 2'),
        reason: 'after fit LOD must return to the fit-resolution pyramid level',
      );
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('mouse wheel zooms around its pointer', (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final fingerprint = (await _fileIo(tester, () => _fingerprint(output)))!;
      await tester.pumpWidget(_viewer(fingerprint: fingerprint));
      await _pumpViewer(tester);
      await tester.tap(find.text('100%'));
      await _pumpViewer(tester);

      final interactive = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final before = interactive.transformationController!.value;
      expect(before.getMaxScaleOnAxis(), closeTo(0.5, 0.001));
      final viewerRect = tester.getRect(find.byType(InteractiveViewer));
      final cursor = viewerRect.center + const Offset(90, 35);
      final localCursor = cursor - viewerRect.topLeft;
      final oldPoint = MatrixUtils.transformPoint(
        Matrix4.inverted(before),
        localCursor,
      );
      final event = PointerScrollEvent(
        position: cursor,
        scrollDelta: const Offset(0, -120),
        device: 13,
      );
      tester.binding.handlePointerEvent(event);
      await _pumpViewer(tester);

      final after = interactive.transformationController!.value;
      final newPoint = MatrixUtils.transformPoint(
        Matrix4.inverted(after),
        localCursor,
      );
      expect(
        after.getMaxScaleOnAxis(),
        greaterThan(before.getMaxScaleOnAxis()),
      );
      expect((oldPoint - newPoint).distance, lessThan(0.01));
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('primary mouse drag pans the panorama', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final fingerprint = (await _fileIo(tester, () => _fingerprint(output)))!;
      await tester.pumpWidget(_viewer(fingerprint: fingerprint));
      await _pumpViewer(tester);
      await tester.tap(find.text('100%'));
      await _pumpViewer(tester);
      final viewer = find.byType(InteractiveViewer);
      final start = tester.getCenter(viewer);
      final before = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value
          .clone();
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
      );
      await gesture.moveBy(const Offset(-70, -45));
      await gesture.up();
      await _pumpViewer(tester);
      final after = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value;
      expect(after.entry(0, 3), isNot(before.entry(0, 3)));
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('touch pinch zooms and one-finger drag pans', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final fingerprint = (await _fileIo(tester, () => _fingerprint(output)))!;
      await tester.pumpWidget(_viewer(fingerprint: fingerprint));
      await _pumpViewer(tester);
      await tester.tap(find.text('100%'));
      await _pumpViewer(tester);

      final viewer = find.byType(InteractiveViewer);
      final controller = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      final center = tester.getCenter(viewer);
      final initialScale = controller.value.getMaxScaleOnAxis();
      final firstStart = center - const Offset(40, 0);
      final secondStart = center + const Offset(40, 0);
      final first = await tester.startGesture(firstStart, pointer: 71);
      final second = await tester.startGesture(secondStart, pointer: 72);
      await first.moveTo(center - const Offset(90, 0));
      await second.moveTo(center + const Offset(90, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await _pumpViewer(tester);
      expect(
        controller.value.getMaxScaleOnAxis(),
        greaterThan(initialScale),
        reason: 'two touch pointers spread apart should zoom the pyramid',
      );

      final beforePan = controller.value.clone();
      final pan = await tester.startGesture(center, pointer: 73);
      await pan.moveBy(const Offset(-70, -45));
      await pan.up();
      await _pumpViewer(tester);
      expect(controller.value.entry(0, 3), isNot(beforePan.entry(0, 3)));
      expect(controller.value.entry(1, 3), isNot(beforePan.entry(1, 3)));
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('only visible pyramid tiles become image widgets', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(900, 700));
      final fingerprint = (await _fileIo(tester, () => _fingerprint(output)))!;
      await tester.pumpWidget(_viewer(fingerprint: fingerprint));
      await _pumpViewer(tester);
      await _pumpTileImages(tester);
      // The test panorama is only 4×8 level-0 tiles; at the default desktop
      // DPR its fitted width occupies nearly the full viewport, so all 32 can
      // legitimately intersect the viewport. At 100%, culling becomes visible.
      expect(find.byType(Image).evaluate().length, lessThanOrEqualTo(32));
      await tester.tap(find.text('100%'));
      await _pumpViewer(tester);
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/0-7.png')),
        findsNothing,
        reason: 'center zoom must not instantiate the far-right corner tile',
      );
      final viewer = find.byType(InteractiveViewer);
      final center = tester.getCenter(viewer);
      final pan = await tester.startGesture(center, pointer: 74);
      await pan.moveBy(const Offset(1000, 500));
      await pan.up();
      await _pumpViewer(tester);
      await _pumpTileImages(tester);
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/0-0.png')),
        findsOneWidget,
        reason: 'panning toward the upper-left reveals its edge tile',
      );
      expect(
        find.byKey(const ValueKey('viewer-tile-level-0/0-4.png')),
        findsNothing,
        reason: 'tiles from the old center viewport leave the visible cache',
      );
      expect(
        find.byType(Image).evaluate().length,
        lessThan(32),
        reason: 'zooming into one viewport should cull offscreen pyramid tiles',
      );
      await tester.binding.setSurfaceSize(null);
    });
  });

  testWidgets('current viewer desktop state screenshots', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(1180, 800));
    final output = File('build/viewer-golden-output.jxl');
    final missingOutput = File('build/viewer-golden-missing.jxl');
    await _fileIo(tester, () async {
      await output.parent.create(recursive: true);
      await output.writeAsBytes([1, 2, 3, 4]);
      if (await missingOutput.exists()) await missingOutput.delete();
    });
    addTearDown(
      () => _fileIo(tester, () async {
        if (await output.exists()) await output.delete();
      }),
    );
    addTearDown(
      () => _fileIo(tester, () async {
        if (await missingOutput.exists()) await missingOutput.delete();
      }),
    );
    final root = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumia-viewer-states-golden',
    );
    await _fileIo(tester, () async {
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
    });
    addTearDown(() async {
      await root.delete(recursive: true);
      await tester.binding.setSurfaceSize(null);
    });
    for (var level = 0; level <= 2; level++) {
      await _fileIo(
        tester,
        () => Directory('${root.path}/level-$level').create(recursive: true),
      );
    }
    await _fileIo(tester, () => _writePyramid(root));
    final fingerprint = (await _fileIo(tester, () => _fingerprint(output)))!;

    Future<void> capture(
      String state,
      ExportFileFingerprint? expected, {
      String? exportPath,
      bool legacyVerified = true,
      bool showInformation = false,
    }) async {
      await tester.pumpWidget(
        ChineseTestApp(
          home: ExportedImageViewer(
            exportFilePath: exportPath ?? output.path,
            pyramidDirectory: root.path,
            expectedExportFingerprint: expected,
            legacyTaskAssociationPresent: true,
            legacyTaskBindingVerified: expected == null && legacyVerified,
          ),
        ),
      );
      await _pumpViewer(tester);
      await _pumpTileImages(tester);
      if (showInformation) {
        await tester.tap(find.byTooltip('查看输出信息'));
        await tester.pumpAndSettle();
      }
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      await expectLater(
        find.byType(ExportedImageViewer),
        matchesGoldenFile('goldens/exported_image_viewer_$state.png'),
      );
    }

    await capture('verified_fit', fingerprint);
    await tester.tap(find.text('100%'));
    await _pumpViewer(tester);
    await _pumpTileImages(tester);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    await expectLater(
      find.byType(ExportedImageViewer),
      matchesGoldenFile('goldens/exported_image_viewer_100_percent.png'),
    );

    await capture('legacy_warning', null);
    await capture('legacy_warning_expanded', null, showInformation: true);
    await capture('legacy_unverified', null, legacyVerified: false);
    await capture(
      'fingerprint_mismatch',
      const ExportFileFingerprint(sizeBytes: 99, modifiedAtMicros: 1),
    );
    await capture(
      'missing_output',
      fingerprint,
      exportPath: missingOutput.path,
    );
    await tester.binding.setSurfaceSize(null);
  });
}

Widget _viewer({
  ExportFileFingerprint? fingerprint,
  bool legacyBound = true,
  bool legacyPresent = true,
}) => ChineseTestApp(
  home: ExportedImageViewer(
    exportFilePath: _currentOutputPath,
    pyramidDirectory: _currentRootPath,
    expectedExportFingerprint: fingerprint,
    legacyTaskAssociationPresent: legacyPresent,
    legacyTaskBindingVerified: legacyBound,
  ),
);

// Test groups update these before constructing each widget.
String get _currentRootPath => _testRoot!.path;
String get _currentOutputPath => _testOutput!.path;
Directory? _testRoot;
File? _testOutput;

Future<ExportFileFingerprint> _fingerprint(File file) async {
  final stat = await file.stat();
  return ExportFileFingerprint(
    sizeBytes: stat.size,
    modifiedAtMicros: stat.modified.microsecondsSinceEpoch,
  );
}

Future<void> _writePyramid(
  Directory root, {
  String tilePath = 'level-2/0-0.png',
}) async {
  final level0 = <Map<String, Object?>>[];
  for (var row = 0; row < 4; row++) {
    for (var column = 0; column < 8; column++) {
      final path = 'level-0/$row-$column.png';
      level0.add(_tile(row, column, 512, 512, path));
      await File('${root.path}/$path').writeAsBytes(_png);
    }
  }
  final level1 = <Map<String, Object?>>[];
  for (var row = 0; row < 2; row++) {
    for (var column = 0; column < 4; column++) {
      final path = 'level-1/$row-$column.png';
      level1.add(_tile(row, column, 512, 512, path));
      await File('${root.path}/$path').writeAsBytes(_png);
    }
  }
  final level2 = <Map<String, Object?>>[];
  for (var column = 0; column < 2; column++) {
    final path = column == 0 ? tilePath : 'level-2/0-1.png';
    level2.add(_tile(0, column, 512, 512, path));
    if (!path.contains('..')) {
      await File('${root.path}/$path').writeAsBytes(_png);
    }
  }
  await File('${root.path}/manifest.json').writeAsString(
    jsonEncode({
      'complete': true,
      'schemaVersion': 1,
      'projection': 'spherical',
      'tileSize': 512,
      'width': 4096,
      'height': 2048,
      'levels': [
        {'level': 0, 'width': 4096, 'height': 2048, 'occupied': level0},
        {'level': 1, 'width': 2048, 'height': 1024, 'occupied': level1},
        {'level': 2, 'width': 1024, 'height': 512, 'occupied': level2},
      ],
    }),
  );
}

Map<String, Object?> _tile(
  int row,
  int column,
  int width,
  int height,
  String path,
) => {
  'row': row,
  'column': column,
  'width': width,
  'height': height,
  'path': path,
};

Future<void> _writeMaximumPyramid(Directory root) async {
  const maximumDimension = 131072;
  const paths = [
    'level-0/0-0.png',
    'level-0/128-128.png',
    'level-0/255-255.png',
  ];
  for (final path in paths) {
    await File('${root.path}/$path').writeAsBytes(_png);
  }
  await File('${root.path}/manifest.json').writeAsString(
    jsonEncode({
      'complete': true,
      'schemaVersion': 1,
      'projection': 'spherical',
      'tileSize': 512,
      'width': maximumDimension,
      'height': maximumDimension,
      'levels': [
        {
          'level': 0,
          'width': maximumDimension,
          'height': maximumDimension,
          'occupied': [
            _tile(0, 0, 512, 512, paths[0]),
            _tile(128, 128, 512, 512, paths[1]),
            _tile(255, 255, 512, 512, paths[2]),
          ],
        },
      ],
    }),
  );
}

Future<void> _pumpViewer(WidgetTester tester) async {
  // Viewer source validation and tile lookup use real filesystem futures.
  // Pump bounded real-time slices instead of pumpAndSettle: the loading
  // indicator intentionally animates while those operations are pending.
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
  expect(
    find.byType(CircularProgressIndicator),
    findsNothing,
    reason: 'viewer source checks should settle within five seconds',
  );
  // Allow a decoded tile image and post-frame fit transform to reach the tree.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _pumpTileImages(WidgetTester tester) async {
  Finder unsettledTiles() => find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        (key.value.startsWith('viewer-tile-pending-') ||
            key.value.startsWith('viewer-tile-decoding-'));
  });

  for (
    var attempt = 0;
    attempt < 50 && unsettledTiles().evaluate().isNotEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  expect(
    unsettledTiles(),
    findsNothing,
    reason:
        'visible tile files and image decoders should settle within five seconds',
  );
}

Future<T?> _fileIo<T>(WidgetTester tester, Future<T> Function() action) =>
    tester.runAsync(action);

String _visibleText(WidgetTester tester) => find
    .byType(Text)
    .evaluate()
    .map((element) => (element.widget as Text).data)
    .whereType<String>()
    .join(' | ');
