import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/usb_dwarf_import_service.dart';

void main() {
  group('USB DWARF queue controller', () {
    late _Harness h;

    setUp(() async {
      h = await _Harness.create();
    });
    tearDown(() async {
      await h.close();
    });

    test('discovery is copy-free and repeated scans retain one row', () async {
      final mount = await h.addMount('G');
      final source = await _createPanorama(mount, 'A');
      await h.controller.initialize();

      expect(await h.controller.discoverUsbDwarf(), 1);
      final first = _itemsFor(h.controller, source.path).single;
      expect(first.state, BatchItemState.pending);
      expect(first.taskId, isNull);
      expect(await _files(h.tasksRoot), isEmpty);
      expect(await h.controller.discoverUsbDwarf(), 0);
      expect(_itemsFor(h.controller, source.path), hasLength(1));
      expect(await _files(h.tasksRoot), isEmpty);
    });

    test('new panorama appends while preserving the existing row', () async {
      final mount = await h.addMount('G');
      final firstSource = await _createPanorama(mount, 'A');
      await h.controller.initialize();
      await h.controller.discoverUsbDwarf();
      final before = _itemsFor(h.controller, firstSource.path).single;

      final secondSource = await _createPanorama(mount, 'B');
      expect(await h.controller.discoverUsbDwarf(), 1);
      expect(_itemsFor(h.controller, firstSource.path), hasLength(1));
      expect(_itemsFor(h.controller, firstSource.path).single.id, before.id);
      expect(_itemsFor(h.controller, firstSource.path).single.taskId, isNull);
      expect(_itemsFor(h.controller, secondSource.path), hasLength(1));
      expect(await _files(h.tasksRoot), isEmpty);
    });

    test(
      'start copies only maximum originals and keeps preview local with settings',
      () async {
        final mount = await h.addMount('G');
        final source = await _createPanorama(
          mount,
          'Settings',
          rootPhotos: const ['alpha.jpg', 'duplicate.jpg', 'omega.jpg'],
          numberedDuplicate: true,
        );
        h.previewHash =
            (await sha256
                    .bind(
                      File(
                        p.join(source.path, 'panorama_thumbnail.jpg'),
                      ).openRead(),
                    )
                    .first)
                .toString();
        expect(
          await File(p.join(source.path, 'duplicate.jpg')).length(),
          greaterThan(
            await File(p.join(source.path, '1', 'duplicate.jpg')).length(),
          ),
        );
        await h.controller.initialize();
        final settings = AppSettings(
          exportFormat: ExportFormat.png,
          performance: const PerformanceOptions(
            fastRegistration: true,
            parallelRendering: false,
            orbFeatures: true,
          ),
          seamBlendMode: SeamBlendMode.feather,
          localTextureWarp: false,
        );
        await h.controller.discoverUsbDwarf(settings: settings);
        final queue = _queueForSource(h.controller, source.path);
        expect(queue.outputFormat, ExportFormat.png);
        expect(queue.performanceOptions.fastRegistration, isTrue);
        expect(queue.performanceOptions.parallelRendering, isFalse);
        expect(queue.performanceOptions.orbFeatures, isTrue);
        expect(queue.seamBlendMode, SeamBlendMode.feather);
        expect(queue.localTextureWarp, isFalse);
        expect(await _files(h.tasksRoot), isEmpty);

        h.advance(const Duration(seconds: 4));
        await h.controller.startAllQueues();
        final imported = _queueForSource(
          h.controller,
          source.path,
        ).items.single;
        expect(imported.taskId, isNotNull);
        final task = await h.controller.taskForItem(imported);
        expect(task, isNotNull);
        expect(task!.photos.map((photo) => photo.originalName).toSet(), {
          'alpha.jpg',
          'duplicate.jpg',
          'omega.jpg',
        });
        final duplicate = task.photos.singleWhere(
          (photo) => photo.originalName == 'duplicate.jpg',
        );
        expect(duplicate.width, 8, reason: 'Higher-pixel-area copy must win');
        expect(duplicate.height, 8);
        expect(task.photos, hasLength(3));
        expect(task.exportFormat, ExportFormat.png);
        expect(task.performanceOptions.fastRegistration, isTrue);
        expect(task.performanceOptions.parallelRendering, isFalse);
        expect(task.seamBlendMode, SeamBlendMode.feather);
        expect(task.localTextureWarp, isFalse);
        expect(task.previewThumbnailPath, isNotNull);
        expect(await File(task.previewThumbnailPath!).exists(), isTrue);
        expect(await File(task.previewThumbnailPath!).length(), 25);
        expect(
          task.photos.any(
            (photo) => p.equals(photo.storedPath, task.previewThumbnailPath!),
          ),
          isFalse,
        );
        final previewHash =
            (await sha256
                    .bind(File(task.previewThumbnailPath!).openRead())
                    .first)
                .toString();
        expect(previewHash, h.previewHash);
        for (final photo in task.photos) {
          expect(await File(photo.storedPath).exists(), isTrue);
          expect(p.isWithin(h.tasksRoot.path, photo.storedPath), isTrue);
          expect(
            (await sha256.bind(File(photo.storedPath).openRead()).first)
                .toString(),
            photo.sha256,
          );
        }
        expect(_NeverScheduleJobApi.startCalls, 0);
      },
    );

    test(
      'pending rows survive restart without automatic photo copying',
      () async {
        final mount = await h.addMount('G');
        final source = await _createPanorama(mount, 'Pending');
        await h.controller.initialize();
        await h.controller.discoverUsbDwarf();
        final oldItemId = _itemsFor(h.controller, source.path).single.id;
        expect(await _files(h.tasksRoot), isEmpty);

        await h.restartController();
        expect(_itemsFor(h.controller, source.path), hasLength(1));
        expect(_itemsFor(h.controller, source.path).single.id, oldItemId);
        expect(_itemsFor(h.controller, source.path).single.taskId, isNull);
        expect(await _files(h.tasksRoot), isEmpty);
      },
    );

    test(
      'completed import remains deduplicated after restart and queue removal',
      () async {
        final mount = await h.addMount('G');
        final source = await _createPanorama(mount, 'Imported');
        await h.controller.initialize();
        await h.controller.discoverUsbDwarf();
        h.advance(const Duration(seconds: 4));
        await h.controller.startAllQueues();
        final item = _itemsFor(h.controller, source.path).single;
        expect(item.taskId, isNotNull);
        final taskId = item.taskId!;
        final inputBefore = (await h.controller.taskForItem(
          item,
        ))!.sourceDirectory;
        final queueId = _queueForSource(h.controller, source.path).id;
        await h.restartController();
        expect(_itemsFor(h.controller, source.path).single.taskId, taskId);
        await h.controller.discoverUsbDwarf();
        expect(_itemsFor(h.controller, source.path), hasLength(1));
        expect(
          (await h.controller.taskForItem(
            _itemsFor(h.controller, source.path).single,
          ))!.sourceDirectory,
          inputBefore,
        );

        await h.clearIsolatedQueueHistory();
        await h.restartController();
        await h.controller.discoverUsbDwarf();
        expect(
          h.controller.queues.where((queue) => queue.usbSource),
          isEmpty,
          reason: 'History-only imported sources must not create empty queues',
        );
        expect(await h.taskRepository.loadById(taskId), isNotNull);
        expect(
          await Directory(p.join(h.queuesRoot.path, queueId)).exists(),
          isFalse,
        );
        expect(await _files(h.tasksRoot), isNotEmpty);
      },
    );

    test(
      'same-volume G to H remount updates every row and preserves imported task',
      () async {
        final mountG = await h.addMount('G');
        final sourceAOnG = await _createPanorama(mountG, 'A');
        await h.controller.initialize();
        await h.controller.discoverUsbDwarf();
        h.advance(const Duration(seconds: 4));
        await h.controller.startAllQueues();
        final itemA = _itemsFor(h.controller, sourceAOnG.path).single;
        final taskIdA = itemA.taskId!;
        final taskA = await h.controller.taskForItem(itemA);
        final localInputA = taskA!.sourceDirectory;
        final localHashesA = {
          for (final photo in taskA.photos) photo.originalName: photo.sha256,
        };

        final mountH = await h.addMount('H');
        final sourceAOnH = await _createPanorama(mountH, 'A');
        final sourceBOnH = await _createPanorama(mountH, 'B');
        expect(await h.controller.discoverUsbDwarf(), 1);
        expect(_itemsFor(h.controller, sourceAOnH.path), hasLength(1));
        expect(_itemsFor(h.controller, sourceAOnH.path).single.id, itemA.id);
        expect(_itemsFor(h.controller, sourceAOnH.path).single.taskId, taskIdA);
        expect(_itemsFor(h.controller, sourceBOnH.path), hasLength(1));
        expect(
          _queueForSource(h.controller, sourceAOnH.path).parentDirectory,
          mountH.path,
        );
        expect(p.isWithin(h.tasksRoot.path, localInputA), isTrue);
        expect(Directory(localInputA).existsSync(), isTrue);

        await h.restartController();
        expect(_itemsFor(h.controller, sourceAOnH.path), hasLength(1));
        expect(_itemsFor(h.controller, sourceAOnH.path).single.taskId, taskIdA);
        expect(_itemsFor(h.controller, sourceBOnH.path), hasLength(1));
        expect(_itemsFor(h.controller, sourceBOnH.path).single.taskId, isNull);
        final restoredTaskA = await h.controller.taskForItem(
          _itemsFor(h.controller, sourceAOnH.path).single,
        );
        expect(restoredTaskA!.sourceDirectory, localInputA);
        expect({
          for (final photo in restoredTaskA.photos)
            photo.originalName: photo.sha256,
        }, localHashesA);
        expect(await h.controller.discoverUsbDwarf(), 0);
        expect(_itemsFor(h.controller, sourceAOnH.path), hasLength(1));
        expect(_itemsFor(h.controller, sourceBOnH.path), hasLength(1));

        h.advance(const Duration(seconds: 4));
        await h.controller.startAllQueues();
        expect(
          _itemsFor(h.controller, sourceBOnH.path).single.taskId,
          isNotNull,
        );
        expect(_itemsFor(h.controller, sourceAOnH.path).single.taskId, taskIdA);
        expect(_NeverScheduleJobApi.startCalls, 0);
      },
    );

    test(
      'failed copy retries under the same item id and writes history after success',
      () async {
        final mount = await h.addMount('G');
        final source = await _createPanorama(mount, 'Retry');
        await h.controller.initialize();
        await h.controller.discoverUsbDwarf();
        final queue = _queueForSource(h.controller, source.path);
        final itemId = queue.items.single.id;
        h.advance(const Duration(seconds: 4));
        h.usb.throwNextCopy = true;
        await h.controller.startAllQueues();
        final failed = _itemsFor(h.controller, source.path).single;
        expect(failed.id, itemId);
        expect(failed.state, BatchItemState.failed);
        expect(failed.taskId, isNull);
        expect(await h.usb.loadImportedIdentities(), isEmpty);
        expect(await File(p.join(source.path, 'alpha.jpg')).exists(), isTrue);

        await h.controller.retry(queue.id, itemId);
        final retried = _itemsFor(h.controller, source.path).single;
        expect(retried.id, itemId);
        expect(retried.taskId, itemId);
        expect(retried.state, isNot(BatchItemState.failed));
        expect(
          await h.usb.loadImportedIdentities(),
          contains(retried.usbSourceIdentity),
        );
        await h.controller.startAllQueues();
        expect(
          (await h.controller.taskForItem(
            _itemsFor(h.controller, source.path).single,
          ))!.id,
          itemId,
        );
        expect(_NeverScheduleJobApi.startCalls, 0);
      },
    );

    test(
      'source cleanup failure preserves imported task and original bytes',
      () async {
        final mount = await h.addMount('G');
        final source = await _createPanorama(mount, 'Cleanup');
        final original = File(p.join(source.path, 'alpha.jpg'));
        final originalHash = (await sha256.bind(original.openRead()).first)
            .toString();
        await h.controller.initialize();
        await h.controller.discoverUsbDwarf();
        final queue = _queueForSource(h.controller, source.path);
        await h.controller.setUsbDeleteSources(queue.id, true);
        h.usb.throwOnDelete = true;
        h.advance(const Duration(seconds: 4));
        await h.controller.startAllQueues();

        final item = _itemsFor(h.controller, source.path).single;
        expect(item.taskId, isNotNull);
        expect(item.state, isNot(BatchItemState.failed));
        expect(item.message, contains('源文件清理失败'));
        final task = await h.controller.taskForItem(item);
        expect(task, isNotNull);
        expect(task!.phase, StitchPhase.imported);
        expect(await original.exists(), isTrue);
        expect(
          (await sha256.bind(original.openRead()).first).toString(),
          originalHash,
        );
        expect(
          await h.usb.loadImportedIdentities(),
          contains(item.usbSourceIdentity),
        );
        expect(_NeverScheduleJobApi.startCalls, 0);
      },
    );

    test(
      'successful opted-in cleanup deletes only verified originals after persistence',
      () async {
        final mount = await h.addMount('G');
        final source = await _createPanorama(mount, 'DeleteVerified');
        final selectedOriginal = File(p.join(source.path, 'alpha.jpg'));
        final thumbnailDirectory = Directory(p.join(source.path, '1'));
        await thumbnailDirectory.create();
        final thumbnailCopy = File(
          p.join(thumbnailDirectory.path, 'alpha.jpg'),
        );
        await thumbnailCopy.writeAsBytes(
          _jpeg(width: 2, height: 2, padding: 64),
        );
        final htmlSidecar = File(p.join(source.path, 'index.html'));
        await htmlSidecar.writeAsString('<html>camera sidecar</html>');
        final preview = File(p.join(source.path, 'panorama_thumbnail.jpg'));
        final latestPhoto = [selectedOriginal, thumbnailCopy]
            .map((file) => file.statSync().modified)
            .reduce((a, b) => a.isAfter(b) ? a : b);
        await preview.setLastModified(
          latestPhoto.add(const Duration(seconds: 5)),
        );
        final selectedOriginalHash =
            (await sha256.bind(selectedOriginal.openRead()).first).toString();
        final sourcePreviewHash = (await sha256.bind(preview.openRead()).first)
            .toString();
        expect(
          await thumbnailCopy.length(),
          greaterThan(await selectedOriginal.length()),
        );

        await h.controller.initialize();
        await h.controller.discoverUsbDwarf();
        final queue = _queueForSource(h.controller, source.path);
        final itemId = queue.items.single.id;
        await h.controller.setUsbDeleteSources(queue.id, true);
        h.advance(const Duration(seconds: 4));
        await h.controller.startAllQueues();

        final importedItem = _itemsFor(h.controller, source.path).single;
        expect(importedItem.id, itemId);
        expect(importedItem.taskId, itemId);
        expect(importedItem.state, isNot(BatchItemState.failed));
        expect(
          await selectedOriginal.exists(),
          isFalse,
          reason:
              'Only the SHA-verified maximum-resolution source should be deleted',
        );
        expect(
          await thumbnailCopy.exists(),
          isTrue,
          reason:
              'The smaller numeric-folder copy is not part of the deletion set',
        );
        expect(await preview.exists(), isTrue);
        expect(await htmlSidecar.exists(), isTrue);

        final task = await h.controller.taskForItem(importedItem);
        expect(task, isNotNull);
        expect(task!.id, itemId);
        expect(task.photos, hasLength(1));
        expect(task.photos.single.originalName, 'alpha.jpg');
        expect(task.photos.single.sha256, selectedOriginalHash);
        expect(task.previewThumbnailPath, isNotNull);
        expect(await File(task.previewThumbnailPath!).exists(), isTrue);
        expect(
          (await sha256.bind(File(task.previewThumbnailPath!).openRead()).first)
              .toString(),
          sourcePreviewHash,
        );
        final localInput = File(task.photos.single.storedPath);
        expect(await localInput.exists(), isTrue);
        expect(p.isWithin(h.tasksRoot.path, localInput.path), isTrue);
        expect(
          (await sha256.bind(localInput.openRead()).first).toString(),
          selectedOriginalHash,
        );
        expect(
          await h.taskRepository.loadById(itemId),
          isNotNull,
          reason: 'Task metadata must be durable before original cleanup',
        );
        expect(
          await h.usb.loadImportedIdentities(),
          contains(importedItem.usbSourceIdentity),
        );
        expect(_NeverScheduleJobApi.startCalls, 0);

        expect(await h.controller.discoverUsbDwarf(), 0);
        expect(_itemsFor(h.controller, source.path), hasLength(1));
        await h.restartController();
        expect(_itemsFor(h.controller, source.path), hasLength(1));
        expect(_itemsFor(h.controller, source.path).single.taskId, itemId);
        expect(
          _queueForSource(h.controller, source.path).deleteUsbSources,
          isTrue,
        );
        final restoredTask = await h.controller.taskForItem(
          _itemsFor(h.controller, source.path).single,
        );
        expect(restoredTask!.photos.single.sha256, selectedOriginalHash);
        expect(await h.controller.discoverUsbDwarf(), 0);
        expect(_itemsFor(h.controller, source.path), hasLength(1));
        expect(await thumbnailCopy.exists(), isTrue);
        expect(await preview.exists(), isTrue);
        expect(await htmlSidecar.exists(), isTrue);
      },
    );

    test(
      'periodic discovery captures errors and dispose stops its timer',
      () async {
        await h.controller.initialize();
        h.usb.throwOnDiscover = true;
        h.controller.setUsbAutoDiscoveryEnabled(
          true,
          interval: const Duration(milliseconds: 5),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.controller.error, contains('扫描 USB DWARF 设备失败'));
        h.usb.throwOnDiscover = false;
        h.controller.setUsbAutoDiscoveryEnabled(false);
        final callsAtStop = h.usb.discoveryCalls;
        h.disposeController();
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(h.usb.discoveryCalls, callsAtStop);
      },
    );
  });
}

