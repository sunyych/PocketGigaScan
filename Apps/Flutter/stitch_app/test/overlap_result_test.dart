import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/main.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/task_repository.dart';
import 'support/chinese_test_app.dart';

class _NoopLock implements ForegroundWorkLock {
  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}
}

class _ResultRepository extends TaskRepository {
  _ResultRepository(this.task);
  final StitchTask task;

  @override
  Future<List<StitchTask>> loadAll() async => [task];
}

void main() {
  testWidgets('result shows measured axes, absolute steps and sample pairs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('stitch-overlap-result-'),
    ))!;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final task = StitchTask(
      id: 'overlap-result',
      createdAt: DateTime.utc(2026),
      sourceDirectory: temp.path,
      outputDirectory: '${temp.path}/output',
      photos: const [
        ImportedPhoto(
          originalName: 'center.jpg',
          storedPath: 'center.jpg',
          sha256: 'hash',
          width: 3840,
          height: 2160,
          originalOrder: 0,
        ),
      ],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 2.93,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.completed,
      resultStats: const {
        'alignment': {
          'gridOverlapEstimate': {
            'horizontal': {
              'overlap': 0.28,
              'stepPixels': -2765,
              'pairs': [
                {'first': '07_11.jpg', 'second': '07_12.jpg'},
              ],
            },
            'vertical': {
              'overlap': 0.24,
              'stepPixels': 1641,
              'pairs': [
                {'first': '07_11.jpg', 'second': '08_11.jpg'},
              ],
            },
            'method': 'SIFT/BF',
            'confidence': 0.83,
            'provenance': 'estimated-grid-not-calibrated',
          },
        },
      },
    );
    await tester.pumpWidget(
      ChineseTestApp(
        home: StitchHomePage(
          initialTask: task,
          repository: _ResultRepository(task),
          foregroundWorkLock: _NoopLock(),
          mobileOverride: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('水平 28.0% · 垂直 24.0%'), findsOneWidget);
    expect(find.textContaining('水平 2765 px · 垂直 1641 px'), findsOneWidget);
    expect(find.textContaining('07_11.jpg ↔ 07_12.jpg'), findsOneWidget);
    expect(
      find.textContaining('estimated-grid-not-calibrated'),
      findsOneWidget,
    );
    expect(find.textContaining('SIFT/BF'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });
}
