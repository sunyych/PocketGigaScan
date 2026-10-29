// Opt-in real-device acceptance harness. By default this test is skipped so
// ordinary `flutter test` runs never scan removable volumes or copy user data.
// Run with USB_DWARF_HARDWARE=1 and USB_DWARF_ROOT=G:\Panoramas.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/usb_dwarf_import_service.dart';

const _defaultPanoramaName = 'DWARF_PANORAMA_2026-10-23-14-01-48-371';
const _expectedPhotoCount = 312;
const _expectedPhotoBytes = 302216496;
const _expectedWidth = 3840;
const _expectedHeight = 2160;
const _expectedPreviewBytes = 33880;

void main() {
  final enabled = Platform.environment['USB_DWARF_HARDWARE'] == '1';
  test(
    'real USB DWARF import remains local, complete, and deduplicated',
    () async {
      final mountedRoot =
          Platform.environment['USB_DWARF_ROOT'] ?? r'G:\Panoramas';
      final panoramaName =
          Platform.environment['USB_DWARF_NAME'] ?? _defaultPanoramaName;
      final expectedDirectory = p.normalize(p.join(mountedRoot, panoramaName));
      final removableRoot = p.normalize(p.dirname(mountedRoot));
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        ':',
        '-',
      );
      final packageRoot = await _findPackageRoot();
      final repositoryRoot = Directory(
        p.normalize(p.join(packageRoot.path, '..', '..', '..')),
      );
      final evidenceBase = Directory(
        p.join(repositoryRoot.path, '.local', 'usb-dwarf-hardware-20261029'),
      );
      await evidenceBase.create(recursive: true);
      final evidenceRoot = await evidenceBase.createTemp('run-$timestamp-');
      final report = <String, Object?>{
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'sourceRoot': mountedRoot,
        'sourceDirectory': expectedDirectory,
        'evidenceRoot': evidenceRoot.path,
        'checks': <String, Object?>{},
      };
      final checks = report['checks']! as Map<String, Object?>;
      BatchQueueController? activeController;
      try {
        _NeverScheduleJobApi.startCalls = 0;
        final deviceRoot = Directory(removableRoot);
        if (!await deviceRoot.exists()) {
          throw StateError('USB volume is not mounted: $removableRoot');
        }
        final sourceDirectory = Directory(expectedDirectory);
        if (!await sourceDirectory.exists()) {
          throw StateError(
            'Expected panorama folder is missing: $expectedDirectory',
          );
        }

        // Use production's default drive scan and volume identity detection.
        // A same-named fixed-disk copy must not become a second USB candidate.
        final priorityService = UsbDwarfImportService(
          supportDirectory: () =>
              Directory(p.join(evidenceRoot.path, 'priority-history')),
        );
        final allSources = await priorityService.discover();
        final matches = allSources
            .where(
              (source) =>
                  p.basename(source.directory).toLowerCase() ==
                  panoramaName.toLowerCase(),
            )
            .toList();
        final deviceMatches = matches
            .where((source) => p.equals(source.directory, expectedDirectory))
            .toList();
        final deviceSource = deviceMatches.isEmpty ? null : deviceMatches.first;
        expect(
          deviceSource,
          isNotNull,
          reason: 'Real G: panorama must be discoverable',
        );
        expect(
          deviceSource!.isRemovable,
          isTrue,
          reason: 'G: must be recognized as removable',
        );
        if (matches.length > 1) {
          expect(matches.first.isRemovable, isTrue);
          expect(
            p.equals(matches.first.directory, expectedDirectory),
            isTrue,
            reason:
                'Removable G: must rank ahead of a same-named D: local copy',
          );
        }
        expect(
          matches.where((source) => !source.isRemovable),
          isEmpty,
          reason:
              'A same-named fixed-disk copy must not be offered as a second USB import',
        );
        checks['discoveryPriority'] = {
          'matchedSources': matches.map((source) => source.directory).toList(),
          'selected': deviceSource.directory,
          'removable': deviceSource.isRemovable,
        };

        final selected = await priorityService.selectMaximumPhotos(
          expectedDirectory,
        );
        expect(
          selected,
          hasLength(_expectedPhotoCount),
          reason: 'Only full-resolution root originals should be selected',
        );
        final selectedBytes = selected.fold<int>(
          0,
          (sum, photo) => sum + photo.length,
        );
        expect(selectedBytes, _expectedPhotoBytes);
        final sourceFiles = selected.map((photo) => photo.file.path).toSet();
        expect(sourceFiles.length, _expectedPhotoCount);
        expect(
          sourceFiles.every(
            (path) => p.equals(p.dirname(path), expectedDirectory),
          ),
          isTrue,
          reason:
              'The 1–5 subfolders are smaller thumbnail sets and must not be selected',
        );
        final sourceHashes = <String, String>{};
        for (final photo in selected) {
          sourceHashes[p.basename(photo.file.path).toLowerCase()] =
              (await sha256.bind(photo.file.openRead()).first).toString();
        }
        checks['sourceSelection'] = {
          'count': selected.length,
          'totalBytes': selectedBytes,
          'files': selected
              .map((photo) => p.basename(photo.file.path))
              .toList(),
          'sha256': sourceHashes,
        };

        // Use isolated repositories for the controller exercise. Discovery
        // retains the production default drive scan; app data stays local.
        var now = DateTime.now();
        final testRoot = Directory(
          p.join(evidenceRoot.path, 'controller-evidence'),
        );
        final historyRoot = Directory(p.join(testRoot.path, 'support'));
        final queuesRoot = Directory(p.join(testRoot.path, 'queues'));
        final tasksRoot = Directory(p.join(testRoot.path, 'tasks'));
        final service = UsbDwarfImportService(
          supportDirectory: () => historyRoot,
          clock: () => now,
        );
        final queueRepository = BatchQueueRepository(rootDirectory: queuesRoot);
        final taskRepository = TaskRepository(rootDirectory: tasksRoot);
        BatchQueueController createController() => BatchQueueController(
          api: _NeverScheduleJobApi(),
          queueRepository: queueRepository,
          taskRepository: taskRepository,
          usbImportService: service,
          clock: () => now,
        );

        var controller = createController();
        activeController = controller;
        await controller.initialize();
        final beforeDiscoverTasks = await _countFiles(tasksRoot);
        expect(
          beforeDiscoverTasks,
          0,
          reason: 'Discovery must not copy or create task data',
        );
        final firstAdded = await controller.discoverUsbDwarf();
        List<(BatchQueue, BatchQueueItem)> targetEntries() => [
          for (final candidateQueue in controller.queues.where(
            (candidate) => candidate.usbSource,
          ))
            for (final candidate in candidateQueue.items)
              if (p.equals(candidate.sourceDirectory, expectedDirectory))
                (candidateQueue, candidate),
        ];
        Future<void> removeUnrelatedItems() async {
          for (final candidateQueue
              in controller.queues
                  .where((candidate) => candidate.usbSource)
                  .toList()) {
            for (final candidate in candidateQueue.items.toList()) {
              if (!p.equals(candidate.sourceDirectory, expectedDirectory)) {
                await controller.removeQueueItem(
                  candidateQueue.id,
                  candidate.id,
                );
              }
            }
          }
        }

        expect(
          targetEntries(),
          hasLength(1),
          reason: 'Exactly one G: source item should be queued',
        );
        expect(targetEntries().single.$2.taskId, isNull);
        expect(
          targetEntries().single.$1.deleteUsbSources,
          isFalse,
          reason: 'The real USB source must remain untouched',
        );
        // Prevent unrelated panoramas on other mounted volumes from being
        // copied during this focused run. These edits affect only temp data.
        await removeUnrelatedItems();
        expect(
          await _countFiles(tasksRoot),
          0,
          reason: 'Discovery must remain copy-free',
        );
        final repeatedAdded = await controller.discoverUsbDwarf();
        expect(targetEntries(), hasLength(1));
        expect(targetEntries().single.$2.taskId, isNull);
        await removeUnrelatedItems();
        checks['copyFreeDiscovery'] = {
          'taskFilesBeforeCopy': await _countFiles(tasksRoot),
          'firstAdded': firstAdded,
          'repeatedAdded': repeatedAdded,
          'queuedTargetItems': targetEntries().length,
        };

        now = now.add(const Duration(seconds: 4));
        await controller.startAllQueues();
        final importedQueue = controller.queues.singleWhere(
          (candidate) => candidate.items.any(
            (candidateItem) =>
                p.equals(candidateItem.sourceDirectory, expectedDirectory),
          ),
        );
        expect(importedQueue.items, hasLength(1));
        final item = importedQueue.items.single;
        expect(
          item.taskId,
          isNotNull,
          reason: 'Controller should finish the local USB copy',
        );
        final task = await controller.taskForItem(item);
        expect(task, isNotNull);
        expect(task!.photos, hasLength(_expectedPhotoCount));
        expect(
          task.photos.every(
            (photo) =>
                photo.width == _expectedWidth &&
                photo.height == _expectedHeight,
          ),
          isTrue,
          reason: 'Every imported original should be 3840 × 2160',
        );
        final copiedPaths = <String>{};
        for (final photo in task.photos) {
          final localPath = p.normalize(p.absolute(photo.storedPath));
          expect(
            p.isWithin(p.normalize(p.absolute(removableRoot)), localPath),
            isFalse,
            reason: 'Imported photos must be copied off the USB volume',
          );
          expect(
            p.isWithin(p.normalize(p.absolute(testRoot.path)), localPath),
            isTrue,
            reason:
                'All copied photo evidence must remain under this harness run directory',
          );
          expect(await File(localPath).exists(), isTrue);
          final name = p.basename(photo.originalName).toLowerCase();
          expect(
            sourceHashes.containsKey(name),
            isTrue,
            reason: 'Copy must correspond to a selected G: original',
          );
          final localHash =
              (await sha256.bind(File(localPath).openRead()).first).toString();
          expect(
            localHash,
            sourceHashes[name],
            reason: 'SHA-256 mismatch for ${photo.originalName}',
          );
          expect(photo.sha256, sourceHashes[name]);
          copiedPaths.add(localPath);
        }
        expect(copiedPaths, hasLength(_expectedPhotoCount));
        final copiedBytes = task.photos.fold<int>(
          0,
          (sum, photo) => sum + File(photo.storedPath).lengthSync(),
        );
        expect(copiedBytes, _expectedPhotoBytes);
        expect(task.grid.rows, 12);
        expect(task.grid.columns, 26);
        expect(
          _NeverScheduleJobApi.startCalls,
          0,
          reason: 'Harness must not schedule native stitching',
        );
        checks['verifiedCopy'] = {
          'count': task.photos.length,
          'uniqueLocalPaths': copiedPaths.length,
          'localInputDirectory': task.sourceDirectory,
          'totalBytes': copiedBytes,
          'grid': {'rows': task.grid.rows, 'columns': task.grid.columns},
          'previewPath': task.previewThumbnailPath,
          'previewIsDistinct':
              task.previewThumbnailPath != null &&
              !copiedPaths.contains(
                p.normalize(p.absolute(task.previewThumbnailPath!)),
              ),
          'nativeStartCalls': _NeverScheduleJobApi.startCalls,
        };

        final previewPath = task.previewThumbnailPath;
        expect(
          previewPath,
          isNotNull,
          reason: 'Full-panorama preview should be retained independently',
        );
        expect(await File(previewPath!).exists(), isTrue);
        expect(await File(previewPath).length(), _expectedPreviewBytes);
        expect(
          p.isWithin(
            p.normalize(p.absolute(removableRoot)),
            p.normalize(p.absolute(previewPath)),
          ),
          isFalse,
        );
        expect(
          copiedPaths.contains(p.normalize(p.absolute(previewPath))),
          isFalse,
        );
        final sourcePreviewCandidates = <File>[];
        await for (final entity in sourceDirectory.list(followLinks: false)) {
          if (entity is File &&
              RegExp(
                r'^panor(?:a|ar)ma_thumbnail\.jpe?g$',
                caseSensitive: false,
              ).hasMatch(p.basename(entity.path))) {
            sourcePreviewCandidates.add(entity);
          }
        }
        expect(sourcePreviewCandidates, isNotEmpty);
        final previewHash =
            (await sha256.bind(File(previewPath).openRead()).first).toString();
        final sourcePreviewHashes = <String>{
          for (final file in sourcePreviewCandidates)
            (await sha256.bind(file.openRead()).first).toString(),
        };
        expect(sourcePreviewHashes.contains(previewHash), isTrue);
        checks['preview'] = {
          'localPath': previewPath,
          'bytes': await File(previewPath).length(),
          'sha256': previewHash,
          'matchesSourcePreview': true,
        };

        final savedQueueId = importedQueue.id;
        controller.dispose();
        activeController = null;
        controller = createController();
        activeController = controller;
        await controller.initialize();
        expect(
          controller.queues
              .singleWhere((candidate) => candidate.id == savedQueueId)
              .items
              .where(
                (candidate) =>
                    p.equals(candidate.sourceDirectory, expectedDirectory),
              ),
          hasLength(1),
        );
        await controller.discoverUsbDwarf();
        await removeUnrelatedItems();
        expect(targetEntries(), hasLength(1));
        controller.dispose();
        activeController = null;
        checks['restartDeduplication'] = {
          'queueId': savedQueueId,
          'itemCountAfterRestart': 1,
        };

        // Remove only this harness's queue history. Keep task copies, import
        // history and the report so the primary agent can inspect evidence.
        final normalizedTestRoot = p.normalize(p.absolute(testRoot.path));
        final normalizedQueueRoot = p.normalize(p.absolute(queuesRoot.path));
        if (!p.isWithin(normalizedTestRoot, normalizedQueueRoot)) {
          throw StateError(
            'Refusing to clear queue data outside the isolated test root',
          );
        }
        if (await queuesRoot.exists()) {
          await for (final entity in queuesRoot.list(followLinks: false)) {
            if (entity is Directory) await entity.delete(recursive: true);
            if (entity is File) await entity.delete();
          }
        }
        controller = createController();
        activeController = controller;
        await controller.initialize();
        await controller.discoverUsbDwarf();
        await removeUnrelatedItems();
        expect(
          targetEntries(),
          isEmpty,
          reason:
              'Imported history should prevent duplicate queue work after queue history is removed',
        );
        controller.dispose();
        activeController = null;
        checks['queueHistoryRemovalDeduplication'] = {
          'queueHistoryRemoved': true,
          'remainingTargetItems': 0,
          'taskEvidenceRetained': await _countFiles(tasksRoot),
          'importHistoryRetained': await _countFiles(historyRoot),
        };

        var unchangedSources = 0;
        for (final photo in selected) {
          final sourcePath = photo.file.path;
          expect(
            await File(sourcePath).exists(),
            isTrue,
            reason:
                'Original source must remain present after a non-destructive import',
          );
          final digest = (await sha256.bind(File(sourcePath).openRead()).first)
              .toString();
          expect(
            digest,
            sourceHashes[p.basename(sourcePath).toLowerCase()],
            reason: 'Original source changed during local import: $sourcePath',
          );
          unchangedSources++;
        }
        expect(unchangedSources, _expectedPhotoCount);
        expect(
          await File(previewPath).exists(),
          isTrue,
          reason: 'Original full-panorama preview must remain present',
        );
        checks['sourceUnchanged'] = {
          'verifiedOriginalCount': unchangedSources,
          'previewStillPresent': true,
          'sha256MatchesPreCopyManifest': true,
        };
        report['status'] = 'passed';
      } catch (error, stack) {
        report['status'] = 'failed';
        report['error'] = '$error';
        report['stack'] = '$stack';
        rethrow;
      } finally {
        activeController?.dispose();
        report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        final reportFile = File(
          p.join(evidenceRoot.path, 'usb-dwarf-hardware-report.json'),
        );
        await reportFile.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          flush: true,
        );
        // This path, the copied input tree, and source manifest remain on disk.
        // ignore: avoid_print
        print('USB_DWARF_HARDWARE_EVIDENCE=${evidenceRoot.path}');
        // ignore: avoid_print
        print('USB_DWARF_HARDWARE_REPORT=${reportFile.path}');
      }
    },
    skip: enabled
        ? false
        : 'Set USB_DWARF_HARDWARE=1 to opt into reading and copying the real G: device.',
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<int> _countFiles(Directory directory) async {
  if (!await directory.exists()) return 0;
  var count = 0;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) count++;
  }
  return count;
}

