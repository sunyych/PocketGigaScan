import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/main.dart' show LumiaStitchApp, StitchHomePage;
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/photo_importer.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'package:stitch_app/services/power_service.dart';

import '../test/support/empty_batch_queue_controller.dart';

class _WindowsImportJobApi implements JobApi {
  @override
  bool get isAvailable => false;
  @override
  String? get unavailableReason => 'Import-only integration test';
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

class _WindowsFixtureImporter extends PhotoImporter {
  _WindowsFixtureImporter(this.files);
  final List<PlatformFile> files;

  // The test substitutes only selection. PhotoImporter.copyIntoTask still
  // streams, hashes, parses metadata, and persists the actual fixture bytes.
  @override
  Future<List<PlatformFile>?> pickJpegs() async => files;
}

class _WindowsTestForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

Future<String> _hashFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixturePath = String.fromEnvironment('TEST_WINDOWS_IMPORT_DIR');
  final skipReason = !Platform.isWindows
      ? 'This integration check requires the Windows Flutter engine.'
      : fixturePath.isEmpty
      ? 'Set TEST_WINDOWS_IMPORT_DIR to a directory of original JPEG fixtures.'
      : null;
  final testDescription = skipReason == null
      ? 'Windows engine streams, hashes, records, and preserves every fixture JPEG'
      : 'Windows import integration skipped: $skipReason';

  testWidgets(testDescription, (tester) async {
    final sourceDirectory = Directory(fixturePath);
    expect(await sourceDirectory.exists(), isTrue, reason: fixturePath);
    final sources = await sourceDirectory
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
    sources.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    expect(sources.length, greaterThan(36));
    final sourceHashes = <String>[];
    final sourceLengths = <int>[];
    for (final source in sources) {
      sourceHashes.add(await _hashFile(source));
      sourceLengths.add(await source.length());
    }

    final temp = await Directory.systemTemp.createTemp(
      'pocket-windows-import-integration-',
    );
    final existingExport = File(p.join(temp.path, 'prior-export.bin'))
      ..writeAsBytesSync(const [0x50, 0x47, 0x53, 0x2d, 0x45, 0x58, 0x50]);
    final preservedExportHash = await _hashFile(existingExport);
    final repository = TaskRepository(
      rootDirectory: Directory(p.join(temp.path, 'isolated-task-records')),
    );
    final importer = _WindowsFixtureImporter([
      for (final source in sources)
        PlatformFile(
          name: p.basename(source.path),
          path: source.path,
          size: sourceLengths[sources.indexOf(source)],
        ),
    ]);
    final api = _WindowsImportJobApi();
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => temp.delete(recursive: true));

    await tester.pumpWidget(
      LumiaStitchApp(
        locale: const Locale('en'),
        home: StitchHomePage(
          photoImporter: importer,
          repository: repository,
          jobApi: api,
          batchQueueController: EmptyBatchQueueController(
            api: api,
            taskRepository: repository,
          ),
          foregroundWorkLock: _WindowsTestForegroundLock(),
          mobileOverride: false,
        ),
      ),
    );
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byType(FloatingActionButton));
    final persisted = await tester.runAsync(() async {
      final timer = Stopwatch()..start();
      while (timer.elapsed < const Duration(minutes: 20)) {
        if ((await repository.loadAll()).isNotEmpty) return true;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      return false;
    });
    expect(
      persisted,
      isTrue,
      reason: 'The full fixture import was not persisted within 20 minutes.',
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    final tasks = await repository.loadAll();
    expect(tasks, hasLength(1));
    final task = tasks.single;
    expect(task.photos.length, sources.length);
    expect(task.photos.length, greaterThan(36));
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      final photo = task.photos[index];
      expect(photo.originalOrder, index);
      expect(photo.originalName, p.basename(source.path));
      expect(photo.sha256, sourceHashes[index]);
      expect(photo.width, greaterThan(0));
      expect(photo.height, greaterThan(0));
      final importedFile = File(photo.storedPath);
      expect(await importedFile.length(), sourceLengths[index]);
      expect(await _hashFile(importedFile), sourceHashes[index]);
      expect(await source.exists(), isTrue);
      expect(await _hashFile(source), sourceHashes[index]);
    }
    expect(await _hashFile(existingExport), preservedExportHash);
    expect(await repository.loadById(task.id), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: skipReason != null);
}
