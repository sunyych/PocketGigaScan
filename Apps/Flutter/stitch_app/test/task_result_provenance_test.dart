import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/task_result_provenance.dart';

void main() {
  test(
    'pure visual report remains normal even when the request was grid-assisted',
    () {
      final provenance = TaskResultProvenance.fromReport({
        'geometryModel': 'visual-sift-ransac-inlier-rays-wahba-global-rotation',
        'placementMode': 'grid-assisted',
        'qualityStatus': 'passed-measured-checks',
        'completeCorrespondenceEvidence': true,
        'visualTileCount': 9,
        'gridEstimatedTileCount': 0,
        'forcedGridTileCount': 0,
        'totalTileCount': 9,
      });

      expect(provenance.kind, TaskResultProvenanceKind.normal);
    },
  );

  test('measured overlap grid is distinct from nominal forced retry grid', () {
    final measured = TaskResultProvenance.fromReport({
      'geometryModel': 'central-measured-overlap-grid',
      'nominalGridOnlyNeedsVisualReview': true,
      'qualityStatus': 'needs-visual-review',
      'visualTileCount': 0,
      'gridEstimatedTileCount': 9,
      'forcedGridTileCount': 0,
      'totalTileCount': 9,
    });
    final forced = TaskResultProvenance.fromReport({
      'geometryModel': 'nominal-fov-grid',
      'nominalGridOnlyNeedsVisualReview': true,
      'qualityStatus': 'needs-visual-review',
      'visualTileCount': 0,
      'gridEstimatedTileCount': 9,
      'forcedGridTileCount': 9,
      'totalTileCount': 9,
    });

    expect(measured.kind, TaskResultProvenanceKind.measuredGrid);
    expect(forced.kind, TaskResultProvenanceKind.forcedGrid);
  });

  test('partial visual and grid evidence is classified as mixed', () {
    final provenance = TaskResultProvenance.fromReport({
      'geometryModel':
          'visual-component-rigid-grid-bridge-refinement-plus-sift-ransac-local-rotation-steps',
      'qualityStatus': 'needs-visual-review',
      'visualTileCount': 7,
      'gridEstimatedTileCount': 2,
      'forcedGridTileCount': 1,
      'totalTileCount': 9,
    });

    expect(provenance.kind, TaskResultProvenanceKind.mixedGrid);
  });

  test(
    'old task without a readable layout stays unknown but keeps retry marker',
    () async {
      final root = await Directory.systemTemp.createTemp('result-provenance-');
      addTearDown(() => root.delete(recursive: true));
      final task = _task(root.path, automaticGridRetry: true);

      final provenance = await TaskResultProvenance.loadForTask(task);

      expect(provenance.kind, TaskResultProvenanceKind.unknown);
      expect(provenance.isAutomaticGridRetry, isTrue);
    },
  );

  test('reader loads report and tile totals from layout.json', () async {
    final root = await Directory.systemTemp.createTemp('result-layout-');
    addTearDown(() => root.delete(recursive: true));
    final layout = File('${root.path}${Platform.pathSeparator}layout.json');
    await layout.writeAsString(
      jsonEncode({
        'tiles': List<Object?>.filled(9, const {}),
        'report': {
          'geometryModel': 'nominal-fov-grid',
          'nominalGridOnlyNeedsVisualReview': true,
          'qualityStatus': 'needs-visual-review',
          'visualTileCount': 0,
          'gridEstimatedTileCount': 9,
          'forcedGridTileCount': 0,
        },
      }),
    );
    final loaded = await TaskResultProvenance.loadForTask(_task(root.path));
    expect(loaded.kind, TaskResultProvenanceKind.nominalGrid);
    expect(loaded.totalTileCount, 9);
  });
}

StitchTask _task(String outputDirectory, {bool automaticGridRetry = false}) =>
    StitchTask(
      id: 'provenance-task',
      createdAt: DateTime.utc(2026),
      sourceDirectory: '/source',
      outputDirectory: outputDirectory,
      photos: const [],
      grid: const GridOptions(),
      horizontalFovDegrees: 90,
      memoryBudgetMiB: 256,
      workers: 1,
      phase: StitchPhase.completed,
      automaticGridRetry: automaticGridRetry,
    );
