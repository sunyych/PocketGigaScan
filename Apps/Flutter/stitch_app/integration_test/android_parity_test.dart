import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:stitch_app/main.dart' show LumiaStitchApp, StitchHomePage;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/mobile_runtime_service.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/photo_importer.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/spherical_request.dart';
import 'package:stitch_app/services/mobile_storage_service.dart';
import 'package:stitch_app/widgets/exported_image_viewer.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android FFI renders a 2x2 fixture and exports PNG, TIFF, and JXL; task deletion keeps outputs',
    (tester) async {
      const sourcePath = String.fromEnvironment(
        'TEST_ANDROID_PARITY_SOURCE_DIR',
      );
      expect(
        sourcePath,
        isNotEmpty,
        reason:
            'Pass TEST_ANDROID_PARITY_SOURCE_DIR with a generated 2x2 JPEG fixture folder.',
      );
      final source = Directory(sourcePath);
      expect(await source.exists(), isTrue, reason: sourcePath);
      final inputs = await source
          .list(followLinks: false)
          .where(
            (entry) =>
                entry is File &&
                const {
                  '.jpg',
                  '.jpeg',
                }.contains(p.extension(entry.path).toLowerCase()),
          )
          .cast<File>()
          .toList();
      inputs.sort((a, b) => a.path.compareTo(b.path));
      expect(inputs, hasLength(4), reason: 'The Android fixture must be 2×2.');

      final api = NativeJobApi();
      expect(api.isAvailable, isTrue, reason: api.unavailableReason);
      final capsResponse = await api.capabilities();
      final caps = capsResponse['capabilities']! as Map<String, Object?>;
      expect(caps['jpegXlAvailable'], isTrue);

      final appSupport = await getApplicationSupportDirectory();
      final temp = Directory(
        p.join(
          appSupport.path,
          'android-parity-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        ),
      );
      await temp.create(recursive: true);
      final taskRepository = TaskRepository(
        rootDirectory: Directory(p.join(temp.path, 'task-records')),
      );
      final queueController = BatchQueueController(
        api: api,
        taskRepository: taskRepository,
        queueRepository: BatchQueueRepository(
          rootDirectory: Directory(p.join(temp.path, 'queues')),
        ),
        requireLargeJobApproval: true,
      );
      final runtime = MobileRuntimeService();
      final completedTasks = <StitchTask>[];
      final guardedJobs = <String>[];
      try {
        final resources = await runtime.readResourceBudget();
        await api.configureResources(
          totalCpuWorkers: resources.recommendedTotalCpuWorkers,
          totalMemoryBudgetMiB: resources.recommendedTotalMemoryBudgetMiB,
          maxConcurrentJobs: resources.recommendedMaxConcurrentJobs,
        );
        for (final format in ExportFormat.values) {
          final photos = <ImportedPhoto>[];
          for (var index = 0; index < inputs.length; index++) {
            final file = inputs[index];
            final metadata = await readJpegMetadata(file);
            photos.add(
              ImportedPhoto(
                originalName: p.basename(file.path),
                storedPath: file.path,
                sha256: sha256.convert(await file.readAsBytes()).toString(),
                width: metadata.width,
                height: metadata.height,
                originalOrder: index,
                exifMake: metadata.make,
                exifModel: metadata.model,
                exifLensModel: metadata.lensModel,
                exifFocalLengthMm: metadata.focalLengthMm,
              ),
            );
          }
          expect(
            photos.every(
              (photo) =>
                  photo.width == photos.first.width &&
                  photo.height == photos.first.height,
            ),
            isTrue,
          );
          final id = taskRepository.createId();
          final renderDirectory = Directory(p.join(temp.path, id, 'render'));
          final task = StitchTask(
            id: id,
            createdAt: DateTime.now(),
            sourceDirectory: source.path,
            outputDirectory: renderDirectory.path,
            photos: photos,
            grid: const GridOptions(
              mode: GridMode.filename,
              rows: 2,
              columns: 2,
            ),
            horizontalFovDegrees:
                2 *
                math.atan(
                  photos.first.width /
                      (2 * 75000.0 * photos.first.width / 3840),
                ) *
                180 /
                math.pi,
            memoryBudgetMiB: 128,
            workers: 1,
            phase: StitchPhase.imported,
            cameraProfileId: 'dwarf3-tele-nominal-150mm',
            exportFormat: format,
            refineGridNeighbors: true,
            localTextureWarp: true,
          );
          await renderDirectory.create(recursive: true);
          final started = await api.start(
            buildSphericalRequest(task),
            renderDirectory.path,
            memoryBudgetMiB: 128,
            workers: 1,
          );
          final jobId = started['jobId'] as String;
          guardedJobs.add(jobId);
          expect(
            await runtime.setProcessingActive(true, jobId: jobId),
            isTrue,
            reason: 'Android foreground guard should acknowledge $jobId.',
          );
          var state = started;
          for (var attempt = 0; attempt < 900; attempt++) {
            if (state['state'] == 'completed') break;
            if (state['state'] == 'failed' || state['state'] == 'cancelled') {
              fail('Android render failed for ${format.name}: $state');
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
            state = await api.status(jobId);
          }
          expect(state['state'], 'completed', reason: 'Render ${format.name}');
          final destination = p.join(temp.path, '$id.${format.extension}');
          state = await api.export(jobId, destination);
          for (var attempt = 0; attempt < 900; attempt++) {
            if (state['state'] == 'completed') break;
            if (state['state'] == 'failed' || state['state'] == 'cancelled') {
              fail('Android ${format.name} export failed: $state');
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
            state = await api.status(jobId);
          }
          expect(state['state'], 'completed', reason: 'Export ${format.name}');
          final output = File(destination);
          expect(await output.exists(), isTrue);
          expect(await output.length(), greaterThan(0));
          final outputBytes = await output.open();
          final header = await outputBytes.read(12);
          await outputBytes.close();
          switch (format) {
            case ExportFormat.png:
              expect(header.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
              break;
            case ExportFormat.tiff:
              expect(
                header.take(4),
                anyOf([
                  [0x49, 0x49, 42, 0],
                  [0x49, 0x49, 43, 0],
                ]),
              );
              break;
            case ExportFormat.jpegXl:
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
              break;
          }
          final fingerprint = await taskRepository.fingerprintFile(destination);
          expect(fingerprint, isNotNull);
          final completed = task.copyWith(
            nativeJobId: jobId,
            phase: StitchPhase.completed,
            stage: 'done',
            exportPath: destination,
            exportFingerprint: fingerprint,
          );
          await taskRepository.save(completed);
          completedTasks.add(completed);
          expect(
            await runtime.setProcessingActive(false, jobId: jobId),
            isTrue,
          );
          guardedJobs.remove(jobId);
        }

        final screenshots = <String>[];
        var surfaceConverted = false;
        for (final locale in const [Locale('en'), Locale('zh')]) {
          final selected = completedTasks.first;
          await _setDeviceOrientation(tester, DeviceOrientation.portraitUp);
          await tester.pumpWidget(
            LumiaStitchApp(
              locale: locale,
              home: StitchHomePage(
                jobApi: api,
                repository: taskRepository,
                batchQueueController: queueController,
                initialTask: selected,
                mobileOverride: true,
                androidOverride: true,
                mobileRuntimeService: runtime,
              ),
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          if (!surfaceConverted) {
            await binding.convertFlutterSurfaceToImage();
            await tester.pump();
            surfaceConverted = true;
          }
          final portrait = 'android-home-${locale.languageCode}-portrait';
          await binding.takeScreenshot(portrait);
          screenshots.add(portrait);
          await _setDeviceOrientation(tester, DeviceOrientation.landscapeLeft);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          final landscape = 'android-home-${locale.languageCode}-landscape';
          await binding.takeScreenshot(landscape);
          screenshots.add(landscape);
          await _setDeviceOrientation(tester, DeviceOrientation.portraitUp);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          final openViewer = find.byKey(const Key('open-exported-image'));
          await tester.ensureVisible(openViewer);
          await tester.tap(openViewer);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          expect(find.textContaining('输出格式：'), findsNothing);
          expect(find.textContaining('Output format:'), findsNothing);
          expect(find.textContaining('输出文件：'), findsNothing);
          expect(find.textContaining('Output file:'), findsNothing);
          await binding.takeScreenshot(
            'android-viewer-${locale.languageCode}-portrait',
          );
          screenshots.add('android-viewer-${locale.languageCode}-portrait');
          expect(
            find.byTooltip(
              locale.languageCode == 'zh'
                  ? '查看输出信息'
                  : 'View output information',
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.byTooltip(
              locale.languageCode == 'zh'
                  ? '查看输出信息'
                  : 'View output information',
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.textContaining(
              locale.languageCode == 'zh'
                  ? '输出文件：${selected.exportPath!}'
                  : 'Output file: ${selected.exportPath!}',
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.byTooltip(
              locale.languageCode == 'zh'
                  ? '收起输出信息'
                  : 'Hide output information',
            ),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('输出文件：'), findsNothing);
          await tester.pageBack();
          await tester.pumpAndSettle();

          await tester.tap(
            find.byTooltip(
              locale.languageCode == 'zh' ? '批处理队列' : 'Batch queue',
            ),
          );
          await tester.pumpAndSettle();
          final queuePortrait = 'android-queue-${locale.languageCode}-portrait';
          await binding.takeScreenshot(queuePortrait);
          screenshots.add(queuePortrait);
          await _setDeviceOrientation(tester, DeviceOrientation.landscapeLeft);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          final queueLandscape =
              'android-queue-${locale.languageCode}-landscape';
          await binding.takeScreenshot(queueLandscape);
          screenshots.add(queueLandscape);
          await _setDeviceOrientation(tester, DeviceOrientation.portraitUp);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          await tester.tap(
            find.byTooltip(
              locale.languageCode == 'zh'
                  ? '批处理资源设置'
                  : 'Batch resource settings',
            ),
          );
          await tester.pumpAndSettle();
          final optionsPortrait =
              'android-queue-options-${locale.languageCode}-portrait';
          await binding.takeScreenshot(optionsPortrait);
          screenshots.add(optionsPortrait);
          await _setDeviceOrientation(tester, DeviceOrientation.landscapeLeft);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          final optionsLandscape =
              'android-queue-options-${locale.languageCode}-landscape';
          await binding.takeScreenshot(optionsLandscape);
          screenshots.add(optionsLandscape);
          await _setDeviceOrientation(tester, DeviceOrientation.portraitUp);
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          await tester.pageBack();
          await tester.pumpAndSettle();
        }
        for (final task in completedTasks) {
          final mimeType = switch (task.exportFormat) {
            ExportFormat.png => 'image/png',
            ExportFormat.tiff => 'image/tiff',
            ExportFormat.jpegXl => 'image/jxl',
          };
          await tester.pumpWidget(
            LumiaStitchApp(
              locale: const Locale('en'),
              home: ExportedImageViewer(
                exportFilePath: task.exportPath!,
                pyramidDirectory: task.outputDirectory,
                expectedExportFingerprint: task.exportFingerprint,
                legacyTaskAssociationPresent: false,
                legacyTaskBindingVerified: true,
                mobileStorageService: const MobileStorageService(),
                exportMimeType: mimeType,
              ),
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          final screenshot = 'android-viewer-format-${task.exportFormat.name}';
          await binding.takeScreenshot(screenshot);
          screenshots.add(screenshot);
          expect(find.byTooltip('Save full image'), findsOneWidget);
          expect(find.byTooltip('Share full image'), findsOneWidget);
          expect(find.textContaining('Output file:'), findsNothing);
          final viewerFinder = find.byKey(
            const ValueKey('exported-image-interactive-viewer'),
          );
          final interactiveViewer = tester.widget<InteractiveViewer>(
            viewerFinder,
          );
          expect(interactiveViewer.panEnabled, isTrue);
          expect(interactiveViewer.scaleEnabled, isTrue);
          expect(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Positioned &&
                      widget.key is ValueKey<String> &&
                      (widget.key! as ValueKey<String>).value.startsWith(
                        'viewer-tile-',
                      ),
                )
                .evaluate()
                .length,
            lessThanOrEqualTo(4),
          );
          final transform = interactiveViewer.transformationController!;
          final startScale = transform.value.getMaxScaleOnAxis();
          final center = tester.getCenter(viewerFinder);
          final firstFinger = await tester.startGesture(
            center - const Offset(35, 0),
            pointer: 1,
          );
          final secondFinger = await tester.startGesture(
            center + const Offset(35, 0),
            pointer: 2,
          );
          await firstFinger.moveTo(center - const Offset(70, 0));
          await secondFinger.moveTo(center + const Offset(70, 0));
          await tester.pump(const Duration(milliseconds: 150));
          expect(
            transform.value.getMaxScaleOnAxis(),
            greaterThan(startScale),
            reason: '${task.exportFormat.name} pinch should zoom the viewer',
          );
          await firstFinger.up();
          await secondFinger.up();
          final scaleAfterPinch = transform.value.getMaxScaleOnAxis();
          final manifestFile = File(
            p.join(task.outputDirectory, 'manifest.json'),
          );
          final manifest = Map<String, Object?>.from(
            jsonDecode(await manifestFile.readAsString()) as Map,
          );
          final imageWidth = (manifest['width']! as num).toDouble();
          final imageHeight = (manifest['height']! as num).toDouble();
          final viewport = tester.getSize(viewerFinder);
          final horizontalPanAvailable =
              imageWidth * scaleAfterPinch > viewport.width + 1;
          final verticalPanAvailable =
              imageHeight * scaleAfterPinch > viewport.height + 1;
          expect(
            horizontalPanAvailable || verticalPanAvailable,
            isTrue,
            reason:
                '${task.exportFormat.name} pinch should leave at least one pannable image axis',
          );
          final panDelta = horizontalPanAvailable
              ? const Offset(-40, 0)
              : const Offset(0, -40);
          final beforePan = transform.value.clone();
          final panStart = tester.getCenter(viewerFinder);
          final pan = await tester.startGesture(panStart, pointer: 3);
          await pan.moveBy(panDelta);
          await tester.pump(const Duration(milliseconds: 100));
          await pan.up();
          final translationChanged =
              (transform.value.entry(0, 3) - beforePan.entry(0, 3)).abs() >
                  0.1 ||
              (transform.value.entry(1, 3) - beforePan.entry(1, 3)).abs() > 0.1;
          expect(
            translationChanged,
            isTrue,
            reason:
                '${task.exportFormat.name} one-finger drag should change viewer translation',
          );
          expect(
            transform.value.getMaxScaleOnAxis(),
            scaleAfterPinch,
            reason: 'Single-finger drag should pan without changing zoom',
          );
        }
        expect(screenshots, hasLength(17));

        for (final task in completedTasks) {
          await taskRepository.removeTaskRecord(task.id);
          expect(await File(task.exportPath!).exists(), isTrue);
          expect(await File(task.photos.first.storedPath).exists(), isTrue);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await SystemChrome.setPreferredOrientations(const []);
        for (final jobId in guardedJobs) {
          await runtime.setProcessingActive(false, jobId: jobId);
        }
        await runtime.dispose();
        queueController.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}

Future<void> _setDeviceOrientation(
  WidgetTester tester,
  DeviceOrientation orientation,
) async {
  final expectedLandscape =
      orientation == DeviceOrientation.landscapeLeft ||
      orientation == DeviceOrientation.landscapeRight;
  Size logicalSize() {
    final views = tester.binding.platformDispatcher.views;
    if (views.isEmpty) return Size.zero;
    final view = views.first;
    return Size(
      view.physicalSize.width / view.devicePixelRatio,
      view.physicalSize.height / view.devicePixelRatio,
    );
  }

  bool matches(Size size) =>
      !size.isEmpty && (size.width > size.height) == expectedLandscape;

  final alreadyInOrientation = matches(logicalSize());
  final metricsObserver = _OrientationMetricsObserver();
  tester.binding.addObserver(metricsObserver);
  try {
    await SystemChrome.setPreferredOrientations([orientation]);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final actualSize = logicalSize();
      if (matches(actualSize) &&
          (alreadyInOrientation || metricsObserver.changed)) {
        await tester.pump();
        return;
      }
    }
    fail(
      'Timed out waiting for $orientation metrics; actual logical size is ${logicalSize()}',
    );
  } finally {
    tester.binding.removeObserver(metricsObserver);
  }
}

class _OrientationMetricsObserver with WidgetsBindingObserver {
  bool changed = false;

  @override
  void didChangeMetrics() => changed = true;
}
