import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/models/export_fingerprint.dart';

StitchTask fixture() => StitchTask(
  id: 'task',
  createdAt: DateTime.utc(2026),
  sourceDirectory: 'input',
  outputDirectory: 'output',
  photos: const [
    ImportedPhoto(
      originalName: 'image.jpg',
      storedPath: 'image.jpg',
      sha256: 'hash',
      width: 3840,
      height: 2160,
      originalOrder: 0,
    ),
  ],
  grid: const GridOptions(mode: GridMode.sequence, rows: 1, columns: 1),
  horizontalFovDegrees: 45,
  memoryBudgetMiB: 128,
  workers: 1,
  phase: StitchPhase.imported,
);

void main() {
  test('grid fallback and overlap settings survive task serialization', () {
    final task = fixture().copyWith(
      forceGridFallback: true,
      autoGridOverlap: false,
      gridHorizontalOverlap: 0.45,
      gridVerticalOverlap: 0.25,
      cameraProfileId: 'dwarf3-tele-nominal-150mm',
      cameraCalibrationOverridden: true,
    );

    final restored = StitchTask.fromJson(task.toJson());

    expect(restored.forceGridFallback, isTrue);
    expect(restored.autoGridOverlap, isFalse);
    expect(restored.gridHorizontalOverlap, 0.45);
    expect(restored.gridVerticalOverlap, 0.25);
    expect(restored.cameraProfileId, 'dwarf3-tele-nominal-150mm');
    expect(restored.cameraCalibrationOverridden, isTrue);
  });

  test('large-job approval persists and is invalidated by job, grid, or photo changes', () {
    final large = fixture().copyWith(
      grid: const GridOptions(mode: GridMode.sequence, rows: 7, columns: 1),
      photos: [
        for (var index = 0; index < 7; index++)
          ImportedPhoto(
            originalName: 'image$index.jpg',
            storedPath: 'image$index.jpg',
            sha256: 'hash$index',
            width: 3840,
            height: 2160,
            originalOrder: index,
          ),
      ],
    );
    expect(large.needsLargeJobConfirmation, isTrue);
    expect(large.hasCurrentLargeJobApproval, isFalse);
    final approved = large.copyWith(
      largeJobApprovalScope: large.currentLargeJobApprovalScope,
    );
    final restored = StitchTask.fromJson(approved.toJson());
    expect(restored.hasCurrentLargeJobApproval, isTrue);
    expect(
      restored.copyWith(grid: restored.grid.copyWith(serpentine: true))
          .hasCurrentLargeJobApproval,
      isFalse,
    );
    expect(
      StitchTask.fromJson({...restored.toJson(), 'id': 'another-job'})
          .hasCurrentLargeJobApproval,
      isFalse,
    );
    expect(
      restored.copyWith(
        photos: [
          ...restored.photos,
          const ImportedPhoto(
            originalName: 'extra.jpg',
            storedPath: 'extra.jpg',
            sha256: 'extra',
            width: 3840,
            height: 2160,
            originalOrder: 7,
          ),
        ],
      ).hasCurrentLargeJobApproval,
      isFalse,
    );
  });

  test('large-job threshold is strictly above 6x6 and includes 7x6 and 7x1', () {
    StitchTask withGrid(int rows, int columns) => fixture().copyWith(
      grid: GridOptions(
        mode: GridMode.sequence,
        rows: rows,
        columns: columns,
      ),
      photos: [
        for (var index = 0; index < rows * columns; index++)
          ImportedPhoto(
            originalName: 'image$index.jpg',
            storedPath: 'image$index.jpg',
            sha256: 'hash$index',
            width: 3840,
            height: 2160,
            originalOrder: index,
          ),
      ],
    );

    expect(withGrid(6, 6).needsLargeJobConfirmation, isFalse);
    expect(withGrid(7, 6).needsLargeJobConfirmation, isTrue);
    expect(withGrid(7, 1).needsLargeJobConfirmation, isTrue);
  });

  test(
    'quality choices persist and legacy tasks retain PNG and old blending',
    () {
      final task = fixture().copyWith(
        exportFormat: ExportFormat.tiff,
        autoExportOnCompletion: true,
        refineGridNeighbors: true,
        seamBlendMode: SeamBlendMode.deghost,
        localTextureWarp: false,
      );
      final restored = StitchTask.fromJson(task.toJson());
      expect(restored.exportFormat, ExportFormat.tiff);
      expect(restored.autoExportOnCompletion, isTrue);
      expect(restored.refineGridNeighbors, isTrue);
      expect(restored.seamBlendMode, SeamBlendMode.deghost);
      expect(restored.localTextureWarp, isFalse);

      final legacy = fixture().toJson()
        ..remove('exportFormat')
        ..remove('autoExportOnCompletion')
        ..remove('refineGridNeighbors')
        ..remove('seamBlendMode');
      legacy.remove('localTextureWarp');
      final oldTask = StitchTask.fromJson(legacy);
      expect(oldTask.exportFormat, ExportFormat.png);
      expect(oldTask.autoExportOnCompletion, isFalse);
      expect(oldTask.refineGridNeighbors, isFalse);
      expect(oldTask.seamBlendMode, SeamBlendMode.feather);
      expect(oldTask.localTextureWarp, isTrue);
    },
  );

  test('JPEG XL extension, label, persistence name, and fingerprint persist', () {
    final task = fixture().copyWith(
      exportFormat: ExportFormat.jpegXl,
      exportPath: r'C:\exports\panorama.jxl',
      exportFingerprint: const ExportFileFingerprint(
        sizeBytes: 1234,
        modifiedAtMicros: 4567,
      ),
    );
    final restored = StitchTask.fromJson(task.toJson());
    expect(restored.exportFormat, ExportFormat.jpegXl);
    expect(restored.exportFingerprint?.sizeBytes, 1234);
    expect(restored.exportFingerprint?.modifiedAtMicros, 4567);
    expect(ExportFormat.fromPath('PANORAMA.JXL'), ExportFormat.jpegXl);
    expect(ExportFormat.jpegXl.extension, 'jxl');
    expect(ExportFormat.jpegXl.label, 'JPEG XL（有损）');
    expect(ExportFormat.jpegXl.shortLabel, 'JPEG XL');
    expect(ExportFormat.png.label, 'PNG（无损）');
    expect(ExportFormat.tiff.label, 'TIFF（无损，大图自动 BigTIFF）');
    expect(task.toJson()['exportFormat'], 'jpegXl');
    expect(ExportFormat.fromSavedValue('jpegXl'), ExportFormat.jpegXl);
    expect(ExportFormat.fromSavedValue('tiff'), ExportFormat.tiff);
    expect(ExportFormat.jpegXl.supportedOnMobile, isTrue);
    expect(ExportFormat.fromSavedValue('unexpected'), ExportFormat.png);
  });

  test('in-flight legacy exports migrate to an immutable checkpoint path', () {
    final legacy = fixture().toJson()
      ..['phase'] = StitchPhase.exporting.name
      ..['stage'] = 'export'
      ..['exportPath'] = r'C:\exports\pending.tif';
    final task = StitchTask.fromJson(legacy);
    expect(task.phase, StitchPhase.interrupted);
    expect(task.exportCheckpointPath, r'C:\exports\pending.tif');
    expect(task.exportPath, isNull);
  });

  test('older tasks default auto overlap on and nominal fallback off', () {
    final json = fixture().toJson()
      ..remove('forceGridFallback')
      ..remove('autoGridOverlap')
      ..remove('gridHorizontalOverlap')
      ..remove('gridVerticalOverlap');

    final restored = StitchTask.fromJson(json);

    expect(restored.forceGridFallback, isFalse);
    expect(restored.autoGridOverlap, isTrue);
    expect(restored.gridHorizontalOverlap, 0.3);
    expect(restored.gridVerticalOverlap, 0.3);
    final legacyNative = fixture().toJson()
      ..remove('autoGridOverlap')
      ..['nativeJobId'] = 'old-saved-request';
    expect(StitchTask.fromJson(legacyNative).autoGridOverlap, isFalse);
  });

  test(
    'performance options persist while legacy tasks receive safe defaults',
    () {
      final options = const PerformanceOptions(
        parallelMatching: false,
        parallelRendering: false,
        useSourceCache: false,
        useAlignmentCache: false,
        fourNeighborFirst: true,
        fastRegistration: true,
        flannMatching: true,
      );
      final task = fixture().copyWith(performanceOptions: options);
      final restored = StitchTask.fromJson(task.toJson());
      expect(restored.performanceOptions.toJson(), options.toJson());

      final legacy = fixture().toJson()
        ..remove('performanceOptions')
        ..remove('resultStats');
      expect(
        StitchTask.fromJson(legacy).performanceOptions.toJson(),
        const PerformanceOptions().toJson(),
      );

      final conflicting = fixture().toJson()
        ..['performanceOptions'] = {'orbFeatures': true, 'flannMatching': true};
      final repaired = StitchTask.fromJson(conflicting).performanceOptions;
      expect(repaired.orbFeatures, isTrue);
      expect(repaired.flannMatching, isFalse);
      expect(repaired.matcherType, 'bf');
    },
  );
}
