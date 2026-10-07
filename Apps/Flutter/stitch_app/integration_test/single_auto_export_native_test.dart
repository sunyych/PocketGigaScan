import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/photo_importer.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';

class _CountingApi implements JobApi {
  _CountingApi(this.inner);

  final NativeJobApi inner;
  int exportCalls = 0;

  @override
  bool get isAvailable => inner.isAvailable;
  @override
  String? get unavailableReason => inner.unavailableReason;
  @override
  Future<Map<String, Object?>> capabilities() => inner.capabilities();
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) => inner.configureResources(
    totalCpuWorkers: totalCpuWorkers,
    totalMemoryBudgetMiB: totalMemoryBudgetMiB,
    maxConcurrentJobs: maxConcurrentJobs,
  );
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) => inner.start(
    request,
    outputDirectory,
    memoryBudgetMiB: memoryBudgetMiB,
    workers: workers,
  );
  @override
  Future<Map<String, Object?>> status(String jobId) => inner.status(jobId);
  @override
  Future<Map<String, Object?>> pause(String jobId) => inner.pause(jobId);
  @override
  Future<Map<String, Object?>> resume(String jobId) => inner.resume(jobId);
  @override
  Future<Map<String, Object?>> cancel(String jobId) => inner.cancel(jobId);
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) {
    exportCalls++;
    return inner.export(jobId, destination);
  }
}

class _IsolatedTaskRepository extends TaskRepository {
  _IsolatedTaskRepository(this.directory);
  final Directory directory;

  @override
  Future<Directory> root() async {
    await directory.create(recursive: true);
    return directory;
  }
}

class _NoopForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

Future<Directory> _findFourPhotoFolder(Directory parent) async {
  Future<bool> hasFourJpegs(Directory directory) async {
    var count = 0;
    await for (final child in directory.list(followLinks: false)) {
      if (child is File &&
          const {
            '.jpg',
            '.jpeg',
          }.contains(p.extension(child.path).toLowerCase())) {
        count++;
      }
    }
    return count == 4;
  }

  if (await hasFourJpegs(parent)) return parent;
  await for (final child in parent.list(followLinks: false)) {
    if (child is Directory && await hasFourJpegs(child)) return child;
  }
  throw StateError(
    'Fixture must contain four JPEGs directly or in a direct child folder.',
  );
}

