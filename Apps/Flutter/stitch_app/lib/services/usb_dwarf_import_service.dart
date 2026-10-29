import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'photo_importer.dart';

/// A DWARF panorama directory found on a mounted removable or local volume.
class UsbPanoramaSource {
  const UsbPanoramaSource({
    required this.volumeId,
    required this.volumeLabel,
    required this.mountPath,
    required this.panoramaRoot,
    required this.directory,
    required this.identity,
    this.isRemovable = false,
  });

  final String volumeId;
  final String volumeLabel;
  final String mountPath;
  final String panoramaRoot;
  final String directory;
  final String identity;
  final bool isRemovable;
}

class UsbPhotoSource {
  const UsbPhotoSource({
    required this.file,
    required this.length,
    required this.modified,
  });
  final File file;
  final int length;
  final DateTime modified;
}

class UsbImportResult {
  const UsbImportResult({
    required this.files,
    required this.deletedFiles,
    required this.sha256ByName,
  });
  final List<File> files;
  final List<String> deletedFiles;
  final Map<String, String> sha256ByName;
}

class UsbSourceCleanupResult {
  const UsbSourceCleanupResult({required this.deleted, required this.retained});
  final List<String> deleted;
  final List<String> retained;
}

/// Discovers only mounted volume roots and the conventional DWARF3/Panoramas
/// locations below them. It deliberately does not recurse through arbitrary
/// folders or network shares.
class UsbDwarfImportService {
  UsbDwarfImportService({
    this.supportDirectory,
    Future<List<Directory>> Function()? mountRoots,
    Future<String> Function(String root)? volumeIdentity,
    Future<bool> Function(String root)? removableCheck,
    DateTime Function()? clock,
  }) : _mountRoots = mountRoots ?? _defaultMountRoots,
       _volumeIdentity = volumeIdentity ?? _defaultVolumeIdentity,
       _removableCheck = removableCheck ?? _isRemovable,
       _clock = clock ?? DateTime.now;

  final Directory Function()? supportDirectory;
  final Future<List<Directory>> Function() _mountRoots;
  final Future<String> Function(String root) _volumeIdentity;
  final Future<bool> Function(String root) _removableCheck;
  final DateTime Function() _clock;

  Future<List<UsbPanoramaSource>> discover() async {
    final result = <UsbPanoramaSource>[];
    for (final mount in await _mountRoots()) {
      String root;
      try {
        root = p.normalize(p.absolute(mount.path));
        if (!await mount.exists()) continue;
      } on Object {
        continue;
      }
      String volumeId;
      bool removable;
      try {
        volumeId = await _volumeIdentity(root);
        removable = await _removableCheck(root);
      } on Object {
        continue;
      }
      if (volumeId.isEmpty) continue;
      final label = p.basename(p.normalize(root)) == ''
          ? root
          : p.basename(p.normalize(root));
      List<Directory> panoramaRoots;
      try {
        panoramaRoots = await _panoramaRoots(mount);
      } on Object {
        continue;
      }
      for (final panoramaRoot in panoramaRoots) {
        try {
          await for (final entity in panoramaRoot.list(followLinks: false)) {
            if (entity is! Directory || !_looksLikeDwarfPanorama(entity)) {
              continue;
            }
            final identity = '$volumeId/${_relative(root, entity.path)}';
            result.add(
              UsbPanoramaSource(
                volumeId: volumeId,
                volumeLabel: label,
                mountPath: root,
                panoramaRoot: panoramaRoot.path,
                directory: entity.path,
                identity: identity.toLowerCase(),
                isRemovable: removable,
              ),
            );
          }
        } on Object {
          // A volume can disappear during a refresh; continue scanning others.
        }
      }
    }
    result.sort((a, b) {
      final priority = (b.isRemovable ? 1 : 0).compareTo(a.isRemovable ? 1 : 0);
      return priority != 0 ? priority : a.identity.compareTo(b.identity);
    });
    final preferred = await _preferredVolumeId();
    if (preferred != null) {
      return List.unmodifiable(
        result.where((source) => source.volumeId == preferred),
      );
    }
    final removable = result.where((source) => source.isRemovable).toList();
    if (removable.isEmpty) return const [];
    final selectedVolume = removable.first.volumeId;
    await selectVolume(selectedVolume);
    return List.unmodifiable(
      removable.where((source) => source.volumeId == selectedVolume),
    );
  }

