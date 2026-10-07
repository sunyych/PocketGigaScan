import 'dart:io';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/main.dart' show LumiaStitchApp;
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/batch_queue_page.dart';

Future<Directory> _copyFourPhotoFolder(
  Directory source,
  Directory destination,
) async {
  Directory? selected;
  var files = <File>[];
  await for (final entity in source.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final candidates = <File>[];
    await for (final child in entity.list(followLinks: false)) {
      if (child is File &&
          const {
            '.jpg',
            '.jpeg',
          }.contains(p.extension(child.path).toLowerCase())) {
        candidates.add(child);
      }
    }
    if (candidates.length == 4) {
      selected = entity;
      files = candidates;
      break;
    }
  }
  if (selected == null) {
    throw StateError('Fixture requires a direct folder with four JPEGs.');
  }
  files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  final target = Directory(p.join(destination.path, p.basename(selected.path)));
  await target.create(recursive: true);
  for (final file in files) {
    await file.copy(p.join(target.path, p.basename(file.path)));
  }
  return target;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('TEST_JXL_NATIVE');

  testWidgets(
    'Windows batch exports JPEG XL and metadata-only task removal retains files (requires TEST_JXL_NATIVE and TEST_JXL_PARENT_DIR)',
    (tester) async {
      await tester.runAsync(() async {
        expect(Platform.isWindows, isTrue, reason: 'Requires Windows FFI.');
        const fixturePath = String.fromEnvironment('TEST_JXL_PARENT_DIR');
        expect(
          fixturePath,
          isNotEmpty,
          reason: 'Pass --dart-define=TEST_JXL_PARENT_DIR=<folder>.',
        );
        final fixture = Directory(fixturePath);
        expect(await fixture.exists(), isTrue, reason: fixturePath);
        final temporary = await Directory.systemTemp.createTemp(
          'lumia-jxl-test-',
        );
        final isolatedFixture = Directory(p.join(temporary.path, 'fixture'));
        final taskRepository = TaskRepository(
          rootDirectory: Directory(p.join(temporary.path, 'tasks')),
        );
        final queueRepository = BatchQueueRepository(
          rootDirectory: Directory(p.join(temporary.path, 'queues')),
        );
        final api = NativeJobApi();
        final controller = BatchQueueController(
          api: api,
          taskRepository: taskRepository,
          queueRepository: queueRepository,
        );
        try {
          await _copyFourPhotoFolder(fixture, isolatedFixture);
          expect(api.isAvailable, isTrue, reason: api.unavailableReason);
          final capabilities = await api.capabilities();
          final caps = capabilities['capabilities']! as Map<String, Object?>;
          expect(caps['jpegXlAvailable'], isTrue);
          expect(
            caps['jpegXlLossless'],
            isFalse,
            reason: 'JPEG XL output uses lossy RGB with lossless alpha.',
          );
          await controller.initialize();
          await controller.addParent(
            isolatedFixture.path,
            outputFormat: ExportFormat.jpegXl,
          );
          final queue = controller.queues.single;
          expect(queue.outputFormat, ExportFormat.jpegXl);
          var item = queue.items.single;
          var task = (await taskRepository.loadById(item.taskId!))!;
          final originalFiles = [
            for (final photo in task.photos) File(photo.storedPath),
          ];
          final originalBytes = [
            for (final file in originalFiles) await file.readAsBytes(),
          ];
          if (item.state == BatchItemState.needsSettings) {
            await controller.setSettings(
              queueId: queue.id,
              itemId: item.id,
              rows: task.grid.rows,
              columns: task.grid.columns,
              horizontalFovDegrees: task.horizontalFovDegrees,
            );
          }
          final deadline = DateTime.now().add(const Duration(minutes: 5));
          while (DateTime.now().isBefore(deadline)) {
            await controller.tick();
            item = controller.queues.single.items.single;
            if (item.state == BatchItemState.completed) break;
            if (item.state == BatchItemState.failed ||
                item.state == BatchItemState.cancelled) {
              fail('JXL batch ended in ${item.state}: ${item.message}');
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          expect(item.state, BatchItemState.completed);
          task = (await taskRepository.loadById(item.taskId!))!;
          final output = File(task.exportPath!);
          expect(p.extension(output.path).toLowerCase(), '.jxl');
          expect(await output.exists(), isTrue);
          final exportedBytes = await output.readAsBytes();
          expect(task.exportFormat, ExportFormat.jpegXl);
          expect(task.resultStats?['exportFormat'], 'jxl');
          expect(task.resultStats?['compression'], 'lossy');
          expect(task.resultStats?['alpha'], 'lossless-alpha');
          expect(task.exportFingerprint?.sizeBytes, await output.length());
          final stat = await output.stat();
          expect(
            task.exportFingerprint?.modifiedAtMicros,
            stat.modified.microsecondsSinceEpoch,
          );
          final handle = await output.open();
          final header = await handle.read(12);
          await handle.close();
          expect(header, [
            0,
            0,
            0,
            12,
            0x4a,
            0x58,
            0x4c,
            0x20,
            0x0d,
            0x0a,
            0x87,
            0x0a,
          ]);
          expect(
            await File(p.join(task.outputDirectory, 'manifest.json')).exists(),
            isTrue,
          );
          expect(originalFiles, hasLength(4));
          for (var index = 0; index < originalFiles.length; index++) {
            expect(
              await originalFiles[index].readAsBytes(),
              originalBytes[index],
            );
          }

          await tester.pumpWidget(
            LumiaStitchApp(
              locale: const Locale('zh', 'CN'),
              home: BatchQueuePage(
                api: api,
                controller: controller,
                mobileOverride: false,
              ),
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(find.byTooltip('打开全景查看器'), findsOneWidget);
          await tester.tap(find.byTooltip('打开全景查看器'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(find.textContaining(output.path), findsNothing);
          expect(find.textContaining('JPEG XL'), findsNothing);
          expect(find.byTooltip('查看输出信息'), findsOneWidget);
          await tester.tap(find.byTooltip('查看输出信息'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(find.textContaining(output.path), findsOneWidget);
          expect(find.textContaining('输出格式：JPEG XL'), findsOneWidget);
          expect(find.byTooltip('收起输出信息'), findsOneWidget);
          await tester.tap(find.byTooltip('收起输出信息'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(find.textContaining(output.path), findsNothing);
          expect(find.textContaining('JPEG XL'), findsNothing);
          expect(find.byTooltip('查看输出信息'), findsOneWidget);
          final manifest =
              jsonDecode(
                    await File(
                      p.join(task.outputDirectory, 'manifest.json'),
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          expect(
            find.text('${manifest['width']} × ${manifest['height']} px'),
            findsOneWidget,
          );
          expect(find.byType(InteractiveViewer), findsOneWidget);
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
          expect(find.byType(Image), findsWidgets);
          expect(find.byIcon(Icons.broken_image_outlined), findsNothing);

          final viewer = find.byType(InteractiveViewer);
          expect(viewer, findsOneWidget);
          await tester.tap(find.text('100%'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          var transform = tester
              .widget<InteractiveViewer>(viewer)
              .transformationController!
              .value
              .clone();
          final scaleBeforeZoom = transform.getMaxScaleOnAxis();
          final viewport = tester.getRect(viewer);
          final mouse = await tester.createGesture(
            pointer: 17,
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: viewport.center);
          await mouse.moveTo(viewport.center, view: tester.view);
          await tester.pump();
          await tester.sendEventToBinding(
            PointerScrollEvent(
              viewId: tester.view.viewId,
              position: viewport.center,
              scrollDelta: const Offset(0, -120),
              device: 1,
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          await mouse.removePointer();
          transform = tester
              .widget<InteractiveViewer>(viewer)
              .transformationController!
              .value
              .clone();
          expect(
            transform.getMaxScaleOnAxis(),
            greaterThan(scaleBeforeZoom),
            reason: 'zoom must still work after collapsing output information',
          );
          final panStart = tester.getCenter(viewer);
          final translationBeforePan = transform.entry(0, 3);
          final pan = await tester.startGesture(
            panStart,
            kind: PointerDeviceKind.mouse,
            buttons: kPrimaryButton,
            view: tester.view,
          );
          await pan.moveBy(const Offset(-70, -45), view: tester.view);
          await pan.up(view: tester.view);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          transform = tester
              .widget<InteractiveViewer>(viewer)
              .transformationController!
              .value;
          expect(
            transform.entry(0, 3),
            isNot(translationBeforePan),
            reason: 'pan must still work after collapsing output information',
          );

          await tester.pageBack();
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          await tester.tap(find.byTooltip('删除本地任务记录'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(find.text('删除任务记录'), findsOneWidget);
          await tester.tap(find.text('删除任务记录'));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          final reloadedRepository = TaskRepository(
            rootDirectory: Directory(p.join(temporary.path, 'tasks')),
          );
          expect(await reloadedRepository.loadById(item.taskId!), isNull);
          expect(await reloadedRepository.loadAll(), isEmpty);
          expect(controller.queues.single.items, isEmpty);
          expect(await output.readAsBytes(), exportedBytes);
          for (var index = 0; index < originalFiles.length; index++) {
            expect(
              await originalFiles[index].readAsBytes(),
              originalBytes[index],
            );
          }
        } finally {
          controller.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (await temporary.exists()) await temporary.delete(recursive: true);
        }
      });
    },
    skip: !enabled,
  );
}
