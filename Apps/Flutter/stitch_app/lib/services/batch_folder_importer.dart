import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/grid_options.dart';
import '../models/imported_photo.dart';
import 'photo_importer.dart';

class BatchFolderSnapshot {
  const BatchFolderSnapshot({
    required this.directory,
    required this.files,
    this.error,
  });
  final String directory;
  final List<File> files;
  final String? error;
}

class BatchImportedFolder {
  const BatchImportedFolder({
    required this.photos,
    required this.inputDirectory,
    required this.grid,
    required this.hasIndexedGrid,
    required this.needsLayout,
    required this.estimatedLayout,
    required this.cameraVerified,
    required this.fovDegrees,
    required this.cameraProfileId,
  });
  final List<ImportedPhoto> photos;
  final String inputDirectory;
  final GridOptions grid;
  final bool hasIndexedGrid;
  final bool needsLayout;
  final bool estimatedLayout;
  final bool cameraVerified;
  final double? fovDegrees;
  final String? cameraProfileId;
}

class BatchFolderImporter {
  /// Captures only direct child directories and direct JPEG files. Links are
  /// never traversed. Call this before creating any task or output directories.
  Future<List<BatchFolderSnapshot>> snapshot(String parentPath) async {
    final parent = Directory(parentPath);
    if (!await parent.exists()) throw FileSystemException('母目录不存在', parentPath);
    final children = <Directory>[];
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is Directory) children.add(entity);
    }
    children.sort(
      (a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()),
    );
    final snapshots = <BatchFolderSnapshot>[];
    for (final child in children) {
      try {
        final files = <File>[];
        await for (final entity in child.list(followLinks: false)) {
          if (entity is File &&
              const {
                '.jpg',
                '.jpeg',
              }.contains(p.extension(entity.path).toLowerCase())) {
            files.add(entity);
          }
        }
        files.sort(
          (a, b) => _compareNatural(p.basename(a.path), p.basename(b.path)),
        );
        snapshots.add(
          BatchFolderSnapshot(
            directory: child.path,
            files: List.unmodifiable(files),
            error: files.isEmpty ? '子目录中没有直接 JPEG 原片' : null,
          ),
        );
      } on Object catch (error) {
        snapshots.add(
          BatchFolderSnapshot(
            directory: child.path,
            files: const [],
            error: '无法读取子目录：$error',
          ),
        );
      }
    }
    return List.unmodifiable(snapshots);
  }

  Future<BatchImportedFolder> importFolder(
    BatchFolderSnapshot snapshot,
    String taskDirectory,
  ) async {
    if (snapshot.files.isEmpty) throw ImportFailure(snapshot.error ?? '没有原片');
    final taskDir = Directory(taskDirectory);
    await taskDir.create(recursive: true);
    final lock = File(p.join(taskDirectory, '.input-import.lock'));
    await lock.create(exclusive: true);
    final input = Directory(p.join(taskDirectory, 'input'));
    var createdInput = false;
    try {
      if (await input.exists()) throw const ImportFailure('任务输入目录已存在，拒绝覆盖');
      await input.create();
      createdInput = true;
      final photos = <ImportedPhoto>[];
      for (var index = 0; index < snapshot.files.length; index++) {
        final source = snapshot.files[index];
        final destination = File(
          p.join(input.path, '${index.toString().padLeft(4, '0')}.jpg'),
        );
        final stream = source.openRead();
        final output = destination.openWrite(mode: FileMode.writeOnly);
        try {
          await output.addStream(stream);
          await output.flush();
        } finally {
          await output.close();
        }
        final meta = await readJpegMetadata(destination);
        photos.add(
          ImportedPhoto(
            originalName: p.basename(source.path),
            storedPath: destination.path,
            sha256: (await sha256.bind(destination.openRead()).first)
                .toString(),
            width: meta.width,
            height: meta.height,
            originalOrder: index,
            exifMake: meta.make,
            exifModel: meta.model,
            exifLensModel: meta.lensModel,
            exifFocalLengthMm: meta.focalLengthMm,
          ),
        );
      }
      if (!photos.every(
        (photo) =>
            photo.width == photos.first.width &&
            photo.height == photos.first.height,
      )) {
        throw const ImportFailure('原片尺寸不一致');
      }
      final indexed = _indexedLayout(photos);
      final hasCoordinates = photos.any(
        (photo) => RegExp(
          r'^\d+[_-]\d+\.',
          caseSensitive: false,
        ).hasMatch(photo.originalName),
      );
      final square = _squareLayout(photos.length);
      final dwarf = photos.every((photo) => photo.isVerifiedDwarf3Tele);
      final fov = dwarf
          ? 2 *
                math.atan(
                  photos.first.width /
                      (2 * (75000 * photos.first.width / 3840)),
                ) *
                180 /
                math.pi
          : null;
      return BatchImportedFolder(
        photos: List.unmodifiable(photos),
        inputDirectory: input.path,
        grid:
            indexed ??
            square ??
            GridOptions(
              mode: GridMode.sequence,
              rows: 1,
              columns: photos.length,
            ),
        hasIndexedGrid: indexed != null,
        needsLayout: indexed == null && (square == null || hasCoordinates),
        estimatedLayout: indexed == null && square != null && !hasCoordinates,
        cameraVerified: dwarf,
        fovDegrees: fov,
        cameraProfileId: dwarf ? 'dwarf3-tele-nominal-150mm' : null,
      );
    } on Object {
      if (createdInput && await input.exists()) {
        await input.delete(recursive: true);
      }
      rethrow;
    } finally {
      if (await lock.exists()) await lock.delete();
    }
  }

  GridOptions? _squareLayout(int count) {
    final side = math.sqrt(count).round();
    if (side * side != count) {
      return null;
    }
    return GridOptions(mode: GridMode.sequence, rows: side, columns: side);
  }

  int _compareNatural(String left, String right) {
    final pattern = RegExp(r'(\d+|\D+)');
    final a = pattern
        .allMatches(left.toLowerCase())
        .map((match) => match[0]!)
        .toList();
    final b = pattern
        .allMatches(right.toLowerCase())
        .map((match) => match[0]!)
        .toList();
    for (var index = 0; index < math.min(a.length, b.length); index++) {
      final an = int.tryParse(a[index]);
      final bn = int.tryParse(b[index]);
      final compared = an != null && bn != null
          ? an.compareTo(bn)
          : a[index].compareTo(b[index]);
      if (compared != 0) return compared;
    }
    return a.length.compareTo(b.length);
  }

  GridOptions? _indexedLayout(List<ImportedPhoto> photos) {
    final pattern = RegExp(
      r'^(\d+)[_-](\d+)\.(?:jpe?g)$',
      caseSensitive: false,
    );
    final coordinates = <(int, int)>[];
    for (final photo in photos) {
      final match = pattern.firstMatch(photo.originalName);
      if (match == null) return null;
      final row = int.tryParse(match.group(1)!);
      final column = int.tryParse(match.group(2)!);
      if (row == null || column == null) return null;
      coordinates.add((row, column));
    }
    final minRow = coordinates.map((item) => item.$1).reduce(math.min);
    final minColumn = coordinates.map((item) => item.$2).reduce(math.min);
    final baseRow = minRow;
    final baseColumn = minColumn;
    final cells = coordinates
        .map((item) => '${item.$1 - baseRow}:${item.$2 - baseColumn}')
        .toSet();
    if (cells.length != photos.length) return null;
    final rows =
        coordinates.map((item) => item.$1 - baseRow).reduce(math.max) + 1;
    final columns =
        coordinates.map((item) => item.$2 - baseColumn).reduce(math.max) + 1;
    if (!GridOptions.productFits(rows, columns) ||
        rows * columns != photos.length) {
      return null;
    }
    return GridOptions(mode: GridMode.filename, rows: rows, columns: columns);
  }
}
