import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/imported_photo.dart';
import 'platform_file_dialogs.dart';

class ImportFailure implements Exception {
  const ImportFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ImportBatch {
  const ImportBatch({required this.photos, required this.inputDirectory});
  final List<ImportedPhoto> photos;
  final String inputDirectory;

  (int width, int height) get dimensions =>
      (photos.first.width, photos.first.height);
  bool get hasUniformDimensions => photos.every(
    (photo) =>
        photo.width == photos.first.width &&
        photo.height == photos.first.height,
  );
}

class _DigestCapture implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) => value = digest;
  @override
  void close() {}
}

class PhotoImporter {
  PhotoImporter({PlatformFileDialogs? dialogs})
    : _dialogs = dialogs ?? PlatformFileDialogs();

  final PlatformFileDialogs _dialogs;

  Future<List<PlatformFile>?> pickJpegs() => _dialogs.pickJpegs();

  Future<ImportBatch> copyIntoTask(
    List<PlatformFile> selected,
    String taskDirectory,
  ) async {
    if (selected.isEmpty) throw const ImportFailure('没有选中照片');
    final inputDirectory = Directory(p.join(taskDirectory, 'input'));
    await Directory(taskDirectory).create(recursive: true);
    final lockFile = File(p.join(taskDirectory, '.input-import.lock'));
    try {
      await lockFile.create(exclusive: true);
    } on FileSystemException {
      throw const ImportFailure('任务输入目录已存在；请新建任务后再导入，避免覆盖原片');
    }
    if (await inputDirectory.exists()) {
      await lockFile.delete();
      throw const ImportFailure('任务输入目录已存在；请新建任务后再导入，避免覆盖原片');
    }
    final photos = <ImportedPhoto>[];
    var ownsInputDirectory = false;
    try {
      await inputDirectory.create();
      ownsInputDirectory = true;
      for (var index = 0; index < selected.length; index++) {
        final file = selected[index];
        final extension = p.extension(file.name).toLowerCase();
        if (extension != '.jpg' && extension != '.jpeg') {
          throw ImportFailure('仅支持 JPEG 原片：${file.name}');
        }
        final input = file.path == null ? null : File(file.path!);
        if (input == null && file.readStream == null) {
          throw ImportFailure('无法读取所选文件：${file.name}');
        }
        // The original UTF-8 name is retained in task metadata; ASCII paths keep native
        // OpenCV loading reliable on Windows builds that use narrow filesystem APIs.
        final storedName = '${index.toString().padLeft(4, '0')}.jpg';
        final destination = File(p.join(inputDirectory.path, storedName));
        final digestCapture = _DigestCapture();
        final digestSink = sha256.startChunkedConversion(digestCapture);
        final output = destination.openWrite(mode: FileMode.writeOnly);
        try {
          final stream = input?.openRead() ?? file.readStream!;
          await for (final chunk in stream) {
            output.add(chunk);
            digestSink.add(chunk);
          }
          await output.flush();
        } finally {
          await output.close();
          digestSink.close();
        }
        final metadata = await readJpegMetadata(destination);
        photos.add(
          ImportedPhoto(
            originalName: file.name,
            storedPath: destination.path,
            sha256: digestCapture.value!.toString(),
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
    } on Object {
      // This directory was created exclusively above, so it contains only this attempt.
      if (ownsInputDirectory && await inputDirectory.exists()) {
        await inputDirectory.delete(recursive: true);
      }
      rethrow;
    } finally {
      if (await lockFile.exists()) await lockFile.delete();
    }
    return ImportBatch(
      photos: List.unmodifiable(photos),
      inputDirectory: inputDirectory.path,
    );
  }
}

class JpegMetadata {
  const JpegMetadata({
    required this.width,
    required this.height,
    this.make,
    this.model,
    this.lensModel,
    this.focalLengthMm,
  });

  final int width;
  final int height;
  final String? make;
  final String? model;
  final String? lensModel;
  final double? focalLengthMm;
}

Future<(int, int)> readJpegDimensions(File file) async {
  final metadata = await readJpegMetadata(file);
  return (metadata.width, metadata.height);
}

Future<JpegMetadata> readJpegMetadata(File file) async {
  // JPEG dimensions and EXIF live near the start of the file. Keep the read
  // bounded so a large original is never decoded or loaded into memory here.
  const maxHeaderBytes = 2 * 1024 * 1024;
  final handle = await file.open();
  late final Uint8List bytes;
  try {
    final length = await handle.length();
    if (length < 4) {
      throw ImportFailure('文件不是有效 JPEG：${p.basename(file.path)}');
    }
    bytes = await handle.read(
      length < maxHeaderBytes ? length : maxHeaderBytes,
    );
  } finally {
    await handle.close();
  }
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
    throw ImportFailure('文件不是有效 JPEG：${p.basename(file.path)}');
  }
  const sofMarkers = {
    0xc0,
    0xc1,
    0xc2,
    0xc3,
    0xc5,
    0xc6,
    0xc7,
    0xc9,
    0xca,
    0xcb,
    0xcd,
    0xce,
    0xcf,
  };
  var make = <String?>[null];
  var model = <String?>[null];
  var lens = <String?>[null];
  var focalLength = <double?>[null];
  var position = 2;
  while (position + 4 <= bytes.length) {
    if (bytes[position] != 0xff) {
      throw ImportFailure('JPEG marker 顺序无效：${p.basename(file.path)}');
    }
    while (position < bytes.length && bytes[position] == 0xff) {
      position++;
    }
    if (position >= bytes.length) break;
    final marker = bytes[position++];
    if (marker == 0xd9 || marker == 0xda) break;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (position + 2 > bytes.length) break;
    final segmentLength = (bytes[position] << 8) | bytes[position + 1];
    if (segmentLength < 2 || position + segmentLength > bytes.length) break;
    final payloadStart = position + 2;
    final payloadEnd = position + segmentLength;
    if (marker == 0xe1 && segmentLength <= 65535) {
      final exif = _readExif(bytes, payloadStart, payloadEnd);
      if (exif != null) {
        make = [exif.make];
        model = [exif.model];
        lens = [exif.lensModel];
        focalLength = [exif.focalLengthMm];
      }
    }
    if (sofMarkers.contains(marker)) {
      if (segmentLength < 7) break;
      final height = (bytes[payloadStart + 1] << 8) | bytes[payloadStart + 2];
      final width = (bytes[payloadStart + 3] << 8) | bytes[payloadStart + 4];
      if (width > 0 && height > 0) {
        return JpegMetadata(
          width: width,
          height: height,
          make: make.single,
          model: model.single,
          lensModel: lens.single,
          focalLengthMm: focalLength.single,
        );
      }
      break;
    }
    position = payloadEnd;
  }
  throw ImportFailure('JPEG 头中找不到图像尺寸：${p.basename(file.path)}');
}

class _ExifValues {
  const _ExifValues({
    this.make,
    this.model,
    this.lensModel,
    this.focalLengthMm,
  });
  final String? make;
  final String? model;
  final String? lensModel;
  final double? focalLengthMm;
}

_ExifValues? _readExif(Uint8List bytes, int start, int end) {
  const exifPrefix = [0x45, 0x78, 0x69, 0x66, 0, 0];
  if (end - start < 14) return null;
  for (var index = 0; index < exifPrefix.length; index++) {
    if (bytes[start + index] != exifPrefix[index]) return null;
  }
  final tiff = start + 6;
  final little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
  if (!little && !(bytes[tiff] == 0x4d && bytes[tiff + 1] == 0x4d)) {
    return null;
  }
  int u16(int offset) => offset + 2 <= end
      ? little
            ? bytes[offset] | (bytes[offset + 1] << 8)
            : (bytes[offset] << 8) | bytes[offset + 1]
      : -1;
  int u32(int offset) => offset + 4 <= end
      ? little
            ? bytes[offset] |
                  (bytes[offset + 1] << 8) |
                  (bytes[offset + 2] << 16) |
                  (bytes[offset + 3] << 24)
            : (bytes[offset] << 24) |
                  (bytes[offset + 1] << 16) |
                  (bytes[offset + 2] << 8) |
                  bytes[offset + 3]
      : -1;
  if (u16(tiff + 2) != 42) return null;
  final ifd0Offset = u32(tiff + 4);
  final ifd0 = tiff + ifd0Offset;
  if (ifd0Offset < 8 || ifd0 + 2 > end) return null;
  String? make;
  String? model;
  String? lensModel;
  double? focalLengthMm;
  int? exifIfdOffset;
  String? ascii(int valueOffset, int count, {int? inlineOffset}) {
    final from = count <= 4 ? inlineOffset! : tiff + valueOffset;
    if (count <= 0 || count > 512 || from < tiff || from + count > end) {
      return null;
    }
    return String.fromCharCodes(
      bytes.sublist(from, from + count),
    ).replaceAll('\u0000', '').trim();
  }

  void readIfd(int offset, {required bool exifIfd}) {
    final absolute = tiff + offset;
    final count = u16(absolute);
    if (offset < 8 ||
        count < 0 ||
        count > 256 ||
        absolute + 2 + count * 12 > end) {
      return;
    }
    for (var index = 0; index < count; index++) {
      final entry = absolute + 2 + index * 12;
      final tag = u16(entry);
      final type = u16(entry + 2);
      final itemCount = u32(entry + 4);
      final value = u32(entry + 8);
      if (!exifIfd && tag == 0x010f && type == 2) {
        make = ascii(value, itemCount, inlineOffset: entry + 8);
      }
      if (!exifIfd && tag == 0x0110 && type == 2) {
        model = ascii(value, itemCount, inlineOffset: entry + 8);
      }
      if (!exifIfd && tag == 0x8769 && type == 4) exifIfdOffset = value;
      if (exifIfd && tag == 0xa434 && type == 2) {
        lensModel = ascii(value, itemCount, inlineOffset: entry + 8);
      }
      if (exifIfd &&
          tag == 0x920a &&
          (type == 5 || type == 10) &&
          itemCount == 1) {
        final rational = tiff + value;
        final rawNumerator = u32(rational);
        final rawDenominator = u32(rational + 4);
        final isSigned = type == 10;
        final numerator = isSigned && rawNumerator >= 0x80000000
            ? rawNumerator - 0x100000000
            : rawNumerator;
        final denominator = isSigned && rawDenominator >= 0x80000000
            ? rawDenominator - 0x100000000
            : rawDenominator;
        if (rawNumerator >= 0 && rawDenominator >= 0 && denominator != 0) {
          final focalLength = numerator / denominator;
          if (focalLength > 0 && focalLength.isFinite) {
            focalLengthMm = focalLength;
          }
        }
      }
    }
  }

  readIfd(ifd0Offset, exifIfd: false);
  if (exifIfdOffset != null) readIfd(exifIfdOffset!, exifIfd: true);
  return _ExifValues(
    make: make,
    model: model,
    lensModel: lensModel,
    focalLengthMm: focalLengthMm,
  );
}
