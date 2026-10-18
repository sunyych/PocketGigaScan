import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/photo_importer.dart';
import 'package:stitch_app/services/power_service.dart';
import 'package:stitch_app/services/spherical_request.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'loads real job ABI; optionally aligns and exports device-readable source images',
    (tester) async {
      final api = NativeJobApi();
      const expectedPower = String.fromEnvironment('TEST_EXPECT_POWER');
      if (expectedPower.isNotEmpty) {
        final actual = await PlatformPowerGate().readState();
        final expected = expectedPower == 'external'
            ? PowerState.externalPower.name
            : expectedPower;
        expect(
          actual.name,
          expected,
          reason:
              'Android power hook should report ACTION_BATTERY_CHANGED EXTRA_PLUGGED.',
        );
      }
      expect(api.isAvailable, isTrue, reason: api.unavailableReason);
      try {
        await api.status('lumia-stitch-invalid-job-smoke');
        fail('Unknown job status must return an explicit native error.');
      } on NativeJobException catch (error) {
        expect(error.code, isNotEmpty);
      }

      const sourcePath = String.fromEnvironment('TEST_SOURCE_DIR');
      if (sourcePath.isEmpty) return;
      const forceGridFallback = bool.fromEnvironment('TEST_FORCE_GRID');
      const forceAllGridCells = bool.fromEnvironment('TEST_FORCE_ALL_CELLS');
      const expectDwarfProfile = bool.fromEnvironment(
        'TEST_EXPECT_DWARF_PROFILE',
      );
      final sourceDirectory = Directory(sourcePath);
      const waitSecondsText = String.fromEnvironment(
        'TEST_WAIT_FOR_FIXTURE_SECONDS',
        defaultValue: '0',
      );
      final waitSeconds = int.tryParse(waitSecondsText);
      expect(
        waitSeconds,
        isNotNull,
        reason: 'TEST_WAIT_FOR_FIXTURE_SECONDS must be a nonnegative integer.',
      );
      expect(waitSeconds, greaterThanOrEqualTo(0));
      if (waitSeconds! > 0) {
        final readyMarker = File(p.join(sourcePath, '.ready'));
        final deadline = DateTime.now().add(Duration(seconds: waitSeconds));
        while (!await readyMarker.exists() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        expect(
          await readyMarker.exists(),
          isTrue,
          reason: 'Fixture transfer timed out; expected $sourcePath/.ready.',
        );
      }
      expect(
        await sourceDirectory.exists(),
        isTrue,
        reason:
            'Push a small image set and pass --dart-define=TEST_SOURCE_DIR=<device path>.',
      );
      final files = await sourceDirectory
          .list()
          .where(
            (entity) =>
                entity is File &&
                const {
                  '.jpg',
                  '.jpeg',
                }.contains(p.extension(entity.path).toLowerCase()),
          )
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      expect(
        files.length,
        4,
        reason:
            'Use four textured neighboring JPEGs for a reproducible 2×2 native smoke.',
      );
      final photos = <ImportedPhoto>[];
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        final metadata = await readJpegMetadata(file);
        photos.add(
          ImportedPhoto(
            originalName: p.basename(file.path),
            storedPath: file.path,
            sha256: '',
            width: metadata.width,
            height: metadata.height,
            originalOrder: index,
            exifMake: metadata.make,
            exifModel: metadata.model,
            exifLensModel: metadata.lensModel,
            exifFocalLengthMm: metadata.focalLengthMm,
          ),
        );
      }
      expect(
        photos.every(
          (photo) =>
              photo.width == photos.first.width &&
              photo.height == photos.first.height,
        ),
        isTrue,
      );
      if (expectDwarfProfile) {
        expect(photos.every((photo) => photo.isVerifiedDwarf3Tele), isTrue);
        expect(
          photos.every(
            (photo) =>
                photo.exifFocalLengthMm != null &&
                (photo.exifFocalLengthMm! - 150).abs() < 0.1,
          ),
          isTrue,
        );
      }
      const focalArg = String.fromEnvironment('TEST_FX');
      const fovArg = String.fromEnvironment('TEST_HORIZONTAL_FOV_DEGREES');
      final focalPixels = double.tryParse(focalArg);
      final horizontalFov =
          double.tryParse(fovArg) ??
          (focalPixels == null
              ? 45.0
              : 2 *
                    math.atan(photos.first.width / (2 * focalPixels)) *
                    180 /
                    math.pi);
      final task = StitchTask(
        id: 'native-smoke',
        createdAt: DateTime.now(),
        sourceDirectory: sourceDirectory.path,
        outputDirectory: '',
        photos: photos,
        grid: GridOptions(
          mode: GridMode.sequence,
          rows: 2,
          columns: 2,
          forceGridCells: forceAllGridCells
              ? {
                  const GridCell(0, 0),
                  const GridCell(0, 1),
                  const GridCell(1, 0),
                  const GridCell(1, 1),
                }
              : const {},
        ),
        horizontalFovDegrees: horizontalFov,
        memoryBudgetMiB: 128,
        workers: 1,
        phase: StitchPhase.imported,
        forceGridFallback: forceGridFallback,
        autoGridOverlap: !forceAllGridCells,
      );
      final temp = await getTemporaryDirectory();
      final output = Directory(
        p.join(
          temp.path,
          'LumiaStitchNativeSmoke-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await output.create();
      final started = await api.start(
        buildSphericalRequest(task),
        output.path,
        memoryBudgetMiB: 128,
        workers: 1,
      );
      final jobId = started['jobId'] as String;
      var current = started;
      for (var attempt = 0; attempt < 3600; attempt++) {
        if (current['state'] == 'completed') break;
        if (current['state'] == 'failed' || current['state'] == 'cancelled') {
          fail('Native job ended: $current');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        current = await api.status(jobId);
      }
      expect(
        current['state'],
        'completed',
        reason:
            'Native alignment and tiled pyramid did not finish in one hour.',
      );
      expect(current['error'], isNull);
      final manifestFile = File(p.join(output.path, 'manifest.json'));
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
      expect(manifest['complete'], isTrue);
      expect(manifest['width'], greaterThan(0));
      expect(manifest['height'], greaterThan(0));
      final layout =
          jsonDecode(
                await File(p.join(output.path, 'layout.json')).readAsString(),
              )
              as Map<String, Object?>;
      expect((layout['tiles'] as List<Object?>), hasLength(4));
      if (forceGridFallback && forceAllGridCells) {
        final report = layout['report']! as Map<String, Object?>;
        expect(report['nominalGridOnlyNeedsVisualReview'], isTrue);
        expect(report['visualTileCount'], 0);
        expect(report['gridEstimatedTileCount'], 4);
        expect(report['qualityStatus'], 'needs-visual-review');
      }
      final png = File(
        p.join(
          temp.path,
          'LumiaStitchNativeSmoke-${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      final export = await api.export(jobId, png.path);
      current = export;
      for (var attempt = 0; attempt < 600; attempt++) {
        if (current['state'] == 'completed') break;
        if (current['state'] == 'failed' || current['state'] == 'cancelled') {
          fail('Native export ended: $current');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        current = await api.status(jobId);
      }
      expect(current['state'], 'completed');
      expect(current['error'], isNull);
      expect(await png.exists(), isTrue);
      expect(await png.length(), greaterThan(1024));
      final handle = await png.open();
      try {
        final header = await handle.read(24);
        expect(header.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final data = ByteData.sublistView(header);
        expect(data.getUint32(16, Endian.big), manifest['width']);
        expect(data.getUint32(20, Endian.big), manifest['height']);
      } finally {
        await handle.close();
      }
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}
