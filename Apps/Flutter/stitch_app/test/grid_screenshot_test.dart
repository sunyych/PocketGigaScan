import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/empty_batch_queue_controller.dart';
import 'support/chinese_test_app.dart';

class _ScreenshotApi implements JobApi {
  @override
  bool get isAvailable => false;
  @override
  String get unavailableReason => '核心未配置';
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
  @override
  Future<Map<String, Object?>> capabilities() async =>
      throw UnimplementedError();
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => throw UnimplementedError();
}

class _ScreenshotPower implements PowerGate {
  @override
  Future<PowerState> readState() async => PowerState.externalPower;
}

class _ScreenshotForegroundLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}
  @override
  Future<void> disable() async {}
}

class _ScreenshotRepository extends TaskRepository {
  _ScreenshotRepository(this.task);
  final StitchTask task;
  @override
  Future<List<StitchTask>> loadAll() async => [task];
  @override
  Future<void> save(StitchTask value) async {}
}

void main() {
  testWidgets(
    'populated 24×16 force-grid contact sheet remains usable at desktop, 1000px, and mobile sizes',
    (tester) async {
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('stitch-grid-golden-'),
      ))!;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final image = File('${temp.path}/thumbnail.png');
      await tester.runAsync(
        () => image.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOIWnAJAAMkAc2CFM/BAAAAAElFTkSuQmCC',
          ),
        ),
      );
      final photos = <ImportedPhoto>[
        for (var row = 0; row < 16; row++)
          for (var column = 0; column < 24; column++)
            ImportedPhoto(
              originalName:
                  '${row.toString().padLeft(2, '0')}_${column.toString().padLeft(2, '0')}.jpg',
              storedPath: image.path,
              sha256: 'fixture',
              width: 3840,
              height: 2160,
              originalOrder: row * 24 + column,
            ),
      ];
      final task = StitchTask(
        id: '384-fixture',
        createdAt: DateTime.utc(2026),
        sourceDirectory: temp.path,
        outputDirectory: '${temp.path}/output',
        photos: photos,
        grid: GridOptions(
          rows: 16,
          columns: 24,
          forceGridCells: {const GridCell(0, 1), const GridCell(15, 23)},
        ),
        horizontalFovDegrees: 2.933,
        memoryBudgetMiB: 128,
        workers: 4,
        phase: StitchPhase.imported,
      );
      final repo = _ScreenshotRepository(task);

      for (final (size, golden) in [
        (const Size(1280, 900), 'goldens/grid_24x16_desktop.png'),
        (const Size(1000, 900), 'goldens/grid_24x16_1000px.png'),
        (const Size(390, 844), 'goldens/grid_24x16_mobile.png'),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          ChineseTestApp(
            home: StitchHomePage(
              initialTask: task,
              jobApi: _ScreenshotApi(),
              powerGate: _ScreenshotPower(),
              repository: repo,
              batchQueueController: EmptyBatchQueueController(
                api: _ScreenshotApi(),
                taskRepository: repo,
              ),
              foregroundWorkLock: _ScreenshotForegroundLock(),
              mobileOverride: size.width < 600,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final mainVerticalScroll = find
            .descendant(
              of: find.byType(Expanded),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .hitTestable();
        expect(mainVerticalScroll, findsOneWidget);
        for (
          var attempt = 0;
          attempt < 4 && find.text('照片与网格映射（384/384）').evaluate().isEmpty;
          attempt++
        ) {
          await tester.drag(mainVerticalScroll, const Offset(0, -900));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump();
        }
        final contactSheetLabel = find.text('照片与网格映射（384/384）');
        expect(contactSheetLabel, findsOneWidget);
        await tester.ensureVisible(contactSheetLabel);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        expect(find.byIcon(Icons.push_pin), findsAtLeastNWidgets(1));
        final contactSheet = tester.getSize(find.byType(GridView).first);
        expect(contactSheet.width / 24, greaterThanOrEqualTo(15));
        expect(contactSheet.height, greaterThanOrEqualTo(100));
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden));
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
