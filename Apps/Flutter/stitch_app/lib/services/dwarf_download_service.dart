import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/dwarf_download.dart';
import 'dwarf_device_client.dart';
import 'photo_importer.dart' show readJpegMetadata;

/// Durable downloader for DWARF album originals. Each file is streamed to a
/// `.part` file, checkpointed in a JSON manifest, then renamed after JPEG and
/// expected-length validation. A subsequent resume uses HTTP Range.
class DwarfDownloadService {
  DwarfDownloadService({
    required this.rootDirectory,
    HttpClient? httpClient,
    this.maxRetries = 4,
  }) : _http = httpClient ?? HttpClient() {
    if (maxRetries < 0 || maxRetries > 10) {
      throw ArgumentError.value(maxRetries, 'maxRetries');
    }
  }
  final String rootDirectory;
  final int maxRetries;
  final HttpClient _http;
  final Set<String> _cancelled = {};
  final Map<String, HttpClientRequest> _requests = {};
  final Set<String> _activeBatches = {};
  final Map<String, Future<void>> _manifestWrites = {};

  String _safeId(String id) {
    if (id.isEmpty || id.length > 512) throw ArgumentError.value(id, 'batchId');
    final readable = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '${readable.substring(0, readable.length > 40 ? 40 : readable.length)}-${sha256.convert(utf8.encode(id)).toString().substring(0, 20)}';
  }

  String _batchDirectory(String id) => p.join(rootDirectory, _safeId(id));
  String _manifestPath(String id) =>
      p.join(_batchDirectory(id), 'manifest.json');