  /// Pins the selected device identity across unplug/replug and drive-letter changes.
  Future<void> selectVolume(String volumeId) async {
    final file = File(
      p.join((await historyRoot()).path, 'preferred-volume.json'),
    );
    final temporary = File(
      '${file.path}.tmp-${_clock().microsecondsSinceEpoch}',
    );
    await temporary.writeAsString(
      '${jsonEncode({'volumeId': volumeId})}\n',
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on Object {
      if (!await file.exists()) rethrow;
      final backup = File('${file.path}.old');
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
      await temporary.rename(file.path);
      await backup.deleteIfExists();
    }
  }

  Future<String?> _preferredVolumeId() async {
    final file = File(
      p.join((await historyRoot()).path, 'preferred-volume.json'),
    );
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['volumeId'] is! String ||
        (decoded['volumeId'] as String).isEmpty) {
      throw const FormatException('已选择的 USB 卷记录损坏');
    }
    return decoded['volumeId'] as String;
  }

  Future<List<Directory>> _panoramaRoots(Directory volume) async {
    final roots = <Directory>[];
    try {
      await for (final entity in volume.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final base = p.basename(entity.path).toLowerCase();
        if (_isPanoramasName(base)) roots.add(entity);
        if (base == 'dwarf3') {
          try {
            await for (final child in entity.list(followLinks: false)) {
              if (child is! Directory) continue;
              if (_isPanoramasName(p.basename(child.path).toLowerCase())) {
                roots.add(child);
              }
              // Some cards wrap DWARF3 data in one extra device directory.
              if (p.basename(child.path).toLowerCase() == 'sdcard') {
                await for (final nested in child.list(followLinks: false)) {
                  if (nested is Directory &&
                      _isPanoramasName(p.basename(nested.path).toLowerCase())) {
                    roots.add(nested);
                  }
                }
              }
            }
          } on Object {
            // An unreadable DWARF3 child is retried on the next refresh.
          }
        }
      }
    } on Object {
      // A missing or unreadable volume is isolated from other mount roots.
    }
    return roots;
  }

  bool _looksLikeDwarfPanorama(Directory directory) {
    final name = p.basename(directory.path).toLowerCase();
    return name.startsWith('dwarf_panorama_') ||
        name.startsWith('dwarf-panorama-') ||
        // Export folders often use timestamped names without a DWARF prefix.
        name.contains('panorama');
  }

  bool _isPanoramasName(String value) => const {
    'panorama',
    'panoramas',
    'panorarma',
    'panorarmas',
  }.contains(value);

  String _relative(String root, String path) =>
      p.relative(path, from: root).replaceAll('\\', '/');

  /// Enumerates root JPEGs and one-level numeric-copy directories. For a
  /// repeated filename, explicit original/full-resolution locations win;
  /// otherwise the largest pixel area, then file size, wins.
  Future<List<UsbPhotoSource>> selectMaximumPhotos(String directory) async {
    final candidates = await _listPhotoCandidates(directory);
    final byName = <String, List<UsbPhotoSource>>{};
    for (final file in candidates) {
      byName
          .putIfAbsent(p.basename(file.file.path).toLowerCase(), () => [])
          .add(file);
    }
    final selected = <UsbPhotoSource>[];
    for (final files in byName.values) {
      UsbPhotoSource? file;
      var bestArea = -1;
      var bestLength = -1;
      var bestExplicit = false;
      for (final candidate in files) {
        final explicit = _isExplicitOriginal(candidate.file.path);
        var area = 0;
        try {
          final metadata = await readJpegMetadata(candidate.file);
          area = metadata.width * metadata.height;
        } on Object {
          // A corrupt JPEG cannot participate in pixel-area ranking.
        }
        if ((explicit && !bestExplicit) ||
            (explicit == bestExplicit && area > bestArea) ||
            (explicit == bestExplicit &&
                area == bestArea &&
                candidate.length > bestLength) ||
            (explicit == bestExplicit &&
                area == bestArea &&
                candidate.length == bestLength &&
                candidate.file.path
                        .toLowerCase()
                        .replaceAll('\\', '/')
                        .compareTo(
                          file?.file.path.toLowerCase().replaceAll('\\', '/') ??
                              '\uFFFF',
                        ) <
                    0)) {
          file = candidate;
          bestArea = area;
          bestLength = candidate.length;
          bestExplicit = explicit;
        }
      }
      final selectedFile = file;
      if (selectedFile != null) selected.add(selectedFile);
    }
    selected.sort(
      (a, b) => p
          .basename(a.file.path)
          .toLowerCase()
          .compareTo(p.basename(b.file.path).toLowerCase()),
    );
    return List.unmodifiable(selected);
  }

