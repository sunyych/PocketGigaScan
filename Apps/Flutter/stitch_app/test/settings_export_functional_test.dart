import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/chinese_test_app.dart';
import 'support/empty_batch_queue_controller.dart';

class _ExportApi implements JobApi {
  String? destination;
  int exports = 0;
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Map<String, Object?>> capabilities() async => {
    'ok': true,
    'capabilities': {
      'jpegXlAvailable': true,
      'exportFormats': {'png': true, 'tiff': true, 'jxl': true},
    },
  };
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => capabilities();
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
  Future<Map<String, Object?>> export(String jobId, String destination) async {
    exports++;
    this.destination = destination;
    File(destination).writeAsBytesSync([1, 2, 3]);
    final time = DateTime.now().toUtc().millisecondsSinceEpoch;
    return {
      'ok': true,
      'state': 'completed',
      'operation': 'export',
      'exportDestination': destination,
      'events': [
        {
          'id': 1,
          'timestampUtc': time - 10,
          'kind': 'native-transition',
          'stage': 'export',
          'state': 'running',
          'operation': 'export',
        },
        {
          'id': 2,
          'timestampUtc': time,
          'kind': 'native-transition',
          'stage': 'export',
          'state': 'completed',
          'operation': 'export',
        },
      ],
    };
  }
}

class _Tasks extends TaskRepository {
  _Tasks(this.task);
  final StitchTask task;
  final saved = <StitchTask>[];
  @override
  Future<List<StitchTask>> loadAll() async => [task];
  @override
  Future<void> save(StitchTask value) async {
    saved.add(value);
  }
}

class _Power implements PowerGate {
  @override
  Future<PowerState> readState() async => PowerState.externalPower;
}

class _Lock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

StitchTask _task(String folder) => StitchTask(
  id: 'settings-export-task',
  createdAt: DateTime.utc(2026, 10, 6),
  sourceDirectory: 'source',
  outputDirectory: 'private-task-output',
  photos: const [
    ImportedPhoto(
      originalName: '00.jpg',
      storedPath: '00.jpg',
      sha256: 'fixture',
      width: 100,
      height: 80,
      originalOrder: 0,
    ),
  ],
  grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 128,
  workers: 1,
  phase: StitchPhase.completed,
  nativeJobId: 'completed-job',
  exportFormat: ExportFormat.tiff,
  exportDirectory: folder,
);

void main() {
  testWidgets(
    'single task keeps its saved quality while Windows encodes into its selected destination',
    (tester) async {
      if (!Platform.isWindows) return;
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('settings-export-functional-'),
      );
      if (temp == null) throw StateError('Temporary directory creation failed');
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );

      final folder = '${temp.path}${Platform.pathSeparator}selected-output';
      final task = _task(folder);
      final api = _ExportApi();
      final repository = _Tasks(task);
      final queue = EmptyBatchQueueController(
        api: api,
        taskRepository: repository,
      );
      final settings = SettingsController(
        initial: AppSettings.defaults(
          mobile: false,
        ).copyWith(outputDirectory: folder),
      );
      await tester.pumpWidget(
        ChineseTestApp(
          home: StitchHomePage(
            jobApi: api,
            repository: repository,
            batchQueueController: queue,
            foregroundWorkLock: _Lock(),
            powerGate: _Power(),
            initialTask: task,
            mobileOverride: false,
            settingsController: settings,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();
      await tester.tap(find.text('输出画质'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<ExportFormat>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PNG（无损）').last);
      await tester.pumpAndSettle();
      expect(
        task.exportFormat,
        ExportFormat.tiff,
        reason: 'Preference edits apply only to new tasks.',
      );
      Navigator.of(tester.element(find.text('输出画质'))).pop();
      await tester.pumpAndSettle();

      final exportButton = find.byKey(const Key('export-task-action'));
      await tester.ensureVisible(exportButton);
      await tester.tap(exportButton);
      final deadline = Stopwatch()..start();
      bool publicationRecorded() =>
          api.destination != null &&
          repository.saved.any(
            (saved) => saved.publishedExportPath == api.destination,
          );
      while (!publicationRecorded()) {
        if (deadline.elapsed > const Duration(seconds: 10)) {
          fail(
            'Export did not persist its publication receipt within 10 seconds.',
          );
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(api.exports, 1);
      expect(api.destination, startsWith(folder));
      final published = repository.saved.lastWhere(
        (saved) => saved.publishedExportPath == api.destination,
      );
      expect(published.exportPath, api.destination);
      expect(
        published.publishedExportPath,
        api.destination,
        reason:
            'The Windows receipt points at the encoded output and avoids copying a huge file onto itself.',
      );
      final finished = published.timeline.events
          .where(
            (event) =>
                event.kind == 'native-transition' && event.state == 'completed',
          )
          .toList();
      expect(finished, hasLength(1));
      expect(finished.single.operation, 'export');
      expect(
        published.timeline.events.where(
          (event) => event.kind == 'lifecycle' && event.state == 'completed',
        ),
        isEmpty,
        reason:
            'A native completion must not also produce a duplicate UI lifecycle event.',
      );
      expect(File(api.destination!).existsSync(), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      queue.dispose();
      settings.dispose();
    },
  );
}
