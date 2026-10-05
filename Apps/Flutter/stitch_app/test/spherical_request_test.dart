import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/spherical_request.dart';

void main() {
  test(
    'request matches native spherical contract, keeps forced photo, derives centered intrinsics',
    () {
      const photoA = ImportedPhoto(
        originalName: '原片甲.jpg',
        storedPath: '0000.jpg',
        sha256: 'a',
        width: 4000,
        height: 3000,
        originalOrder: 0,
      );
      const photoB = ImportedPhoto(
        originalName: '原片乙.jpg',
        storedPath: '0001.jpg',
        sha256: 'b',
        width: 4000,
        height: 3000,
        originalOrder: 1,
      );
      final task = StitchTask(
        id: 'job',
        createdAt: DateTime.utc(2026),
        sourceDirectory: 'input',
        outputDirectory: 'output',
        photos: const [photoA, photoB],
        grid: GridOptions(
          mode: GridMode.sequence,
          rows: 1,
          columns: 2,
          forceGridCells: {GridCell(0, 1)},
        ),
        horizontalFovDegrees: 60,
        memoryBudgetMiB: 128,
        workers: 2,
        phase: StitchPhase.imported,
      );
      final request = buildSphericalRequest(task);
      expect(request.keys.toSet(), {
        'tiles',
        'rows',
        'columns',
        'fx',
        'fy',
        'cx',
        'cy',
        'sourceWidth',
        'sourceHeight',
        'placementMode',
        'neighborMode',
        'parallelMatching',
        'parallelRendering',
        'useSourceCache',
        'useAlignmentCache',
        'alignmentCacheDir',
        'featureType',
        'matcherType',
        'registrationMegapixels',
        'allowNominalGridFallback',
        'autoGridOverlap',
        'refineGridNeighbors',
        'seamBlendMode',
        'localTextureWarp',
      });
      expect(request['placementMode'], 'grid-assisted');
      expect(request['neighborMode'], 'eight');
      expect(request['parallelMatching'], isTrue);
      expect(request['parallelRendering'], isTrue);
      expect(request['useSourceCache'], isTrue);
      expect(request['useAlignmentCache'], isTrue);
      expect(
        request['alignmentCacheDir'],
        p.normalize(p.absolute(p.join('.', '.alignment-cache'))),
      );
      expect(request['featureType'], 'sift');
      expect(request['matcherType'], 'bf');
      expect(request['registrationMegapixels'], 2.0);
      expect(request['allowNominalGridFallback'], isFalse);
      expect(request['autoGridOverlap'], isTrue);
      expect(request['refineGridNeighbors'], isFalse);
      expect(request['seamBlendMode'], 'feather');
      expect(request['localTextureWarp'], isTrue);
      expect(request.containsKey('gridHorizontalOverlap'), isFalse);
      expect(request.containsKey('gridVerticalOverlap'), isFalse);
      expect(request['rows'], 1);
      expect(request['columns'], 2);
      expect(request['sourceWidth'], 4000);
      expect(request['sourceHeight'], 3000);
      expect(request['cx'], 1999.5);
      expect(request['cy'], 1499.5);
      expect((request['fx'] as double), closeTo(4000 / (2 * 0.577350269), .01));
      final tiles = request['tiles']! as List<Map<String, Object?>>;
      expect(tiles, hasLength(2));
      expect(tiles.map((tile) => tile['path']), ['0000.jpg', '0001.jpg']);
      expect(tiles[1]['forceGrid'], true);
    },
  );

  test('force-grid opt-in and overlap values map to the native request', () {
    const photo = ImportedPhoto(
      originalName: 'one.jpg',
      storedPath: '0000.jpg',
      sha256: 'a',
      width: 100,
      height: 80,
      originalOrder: 0,
    );
    final task = StitchTask(
      id: 'job',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'in',
      outputDirectory: 'out',
      photos: const [photo],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 2,
      phase: StitchPhase.imported,
      forceGridFallback: true,
      autoGridOverlap: false,
      gridHorizontalOverlap: 0.45,
      gridVerticalOverlap: 0.25,
    );
    final request = buildSphericalRequest(task);
    expect(request['allowNominalGridFallback'], isTrue);
    expect(request['autoGridOverlap'], isFalse);
    expect(request['gridHorizontalOverlap'], 0.45);
    expect(request['gridVerticalOverlap'], 0.25);
  });

  test('auto overlap can be disabled and nominal DWARF fx scales by width', () {
    const photo = ImportedPhoto(
      originalName: 'one.jpg',
      storedPath: '0000.jpg',
      sha256: 'a',
      width: 1920,
      height: 1080,
      originalOrder: 0,
    );
    final task = StitchTask(
      id: 'job',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'in',
      outputDirectory: 'out',
      photos: const [photo],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 2.933,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.imported,
      autoGridOverlap: false,
      cameraProfileId: 'dwarf3-tele-nominal-150mm',
    );
    final request = buildSphericalRequest(task);
    expect(request['autoGridOverlap'], isFalse);
    expect(request['fx'], 37500);
    expect(request['fy'], 37500);
  });

  test(
    'performance options map to the flat native request and ORB forces BF',
    () {
      const photo = ImportedPhoto(
        originalName: 'one.jpg',
        storedPath: '0000.jpg',
        sha256: 'a',
        width: 100,
        height: 80,
        originalOrder: 0,
      );
      final task = StitchTask(
        id: 'job',
        createdAt: DateTime.utc(2026),
        sourceDirectory: 'tasks/job/input',
        outputDirectory: 'out',
        photos: const [photo],
        grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
        horizontalFovDegrees: 45,
        memoryBudgetMiB: 128,
        workers: 2,
        phase: StitchPhase.imported,
        performanceOptions: const PerformanceOptions(
          parallelMatching: false,
          parallelRendering: false,
          useSourceCache: false,
          useAlignmentCache: false,
          fourNeighborFirst: true,
          fastRegistration: true,
          flannMatching: true,
          orbFeatures: true,
        ),
      );
      final request = buildSphericalRequest(task);
      expect(request['parallelMatching'], isFalse);
      expect(request['parallelRendering'], isFalse);
      expect(request['useSourceCache'], isFalse);
      expect(request['useAlignmentCache'], isFalse);
      expect(
        request['alignmentCacheDir'],
        p.normalize(p.absolute(p.join('tasks', 'job', '.alignment-cache'))),
      );
      expect(request['neighborMode'], 'adaptive');
      expect(request['registrationMegapixels'], 0.6);
      expect(request['featureType'], 'orb');
      expect(request['matcherType'], 'bf');
    },
  );

  test('new alignment and seam options map to native request', () {
    const photo = ImportedPhoto(
      originalName: 'one.jpg',
      storedPath: '0000.jpg',
      sha256: 'a',
      width: 100,
      height: 80,
      originalOrder: 0,
    );
    final task = StitchTask(
      id: 'quality',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'input',
      outputDirectory: 'output',
      photos: const [photo],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 1,
      phase: StitchPhase.imported,
      refineGridNeighbors: true,
      seamBlendMode: SeamBlendMode.deghost,
      localTextureWarp: false,
    );
    final request = buildSphericalRequest(task);
    expect(request['refineGridNeighbors'], isTrue);
    expect(request['seamBlendMode'], 'deghost');
    expect(request['localTextureWarp'], isFalse);
  });

  test('sequence errors cannot build a truncated request', () {
    const one = ImportedPhoto(
      originalName: 'one.jpg',
      storedPath: '0000.jpg',
      sha256: 'a',
      width: 100,
      height: 80,
      originalOrder: 0,
    );
    final task = StitchTask(
      id: 'job',
      createdAt: DateTime.utc(2026),
      sourceDirectory: 'in',
      outputDirectory: 'out',
      photos: const [one],
      grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 2),
      horizontalFovDegrees: 45,
      memoryBudgetMiB: 128,
      workers: 2,
      phase: StitchPhase.imported,
    );
    expect(() => buildSphericalRequest(task), throwsFormatException);
  });
}
