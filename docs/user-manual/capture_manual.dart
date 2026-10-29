import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';
import 'package:stitch_app/services/task_repository.dart';

const _manualPython = String.fromEnvironment('MANUAL_PYTHON', defaultValue: '');
const _manualLanguage = String.fromEnvironment(
  'MANUAL_LANGUAGE',
  defaultValue: 'zh',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final packageRoot = Directory.current;
  final repositoryRoot = Directory(
    p.normalize(p.join(packageRoot.path, '..', '..', '..')),
  );
  final manualRoot = Directory(
    p.join(repositoryRoot.path, '.local', 'manual-capture'),
  );
  final originalRoot = Directory(p.join(manualRoot.path, 'originals'));
  final outputRoot = Directory(p.join(manualRoot.path, 'output'));
  await outputRoot.create(recursive: true);
  _requireFixtures(packageRoot, originalRoot);

  final repository = TaskRepository(
    rootDirectory: Directory(p.join(manualRoot.path, 'tasks')),
  );
  final settingsController = SettingsController(
    repository: SettingsRepository(
      file: File(p.join(manualRoot.path, 'app-settings.json')),
    ),
    initial: AppSettings.defaults(mobile: false).copyWith(
      language: _manualLanguage == 'en' ? AppLanguage.en : AppLanguage.zh,
    ),
  );
  final api = NativeJobApi();
  final batchQueue = BatchQueueController(
    api: api,
    taskRepository: repository,
    queueRepository: _ManualBatchQueueRepository(
      Directory(p.join(manualRoot.path, 'batches')),
    ),
  );
  final existingTasks = await repository.loadAll();
  final task = existingTasks.isEmpty
      ? await _makeInitialTask(packageRoot, originalRoot, outputRoot)
      : existingTasks.first;
  if (existingTasks.isEmpty) await repository.save(task);

  runApp(
    LumiaStitchApp(
      settingsController: settingsController,
      home: StitchHomePage(
        jobApi: api,
        repository: repository,
        batchQueueController: batchQueue,
        initialTask: task,
        settingsController: settingsController,
      ),
    ),
  );
}

void _requireFixtures(Directory packageRoot, Directory destination) {
  final images = [
    for (var row = 1; row <= 2; row++)
      for (var column = 1; column <= 3; column++)
        File(
          p.join(
            destination.path,
            'row_${row.toString().padLeft(2, '0')}_col_${column.toString().padLeft(2, '0')}.jpg',
          ),
        ),
  ];
  if (images.every((file) => file.existsSync() && file.lengthSync() > 1024)) {
    return;
  }
  final script = p.join(
    packageRoot.path,
    '..',
    '..',
    '..',
    'docs',
    'user-manual',
    'generate_capture_fixtures.py',
  );
  final python = _manualPython.isEmpty ? r'$env:MANUAL_PYTHON' : _manualPython;
  throw StateError(
    'Synthetic JPEGs are missing. Set MANUAL_PYTHON to the bundled Python '
    'executable, then run: & "$python" "$script" "${destination.path}"',
  );
}

Future<StitchTask> _makeInitialTask(
  Directory packageRoot,
  Directory originals,
  Directory output,
) async {
  final photos = <ImportedPhoto>[];
  for (var row = 1; row <= 2; row++) {
    for (var column = 1; column <= 3; column++) {
      final name =
          'row_${row.toString().padLeft(2, '0')}_col_${column.toString().padLeft(2, '0')}.jpg';
      final file = File(p.join(originals.path, name));
      final bytes = await file.readAsBytes();
      photos.add(
        ImportedPhoto(
          originalName: name,
          storedPath: file.path,
          sha256: sha256.convert(bytes).toString(),
          width: 640,
          height: 400,
          originalOrder: photos.length,
        ),
      );
    }
  }
  return StitchTask(
    id: 'manual-demo',
    createdAt: DateTime.now().toUtc(),
    sourceDirectory: p.relative(originals.path, from: packageRoot.path),
    outputDirectory: p.relative(output.path, from: packageRoot.path),
    photos: photos,
    grid: const GridOptions(mode: GridMode.sequence, rows: 2, columns: 3),
    horizontalFovDegrees: 45,
    memoryBudgetMiB: 512,
    workers: 2,
    phase: StitchPhase.imported,
    autoGridOverlap: true,
    exportFormat: ExportFormat.png,
  );
}

class _ManualBatchQueueRepository extends BatchQueueRepository {
  _ManualBatchQueueRepository(this.directory);

  final Directory directory;

  @override
  Future<Directory> root() async {
    await directory.create(recursive: true);
    return directory;
  }
}
