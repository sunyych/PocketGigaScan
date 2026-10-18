import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/output_source_locator.dart';

void main() {
  final task = StitchTask(
    id: 'trace',
    createdAt: DateTime.utc(2026),
    sourceDirectory: '/in',
    outputDirectory: '/out',
    photos: [
      const ImportedPhoto(
        originalName: '0_0.jpg',
        storedPath: '/in/0_0.jpg',
        sha256: 'a',
        width: 100,
        height: 100,
        originalOrder: 0,
      ),
    ],
    grid: const GridOptions(rows: 1, columns: 1),
    horizontalFovDegrees: 90,
    memoryBudgetMiB: 128,
    workers: 1,
    phase: StitchPhase.completed,
  );

  Map<String, Object?> layout({
    Object? warp,
    bool legacyLock = false,
    String tilePath = '/in/0_0.jpg',
  }) => {
    'projection': 'spherical',
    'yawMinRad': -0.5,
    'yawMaxRad': 0.5,
    'pitchMinRad': -0.5,
    'pitchMaxRad': 0.5,
    'tiles': [
      {
        'row': 0,
        'column': 0,
        'path': tilePath,
        'width': 100,
        'height': 100,
        'fx': 50,
        'fy': 50,
        'cx': 49.5,
        'cy': 49.5,
        'cameraToWorld': [1, 0, 0, 0, 1, 0, 0, 0, 1],
        'positionSource': legacyLock ? 'gridEstimated' : 'visual',
        'forceGrid': legacyLock,
        'sourcePlaneWarp': ?warp,
      },
    ],
    'report': {'edgeDiagnostics': []},
  };

  test('maps output center ray into camera source coordinates', () {
    final trace = OutputSourceLocator.locate(
      layout: layout(),
      task: task,
      outputWidth: 100,
      outputHeight: 100,
      outputX: 49.5,
      outputY: 49.5,
    );
    expect(trace.cameras, hasLength(1));
    expect(trace.cameras.single.sourceX, closeTo(49.5, 1e-8));
    expect(trace.cameras.single.sourceY, closeTo(49.5, 1e-8));
    expect(trace.rendererChoice, isNull);
    expect(trace.exposureAndColorGains, isNull);
  });

  test('rejects coordinates outside output bounds', () {
    expect(
      () => OutputSourceLocator.locate(
        layout: layout(),
        task: task,
        outputWidth: 100,
        outputHeight: 100,
        outputX: 100,
        outputY: 0,
      ),
      throwsFormatException,
    );
  });

  test(
    'returns no camera when the source-plane inverse resolves outside source pixels',
    () {
      final outwardWarp = {
        'columns': 3,
        'rows': 3,
        'offsets': List.generate(9, (_) => [64.0, 0.0]),
      };
      final trace = OutputSourceLocator.locate(
        layout: layout(warp: outwardWarp),
        task: task,
        outputWidth: 100,
        outputHeight: 100,
        outputX: 0,
        outputY: 49,
      );
      expect(trace.cameras, isEmpty);
    },
  );

  test('inverts nonidentity warp and reports legacy hard lock as unknown', () {
    final warp = {
      'columns': 3,
      'rows': 3,
      'offsets': List.generate(9, (_) => [2.0, -1.0]),
    };
    final trace = OutputSourceLocator.locate(
      layout: layout(warp: warp, legacyLock: true),
      task: task,
      outputWidth: 100,
      outputHeight: 100,
      outputX: 49.5,
      outputY: 49.5,
    );
    expect(trace.cameras, hasLength(1));
    expect(trace.cameras.single.sourceX, closeTo(47.5, 0.03));
    expect(trace.cameras.single.sourceY, closeTo(50.5, 0.03));
    expect(trace.cameras.single.placementKind, 'hardGridLock');
    expect(trace.cameras.single.placementOrigin, 'legacyUnknown');
  });

  test('edge indices follow layout tile order after task photo reordering', () {
    final reorderedTask = task.copyWith(
      photos: [
        task.photos.single,
        const ImportedPhoto(
          originalName: '0_1.jpg',
          storedPath: '/in/0_1.jpg',
          sha256: 'b',
          width: 100,
          height: 100,
          originalOrder: 1,
        ),
      ],
      grid: const GridOptions(rows: 1, columns: 2),
    );
    Map<String, Object?> tile(int row, int column, String path) => {
      'row': row,
      'column': column,
      'path': path,
      'width': 100,
      'height': 100,
      'fx': 50,
      'fy': 50,
      'cx': 49.5,
      'cy': 49.5,
      'cameraToWorld': [1, 0, 0, 0, 1, 0, 0, 0, 1],
      'positionSource': 'visual',
    };
    final orderedLayout = {
      'projection': 'spherical', 'yawMinRad': -0.5, 'yawMaxRad': 0.5,
      'pitchMinRad': -0.5, 'pitchMaxRad': 0.5,
      // Deliberately place task photo 1 first in native tile order.
      'tiles': [tile(0, 1, '/in/0_1.jpg'), tile(0, 0, '/in/0_0.jpg')],
      'report': {
        'edgeDiagnostics': [
          {
            'from': 0,
            'to': 1,
            'disposition': 'accepted',
            'rayMedianResidualPx': 2.5,
            'rayRmsResidualPx': 3.0,
          },
        ],
      },
    };
    final trace = OutputSourceLocator.locate(
      layout: orderedLayout,
      task: reorderedTask,
      outputWidth: 100,
      outputHeight: 100,
      outputX: 49,
      outputY: 49,
    );
    expect(trace.cameras, hasLength(2));
    for (final camera in trace.cameras) {
      expect(camera.neighborEdges, hasLength(1));
      expect(camera.neighborEdges.single.disposition, 'accepted');
      expect(camera.neighborEdges.single.medianResidualPx, 2.5);
    }
  });

  test(
    'matches Windows extended drive and UNC paths ignoring prefix and case',
    () {
      final driveTask = task.copyWith(
        photos: [task.photos.single.copyWithPath(r'C:\CAPTURES\0_0.jpg')],
      );
      final driveTrace = OutputSourceLocator.locate(
        layout: layout(tilePath: r'\\?\c:\captures\0_0.jpg'),
        task: driveTask,
        outputWidth: 100,
        outputHeight: 100,
        outputX: 49,
        outputY: 49,
      );
      expect(driveTrace.cameras, hasLength(1));

      final uncTask = task.copyWith(
        photos: [
          task.photos.single.copyWithPath(r'\\Server\Share\Captures\0_0.jpg'),
        ],
      );
      final uncTrace = OutputSourceLocator.locate(
        layout: layout(tilePath: r'\\?\UNC\server\share\captures\0_0.jpg'),
        task: uncTask,
        outputWidth: 100,
        outputHeight: 100,
        outputX: 49,
        outputY: 49,
      );
      expect(uncTrace.cameras, hasLength(1));
    },
  );

  test('independently reads PNG/TIFF dimensions and refuses JPEG XL', () async {
    final directory = await Directory.systemTemp.createTemp('output-dims-');
    addTearDown(() => directory.delete(recursive: true));
    final png = File('${directory.path}/tiny.png');
    await png.writeAsBytes([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
      0,
      0,
      0,
      3,
      0,
      0,
      0,
      2,
    ]);
    expect(await readExportDimensions(png.path), (3, 2));
    final tiff = File('${directory.path}/tiny.tif');
    await tiff.writeAsBytes([
      0x49,
      0x49,
      42,
      0,
      8,
      0,
      0,
      0,
      2,
      0,
      0,
      1,
      4,
      0,
      1,
      0,
      0,
      0,
      3,
      0,
      0,
      0,
      1,
      1,
      4,
      0,
      1,
      0,
      0,
      0,
      2,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    expect(await readExportDimensions(tiff.path), (3, 2));
    final jxl = File('${directory.path}/tiny.jxl');
    await jxl.writeAsBytes([1, 2, 3]);
    expect(await readExportDimensions(jxl.path), isNull);
  });
}
