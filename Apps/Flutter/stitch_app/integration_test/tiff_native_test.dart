import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/stitch_quality.dart';
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

Future<void> _copyFourPhotoFolder(
  Directory source,
  Directory destination,
) async {
  Directory? selected;
  var selectedFiles = <File>[];
  await for (final entity in source.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final files = <File>[];
    await for (final child in entity.list(followLinks: false)) {
      if (child is File &&
          const {
            '.jpg',
            '.jpeg',
          }.contains(p.extension(child.path).toLowerCase())) {
        files.add(child);
      }
    }
    if (files.length == 4) {
      selected = entity;
      selectedFiles = files;
      break;
    }
  }
  if (selected == null) {
    throw StateError(
      'Fixture must contain a direct child folder with exactly four JPEGs.',
    );
  }
  selectedFiles.sort(
    (a, b) => p.basename(a.path).compareTo(p.basename(b.path)),
  );
  final target = Directory(p.join(destination.path, p.basename(selected.path)));
  await target.create(recursive: true);
  for (final file in selectedFiles) {
    await file.copy(p.join(target.path, p.basename(file.path)));
  }
}

Future<Map<int, ({int type, int count, int valueField})>> _readClassicIfd(
  RandomAccessFile file,
) async {
  final header = Uint8List.fromList(await file.read(8));
  if (header.length != 8 ||
      header[0] != 0x49 ||
      header[1] != 0x49 ||
      header[2] != 42 ||
      header[3] != 0) {
    throw const FormatException(
      'Expected a little-endian classic TIFF header.',
    );
  }
  final headerData = ByteData.sublistView(header);
  await file.setPosition(headerData.getUint32(4, Endian.little));
  final countBytes = Uint8List.fromList(await file.read(2));
  if (countBytes.length != 2) {
    throw const FormatException('Truncated TIFF IFD.');
  }
  final count = ByteData.sublistView(countBytes).getUint16(0, Endian.little);
  final entries = Uint8List.fromList(await file.read(count * 12));
  if (entries.length != count * 12) {
    throw const FormatException('Truncated TIFF tags.');
  }
  final data = ByteData.sublistView(entries);
  final tags = <int, ({int type, int count, int valueField})>{};
  for (var index = 0; index < count; index++) {
    final offset = index * 12;
    tags[data.getUint16(offset, Endian.little)] = (
      type: data.getUint16(offset + 2, Endian.little),
      count: data.getUint32(offset + 4, Endian.little),
      valueField: data.getUint32(offset + 8, Endian.little),
    );
  }
  return tags;
}

