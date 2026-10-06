import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/imported_photo.dart';
import 'package:stitch_app/services/photo_importer.dart';

List<int> makeJpegWithLargeMetadata() {
  final bytes = <int>[0xff, 0xd8];
  for (var i = 0; i < 18; i++) {
    bytes.addAll([
      0xff,
      0xe1,
      0xff,
      0xff,
    ]); // 65,535-byte EXIF-like APP segment.
    bytes.addAll(List<int>.filled(65533, i));
  }
  bytes.addAll([
    0xff,
    0xc0,
    0x00,
    0x11,
    0x08,
    0x0b,
    0xb8,
    0x0f,
    0xa0,
    0x03,
    0x01,
    0x11,
    0x00,
    0x02,
    0x11,
    0x00,
    0x03,
    0x11,
    0x00,
    0xff,
    0xd9,
  ]);
  return bytes;
}

List<int> makeDwarf3TeleJpeg() {
  // Mirrors the real DWARF JPEG's TIFF offsets and SRATIONAL focal length
  // representation without retaining any original image or GPS metadata.
  final tiff = List<int>.filled(432, 0);
  void u16(int offset, int value) {
    tiff[offset] = value & 0xff;
    tiff[offset + 1] = (value >> 8) & 0xff;
  }

  void u32(int offset, int value) {
    for (var index = 0; index < 4; index++) {
      tiff[offset + index] = (value >> (index * 8)) & 0xff;
    }
  }

  void entry(int offset, int tag, int type, int count, int value) {
    u16(offset, tag);
    u16(offset + 2, type);
    u32(offset + 4, count);
    u32(offset + 8, value);
  }

  tiff.setRange(0, 8, [0x49, 0x49, 0x2a, 0, 8, 0, 0, 0]);
  u16(8, 3);
  entry(10, 0x010f, 2, 9, 80);
  entry(22, 0x0110, 2, 8, 89);
  entry(34, 0x8769, 4, 1, 180);
  u32(46, 0);
  u16(180, 2);
  entry(182, 0x920a, 10, 1, 406);
  entry(194, 0xa434, 2, 5, 424);
  u32(206, 0);
  tiff.setRange(80, 89, [...'DWARFLAB'.codeUnits, 0]);
  tiff.setRange(89, 97, [...'DWARF 3'.codeUnits, 0]);
  tiff.setRange(424, 429, [...'TELE'.codeUnits, 0]);
  u32(406, 150);
  u32(410, 1);
  final exif = [...'Exif\u0000\u0000'.codeUnits, ...tiff];
  final segmentLength = exif.length + 2;
  return [
    0xff,
    0xd8,
    0xff,
    0xe1,
    (segmentLength >> 8) & 0xff,
    segmentLength & 0xff,
    ...exif,
    0xff,
    0xc0,
    0x00,
    0x11,
    0x08,
    0x08,
    0x70,
    0x0f,
    0x00,
    0x03,
    0x01,
    0x11,
    0x00,
    0x02,
    0x11,
    0x00,
    0x03,
    0x11,
    0x00,
    0xff,
    0xd9,
  ];
}

void main() {
  test(
    'imports Chinese original name to ASCII storage path and parses large JPEG metadata',
    () async {
      final temp = await Directory.systemTemp.createTemp('stitch-import-test-');
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}/相机照片.jpg');
      final bytes = makeJpegWithLargeMetadata();
      await source.writeAsBytes(bytes);
      final task = Directory('${temp.path}/task')..createSync();
      final batch = await PhotoImporter().copyIntoTask([
        PlatformFile(name: '原始照片.jpg', path: source.path, size: bytes.length),
      ], task.path);
      expect(batch.photos.single.originalName, '原始照片.jpg');
      expect(batch.photos.single.storedPath, endsWith('0000.jpg'));
      expect(
        (batch.photos.single.width, batch.photos.single.height),
        (4000, 3000),
      );
      expect(batch.photos.single.sha256, isNotEmpty);
    },
  );

  test(
    'reads verified camera tags and SRATIONAL focal length from real-layout EXIF',
    () async {
      final temp = await Directory.systemTemp.createTemp('stitch-exif-test-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/arbitrary-name.jpg')
        ..writeAsBytesSync(makeDwarf3TeleJpeg());

      final metadata = await readJpegMetadata(file);
      expect((metadata.width, metadata.height), (3840, 2160));
      expect(metadata.make, 'DWARFLAB');
      expect(metadata.model, 'DWARF 3');
      expect(metadata.lensModel, 'TELE');
      expect(metadata.focalLengthMm, 150);
      expect(
        ImportedPhoto(
          originalName: 'arbitrary-name.jpg',
          storedPath: file.path,
          sha256: 'test',
          width: metadata.width,
          height: metadata.height,
          originalOrder: 0,
          exifMake: metadata.make,
          exifModel: metadata.model,
          exifLensModel: metadata.lensModel,
          exifFocalLengthMm: metadata.focalLengthMm,
        ).isVerifiedDwarf3Tele,
        isTrue,
      );
    },
  );

  test(
    'refuses an existing input folder without deleting its contents and accepts more than 1024 photos',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'stitch-import-owned-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final task = Directory('${temp.path}/task')..createSync();
      final input = Directory('${task.path}/input')..createSync();
      final marker = File('${input.path}/keep.txt')
        ..writeAsStringSync('preserve');
      await expectLater(
        PhotoImporter().copyIntoTask([
          PlatformFile(name: 'image.jpg', size: 1),
        ], task.path),
        throwsA(isA<ImportFailure>()),
      );
      expect(await marker.readAsString(), 'preserve');
      final source = File('${temp.path}/source.jpg')
        ..writeAsBytesSync(const [
          0xff, 0xd8, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00,
          0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
        ]);
      final imported = await PhotoImporter().copyIntoTask(
        [
          for (var index = 0; index < 1025; index++)
            PlatformFile(
              name: 'photo$index.jpg',
              size: source.lengthSync(),
              path: source.path,
            ),
        ],
        '${temp.path}/other',
      );
      expect(imported.photos, hasLength(1025));
    },
  );
}