  Future<List<UsbPhotoSource>> _listPhotoCandidates(String directory) async {
    final candidates = <File>[];
    final root = Directory(directory);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && _isPhoto(entity.path)) candidates.add(entity);
      if (entity is Directory &&
          RegExp(r'^\d+$').hasMatch(p.basename(entity.path))) {
        await for (final file in entity.list(followLinks: false)) {
          if (file is File && _isPhoto(file.path)) candidates.add(file);
        }
      }
    }
    final result = <UsbPhotoSource>[];
    for (final file in candidates) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final stat = await file.stat();
      if (stat.size > 0) {
        result.add(
          UsbPhotoSource(
            file: file,
            length: stat.size,
            modified: stat.modified,
          ),
        );
      }
    }
    result.sort(
      (a, b) => p
          .relative(a.file.path, from: directory)
          .replaceAll('\\', '/')
          .toLowerCase()
          .compareTo(
            p
                .relative(b.file.path, from: directory)
                .replaceAll('\\', '/')
                .toLowerCase(),
          ),
    );
    return result;
  }

  Future<bool> isPanoramaComplete(String directory) async {
    final photos = await _listPhotoCandidates(directory);
    if (photos.isEmpty) return false;
    final newestPhoto = photos
        .map((photo) => photo.modified)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final root = Directory(directory);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File ||
          !RegExp(
            r'^panor(?:a|ar)ma_thumbnail\.jpe?g$',
            caseSensitive: false,
          ).hasMatch(p.basename(entity.path))) {
        continue;
      }
      final stat = await entity.stat();
      if (stat.size > 0 && !stat.modified.isBefore(newestPhoto)) {
        return true;
      }
    }
    return false;
  }

  UsbPanoramaSource sourceFor({
    required String volumeId,
    required String identity,
    required String directory,
    required String mountPath,
  }) => UsbPanoramaSource(
    volumeId: volumeId,
    volumeLabel: p.basename(mountPath),
    mountPath: mountPath,
    panoramaRoot: p.dirname(directory),
    directory: directory,
    identity: identity,
  );

  Future<void> copyPreview({
    required String sourceDirectory,
    required String destinationDirectory,
  }) async {
    final root = Directory(sourceDirectory);
    final candidates = <File>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File &&
          RegExp(
            r'^panor(?:a|ar)ma_thumbnail\.jpe?g$',
            caseSensitive: false,
          ).hasMatch(p.basename(entity.path))) {
        candidates.add(entity);
      }
    }
    candidates.sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
    if (candidates.isEmpty) return;
    final target = File(destinationDirectory);
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    final before = await candidates.last.stat();
    final sink = part.openWrite(mode: FileMode.writeOnly);
    try {
      await sink.addStream(candidates.last.openRead());
      await sink.flush();
    } finally {
      await sink.close();
    }
    final after = await candidates.last.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        await part.length() != before.size) {
      await part.deleteIfExists();
      throw FileSystemException('全景预览在复制期间发生变化', candidates.last.path);
    }
    await part.rename(target.path);
  }

  Future<UsbSourceCleanupResult> deleteVerifiedSources({
    required List<UsbPhotoSource> sources,
    required Map<String, String> expectedHashesByName,
  }) async {
    if (sources.length != expectedHashesByName.length) {
      throw const FormatException('USB 源文件校验清单不完整');
    }
    final allPaths = List<String>.unmodifiable(
      sources.map((source) => source.file.path),
    );
    // Validate the whole selected source set before deleting any member.
    // A changed, missing, or linked source means the set is not safe to prune.
    try {
      for (final source in sources) {
        final file = source.file;
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return UsbSourceCleanupResult(deleted: const [], retained: allPaths);
        }
        final expected =
            expectedHashesByName[p.basename(file.path).toLowerCase()];
        if (expected == null ||
            (await sha256.bind(file.openRead()).first).toString() != expected) {
          return UsbSourceCleanupResult(deleted: const [], retained: allPaths);
        }
      }
    } on Object {
      // Unplugged or unreadable sources stay in place; the local task is valid.
      return UsbSourceCleanupResult(deleted: const [], retained: allPaths);
    }
    final deleted = <String>[];
    final retained = <String>[];
    for (final source in sources) {
      final file = source.file;
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          retained.add(file.path);
          continue;
        }
        final actual = await sha256.bind(file.openRead()).first;
        final expected =
            expectedHashesByName[p.basename(file.path).toLowerCase()];
        if (expected == null || actual.toString() != expected) {
          retained.add(file.path);
          continue;
        }
        await file.delete();
        deleted.add(file.path);
      } on Object {
        retained.add(file.path);
      }
    }
    return UsbSourceCleanupResult(
      deleted: List.unmodifiable(deleted),
      retained: List.unmodifiable(retained),
    );
  }

  bool _isPhoto(String path) {
    final name = p.basenameWithoutExtension(path).toLowerCase();
    if (!const {'.jpg', '.jpeg'}.contains(p.extension(path).toLowerCase())) {
      return false;
    }
    return !name.contains('thumbnail') &&
        !name.contains('thumb') &&
        !name.contains('preview');
  }

  bool _isExplicitOriginal(String path) => RegExp(
    r'/(original|originals|full|highres|high-resolution)/',
  ).hasMatch(path.toLowerCase().replaceAll('\\', '/'));

  Future<UsbImportResult> copyVerified({
    required List<UsbPhotoSource> sources,
    required String destinationDirectory,
    required bool deleteSources,
  }) async {
    if (deleteSources) {
      throw StateError('USB 源文件只能在任务和队列状态持久化后删除');
    }
    final output = Directory(destinationDirectory);
    await output.create(recursive: true);
    final copied = <File>[];
    final hashesByName = <String, String>{};
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      if (await FileSystemEntity.type(source.file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException('拒绝复制链接或非普通文件', source.file.path);
      }
      final before = await source.file.stat();
      if (before.size != source.length || before.modified != source.modified) {
        throw FileSystemException('源照片仍在变化，已取消复制', source.file.path);
      }
      final target = File(p.join(output.path, p.basename(source.file.path)));
      final part = File('${target.path}.part');
      final input = source.file.openRead();
      final sink = part.openWrite(mode: FileMode.writeOnly);
      var length = 0;
      try {
        await for (final chunk in input) {
          sink.add(chunk);
          length += chunk.length;
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (length != source.length) {
        await part.deleteIfExists();
        throw FileSystemException('源照片复制长度不符', source.file.path);
      }
      final copiedHash = await sha256.bind(part.openRead()).first;
      if (await FileSystemEntity.type(source.file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        await part.deleteIfExists();
        throw FileSystemException('源照片已替换为链接，已取消复制', source.file.path);
      }
      final sourceHash = await sha256.bind(source.file.openRead()).first;
      final after = await source.file.stat();
      if (copiedHash != sourceHash ||
          after.size != before.size ||
          after.modified != before.modified) {
        await part.deleteIfExists();
        throw FileSystemException('源照片在复制期间发生变化', source.file.path);
      }
      await part.rename(target.path);
      copied.add(target);
      hashesByName[p.basename(source.file.path).toLowerCase()] = copiedHash
          .toString();
    }
    return UsbImportResult(
      files: List.unmodifiable(copied),
      deletedFiles: const [],
      sha256ByName: Map.unmodifiable(hashesByName),
    );
  }

  Future<Directory> historyRoot() async {
    final root =
        supportDirectory?.call() ?? await getApplicationSupportDirectory();
    final history = Directory(p.join(root.path, 'usb-dwarf-import-history'));
    await history.create(recursive: true);
    return history;
  }

  Future<Set<String>> loadImportedIdentities() async {
    final root = await historyRoot();
    final identities = <String>{};
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File ||
          !RegExp(
            r'^[a-f0-9]{64}\.json$',
            caseSensitive: false,
          ).hasMatch(p.basename(entity.path))) {
        continue;
      }
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map || decoded['identity'] is! String) {
        throw FormatException('USB 导入历史损坏：${entity.path}');
      }
      identities.add((decoded['identity'] as String).toLowerCase());
    }
    return identities;
  }

  Future<void> markImported(String identity) async {
    final normalized = identity.toLowerCase();
    final name = sha256.convert(utf8.encode(normalized)).toString();
    final marker = File(p.join((await historyRoot()).path, '$name.json'));
    if (!await marker.exists()) {
      final temporary = File(
        '${marker.path}.tmp-${_clock().microsecondsSinceEpoch}',
      );
      await temporary.writeAsString(
        '${jsonEncode({'identity': normalized, 'importedAt': _clock().toUtc().toIso8601String()})}\n',
        flush: true,
      );
      try {
        await temporary.rename(marker.path);
      } on Object {
        if (!await marker.exists()) rethrow;
        await temporary.deleteIfExists();
      }
    }
  }

  Future<String> sourceSignature(UsbPanoramaSource source) async {
    final photos = await _listPhotoCandidates(source.directory);
    final pieces = <String>[];
    for (final photo in photos) {
      pieces.add(
        '${p.relative(photo.file.path, from: source.directory).replaceAll('\\', '/').toLowerCase()}:${photo.length}:${photo.modified.microsecondsSinceEpoch}',
      );
    }
    pieces.sort();
    return sha256.convert(utf8.encode(pieces.join('\n'))).toString();
  }

  DateTime now() => _clock();

  static Future<List<Directory>> _defaultMountRoots() async {
    final roots = <Directory>[];
    if (Platform.isWindows) {
      for (var letter = 65; letter <= 90; letter++) {
        final root = Directory('${String.fromCharCode(letter)}:\\');
        final driveType = await _getDriveType(root.path);
        if (driveType == 2 || driveType == 3) {
          if (await root.exists()) {
            roots.add(root);
          }
        }
      }
    } else {
      final candidates = <Directory>[];
      for (final path in ['/Volumes', '/media', '/mnt', '/run/media']) {
        final directory = Directory(path);
        if (await directory.exists()) {
          await for (final child in directory.list(followLinks: false)) {
            if (child is Directory) {
              if (path == '/run/media' || path == '/media') {
                await for (final nested in child.list(followLinks: false)) {
                  if (nested is Directory) candidates.add(nested);
                }
              }
              candidates.add(child);
            }
          }
        }
      }
      roots.addAll(candidates);
    }
    return roots;
  }

  static Future<String> _defaultVolumeIdentity(String root) async {
    if (Platform.isWindows) {
      try {
        final library = DynamicLibrary.open('kernel32.dll');
        final getName = library
            .lookupFunction<
              Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
              int Function(Pointer<Utf16>, Pointer<Utf16>, int)
            >('GetVolumeNameForVolumeMountPointW');
        final rootPointer = root.toNativeUtf16();
        final namePointer = calloc<Uint16>(261).cast<Utf16>();
        try {
          if (getName(rootPointer, namePointer, 261) != 0) {
            return namePointer.toDartString().toLowerCase();
          }
        } finally {
          calloc.free(rootPointer);
          calloc.free(namePointer);
        }
      } on Object {
        // Fall back to the mount path when Windows cannot return a volume GUID.
      }
    }
    // Mounted path is the stable best effort on Unix. No whole-disk probing is
    // performed, and importer identities also include the panorama-relative path.
    return p.normalize(p.absolute(root)).replaceAll('\\', '/').toLowerCase();
  }

  static Future<bool> _isRemovable(String root) async {
    if (!Platform.isWindows) {
      final normalized = p.normalize(root).replaceAll('\\', '/');
      return normalized.startsWith('/Volumes/') ||
          normalized.startsWith('/media/') ||
          normalized.startsWith('/mnt/') ||
          normalized.startsWith('/run/media/');
    }
    return await _getDriveType(root) == 2;
  }

  static Future<int> _getDriveType(String root) async {
    try {
      final library = DynamicLibrary.open('kernel32.dll');
      final getDriveType = library
          .lookupFunction<
            Uint32 Function(Pointer<Utf16>),
            int Function(Pointer<Utf16>)
          >('GetDriveTypeW');
      final pointer = root.toNativeUtf16();
      try {
        return getDriveType(pointer);
      } finally {
        calloc.free(pointer);
      }
    } on Object {
      return 0;
    }
  }
}

extension on File {
  Future<void> deleteIfExists() async {
    if (await exists()) await delete();
  }
}