List<BatchQueueItem> _itemsFor(
  BatchQueueController controller,
  String path,
) => [
  for (final queue in controller.queues.where((queue) => queue.usbSource))
    for (final item in queue.items)
      if (p.equals(p.normalize(item.sourceDirectory), p.normalize(path))) item,
];

BatchQueue _queueForSource(BatchQueueController controller, String path) =>
    controller.queues.singleWhere(
      (queue) => queue.items.any(
        (item) =>
            p.equals(p.normalize(item.sourceDirectory), p.normalize(path)),
      ),
    );

Future<List<File>> _files(Directory directory) async {
  if (!await directory.exists()) return const [];
  final result = <File>[];
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) result.add(entity);
  }
  return result;
}

Future<Directory> _createPanorama(
  Directory mount,
  String name, {
  List<String> rootPhotos = const ['alpha.jpg'],
  bool numberedDuplicate = false,
}) async {
  final panorama = Directory(
    p.join(mount.path, 'Panoramas', 'DWARF_PANORAMA_$name'),
  );
  await panorama.create(recursive: true);
  for (var index = 0; index < rootPhotos.length; index++) {
    final duplicateLowResolution =
        numberedDuplicate && rootPhotos[index] == 'duplicate.jpg';
    final bytes = _jpeg(
      width: duplicateLowResolution ? 2 : 8,
      height: duplicateLowResolution ? 2 : 8,
      padding: duplicateLowResolution ? 64 : index + 1,
    );
    await File(p.join(panorama.path, rootPhotos[index])).writeAsBytes(bytes);
  }
  if (numberedDuplicate) {
    final numbered = Directory(p.join(panorama.path, '1'));
    await numbered.create();
    await File(
      p.join(numbered.path, 'duplicate.jpg'),
    ).writeAsBytes(_jpeg(width: 8, height: 8));
  }
  final newestPhoto = <File>[];
  await for (final entity in panorama.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && p.extension(entity.path).toLowerCase() == '.jpg') {
      newestPhoto.add(entity);
    }
  }
  final latest = newestPhoto
      .map((file) => file.statSync().modified)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  final preview = File(p.join(panorama.path, 'panorama_thumbnail.jpg'));
  await preview.writeAsBytes(_jpeg(width: 4, height: 2, padding: 10));
  await preview.setLastModified(latest.add(const Duration(seconds: 5)));
  return panorama;
}