Future<Directory> _findPackageRoot() async {
  var current = Directory.current.absolute;
  while (true) {
    final manifest = File(p.join(current.path, 'pubspec.yaml'));
    if (await manifest.exists() &&
        (await manifest.readAsString()).contains('name: stitch_app')) {
      return current;
    }
    final parent = current.parent;
    if (p.equals(parent.path, current.path)) break;
    current = parent;
  }
  throw StateError(
    'Could not locate the stitch_app package root from ${Directory.current.path}',
  );
}

/// Explicitly blocks stitching. Any accidental native start is observable.
class _NeverScheduleJobApi implements JobApi {
  static int startCalls = 0;

  @override
  bool get isAvailable => false;
  @override
  String? get unavailableReason => 'Hardware harness keeps stitching disabled';
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    startCalls++;
    throw StateError('Native stitching is disabled in this hardware harness');
  }

  @override
  Future<Map<String, Object?>> status(String jobId) async => {
    'state': 'queued',
  };
  @override
  Future<Map<String, Object?>> pause(String jobId) async => {'state': 'queued'};
  @override
  Future<Map<String, Object?>> resume(String jobId) async => {
    'state': 'queued',
  };
  @override
  Future<Map<String, Object?>> cancel(String jobId) async => {
    'state': 'cancelled',
  };
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      {'state': 'queued'};
  @override
  Future<Map<String, Object?>> capabilities() async => {'available': false};
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => {'configured': false};
}
