import 'dart:io';

import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';

class LocalizationSurfaceJobApi implements JobApi {
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;

  @override
  Future<Map<String, Object?>> capabilities() async => {
    'capabilities': {'jpegXlAvailable': false},
  };

  @override
  Future<Map<String, Object?>> cancel(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => const {};
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      const {};
  @override
  Future<Map<String, Object?>> pause(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> resume(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => const {};
  @override
  Future<Map<String, Object?>> status(String jobId) async => const {};
}

class LocalizationSurfaceTaskRepository extends TaskRepository {
  @override
  Future<List<StitchTask>> loadAll() async => const [];
}

class LocalizationSurfaceLock implements ForegroundWorkLock {
  @override
  Future<void> disable() async {}
  @override
  Future<void> enable() async {}
}

StitchTask localizationTask() => StitchTask(
  id: 'localization-task',
  createdAt: DateTime.utc(2026),
  sourceDirectory: 'synthetic-input',
  outputDirectory: 'synthetic-output',
  photos: const [
    ImportedPhoto(
      originalName: 'synthetic.jpg',
      storedPath: 'synthetic-input/synthetic.jpg',
      sha256: 'synthetic-hash',
      width: 32,
      height: 24,
      originalOrder: 0,
    ),
  ],
  grid: const GridOptions(),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 512,
  workers: 4,
  phase: StitchPhase.imported,
);

Directory localizationTempDirectory(String name) =>
    Directory('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