List<int> _jpeg({required int width, required int height, int padding = 0}) => [
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  height >> 8,
  height & 0xff,
  width >> 8,
  width & 0xff,
  0x01,
  0x01,
  0x11,
  0x00,
  ...List<int>.filled(padding, 0x41),
];

class _Harness {
  final Directory root;
  final Directory supportRoot;
  final Directory queuesRoot;
  final Directory tasksRoot;
  final List<Directory> mounts = [];
  DateTime now = DateTime.utc(2026, 10, 29, 18);
  late final _FaultingUsbService usb;
  late BatchQueueController controller;
  final TaskRepository taskRepository;
  final BatchQueueRepository queueRepository;
  String previewHash = '';
  bool _controllerDisposed = false;

  static Future<_Harness> create() async {
    final root = await Directory.systemTemp.createTemp('usb-dwarf-queue-');
    return _Harness._(root);
  }

  _Harness._(Directory root)
    : root = root,
      supportRoot = Directory(p.join(root.path, 'support')),
      queuesRoot = Directory(p.join(root.path, 'queues')),
      tasksRoot = Directory(p.join(root.path, 'tasks')),
      taskRepository = TaskRepository(
        rootDirectory: Directory(p.join(root.path, 'tasks')),
      ),
      queueRepository = BatchQueueRepository(
        rootDirectory: Directory(p.join(root.path, 'queues')),
      ) {
    _NeverScheduleJobApi.startCalls = 0;
    usb = _FaultingUsbService(
      supportDirectory: () => supportRoot,
      mountRoots: () async => mounts,
      volumeIdentity: (_) async => 'fixture-volume-guid',
      removableCheck: (_) async => true,
      clock: () => now,
    );
    controller = _newController();
  }

