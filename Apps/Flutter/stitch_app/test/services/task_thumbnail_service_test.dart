import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/grid_options.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/task_thumbnail_service.dart';

void main() {
  late Directory temp;
  late Directory output;
  late Directory cache;
  late File tile;
  late File validPng;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('task-thumbnail-test-');
    output = Directory(p.join(temp.path, 'output'));
    await output.create();
    cache = Directory(p.join(temp.path, 'support'));
    tile = File(p.join(output.path, 'level-8', '0-0.png'));
    await tile.parent.create(recursive: true);
    await tile.writeAsBytes(await _overviewPng());
    final finalTile = File(p.join(output.path, 'level-17', '0-0.png'));
    await finalTile.parent.create(recursive: true);
    await finalTile.writeAsBytes(
      await _solidPng(1, 1, const ui.Color(0xff0000ff)),
    );
    validPng = File(
      p.absolute('test/goldens/tiff_quality_desktop_png-feather.png'),
    );
    await File(p.join(output.path, 'manifest.json')).writeAsString(
      jsonEncode({
        'width': 2048,
        'height': 1024,
        'tileSize': 512,
        'levels': [
          {
            'level': 0,
            'width': 2048,
            'height': 1024,
            'occupied': [
              {'path': 'level-0/0-0.png', 'width': 512, 'height': 512},
            ],
          },
          {
            'level': 8,
            'width': 512,
            'height': 256,
            'occupied': [
              {'path': 'level-8/0-0.png', 'width': 512, 'height': 256},
            ],
          },
          {
            'level': 17,
            'width': 1,
            'height': 1,
            'occupied': [
              {'path': 'level-17/0-0.png', 'width': 1, 'height': 1},
            ],
          },
        ],
      }),
    );
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  StitchTask task({
    required String id,
    StitchPhase phase = StitchPhase.completed,
    String? exportPath,
    String? previewThumbnailPath,
    List<ImportedPhoto> photos = const [],
  }) => StitchTask(
    id: id,
    createdAt: DateTime.utc(2026),
    sourceDirectory: temp.path,
    outputDirectory: output.path,
    photos: photos,
    grid: const GridOptions(),
    horizontalFovDegrees: 90,
    memoryBudgetMiB: 512,
    workers: 1,
    phase: phase,
    exportPath: exportPath,
    previewThumbnailPath: previewThumbnailPath,
  );

  TaskThumbnailService service() =>
      TaskThumbnailService(supportDirectory: () async => cache);

  test(
    'completed preview uses structured overview instead of final 1x1 tile',
    () async {
      // A directory at exportPath would fail if the service tried to open/decode
      // it before trying the small pyramid tile.
      final exportDirectory = Directory(p.join(temp.path, 'huge-export'));
      await exportDirectory.create();

      final result = await service().thumbnailFor(
        task(id: 'completed', exportPath: exportDirectory.path),
      );

      expect(result, isNotNull);
      expect(await result!.exists(), isTrue);
      expect(result.path, isNot(tile.path));
      final codec = await ui.instantiateImageCodec(await result.readAsBytes());
      final frame = await codec.getNextFrame();
      final pixels = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      expect(frame.image.width, 256);
      expect(pixels, isNotNull);
      final left = pixels!.getUint32(20 * 4, Endian.host);
      final right = pixels.getUint32((frame.image.width - 20) * 4, Endian.host);
      expect(left, isNot(right));
      frame.image.dispose();
      codec.dispose();
    },
  );

  test('unsupported pyramid tile falls back to camera thumbnail', () async {
    await tile.writeAsString('not a png');
    final camera = File(p.join(temp.path, 'camera-thumbnail.jpg'));
    await validPng.copy(camera.path);

    final result = await service().thumbnailFor(
      task(id: 'camera-fallback', previewThumbnailPath: camera.path),
    );

    expect(result, isNotNull);
    expect(await result!.exists(), isTrue);
  });

  test(
    'failed candidates are retried and can fall back to first photo',
    () async {
      await tile.writeAsString('invalid tile');
      final firstPhoto = File(p.join(temp.path, 'source.jpg'));
      await firstPhoto.writeAsString('invalid source');
      final currentTask = task(
        id: 'retry',
        phase: StitchPhase.imported,
        photos: [
          ImportedPhoto(
            originalName: 'source.jpg',
            storedPath: firstPhoto.path,
            sha256: 'hash',
            width: 1,
            height: 1,
            originalOrder: 0,
          ),
        ],
      );

      final thumbnailService = service();
      expect(await thumbnailService.thumbnailFor(currentTask), isNull);
      await validPng.copy(firstPhoto.path);

      final result = await thumbnailService.thumbnailFor(currentTask);
      expect(result, isNotNull);
      expect(await result!.exists(), isTrue);
    },
  );
}

Future<List<int>> _overviewPng() => _solidPng(
  512,
  256,
  const ui.Color(0xff000000),
  endColor: const ui.Color(0xffffffff),
);

Future<List<int>> _solidPng(
  int width,
  int height,
  ui.Color color, {
  ui.Color? endColor,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint()
    ..shader = endColor == null
        ? null
        : ui.Gradient.linear(ui.Offset.zero, ui.Offset(width.toDouble(), 0), [
            color,
            endColor,
          ])
    ..color = color;
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    paint,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}
