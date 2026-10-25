import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/spherical_request.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS links NativeJobApi and runs a synthetic nominal 1x2 grid',
    (tester) async {
      await tester.runAsync(() async {
        if (!Platform.isIOS) return;
        final api = NativeJobApi();
        expect(api.isAvailable, isTrue, reason: api.unavailableReason);

        final capabilitiesResponse = await api.capabilities();
        final capabilities =
            capabilitiesResponse['capabilities']! as Map<String, Object?>;
        expect(capabilities['backend'], 'cpu-rust-tiled');
        final formats = capabilities['exportFormats']! as Map<String, Object?>;
        expect(capabilities['sceneAnalysisAvailable'], isFalse);
        expect(formats['png'], isTrue);
        expect(formats['tiff'], isTrue);
        expect(formats['jpeg'], isTrue);
        expect(formats['jxl'], isTrue);

        final temp = await getTemporaryDirectory();
        final root = Directory(
          p.join(
            temp.path,
            'pocket-ios-native-smoke-${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
        await root.create();
        final sourceDirectory = Directory(p.join(root.path, 'source'));
        final outputDirectory = Directory(p.join(root.path, 'output'));
        final exportDirectory = Directory(p.join(root.path, 'exports'));
        await sourceDirectory.create();
        await outputDirectory.create();
        await exportDirectory.create();
        final sources = [
          File(p.join(sourceDirectory.path, 'synthetic-00.jpg')),
          File(p.join(sourceDirectory.path, 'synthetic-01.jpg')),
        ];
        final jpegBytes = _makeSyntheticJpeg();
        for (final source in sources) {
          await source.writeAsBytes(jpegBytes);
        }
        final photos = sources.indexed
            .map(
              (entry) => ImportedPhoto(
                originalName: p.basename(entry.$2.path),
                storedPath: entry.$2.path,
                sha256: '',
                width: 128,
                height: 96,
                originalOrder: entry.$1,
              ),
            )
            .toList(growable: false);
        final task = StitchTask(
          id: 'ios-native-smoke',
          createdAt: DateTime.now(),
          sourceDirectory: sourceDirectory.path,
          outputDirectory: outputDirectory.path,
          photos: photos,
          grid: GridOptions(
            mode: GridMode.sequence,
            rows: 1,
            columns: 2,
            forceGridCells: {const GridCell(0, 0), const GridCell(0, 1)},
          ),
          horizontalFovDegrees: 60,
          memoryBudgetMiB: 128,
          workers: 1,
          phase: StitchPhase.imported,
          forceGridFallback: true,
          autoGridOverlap: false,
          gridHorizontalOverlap: 0.3,
          gridVerticalOverlap: 0.3,
        );

        final request = buildSphericalRequest(task);
        expect(request['protectPeople'], isFalse);
        expect(request['smoothWater'], isFalse);
        expect(request.containsKey('sceneModelPath'), isFalse);

        try {
          final started = await api.start(
            request,
            outputDirectory.path,
            memoryBudgetMiB: 128,
            workers: 1,
          );
          final jobId = started['jobId']! as String;
          var current = await _waitForTerminalState(api, jobId, started);
          expect(current['state'], 'completed', reason: '$current');
          expect(current['error'], isNull);
          final layout =
              jsonDecode(
                    await File(
                      p.join(outputDirectory.path, 'layout.json'),
                    ).readAsString(),
                  )
                  as Map<String, Object?>;
          final tiles = layout['tiles']! as List<Object?>;
          expect(tiles, hasLength(2));
          final tileCells = tiles.map((value) {
            final tile = value! as Map<String, Object?>;
            return '${tile['row']},${tile['column']}';
          }).toSet();
          expect(tileCells, {'0,0', '0,1'});
          final report = layout['report']! as Map<String, Object?>;
          expect(report['nominalGridOnlyNeedsVisualReview'], isTrue);
          expect(report['qualityStatus'], 'needs-visual-review');

          final expectedHeaders = <String, bool Function(Uint8List)>{
            'png': (bytes) =>
                _startsWith(bytes, const [137, 80, 78, 71, 13, 10, 26, 10]),
            'tiff': _isTiff,
            'jpeg': (bytes) => _startsWith(bytes, const [0xff, 0xd8, 0xff]),
            'jxl': _isJxl,
          };
          for (final format in ['png', 'tiff', 'jpeg', 'jxl']) {
            final destination = File(
              p.join(exportDirectory.path, 'ios-native-smoke.$format'),
            );
            current = await api.export(jobId, destination.path);
            current = await _waitForTerminalState(api, jobId, current);
            expect(current['state'], 'completed', reason: '$format: $current');
            expect(await destination.exists(), isTrue, reason: format);
            final byteLength = await destination.length();
            expect(byteLength, greaterThan(32), reason: format);
            final handle = await destination.open();
            late final Uint8List header;
            try {
              header = Uint8List.fromList(await handle.read(16));
            } finally {
              await handle.close();
            }
            expect(
              expectedHeaders[format]!(header),
              isTrue,
              reason: 'invalid $format header',
            );
            debugPrint('iOS native smoke export: $format $byteLength bytes');
          }
        } finally {
          await root.delete(recursive: true);
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

// 128x96 JPEG: deterministic colored blocks and a white center line.
// Embedded so the test needs no pubspec asset or user-provided photo.
Uint8List _makeSyntheticJpeg() => base64Decode(_syntheticJpegBase64);

const _syntheticJpegBase64 =
    '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';

Future<Map<String, Object?>> _waitForTerminalState(
  NativeJobApi api,
  String jobId,
  Map<String, Object?> initial,
) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  var current = initial;
  while (current['state'] == 'running' || current['state'] == 'queued') {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Native job $jobId did not finish: $current');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    current = await api.status(jobId);
  }
  return current;
}

bool _startsWith(Uint8List bytes, List<int> prefix) =>
    bytes.length >= prefix.length &&
    prefix.indexed.every((entry) => bytes[entry.$1] == entry.$2);

bool _isTiff(Uint8List bytes) =>
    _startsWith(bytes, const [0x49, 0x49, 0x2a, 0x00]) ||
    _startsWith(bytes, const [0x4d, 0x4d, 0x00, 0x2a]) ||
    _startsWith(bytes, const [0x49, 0x49, 0x2b, 0x00]) ||
    _startsWith(bytes, const [0x4d, 0x4d, 0x00, 0x2b]);

bool _isJxl(Uint8List bytes) =>
    _startsWith(bytes, const [0xff, 0x0a]) ||
    _startsWith(bytes, const [0x00, 0x00, 0x00, 0x0c, 0x4a, 0x58, 0x4c, 0x20]);