  Future<List<DwarfDownloadBatch>> listBatches() async {
    final root = Directory(rootDirectory);
    if (!await root.exists()) return const [];
    final result = <DwarfDownloadBatch>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final manifest = File(p.join(entity.path, 'manifest.json'));
      final backup = File('${manifest.path}.bak');
      if (!await manifest.exists() && !await backup.exists()) continue;
      try {
        result.add(
          await _readManifest(
            await manifest.exists() ? manifest : backup,
            expectedDirectory: entity.path,
          ),
        );
      } on Object {
        if (await backup.exists()) {
          try {
            result.add(
              await _readManifest(backup, expectedDirectory: entity.path),
            );
          } on Object {
            // Leave damaged manifests out of the recoverable batch listing.
          }
        }
      }
    }
    result.sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(result);
  }

  Future<DwarfDownloadBatch?> loadBatch(String batchId) async =>
      _serializeManifestAccess(batchId, () async {
        final manifest = File(_manifestPath(batchId));
        final backup = File('${manifest.path}.bak');
        Object? mainError;
        if (await manifest.exists()) {
          try {
            return await _readManifest(
              manifest,
              expectedDirectory: _batchDirectory(batchId),
            );
          } on Object catch (error) {
            mainError = error;
          }
        }
        if (await backup.exists()) {
          return _readManifest(
            backup,
            expectedDirectory: _batchDirectory(batchId),
          );
        }
        if (mainError != null) throw mainError;
        return null;
      });

  Future<DwarfDownloadBatch> downloadBatch({
    required String batchId,
    required List<DwarfOriginal> originals,
    Map<String, Object?> metadata = const {},
    void Function(DwarfDownloadProgress progress)? onProgress,
  }) async {
    if (originals.isEmpty) {
      throw ArgumentError.value(
        originals,
        'originals',
        'At least one source photo is required',
      );
    }
    final id = batchId, dir = Directory(_batchDirectory(batchId));
    await dir.create(recursive: true);
    final existing = await loadBatch(id);
    if (existing != null) {
      if (!_sameSources(
        existing.files.map((f) => f.original).toList(),
        originals,
      )) {
        throw StateError(
          'Batch $id already exists with a different source set; refusing to overwrite it',
        );
      }
      return _download(
        existing.copyWith(state: DwarfDownloadState.queued),
        onProgress,
      );
    }
    final used = <String>{};
    final files = <DwarfDownloadFile>[];
    for (var i = 0; i < originals.length; i++) {
      final source = originals[i];
      final base = p.basename(source.name.replaceAll('\\', '/'));
      if (base != source.name ||
          source.name.contains('/') ||
          source.name.contains('\\') ||
          base.isEmpty ||
          base == '.' ||
          base == '..' ||
          base.contains('/') ||
          base.contains('\u0000')) {
        throw ArgumentError.value(
          source.name,
          'originals',
          'Unsafe source filename',
        );
      }
      if (!used.add(base.toLowerCase())) {
        throw ArgumentError.value(
          source.name,
          'originals',
          'Duplicate source filenames cannot be preserved',
        );
      }
      files.add(
        DwarfDownloadFile(original: source, path: p.join(dir.path, base)),
      );
    }
    return _download(
      DwarfDownloadBatch(
        id: id,
        directory: dir.path,
        state: DwarfDownloadState.queued,
        files: files,
        metadata: metadata,
      ),
      onProgress,
    );
  }

  Future<DwarfDownloadBatch> resumeBatch(
    String batchId, {
    void Function(DwarfDownloadProgress progress)? onProgress,
  }) async {
    final batch = await loadBatch(batchId);
    if (batch == null) {
      throw StateError('Download batch $batchId was not found');
    }
    return _download(
      batch.copyWith(state: DwarfDownloadState.queued, clearError: true),
      onProgress,
    );
  }

  Future<void> cancelBatch(String batchId) async {
    final id = batchId;
    _cancelled.add(id);
    _requests.remove(id)?.abort(StateError('Download cancelled'));
    final batch = await loadBatch(id);
    if (batch != null) {
      await _save(batch.copyWith(state: DwarfDownloadState.cancelled));
    }
  }

  Future<DwarfDownloadBatch> _download(
    DwarfDownloadBatch batch,
    void Function(DwarfDownloadProgress)? onProgress,
  ) async {
    final id = batch.id;
    if (batch.files.isEmpty) {
      throw StateError('Cannot complete an empty download batch');
    }
    if (!_activeBatches.add(id)) {
      throw StateError('Download batch $id is already active');
    }
    try {
      _cancelled.remove(id);
      var current = batch.copyWith(
        state: DwarfDownloadState.downloading,
        clearError: true,
      );
      await _save(current);
      for (var index = 0; index < current.files.length; index++) {
        if (_cancelled.contains(id)) {
          return _finish(current, DwarfDownloadState.cancelled);
        }
        var file = current.files[index];
        if (file.complete &&
            await _validJpeg(File(file.path), file.original.size) &&
            (file.sha256 == null ||
                await _fileSha256(File(file.path)) == file.sha256)) {
          continue;
        }
        if (file.complete) {
          file = file.copyWith(complete: false, bytes: 0, clearError: true);
        }
        Object? lastError;
        var completed = false;
        for (var attempt = 0; attempt <= maxRetries && !completed; attempt++) {
          if (_cancelled.contains(id)) {
            return _finish(current, DwarfDownloadState.cancelled);
          }
          try {
            file = await _downloadOne(
              id,
              file,
              onProgress,
              index,
              current.files.length,
            );
            completed = file.complete;
          } on Object catch (error) {
            lastError = error;
            final persisted = await loadBatch(id);
            if (persisted != null) {
              for (final saved in persisted.files) {
                if (saved.original.id == file.original.id) {
                  final partial = File('${saved.path}.part');
                  final partialBytes = await partial.exists()
                      ? await partial.length()
                      : saved.bytes;
                  file = saved.copyWith(complete: false, bytes: partialBytes);
                  break;
                }
              }
            }
            if (attempt < maxRetries) {
              await Future<void>.delayed(
                Duration(milliseconds: 250 * (1 << attempt)),
              );
            }
          }
        }
        final files = [...current.files]
          ..[index] = file.copyWith(error: completed ? null : '$lastError');
        current = current.copyWith(
          files: files,
          state: _cancelled.contains(id)
              ? DwarfDownloadState.cancelled
              : DwarfDownloadState.downloading,
          error: completed ? null : '$lastError',
        );
        await _save(current);
        if (!completed) {
          return _finish(
            current,
            _cancelled.contains(id)
                ? DwarfDownloadState.cancelled
                : DwarfDownloadState.failed,
            error: '$lastError',
          );
        }
      }
      return _finish(current, DwarfDownloadState.completed);
    } finally {
      _activeBatches.remove(id);
    }
  }

  Future<DwarfDownloadFile> _downloadOne(
    String id,
    DwarfDownloadFile file,
    void Function(DwarfDownloadProgress)? onProgress,
    int index,
    int count,
  ) async {
    final target = File(file.path), partial = File('${file.path}.part');
    await target.parent.create(recursive: true);
    var offset = await partial.exists() ? await partial.length() : 0;
    if (file.original.size != null && offset > file.original.size!) {
      await partial.delete();
      offset = 0;
    }
    final strongEtag =
        file.original.etag != null &&
        file.original.etag!.isNotEmpty &&
        !file.original.etag!.startsWith('W/');
    final hasResumeValidator =
        strongEtag ||
        (file.original.lastModified != null &&
            file.original.lastModified!.isNotEmpty);
    if (offset > 0 && !hasResumeValidator) {
      await partial.delete();
      offset = 0;
    }
    final uri = Uri.parse(file.original.url);
    if (uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        !DwarfDeviceClient.isLocalNetworkHost(uri.host)) {
      throw const FormatException(
        'DWARF source must use a local network HTTP address',
      );
    }
    var restarted = false;
    while (true) {
      final request = await _http
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      _requests[id] = request;
      request.followRedirects = false;
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        final validator = strongEtag
            ? file.original.etag
            : file.original.lastModified;
        if (validator != null) {
          request.headers.set(HttpHeaders.ifRangeHeader, validator);
        }
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (_cancelled.contains(id)) {
        await response.listen(null).cancel();
        return file.copyWith(bytes: offset, complete: false);
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
      final changed =
          (file.original.etag != null &&
              etag != null &&
              file.original.etag != etag) ||
          (file.original.lastModified != null &&
              modified != null &&
              file.original.lastModified != modified);
      if (changed) {
        await response.listen(null).cancel();
        throw const FormatException(
          'DWARF source changed after it was selected; select the panorama again',
        );
      }
      if (offset > 0 &&
          ((strongEtag && etag != file.original.etag) ||
              (!strongEtag && modified != file.original.lastModified))) {
        await response.listen(null).cancel();
        throw const FormatException(
          'DWARF server did not confirm the source validator for resume',
        );
      }
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        final range = RegExp(r'bytes \*/(\d+)').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        );
        final total = range == null ? null : int.tryParse(range.group(1)!);
        await response.listen(null).cancel();
        if (total != null &&
            total == offset &&
            (file.original.size == null || total == file.original.size) &&
            await _validJpeg(partial, total)) {
          final digest = await _fileSha256(partial);
          await partial.rename(target.path);
          return file.copyWith(
            bytes: offset,
            complete: true,
            clearError: true,
            sha256: digest,
          );
        }
        if (restarted) {
          throw HttpException('DWARF server rejected resume at byte $offset');
        }
        await partial.deleteIfExists();
        offset = 0;
        restarted = true;
        continue;
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await response.listen(null).cancel();
        throw HttpException(
          'DWARF file download returned HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      if (response.statusCode == HttpStatus.partialContent) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        );
        if (range == null || int.parse(range.group(1)!) != offset) {
          await response.listen(null).cancel();
          if (!restarted) {
            await partial.deleteIfExists();
            offset = 0;
            restarted = true;
            continue;
          }
          throw const FormatException(
            'Invalid Content-Range from DWARF camera',
          );
        }
      } else if (offset > 0) {
        // A 200 response means Range was ignored or the entity changed. Restart
        // cleanly so bytes from two versions can never be concatenated.
        offset = 0;
      }
      final totalFromRange = response.statusCode == HttpStatus.partialContent
          ? int.tryParse(
              RegExp(r'/([0-9]+)$')
                      .firstMatch(
                        response.headers.value(
                              HttpHeaders.contentRangeHeader,
                            ) ??
                            '',
                      )
                      ?.group(1) ??
                  '',
            )
          : null;
      final expected =
          file.original.size ??
          totalFromRange ??
          (response.contentLength >= 0
              ? response.contentLength + offset
              : null);
      if (response.statusCode == HttpStatus.partialContent) {
        final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        )!;
        final rangeEnd = int.parse(match.group(2)!);
        final rangeTotal = int.tryParse(match.group(3)!);
        if (rangeEnd < offset ||
            (rangeTotal != null &&
                file.original.size != null &&
                rangeTotal != file.original.size)) {
          await response.listen(null).cancel();
          if (!restarted) {
            await partial.deleteIfExists();
            offset = 0;
            restarted = true;
            continue;
          }
          throw const FormatException(
            'DWARF file changed during range download',
          );
        }
      } else if (response.contentLength >= 0 &&
          file.original.size != null &&
          response.contentLength != file.original.size) {
        await response.listen(null).cancel();
        throw const FormatException(
          'DWARF file size changed since it was listed',
        );
      }
      file = file.copyWith(
        original: file.original.copyWith(
          size: expected,
          etag: etag ?? file.original.etag,
          lastModified: modified ?? file.original.lastModified,
        ),
      );
      await _persistSource(id, file);
      final sink = partial.openWrite(
        mode: offset == 0 ? FileMode.writeOnly : FileMode.append,
      );
      var written = offset;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
        )) {
          if (_cancelled.contains(id)) break;
          sink.add(chunk);
          written += chunk.length;
          onProgress?.call(
            DwarfDownloadProgress(
              batchId: id,
              fileName: file.original.name,
              fileBytes: written,
              fileSize: expected ?? 0,
              completedFiles: index,
              totalFiles: count,
            ),
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
        _requests.remove(id);
      }
      if (_cancelled.contains(id)) {
        return file.copyWith(bytes: written, complete: false);
      }
      if (response.statusCode == HttpStatus.partialContent) {
        final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        )!;
        if (int.parse(match.group(2)!) != written - 1) {
          throw const FormatException(
            'DWARF Content-Range length does not match response body',
          );
        }
      }
      if (expected != null && written != expected) {
        throw HttpException(
          'Incomplete DWARF file: received $written of $expected bytes',
        );
      }
      if (!await _validJpeg(partial, expected)) {
        throw const FormatException('Downloaded source is not a complete JPEG');
      }
      final digest = await _fileSha256(partial);
      await target.deleteIfExists();
      await partial.rename(target.path);
      return file.copyWith(
        bytes: written,
        complete: true,
        clearError: true,
        original: file.original.copyWith(
          size: expected,
          etag: etag,
          lastModified: modified,
        ),
        sha256: digest,
      );
    }
  }

  Future<bool> _validJpeg(File file, int? expected) async {
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < 4 || (expected != null && length != expected)) return false;
    final raf = await file.open();
    try {
      final start = await raf.read(2);
      await raf.setPosition(length - 2);
      final end = await raf.read(2);
      if (!(start.length == 2 &&
          end.length == 2 &&
          start[0] == 0xff &&
          start[1] == 0xd8 &&
          end[0] == 0xff &&
          end[1] == 0xd9)) {
        return false;
      }
      await readJpegMetadata(file);
      return true;
    } finally {
      await raf.close();
    }
  }

  Future<DwarfDownloadBatch> _finish(
    DwarfDownloadBatch batch,
    DwarfDownloadState state, {
    String? error,
  }) async {
    final result = batch.copyWith(
      state: state,
      error: error,
      clearError: error == null,
    );
    await _save(result);
    return result;
  }

  Future<void> _save(DwarfDownloadBatch batch) async {
    await _serializeManifestAccess(batch.id, () => _writeManifest(batch));
  }

  Future<T> _serializeManifestAccess<T>(
    String id,
    Future<T> Function() action,
  ) async {
    final previous = _manifestWrites[id];
    final gate = Completer<void>();
    _manifestWrites[id] = gate.future;
    try {
      if (previous != null) await previous;
    } catch (_) {
      // A failed prior write must not permanently block later recovery writes.
    }
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_manifestWrites[id], gate.future)) {
        _manifestWrites.remove(id);
      }
    }
  }

  Future<void> _writeManifest(DwarfDownloadBatch batch) async {
    final file = File(_manifestPath(batch.id));
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      encodeDwarfDownloadJson(batch.toJson()),
      flush: true,
    );
    final backup = File('${file.path}.bak');
    await backup.deleteIfExists();
    if (await file.exists()) await file.rename(backup.path);
    await temp.rename(file.path);
    await backup.deleteIfExists();
  }

  Future<DwarfDownloadBatch> _readManifest(
    File file, {
    required String expectedDirectory,
  }) async {
    final batch = DwarfDownloadBatch.fromJson(
      (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>(),
    );
    final root = p.normalize(p.absolute(expectedDirectory));
    if (p.normalize(p.absolute(batch.directory)) != root) {
      throw const FormatException('Unsafe download manifest directory');
    }
    for (final item in batch.files) {
      if (p.dirname(p.normalize(p.absolute(item.path))) != root ||
          p.basename(item.path) != item.original.name) {
        throw const FormatException('Unsafe download manifest file path');
      }
    }
    final recoveredFiles = <DwarfDownloadFile>[];
    for (final item in batch.files) {
      if (item.complete) {
        recoveredFiles.add(item);
        continue;
      }
      final partial = File('${item.path}.part');
      final length = await partial.exists()
          ? await partial.length()
          : item.bytes;
      recoveredFiles.add(
        length == item.bytes ? item : item.copyWith(bytes: length),
      );
    }
    return batch.copyWith(files: recoveredFiles);
  }

  Future<String> _fileSha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _persistSource(String id, DwarfDownloadFile file) async {
    final batch = await loadBatch(id);
    if (batch == null) return;
    final files = [...batch.files];
    final index = files.indexWhere(
      (item) => item.original.id == file.original.id,
    );
    if (index < 0) return;
    files[index] = files[index].copyWith(original: file.original);
    await _save(batch.copyWith(files: files));
  }

  bool _sameSources(List<DwarfOriginal> a, List<DwarfOriginal> b) =>
      a.length == b.length &&
      List.generate(
        a.length,
        (i) =>
            a[i].id == b[i].id &&
            a[i].url == b[i].url &&
            a[i].name == b[i].name &&
            (b[i].size == null || a[i].size == b[i].size) &&
            (b[i].etag == null || a[i].etag == b[i].etag) &&
            (b[i].lastModified == null ||
                a[i].lastModified == b[i].lastModified),
      ).every((v) => v);
  void close({bool force = false}) => _http.close(force: force);
}

