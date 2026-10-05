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

  test('JPEG XL is a distinct lossless extension and fingerprint persists', () {
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
    expect(ExportFormat.jpegXl.supportedOnMobile, isFalse);
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