Future<List<ImportedPhoto>> _copyAndReadPhotos(
  Directory source,
  Directory destination,
) async {
  await destination.create(recursive: true);
  final files = await source
      .list(followLinks: false)
      .where(
        (entity) =>
            entity is File &&
            const {
              '.jpg',
              '.jpeg',
            }.contains(p.extension(entity.path).toLowerCase()),
      )
      .cast<File>()
      .toList();
  files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  final photos = <ImportedPhoto>[];
  for (var index = 0; index < files.length; index++) {
    final original = files[index];
    final copy = await original.copy(
      p.join(destination.path, p.basename(original.path)),
    );
    final metadata = await readJpegMetadata(copy);
    final digest = await sha256.bind(copy.openRead()).first;
    photos.add(
      ImportedPhoto(
        originalName: p.basename(original.path),
        storedPath: copy.path,
        sha256: digest.toString(),
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
  return photos;
}

Future<T> _runReal<T>(WidgetTester tester, Future<T> Function() action) async {
  final result = await tester.runAsync(action);
  if (result == null) {
    throw StateError('Real asynchronous operation returned null.');
  }
  return result;
}

Future<Finder> _visibleAfterScroll(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  final visible = target.hitTestable();
  expect(visible, findsOneWidget);
  return visible;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('TEST_SINGLE_AUTO_NATIVE');

  testWidgets(
    'Windows single task automatically exports PNG, TIFF, and JPEG XL once (requires TEST_SINGLE_AUTO_NATIVE and TEST_SINGLE_AUTO_PARENT_DIR)',
    (tester) async {
      expect(Platform.isWindows, isTrue, reason: 'Requires Windows FFI.');
      const parentPath = String.fromEnvironment('TEST_SINGLE_AUTO_PARENT_DIR');
      expect(
        parentPath,
        isNotEmpty,
        reason:
            'Pass --dart-define=TEST_SINGLE_AUTO_PARENT_DIR=<fixture parent>.',
      );
      final parent = Directory(parentPath);
      expect(await _runReal(tester, parent.exists), isTrue, reason: parentPath);
      final source = await _runReal(tester, () => _findFourPhotoFolder(parent));
      final temporary = await _runReal(
        tester,
        () => Directory.systemTemp.createTemp('lumia-single-auto-export-'),
      );
      final sourceCopy = Directory(p.join(temporary.path, 'source'));
      final photos = await _runReal(
        tester,
        () => _copyAndReadPhotos(source, sourceCopy),
      );
      expect(photos, hasLength(4));
      expect(
        photos.every(
          (photo) =>
              photo.width == photos.first.width &&
              photo.height == photos.first.height,
        ),
        isTrue,
      );

      final api = _CountingApi(NativeJobApi());
      expect(api.isAvailable, isTrue, reason: api.unavailableReason);
      final capabilities = await _runReal(tester, api.capabilities);
      final caps = capabilities['capabilities']! as Map<String, Object?>;
      expect(
        (caps['activeJobs'] as num).toInt(),
        0,
        reason:
            'Use a dedicated Windows app process for this integration test.',
      );
      expect(caps['jpegXlAvailable'], isTrue);

      final repository = _IsolatedTaskRepository(
        Directory(p.join(temporary.path, 'tasks')),
      );
      final documents = await _runReal(
        tester,
        getApplicationDocumentsDirectory,
      );
      final exportedPaths = <String>[];
      final activeJobIds = <String>{};
      try {
        for (final format in ExportFormat.values) {
          final id = repository.createId();
          final taskDirectory = await _runReal(
            tester,
            () => repository.directoryFor(id),
          );
          final task = StitchTask(
            id: id,
            createdAt: DateTime.now(),
            sourceDirectory: sourceCopy.path,
            outputDirectory: p.join(taskDirectory.path, 'output'),
            photos: photos,
            grid: const GridOptions(
              mode: GridMode.sequence,
              rows: 2,
              columns: 2,
            ),
            horizontalFovDegrees: 45,
            memoryBudgetMiB: 512,
            workers: 1,
            phase: StitchPhase.imported,
            autoGridOverlap: true,
            exportFormat: format,
            autoExportOnCompletion: true,
            refineGridNeighbors: false,
            seamBlendMode: SeamBlendMode.feather,
            localTextureWarp: false,
          );
          await tester.runAsync(() async {
            await repository.save(task);
          });
          await tester.pumpWidget(
            LumiaStitchApp(
              locale: const Locale('zh', 'CN'),
              home: StitchHomePage(
                initialTask: task,
                jobApi: api,
                repository: repository,
                foregroundWorkLock: _NoopForegroundLock(),
                mobileOverride: false,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final startButton = await _visibleAfterScroll(
            tester,
            find.text('开始合成'),
          );
          await tester.tap(startButton);
          await tester.pump();

          StitchTask? finished;
          final deadline = DateTime.now().add(const Duration(minutes: 10));
          while (DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 500));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 500)),
            );
            finished = await _runReal(tester, () => repository.loadById(id));
            final jobId = finished?.nativeJobId;
            if (jobId != null) activeJobIds.add(jobId);
            if (finished?.exportPath != null) break;
            if (finished?.stage == 'export-failed' ||
                finished?.phase == StitchPhase.failed ||
                finished?.phase == StitchPhase.cancelled) {
              fail(
                'Native ${format.shortLabel} task failed: ${finished?.error}',
              );
            }
          }
          expect(
            finished?.phase,
            StitchPhase.completed,
            reason:
                'Native ${format.shortLabel} auto-export exceeded ten minutes.',
          );
          expect(finished?.autoExportOnCompletion, isFalse);
          expect(finished?.exportPath, endsWith('.${format.extension}'));
          final exportPath = finished!.exportPath!;
          final finishedJobId = finished.nativeJobId!;
          activeJobIds.remove(finishedJobId);
          exportedPaths.add(exportPath);
          final output = File(exportPath);
          expect(await _runReal(tester, output.exists), isTrue);
          expect(await _runReal(tester, output.length), greaterThan(1024));
          expect(api.exportCalls, exportedPaths.length);
          final status = await _runReal(
            tester,
            () => api.status(finishedJobId),
          );
          expect(status['state'], 'completed');
          expect(status['operation'], 'export');
          expect(status['exportDestination'], exportPath);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      } finally {
        await tester.runAsync(() async {
          for (final jobId in activeJobIds) {
            try {
              await api.cancel(jobId);
            } on Object {
              // The native job may already have reached a terminal state.
            }
          }
          for (final path in exportedPaths) {
            final file = File(path);
            if (await file.exists() &&
                p.isWithin(p.join(documents.path, 'LumiaStitch'), file.path)) {
              await file.delete();
            }
          }
          await temporary.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(hours: 1)),
    skip: !enabled,
  );
}