  Future<Directory> addMount(String letter) async {
    final mount = Directory(p.join(root.path, 'volume-$letter'));
    await mount.create(recursive: true);
    mounts
      ..clear()
      ..add(mount);
    return mount;
  }

  BatchQueueController _newController() => BatchQueueController(
    api: _NeverScheduleJobApi(),
    queueRepository: queueRepository,
    taskRepository: taskRepository,
    usbImportService: usb,
    clock: () => now,
  );

  void advance(Duration duration) => now = now.add(duration);

  Future<void> restartController() async {
    disposeController();
    _controllerDisposed = false;
    controller = _newController();
    await controller.initialize();
  }

  void disposeController() {
    if (_controllerDisposed) return;
    controller.dispose();
    _controllerDisposed = true;
  }

  Future<void> clearIsolatedQueueHistory() async {
    final normalizedRoot = p.normalize(p.absolute(root.path));
    final normalizedQueues = p.normalize(p.absolute(queuesRoot.path));
    if (!p.isWithin(normalizedRoot, normalizedQueues)) {
      throw StateError(
        'Refusing to clear queues outside the test temp directory',
      );
    }
    if (await queuesRoot.exists()) {
      await for (final entity in queuesRoot.list(followLinks: false)) {
        if (entity is Directory) await entity.delete(recursive: true);
        if (entity is File) await entity.delete();
      }
    }
  }

