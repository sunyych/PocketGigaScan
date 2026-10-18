import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/photo_importer.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:path/path.dart' as p;
import 'support/empty_batch_queue_controller.dart';

final _onePixelJpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDnaKKK9I4D/9k=',
);

class _ImportJobApi implements JobApi {
  @override
  bool get isAvailable => false;
  @override
  String? get unavailableReason => 'Import workflow test';
  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'jpegXlAvailable': false,
      'exportFormats': {'png': true},
    },
  };
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) => capabilities();
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => throw UnimplementedError();
  @override
  Future<Map<String, Object?>> status(String jobId) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> pause(String jobId) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> resume(String jobId) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> cancel(String jobId) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      throw UnimplementedError();
}

class _PickerSequenceImporter extends PhotoImporter {
  _PickerSequenceImporter(this.results);

  final List<Object?> results;
  int calls = 0;

  @override
  Future<List<PlatformFile>?> pickJpegs() async {
    calls++;
    final result = results.removeAt(0);
    if (result == null) return null;
    if (result is List<PlatformFile>) return result;
    throw result;
  }
}

class _TestForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

class _NoIoTaskRepository extends TaskRepository {
  @override
  Future<List<StitchTask>> loadAll() async => const [];
}

Future<void> _pumpImport(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'cancel and picker error leave import reusable in English and Chinese',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final language in const ['en', 'zh']) {
        final importer = _PickerSequenceImporter([
          null,
          const ImportFailure('picker test failure'),
        ]);
        final repository = _NoIoTaskRepository();
        final api = _ImportJobApi();
        await tester.pumpWidget(
          LumiaStitchApp(
            locale: Locale(language),
            home: StitchHomePage(
              photoImporter: importer,
              repository: repository,
              jobApi: api,
              batchQueueController: EmptyBatchQueueController(
                api: api,
                taskRepository: repository,
              ),
              foregroundWorkLock: _TestForegroundLock(),
              mobileOverride: false,
            ),
          ),
        );
        await _pumpImport(tester);
        final importButton = find.byType(FloatingActionButton);
        expect(importButton, findsOneWidget);

        await tester.tap(importButton);
        await _pumpImport(tester);
        expect(importer.calls, 1);
        expect(find.textContaining('Import failed:'), findsNothing);
        expect(find.textContaining('导入失败：'), findsNothing);
        expect(
          tester.widget<FloatingActionButton>(importButton).onPressed,
          isNotNull,
        );

        await tester.tap(importButton);
        await _pumpImport(tester);
        expect(importer.calls, 2);
        expect(
          find.text(language == 'en' ? 'Import failed: ' : '导入失败：'),
          findsOneWidget,
        );
        expect(
          tester.widget<FloatingActionButton>(importButton).onPressed,
          isNotNull,
        );
        expect(await repository.loadAll(), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  test(
    'copies, hashes, records metadata, and retains 37 selected photos',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'pocket-import-pipeline-',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final originals = Directory('${temp.path}/originals')..createSync();
      final selected = <PlatformFile>[];
      final sourceHashes = <String>[];
      for (var index = 0; index < 37; index++) {
        // Add a legal JPEG COM marker after SOI for distinct hashes.
        final bytes = <int>[
          ..._onePixelJpeg.take(2),
          0xff,
          0xfe,
          0x00,
          0x04,
          0x00,
          index,
          ..._onePixelJpeg.skip(2),
        ];
        final file = File('${originals.path}/photo-$index.jpg')
          ..writeAsBytesSync(bytes);
        sourceHashes.add(sha256.convert(bytes).toString());
        selected.add(
          PlatformFile(
            name: file.uri.pathSegments.last,
            path: file.path,
            size: bytes.length,
          ),
        );
      }
      expect(sourceHashes.toSet(), hasLength(37));
      final untouchedExport = File('${temp.path}/previous-export.png')
        ..writeAsBytesSync(const [1, 3, 3, 7]);
      final exportHash = sha256
          .convert(untouchedExport.readAsBytesSync())
          .toString();
      final repository = TaskRepository(
        rootDirectory: Directory(p.join(temp.path, 'task-records')),
      );
      final id = repository.createId();
      final taskDirectory = p.join(temp.path, 'task-records', id);
      final batch = await PhotoImporter().copyIntoTask(selected, taskDirectory);
      final task = StitchTask(
        id: id,
        createdAt: DateTime.now(),
        sourceDirectory: batch.inputDirectory,
        outputDirectory: p.join(taskDirectory, 'output'),
        photos: batch.photos,
        grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 37),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 512,
        workers: 4,
        phase: StitchPhase.imported,
      );
      await repository.save(task);
      final loaded = await repository.loadAll();
      expect(loaded, hasLength(1));
      final persisted = loaded.single;
      expect(persisted.photos, hasLength(37));
      for (var index = 0; index < persisted.photos.length; index++) {
        final photo = persisted.photos[index];
        expect(photo.originalOrder, index);
        expect(photo.originalName, 'photo-$index.jpg');
        expect((photo.width, photo.height), (1, 1));
        expect(photo.sha256, sourceHashes[index]);
        final imported = File(photo.storedPath);
        final source = File(selected[index].path!);
        expect(await imported.exists(), isTrue);
        expect(await source.exists(), isTrue);
        expect(
          (await sha256.bind(imported.openRead()).first).toString(),
          sourceHashes[index],
        );
        expect(
          (await sha256.bind(source.openRead()).first).toString(),
          sourceHashes[index],
        );
      }
      expect(
        sha256.convert(await untouchedExport.readAsBytes()).toString(),
        exportHash,
      );
    },
  );

  testWidgets('shows the persisted count for a task with 37 photos', (
    tester,
  ) async {
    final photos = List<ImportedPhoto>.generate(
      37,
      (index) => ImportedPhoto(
        originalName: 'photo-$index.jpg',
        storedPath: 'photo-$index.jpg',
        sha256: 'hash-$index',
        width: 1,
        height: 1,
        originalOrder: index,
        exifMake: 'Fixture',
      ),
    );
    final task = StitchTask(
      id: 'display-37-photos',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'fixtures',
      outputDirectory: 'exports',
      photos: photos,
      grid: const GridOptions(rows: 1, columns: 37),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 512,
      workers: 4,
      phase: StitchPhase.completed,
    );
    final repository = _NoIoTaskRepository();
    final api = _ImportJobApi();
    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('en'),
        home: StitchHomePage(
          initialTask: task,
          repository: repository,
          jobApi: api,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          foregroundWorkLock: _TestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('37 source photos'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
