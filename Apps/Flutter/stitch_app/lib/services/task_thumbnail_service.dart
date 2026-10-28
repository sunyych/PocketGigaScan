import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/stitch_task.dart';

/// Makes small durable task-rail previews and reuses them across list rebuilds.
class TaskThumbnailService {
  TaskThumbnailService({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _targetWidth = 256;
  static const _tileSize = 512;
  static const _maxManifestBytes = 32 * 1024 * 1024;
  static const _maxEncodedTileBytes = 8 * 1024 * 1024;
  static const _maxSourceImageBytes = 64 * 1024 * 1024;

  final Future<Directory> Function() _supportDirectory;
  final Map<String, Future<File?>> _pending = {};

  Future<File?> thumbnailFor(StitchTask task) async {
    final candidates = <_ThumbnailCandidate>[];
    if (task.phase == StitchPhase.completed) {
      candidates.addAll(await _pyramidCandidates(task));
    }
    final cameraThumbnail = task.previewThumbnailPath;
    if (cameraThumbnail != null && cameraThumbnail.isNotEmpty) {
      candidates.add(_ThumbnailCandidate(cameraThumbnail, maxDimension: null));
    }
    if (task.photos.isNotEmpty) {
      candidates.add(
        _ThumbnailCandidate(task.photos.first.storedPath, maxDimension: null),
      );
    }

    for (final candidate in candidates) {
      try {
        final source = File(candidate.path);
        final stat = await source.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size == 0 ||
            (candidate.maxDimension != null &&
                (stat.size > _maxEncodedTileBytes ||
                    candidate.maxDimension! > _tileSize))) {
          continue;
        }
        final signature = [
          task.id,
          candidate.path,
          stat.size,
          stat.modified.microsecondsSinceEpoch,
        ].join('|');
        final cached = _pending[signature];
        if (cached != null) {
          final result = await cached;
          if (result != null) return result;
          if (identical(_pending[signature], cached)) {
            _pending.remove(signature);
          }
          continue;
        }
        final future = _createCachedThumbnail(source, signature);
        _pending[signature] = future;
        final result = await future;
        if (result != null) return result;
        if (identical(_pending[signature], future)) {
          _pending.remove(signature);
        }
      } on Object {
        // Missing, unreadable, or unsupported candidates fall through to the
        // next source. A transient failure must not poison later attempts.
        continue;
      }
    }
    return null;
  }

  Future<List<_ThumbnailCandidate>> _pyramidCandidates(StitchTask task) async {
    try {
      final manifest = File(p.join(task.outputDirectory, 'manifest.json'));
      final stat = await manifest.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size <= 0 ||
          stat.size > _maxManifestBytes) {
        return const [];
      }
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) return const [];
      final rawLevels = decoded['levels'];
      if (rawLevels is! List || rawLevels.isEmpty || rawLevels.length > 32) {
        return const [];
      }
      final levels = <_ThumbnailLevel>[];
      for (final rawLevel in rawLevels) {
        if (rawLevel is! Map<String, dynamic>) continue;
        final number = rawLevel['level'];
        final width = rawLevel['width'];
        final height = rawLevel['height'];
        final occupied = rawLevel['occupied'];
        if (number is! int ||
            number < 0 ||
            width is! int ||
            width <= 0 ||
            height is! int ||
            height <= 0 ||
            occupied is! List ||
            occupied.isEmpty ||
            occupied.length > 1000000) {
          continue;
        }
        final tiles = <_ThumbnailCandidate>[];
        for (final rawTile in occupied) {
          if (rawTile is! Map<String, dynamic>) continue;
          final tilePath = rawTile['path'];
          final tileWidth = rawTile['width'];
          final tileHeight = rawTile['height'];
          if (tilePath is! String ||
              tileWidth is! int ||
              tileWidth <= 0 ||
              tileWidth > _tileSize ||
              tileHeight is! int ||
              tileHeight <= 0 ||
              tileHeight > _tileSize ||
              (width <= _tileSize &&
                  height <= _tileSize &&
                  (tileWidth != width || tileHeight != height))) {
            continue;
          }
          final normalized = tilePath.replaceAll('\\', '/');
          final context = p.Context(style: p.Style.posix);
          final relative = context.normalize(normalized);
          if (context.isAbsolute(normalized) ||
              normalized.split('/').contains('..') ||
              !relative.startsWith('level-$number/') ||
              !relative.toLowerCase().endsWith('.png')) {
            continue;
          }
          if (tiles.length >= 16) break;
          tiles.add(
            _ThumbnailCandidate(
              p.join(task.outputDirectory, relative),
              maxDimension: tileWidth > tileHeight ? tileWidth : tileHeight,
            ),
          );
        }
        if (width <= _tileSize &&
            height <= _tileSize &&
            occupied.length == 1 &&
            tiles.length == 1 &&
            tiles.single.maxDimension == (width > height ? width : height)) {
          levels.add(_ThumbnailLevel(width, height, number, tiles.single));
        }
      }
      if (levels.isEmpty) return const [];
      final preferred =
          levels.where((level) => level.longEdge >= 256).toList(growable: false)
            ..sort((a, b) => b.longEdge.compareTo(a.longEdge));
      if (preferred.isNotEmpty) return [preferred.first.tile];
      levels.sort(
        (a, b) => (a.longEdge - 384).abs().compareTo((b.longEdge - 384).abs()),
      );
      return [levels.first.tile];
    } on Object {
      return const [];
    }
  }

  Future<File?> _createCachedThumbnail(File source, String signature) async {
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      final support = await _supportDirectory();
      final cache = Directory(p.join(support.path, 'task-thumbnails'));
      await cache.create(recursive: true);
      final destination = File(
        p.join(cache.path, '${sha256.convert(signature.codeUnits)}.png'),
      );
      if (await destination.exists() && await destination.length() > 0) {
        return destination;
      }
      final sourceLength = await source.length();
      if (sourceLength <= 0 || sourceLength > _maxSourceImageBytes) {
        return null;
      }
      final encoded = await source.readAsBytes();
      codec = await ui.instantiateImageCodec(
        encoded,
        targetWidth: _targetWidth,
        allowUpscaling: false,
      );
      frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return null;
      final temporary = File('${destination.path}.tmp');
      await temporary.writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        flush: true,
      );
      await temporary.rename(destination.path);
      return destination;
    } on Object {
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }
}

class _ThumbnailCandidate {
  const _ThumbnailCandidate(this.path, {required this.maxDimension});
  final String path;
  final int? maxDimension;
}

class _ThumbnailLevel {
  const _ThumbnailLevel(this.width, this.height, this.number, this.tile);
  final int width;
  final int height;
  final int number;
  final _ThumbnailCandidate tile;
  int get longEdge => width > height ? width : height;
}