int _inlineValue(({int type, int count, int valueField}) tag) {
  if (tag.count != 1) throw const FormatException('TIFF tag is not a scalar.');
  return switch (tag.type) {
    3 => tag.valueField & 0xffff,
    4 => tag.valueField,
    _ => throw FormatException(
      'Unsupported scalar TIFF field type ${tag.type}.',
    ),
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows batch exports lossless TIFF and applies new desktop defaults',
    (tester) async {
      const enabled = bool.fromEnvironment('TEST_TIFF_NATIVE');
      if (!enabled) return;

      await tester.runAsync(() async {
        expect(Platform.isWindows, isTrue, reason: 'Requires Windows FFI.');
        const fixturePath = String.fromEnvironment('TEST_TIFF_PARENT_DIR');
        expect(
          fixturePath,
          isNotEmpty,
          reason: 'Pass --dart-define=TEST_TIFF_PARENT_DIR=<fixture parent>.',
        );
        final fixture = Directory(fixturePath);
        expect(await fixture.exists(), isTrue, reason: fixturePath);

        final temporary = await Directory.systemTemp.createTemp(
          'lumia-tiff-batch-test-',
        );
        final isolatedFixture = Directory(p.join(temporary.path, 'fixture'));
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
        try {
          await _copyFourPhotoFolder(fixture, isolatedFixture);
          expect(api.isAvailable, isTrue, reason: api.unavailableReason);
          final initial = await api.capabilities();
          final initialCaps = initial['capabilities']! as Map<String, Object?>;
          expect(initialCaps['backend'], 'cpu-rust-tiled');
          expect(
            initialCaps['activeJobs'],
            0,
            reason:
                'Use a dedicated Windows app process for this native integration test.',
          );
          expect(
            (initialCaps['totalCpuWorkers'] as num).toInt(),
            greaterThanOrEqualTo(1),
          );
          expect(
            (initialCaps['totalMemoryBudgetMiB'] as num).toInt(),
            greaterThanOrEqualTo(512),
          );
          expect(
            (initialCaps['maxConcurrentJobs'] as num).toInt(),
            greaterThanOrEqualTo(1),
          );

          await controller.initialize();
          await controller.addParent(
            isolatedFixture.path,
            outputFormat: ExportFormat.tiff,
          );
          expect(controller.error, isNull, reason: controller.error);
          expect(controller.queues, hasLength(1));
          final queue = controller.queues.single;
          expect(queue.outputFormat, ExportFormat.tiff);
          expect(queue.items, hasLength(1));
          final item = queue.items.single;
          final imported = await taskRepository.loadById(item.taskId!);
          expect(imported, isNotNull);
          var task = imported!;
          expect(task.photos, hasLength(4));
          expect(task.grid.rows * task.grid.columns, 4);
          expect(task.exportFormat, ExportFormat.tiff);
          expect(
            task.autoExportOnCompletion,
            isFalse,
            reason: 'Batch queue owns its export lifecycle.',
          );
          expect(task.autoGridOverlap, isTrue);
          expect(task.refineGridNeighbors, isTrue);
          expect(task.seamBlendMode, SeamBlendMode.deghost);
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
            final current = controller.queues.single.items.single;
            if (current.state == BatchItemState.completed) break;
            if (current.state == BatchItemState.failed ||
                current.state == BatchItemState.cancelled) {
              fail(
                'Native TIFF batch ended in ${current.state}: ${current.message}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }

          final finished = controller.queues.single.items.single;
          expect(
            finished.state,
            BatchItemState.completed,
            reason:
                'Native TIFF stitch/export exceeded its five-minute deadline.',
          );
          task = (await taskRepository.loadById(item.taskId!))!;
          expect(task.exportFormat, ExportFormat.tiff);
          expect(task.exportPath, isNotNull);
          expect(task.exportPath!.toLowerCase().endsWith('.tif'), isTrue);
          expect(task.resultStats?['exportFormat'], 'tiff');
          expect(task.resultStats?['tiffVariant'], 'classic');

          final job = await api.status(task.nativeJobId!);
          expect(job['state'], 'completed');
          expect(job['exportFormat'], 'tiff');
          final manifestFile = File(
            p.join(task.outputDirectory, 'manifest.json'),
          );
          final manifest =
              jsonDecode(await manifestFile.readAsString())
                  as Map<String, Object?>;
          final layout =
              jsonDecode(
                    await File(
                      p.join(task.outputDirectory, 'layout.json'),
                    ).readAsString(),
                  )
                  as Map<String, Object?>;
          final report = layout['report']! as Map<String, Object?>;
          expect(report['autoGridOverlap'], isTrue);
          expect(report['refineGridNeighbors'], isTrue);
          expect(
            report['geometryModel'],
            'central-overlap+four-neighbor-visual-ray-grid',
          );
          expect(layout['renderBlendMode'], 'deghost');
          expect(report['gridNeighborRefinement'], isA<Map<String, Object?>>());

          final tiff = File(task.exportPath!);
          expect(await tiff.exists(), isTrue);
          expect(await tiff.length(), greaterThan(1024));
          final handle = await tiff.open();
          try {
            final tags = await _readClassicIfd(handle);
            expect(_inlineValue(tags[256]!), manifest['width']); // ImageWidth
            expect(_inlineValue(tags[257]!), manifest['height']); // ImageLength
            expect(_inlineValue(tags[259]!), 1); // Compression: none
            expect(_inlineValue(tags[277]!), 4); // RGB plus alpha
            expect(tags[258]!.count, 4); // BitsPerSample for RGBA
            expect(
              _inlineValue(tags[338]!),
              2,
            ); // ExtraSamples: unassociated alpha
          } finally {
            await handle.close();
          }

          final persistedQueues = await queueRepository.loadAll();
          expect(persistedQueues.single.outputFormat, ExportFormat.tiff);
        } finally {
          final jobs = <String>{};
          for (final queue in controller.queues) {
            for (final item in queue.items) {
              final stored = item.taskId == null
                  ? null
                  : await taskRepository.loadById(item.taskId!);
              if (stored?.nativeJobId != null) jobs.add(stored!.nativeJobId!);
            }
          }
          controller.dispose();
          for (final id in jobs) {
            try {
              final status = await api.status(id);
              if (['running', 'queued', 'pausing'].contains(status['state'])) {
                await api.cancel(id);
              }
            } on Object {
              // Preserve the test failure while making a best-effort native cleanup.
            }
          }
          final releaseDeadline = DateTime.now().add(
            const Duration(seconds: 10),
          );
          var released = false;
          do {
            try {
              final response = await api.capabilities();
              final caps = response['capabilities']! as Map<String, Object?>;
              released =
                  caps['activeJobs'] == 0 &&
                  caps['reservedWorkers'] == 0 &&
                  caps['reservedMemoryMiB'] == 0;
            } on Object {
              break;
            }
            if (released) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } while (DateTime.now().isBefore(releaseDeadline));
          if (released && await temporary.exists()) {
            await temporary.delete(recursive: true);
          } else if (await temporary.exists()) {
            debugPrint(
              'Native TIFF cleanup timed out; kept ${temporary.path} alive.',
            );
          }
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
