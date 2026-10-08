import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/services/batch_folder_importer.dart';

Future<void> _writePhoto(Directory directory, String name) async {
  // The importer reads JPEG marker headers only; this minimal SOF header carries
  // a valid 1x1 image size without requiring a raster codec in this test.
  final bytes = <int>[
    0xff,
    0xd8,
    0xff,
    0xc0,
    0x00,
    0x0b,
    0x08,
    0x00,
    0x01,
    0x00,
    0x01,
    0x01,
    0x01,
    0x11,
    0x00,
  ];
  await File(
    '${directory.path}${Platform.pathSeparator}$name',
  ).writeAsBytes(bytes);
}

void main() {
  late Directory temporary;
  late Directory parent;
  late BatchFolderImporter importer;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('batch-import-test-');
    parent = Directory('${temporary.path}${Platform.pathSeparator}parent')
      ..createSync();
    importer = BatchFolderImporter();
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('snapshots only direct child folders and direct JPEG files', () async {
    final child = Directory('${parent.path}${Platform.pathSeparator}scan')
      ..createSync();
    final nested = Directory('${child.path}${Platform.pathSeparator}nested')
      ..createSync();
    await _writePhoto(child, '01.jpg');
    await _writePhoto(nested, '02.jpg');
    File(
      '${child.path}${Platform.pathSeparator}notes.txt',
    ).writeAsStringSync('ignore');

    final result = await importer.snapshot(parent.path);
    expect(result, hasLength(1));
    expect(result.single.files.map((file) => file.uri.pathSegments.last), [
      '01.jpg',
    ]);
  });

  test('recognizes complete row-column grids and natural order', () async {
    final child = Directory('${parent.path}${Platform.pathSeparator}indexed')
      ..createSync();
    for (final name in ['10-10.jpg', '10-11.jpg', '11-10.jpg', '11-11.jpg']) {
      await _writePhoto(child, name);
    }
    final source = (await importer.snapshot(parent.path)).single;
    final originalFile = source.files.first;
    final originalBytes = await originalFile.readAsBytes();
    expect(source.files.map((file) => file.uri.pathSegments.last), [
      '10-10.jpg',
      '10-11.jpg',
      '11-10.jpg',
      '11-11.jpg',
    ]);
    final imported = await importer.importFolder(
      source,
      '${temporary.path}${Platform.pathSeparator}task',
    );
    expect(imported.hasIndexedGrid, isTrue);
    expect(imported.needsLayout, isFalse);
    expect(imported.grid.rows, 2);
    expect(imported.grid.columns, 2);
    expect(await originalFile.exists(), isTrue);
    expect(await originalFile.readAsBytes(), originalBytes);
  });

  test(
    'estimates unnumbered squares but asks about partial indexed and nonsquare folders',
    () async {
      final square = Directory('${parent.path}${Platform.pathSeparator}square')
        ..createSync();
      for (var index = 1; index <= 4; index++) {
        await _writePhoto(square, 'photo$index.jpg');
      }
      final partial = Directory(
        '${parent.path}${Platform.pathSeparator}partial',
      )..createSync();
      for (final name in ['1_1.jpg', '1_2.jpg', '2_1.jpg', '2_3.jpg']) {
        await _writePhoto(partial, name);
      }
      final nonsquare = Directory(
        '${parent.path}${Platform.pathSeparator}nonsquare',
      )..createSync();
      for (var index = 1; index <= 3; index++) {
        await _writePhoto(nonsquare, 'image$index.jpg');
      }
      final snapshots = await importer.snapshot(parent.path);
      final squareResult = await importer.importFolder(
        snapshots.firstWhere(
          (item) =>
              item.directory.split(Platform.pathSeparator).last == 'square',
        ),
        '${temporary.path}${Platform.pathSeparator}square-task',
      );
      expect(squareResult.grid.rows, 2);
      expect(squareResult.estimatedLayout, isTrue);
      expect(squareResult.needsLayout, isFalse);
      final partialResult = await importer.importFolder(
        snapshots.firstWhere((item) => item.directory.endsWith('partial')),
        '${temporary.path}${Platform.pathSeparator}partial-task',
      );
      expect(partialResult.estimatedLayout, isFalse);
      expect(partialResult.needsLayout, isTrue);
      final nonSquareResult = await importer.importFolder(
        snapshots.firstWhere((item) => item.directory.endsWith('nonsquare')),
        '${temporary.path}${Platform.pathSeparator}nonsquare-task',
      );
      expect(nonSquareResult.needsLayout, isTrue);
    },
  );
}