extension on DwarfOriginal {
  DwarfOriginal copyWith({int? size, String? etag, String? lastModified}) =>
      DwarfOriginal(
        id: id,
        name: name,
        url: url,
        size: size ?? this.size,
        etag: etag ?? this.etag,
        lastModified: lastModified ?? this.lastModified,
      );
}

extension on DwarfDownloadFile {
  DwarfDownloadFile copyWith({
    DwarfOriginal? original,
    String? path,
    int? bytes,
    bool? complete,
    String? error,
    bool clearError = false,
    String? sha256,
  }) => DwarfDownloadFile(
    original: original ?? this.original,
    path: path ?? this.path,
    bytes: bytes ?? this.bytes,
    complete: complete ?? this.complete,
    error: clearError ? null : error ?? this.error,
    sha256: sha256 ?? this.sha256,
  );
}

extension on DwarfDownloadBatch {
  DwarfDownloadBatch copyWith({
    String? id,
    String? directory,
    DwarfDownloadState? state,
    List<DwarfDownloadFile>? files,
    String? error,
    bool clearError = false,
    Map<String, Object?>? metadata,
  }) => DwarfDownloadBatch(
    id: id ?? this.id,
    directory: directory ?? this.directory,
    state: state ?? this.state,
    files: files ?? this.files,
    error: clearError ? null : error ?? this.error,
    metadata: metadata ?? this.metadata,
  );
}

extension on File {
  Future<void> deleteIfExists() async {
    if (await exists()) await delete();
  }
}