  Future<void> close() async {
    disposeController();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class _FaultingUsbService extends UsbDwarfImportService {
  _FaultingUsbService({
    required super.supportDirectory,
    required super.mountRoots,
    required super.volumeIdentity,
    required super.removableCheck,
    required super.clock,
  });

  bool throwNextCopy = false;
  bool throwOnDelete = false;
  bool throwOnDiscover = false;
  int discoveryCalls = 0;

  @override
  Future<List<UsbPanoramaSource>> discover() async {
    discoveryCalls++;
    if (throwOnDiscover) {
      throw const FileSystemException('fixture discovery failure');
    }
    return super.discover();
  }

  @override
  Future<UsbImportResult> copyVerified({
    required List<UsbPhotoSource> sources,
    required String destinationDirectory,
    required bool deleteSources,
  }) async {
    if (throwNextCopy) {
      throwNextCopy = false;
      throw const FileSystemException('fixture copy failure');
    }
    return super.copyVerified(
      sources: sources,
      destinationDirectory: destinationDirectory,
      deleteSources: deleteSources,
    );
  }

  @override
  Future<UsbSourceCleanupResult> deleteVerifiedSources({
    required List<UsbPhotoSource> sources,
    required Map<String, String> expectedHashesByName,
  }) async {
    if (throwOnDelete) {
      throw const FileSystemException('fixture delete failure');
    }
    return super.deleteVerifiedSources(
      sources: sources,
      expectedHashesByName: expectedHashesByName,
    );
  }
}

class _NeverScheduleJobApi implements JobApi {
  static int startCalls = 0;

  @override
  bool get isAvailable => false;
  @override
  String? get unavailableReason => 'USB queue tests never render';
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async {
    startCalls++;
    throw StateError('Native job start must remain unreachable in this test');
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
