import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';

class _IsolatedTaskRepository extends TaskRepository {
  _IsolatedTaskRepository(this.directory);

  final Directory directory;

  @override
  Future<Directory> root() async {
    await directory.create(recursive: true);
    return directory;
  }
}

Future<void> _copyFixture(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final outputDirectory = Directory(
      p.join(destination.path, p.basename(entity.path)),
    );
    await outputDirectory.create(recursive: true);
    await for (final child in entity.list(followLinks: false)) {
      if (child is! File ||
          !const {
            '.jpg',
            '.jpeg',
          }.contains(p.extension(child.path).toLowerCase())) {
        continue;
      }
      await child.copy(p.join(outputDirectory.path, p.basename(child.path)));
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('TEST_BATCH_NATIVE');

  testWidgets(
    'native batch stitches two DWARF3 Tele folders and skips the empty folder (requires TEST_BATCH_NATIVE and TEST_BATCH_PARENT_DIR)',
    (tester) async {
      await tester.runAsync(() async {
        expect(
          Platform.isWindows,
          isTrue,
          reason: 'This native batch integration test requires Windows FFI.',
        );
        const fixturePath = String.fromEnvironment('TEST_BATCH_PARENT_DIR');
        expect(
          fixturePath,
          isNotEmpty,
          reason:
              'Pass --dart-define=TEST_BATCH_PARENT_DIR=<parent-originals fixture>.',
        );
        final fixtureParent = Directory(fixturePath);
        expect(await fixtureParent.exists(), isTrue, reason: fixturePath);

        final temporary = await Directory.systemTemp.createTemp(
          'lumia-native-batch-test-',
        );
        final isolatedFixture = Directory(
          p.join(temporary.path, 'parent-originals'),
        );
        final api = NativeJobApi();
        final taskRepository = _IsolatedTaskRepository(
          Directory(p.join(temporary.path, 'tasks')),
        );
        final queueRepository = BatchQueueRepository(
          rootDirectory: Directory(p.join(temporary.path, 'queues')),
        );
        final controller = BatchQueueController(
          api: api,
          queueRepository: queueRepository,
          taskRepository: taskRepository,
        );
        var nativeJobIds = <String>{};
        try {
          await _copyFixture(fixtureParent, isolatedFixture);
          expect(api.isAvailable, isTrue, reason: api.unavailableReason);
          final initial = await api.capabilities();
          final initialCaps = initial['capabilities']! as Map<String, Object?>;
          expect(initialCaps['backend'], 'cpu-rust-tiled');
          expect(initialCaps['gpuAvailable'], isFalse);
          expect(
            initialCaps['activeJobs'],
            0,
            reason:
                'Run this integration in a dedicated Windows app process so it cannot alter another native queue.',
          );
          final cpuLimit = (initialCaps['totalCpuWorkers'] as num).toInt();
          final memoryLimit = (initialCaps['totalMemoryBudgetMiB'] as num)
              .toInt();
          final jobLimit = (initialCaps['maxConcurrentJobs'] as num).toInt();
          expect(cpuLimit, greaterThanOrEqualTo(1));
          expect(memoryLimit, greaterThanOrEqualTo(512));
          expect(jobLimit, greaterThanOrEqualTo(1));

          await controller.initialize();
          await controller.addParent(isolatedFixture.path);
          expect(controller.error, isNull, reason: controller.error);
          expect(controller.queues, hasLength(1));
          final queueId = controller.queues.single.id;
          final importedItems = controller.queues.single.items;
          expect(importedItems, hasLength(3));
          expect(
            importedItems.where((item) => item.state == BatchItemState.skipped),
            hasLength(1),
          );
          expect(
            importedItems.where(
              (item) =>
                  item.state != BatchItemState.skipped && item.taskId != null,
            ),
            hasLength(2),
            reason:
                'The fixture should contain two four-photo folders and one empty folder.',
          );

          for (final item in importedItems.where(
            (item) =>
                item.state != BatchItemState.skipped && item.taskId != null,
          )) {
            final task = await taskRepository.loadById(item.taskId!);
            expect(task, isNotNull);
            expect(task!.photos, hasLength(4));
            expect(task.grid.rows, 2);
            expect(task.grid.columns, 2);
            expect(task.cameraProfileId, 'dwarf3-tele-nominal-150mm');
            expect(
              task.photos.every((photo) => photo.isVerifiedDwarf3Tele),
              isTrue,
            );
            expect(
              task.photos.every(
                (photo) =>
                    photo.exifFocalLengthMm != null &&
                    (photo.exifFocalLengthMm! - 150).abs() < 0.1,
              ),
              isTrue,
            );
          }

          var peakJobs = 0;
          var peakWorkers = 0;
          var peakMemory = 0;
          final deadline = DateTime.now().add(const Duration(minutes: 5));
          while (DateTime.now().isBefore(deadline)) {
            await controller.tick();
            final capabilityResponse = await api.capabilities();
            final caps =
                capabilityResponse['capabilities']! as Map<String, Object?>;
            final activeJobs = (caps['activeJobs'] as num).toInt();
            final reservedWorkers = (caps['reservedWorkers'] as num).toInt();
            final reservedMemory = (caps['reservedMemoryMiB'] as num).toInt();
            expect(activeJobs, lessThanOrEqualTo(jobLimit));
            expect(reservedWorkers, lessThanOrEqualTo(cpuLimit));
            expect(reservedMemory, lessThanOrEqualTo(memoryLimit));
            if (activeJobs > peakJobs) peakJobs = activeJobs;
            if (reservedWorkers > peakWorkers) peakWorkers = reservedWorkers;
            if (reservedMemory > peakMemory) peakMemory = reservedMemory;

            final items = controller.queues
                .singleWhere((queue) => queue.id == queueId)
                .items;
            final terminal = items.every(
              (item) =>
                  item.state == BatchItemState.completed ||
                  item.state == BatchItemState.skipped ||
                  item.state == BatchItemState.failed ||
                  item.state == BatchItemState.cancelled,
            );
            if (terminal) break;
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }

          final finished = controller.queues.singleWhere(
            (queue) => queue.id == queueId,
          );
          expect(
            finished.items.where(
              (item) => item.state == BatchItemState.completed,
            ),
            hasLength(2),
          );
          expect(
            finished.items.where(
              (item) => item.state == BatchItemState.skipped,
            ),
            hasLength(1),
          );
          expect(
            finished.items.where(
              (item) =>
                  item.state == BatchItemState.failed ||
                  item.state == BatchItemState.cancelled,
            ),
            isEmpty,
          );
          final expectedConcurrentJobs =
              jobLimit >= 2 && cpuLimit >= 2 && memoryLimit >= 1024 ? 2 : 1;
          expect(peakJobs, greaterThanOrEqualTo(expectedConcurrentJobs));
          expect(peakWorkers, lessThanOrEqualTo(cpuLimit));
          expect(peakMemory, lessThanOrEqualTo(memoryLimit));

          final completed = finished.items
              .where((item) => item.state == BatchItemState.completed)
              .toList();
          final exportPaths = <String>{};
          for (final item in completed) {
            final task = await taskRepository.loadById(item.taskId!);
            expect(task, isNotNull);
            final pngPath = task!.exportPath;
            expect(pngPath, isNotNull);
            final png = File(pngPath!);
            exportPaths.add(p.normalize(png.absolute.path));
            expect(await png.exists(), isTrue, reason: pngPath);
            expect(await png.length(), greaterThan(0), reason: pngPath);
          }
          expect(exportPaths, hasLength(2));

          final resourceDeadline = DateTime.now().add(
            const Duration(seconds: 10),
          );
          Map<String, Object?> finalCaps = const {};
          do {
            final finalCapsResponse = await api.capabilities();
            finalCaps =
                finalCapsResponse['capabilities']! as Map<String, Object?>;
            if (finalCaps['activeJobs'] == 0 &&
                finalCaps['reservedWorkers'] == 0 &&
                finalCaps['reservedMemoryMiB'] == 0) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } while (DateTime.now().isBefore(resourceDeadline));
          expect(finalCaps['activeJobs'], 0);
          expect(finalCaps['reservedWorkers'], 0);
          expect(finalCaps['reservedMemoryMiB'], 0);
        } finally {
          for (final queue in controller.queues) {
            for (final item in queue.items) {
              final task = item.taskId == null
                  ? null
                  : await taskRepository.loadById(item.taskId!);
              final nativeJobId = task?.nativeJobId;
              if (nativeJobId != null) nativeJobIds.add(nativeJobId);
            }
          }
          controller.dispose();
          for (final jobId in nativeJobIds) {
            try {
              final status = await api.status(jobId);
              final state = status['state'];
              if (state == 'running' ||
                  state == 'queued' ||
                  state == 'pausing') {
                await api.cancel(jobId);
              }
            } on Object {
              // The test's assertions report the primary failure.
            }
          }
          final cleanupDeadline = DateTime.now().add(
            const Duration(seconds: 10),
          );
          var resourcesReleased = false;
          do {
            try {
              final response = await api.capabilities();
              final caps = response['capabilities']! as Map<String, Object?>;
              resourcesReleased =
                  caps['activeJobs'] == 0 &&
                  caps['reservedWorkers'] == 0 &&
                  caps['reservedMemoryMiB'] == 0;
            } on Object {
              break;
            }
            if (resourcesReleased) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } while (DateTime.now().isBefore(cleanupDeadline));
          if (resourcesReleased && await temporary.exists()) {
            await temporary.delete(recursive: true);
          } else if (await temporary.exists()) {
            // Keep source/output files alive if native workers did not unwind.
            // This diagnostic preserves the original failure instead of racing them.
            debugPrint(
              'Native batch cleanup timed out; kept ${temporary.path} alive.',
            );
          }
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip: !enabled,
  );
}
