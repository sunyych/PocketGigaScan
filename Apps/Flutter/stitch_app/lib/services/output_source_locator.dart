import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import '../models/grid_options.dart';
import '../models/stitch_task.dart';

/// Read-only geometric trace for a rendered equirectangular output pixel.
/// This reports every camera whose source rectangle covers the ray; the
/// renderer's final blend/ownership decision is intentionally not inferred.
class OutputSourceLocator {
  const OutputSourceLocator._();

  static OutputPixelTrace locate({
    required Map<String, Object?> layout,
    required StitchTask task,
    required int outputWidth,
    required int outputHeight,
    required double outputX,
    required double outputY,
  }) {
    if (layout['projection'] != 'spherical' ||
        outputWidth <= 0 ||
        outputHeight <= 0 ||
        !outputX.isFinite ||
        !outputY.isFinite ||
        outputX < 0 ||
        outputY < 0 ||
        outputX >= outputWidth ||
        outputY >= outputHeight) {
      throw const FormatException('Output coordinate or layout is invalid.');
    }
    final tiles = layout['tiles'];
    if (tiles is! List) {
      throw const FormatException('Layout tiles are missing.');
    }
    final yawMin = _number(layout['yawMinRad']);
    final yawMax = _number(layout['yawMaxRad']);
    final pitchMin = _number(layout['pitchMinRad']);
    final pitchMax = _number(layout['pitchMaxRad']);
    if (yawMin == null ||
        yawMax == null ||
        pitchMin == null ||
        pitchMax == null ||
        yawMax <= yawMin ||
        pitchMax <= pitchMin) {
      throw const FormatException('Layout projection bounds are invalid.');
    }
    final yaw = yawMin + (outputX + 0.5) / outputWidth * (yawMax - yawMin);
    final pitch =
        pitchMax - (outputY + 0.5) / outputHeight * (pitchMax - pitchMin);
    final world = <double>[
      math.sin(yaw) * math.cos(pitch),
      math.sin(pitch),
      math.cos(yaw) * math.cos(pitch),
    ];
    final mapping = task.grid.mode == GridMode.filename
        ? GridMapping.fromFilenames(task.photos)
        : GridMapping.sequence(task.photos, task.grid);
    if (!mapping.isValid || mapping.cells.length != task.photos.length) {
      throw const FormatException('Task grid mapping is invalid.');
    }
    final byCell = <String, int>{};
    for (var i = 0; i < mapping.cells.length; i++) {
      final c = mapping.cells[i];
      byCell['${c.row}:${c.column}'] = i;
    }
    final parsedTiles = <_LayoutTile>[];
    for (var layoutIndex = 0; layoutIndex < tiles.length; layoutIndex++) {
      final raw = tiles[layoutIndex];
      if (raw is! Map<String, Object?>) continue;
      final row = _integer(raw['row']);
      final column = _integer(raw['column']);
      final index = row == null || column == null
          ? null
          : byCell['$row:$column'];
      if (index == null) continue;
      final matrix = raw['cameraToWorld'];
      final width = _integer(raw['width']);
      final height = _integer(raw['height']);
      final fx = _number(raw['fx']);
      final fy = _number(raw['fy']);
      final cx = _number(raw['cx']);
      final cy = _number(raw['cy']);
      if (matrix is! List ||
          matrix.length != 9 ||
          width == null ||
          height == null ||
          width < 2 ||
          height < 2 ||
          fx == null ||
          fy == null ||
          cx == null ||
          cy == null ||
          fx <= 0 ||
          fy <= 0) {
        continue;
      }
      final m = matrix.map(_number).toList();
      if (m.any((v) => v == null)) continue;
      final values = m.cast<double>();
      if (values.any((v) => !v.isFinite)) continue;
      final photo = task.photos[index];
      final tilePath = raw['path'];
      if (width != photo.width ||
          height != photo.height ||
          tilePath is! String ||
          !sameFilesystemPath(tilePath, photo.storedPath)) {
        continue;
      }
      parsedTiles.add(
        _LayoutTile(
          index: index,
          layoutIndex: layoutIndex,
          row: row!,
          column: column!,
          values: values,
          width: width,
          height: height,
          fx: fx,
          fy: fy,
          cx: cx,
          cy: cy,
          warp: raw['sourcePlaneWarp'],
          raw: raw,
        ),
      );
    }
    final candidates = <OutputCameraCoverage>[];
    for (final tile in parsedTiles) {
      final m = tile.values;
      // Transpose the row-major camera-to-world rotation, matching the native
      // renderer's world-ray to camera-ray projection.
      final camera = <double>[
        m[0] * world[0] + m[3] * world[1] + m[6] * world[2],
        m[1] * world[0] + m[4] * world[1] + m[7] * world[2],
        m[2] * world[0] + m[5] * world[1] + m[8] * world[2],
      ];
      if (camera[2] <= 1e-5) continue;
      final idealX = tile.cx + tile.fx * camera[0] / camera[2];
      final idealY = tile.cy - tile.fy * camera[1] / camera[2];
      final source = _inverseWarp(
        tile.warp,
        tile.width,
        tile.height,
        idealX,
        idealY,
      );
      if (source == null) continue;
      final hasWarp = _hasNonzeroWarp(tile.warp);
      final inside = hasWarp
          ? source.$1 >= 0 &&
                source.$2 >= 0 &&
                source.$1 <= tile.width - 1 &&
                source.$2 <= tile.height - 1
          : source.$1 >= 0 &&
                source.$2 >= 0 &&
                source.$1 < tile.width &&
                source.$2 < tile.height;
      if (!inside) continue;
      final photo = task.photos[tile.index];
      final constraint = _placement(tile.raw);
      candidates.add(
        OutputCameraCoverage(
          row: tile.row,
          column: tile.column,
          originalName: photo.originalName,
          sourcePath: photo.storedPath,
          sourceX: source.$1,
          sourceY: source.$2,
          positionSource: tile.raw['positionSource'] is String
              ? tile.raw['positionSource'] as String
              : 'unknown',
          placementKind: constraint.$1,
          placementOrigin: constraint.$2,
          directVisualEvidence: tile.raw['directVisualEvidence'] == true,
          neighborEdges: _neighborEdges(tile, parsedTiles, layout['report']),
        ),
      );
    }
    return OutputPixelTrace(
      outputX: outputX,
      outputY: outputY,
      yawRad: yaw,
      pitchRad: pitch,
      cameras: List.unmodifiable(candidates),
      rendererChoice: null,
      exposureAndColorGains: null,
    );
  }

  static (String, String) _placement(Map<String, Object?> tile) {
    final raw = tile['placementConstraint'];
    if (raw is Map<String, Object?>) {
      final kind = raw['kind'];
      if (kind is String &&
          (kind == 'hardGridLock' || kind == 'gridPrior' || kind == 'none')) {
        return (
          kind,
          raw['origin'] is String ? raw['origin'] as String : 'unknown',
        );
      }
    }
    if (tile['forceGrid'] == true) return ('hardGridLock', 'legacyUnknown');
    return (
      tile['positionSource'] == 'gridEstimated' ? 'gridPrior' : 'none',
      'legacyUnknown',
    );
  }

  static List<OutputNeighborEdge> _neighborEdges(
    _LayoutTile tile,
    List<_LayoutTile> tiles,
    Object? report,
  ) {
    if (report is! Map<String, Object?> || report['edgeDiagnostics'] is! List) {
      return const [];
    }
    final result = <OutputNeighborEdge>[];
    for (final other in tiles) {
      if ((other.row - tile.row).abs() > 1 ||
          (other.column - tile.column).abs() > 1 ||
          (other.row == tile.row && other.column == tile.column)) {
        continue;
      }
      for (final item in report['edgeDiagnostics'] as List) {
        if (item is! Map<String, Object?>) continue;
        final from = _integer(item['from']);
        final to = _integer(item['to']);
        final matches =
            (from == tile.layoutIndex && to == other.layoutIndex) ||
            (to == tile.layoutIndex && from == other.layoutIndex);
        if (!matches) continue;
        result.add(
          OutputNeighborEdge(
            row: other.row,
            column: other.column,
            disposition: item['disposition'] is String
                ? item['disposition'] as String
                : 'unknown',
            medianResidualPx: _number(item['rayMedianResidualPx']),
            rmsResidualPx: _number(item['rayRmsResidualPx']),
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  static (double, double)? _inverseWarp(
    Object? value,
    int width,
    int height,
    double x,
    double y,
  ) {
    if (value == null) return (x, y);
    if (value is! Map<String, Object?>) return null;
    final columns = _integer(value['columns']);
    final rows = _integer(value['rows']);
    final rawOffsets = value['offsets'];
    if (columns == null ||
        rows == null ||
        columns != rows ||
        ![3, 5, 9].contains(columns) ||
        rawOffsets is! List ||
        rawOffsets.length != columns * rows) {
      return null;
    }
    final offsets = <(double, double)>[];
    for (final pair in rawOffsets) {
      if (pair is! List || pair.length != 2) return null;
      final dx = _number(pair[0]);
      final dy = _number(pair[1]);
      if (dx == null ||
          dy == null ||
          !dx.isFinite ||
          !dy.isFinite ||
          math.sqrt(dx * dx + dy * dy) > 64.000000001) {
        return null;
      }
      offsets.add((dx, dy));
    }
    final stepX = (width - 1) / (columns - 1);
    final stepY = (height - 1) / (rows - 1);
    for (var row = 0; row < rows - 1; row++) {
      for (var column = 0; column < columns - 1; column++) {
        final a = offsets[row * columns + column];
        final b = offsets[row * columns + column + 1];
        final c = offsets[(row + 1) * columns + column];
        final d = offsets[(row + 1) * columns + column + 1];
        for (final u in [0.0, 1.0]) {
          for (final v in [0.0, 1.0]) {
            final j00 = ((1 - v) * (b.$1 - a.$1) + v * (d.$1 - c.$1)) / stepX;
            final j01 = ((1 - u) * (c.$1 - a.$1) + u * (d.$1 - b.$1)) / stepY;
            final j10 = ((1 - v) * (b.$2 - a.$2) + v * (d.$2 - c.$2)) / stepX;
            final j11 = ((1 - u) * (c.$2 - a.$2) + u * (d.$2 - b.$2)) / stepY;
            final trace = j00 * j00 + j01 * j01 + j10 * j10 + j11 * j11;
            final determinant = (j00 * j11 - j01 * j10);
            final norm = math.sqrt(
              (trace +
                      math.sqrt(
                        math.max(
                          0.0,
                          trace * trace - 4 * determinant * determinant,
                        ),
                      )) /
                  2,
            );
            if (!norm.isFinite || norm > 0.100000001) return null;
          }
        }
      }
    }
    double ix(double px, double py) {
      final gx = px / (width - 1) * (columns - 1);
      final gy = py / (height - 1) * (rows - 1);
      final x0 = gx.floor().clamp(0, columns - 2).toInt();
      final y0 = gy.floor().clamp(0, rows - 2).toInt();
      final tx = (gx - x0).clamp(0.0, 1.0).toDouble();
      final ty = (gy - y0).clamp(0.0, 1.0).toDouble();
      final a = offsets[y0 * columns + x0];
      final b = offsets[y0 * columns + x0 + 1];
      final c = offsets[(y0 + 1) * columns + x0];
      final d = offsets[(y0 + 1) * columns + x0 + 1];
      return (1 - ty) * ((1 - tx) * a.$1 + tx * b.$1) +
          ty * ((1 - tx) * c.$1 + tx * d.$1);
    }

    double iy(double px, double py) {
      final gx = px / (width - 1) * (columns - 1);
      final gy = py / (height - 1) * (rows - 1);
      final x0 = gx.floor().clamp(0, columns - 2).toInt();
      final y0 = gy.floor().clamp(0, rows - 2).toInt();
      final tx = (gx - x0).clamp(0.0, 1.0).toDouble();
      final ty = (gy - y0).clamp(0.0, 1.0).toDouble();
      final a = offsets[y0 * columns + x0];
      final b = offsets[y0 * columns + x0 + 1];
      final c = offsets[(y0 + 1) * columns + x0];
      final d = offsets[(y0 + 1) * columns + x0 + 1];
      return (1 - ty) * ((1 - tx) * a.$2 + tx * b.$2) +
          ty * ((1 - tx) * c.$2 + tx * d.$2);
    }

    var sx = x.clamp(0.0, (width - 1).toDouble()).toDouble();
    var sy = y.clamp(0.0, (height - 1).toDouble()).toDouble();
    for (var i = 0; i < 8; i++) {
      final clampedX = sx.clamp(0.0, (width - 1).toDouble()).toDouble();
      final clampedY = sy.clamp(0.0, (height - 1).toDouble()).toDouble();
      final nx = x - ix(clampedX, clampedY);
      final ny = y - iy(clampedX, clampedY);
      final change = math.sqrt(math.pow(nx - sx, 2) + math.pow(ny - sy, 2));
      sx = nx;
      sy = ny;
      if (change <= 0.002) break;
    }
    if (sx < 0 || sy < 0 || sx > width - 1 || sy > height - 1) return null;
    final roundX = sx + ix(sx, sy);
    final roundY = sy + iy(sx, sy);
    if (math.sqrt(math.pow(roundX - x, 2) + math.pow(roundY - y, 2)) > 0.02) {
      return null;
    }
    return (sx, sy);
  }

  static bool _hasNonzeroWarp(Object? value) =>
      value is Map<String, Object?> &&
      value['offsets'] is List &&
      (value['offsets'] as List).any(
        (e) =>
            e is List &&
            e.length == 2 &&
            ((_number(e[0]) ?? 0) != 0 || (_number(e[1]) ?? 0) != 0),
      );
  static int? _integer(Object? value) => value is int ? value : null;
  static double? _number(Object? value) =>
      value is num ? value.toDouble() : null;

  static bool sameFilesystemPath(String left, String right) {
    final windows = p.Context(style: p.Style.windows);
    String stripExtendedPrefix(String path) {
      final normalizedSeparators = path.replaceAll('/', '\\');
      final lower = normalizedSeparators.toLowerCase();
      const uncPrefix = '\\\\?\\unc\\';
      const extendedPrefix = '\\\\?\\';
      if (lower.startsWith(uncPrefix)) {
        return '\\\\${normalizedSeparators.substring(uncPrefix.length)}';
      }
      if (lower.startsWith(extendedPrefix)) {
        return normalizedSeparators.substring(extendedPrefix.length);
      }
      return normalizedSeparators;
    }

    final windowsLeft = stripExtendedPrefix(left);
    final windowsRight = stripExtendedPrefix(right);
    if (windows.isAbsolute(windowsLeft) || windows.isAbsolute(windowsRight)) {
      return windows.isAbsolute(windowsLeft) &&
          windows.isAbsolute(windowsRight) &&
          windows.normalize(windowsLeft).toLowerCase() ==
              windows.normalize(windowsRight).toLowerCase();
    }
    return p.equals(
      p.normalize(p.absolute(left)),
      p.normalize(p.absolute(right)),
    );
  }
}

/// Independently reads the exported raster header. JPEG XL is intentionally
/// unsupported here: without decoding its codestream or a recorded digest,
/// pyramid dimensions alone cannot establish output/layout identity.
Future<(int, int)?> readExportDimensions(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final raf = await file.open();
  try {
    final ext = path.toLowerCase();
    if (ext.endsWith('.png')) {
      final bytes = await raf.read(24);
      if (bytes.length < 24 ||
          bytes[0] != 137 ||
          bytes[1] != 80 ||
          bytes[2] != 78 ||
          bytes[3] != 71 ||
          bytes[12] != 73 ||
          bytes[13] != 72 ||
          bytes[14] != 68 ||
          bytes[15] != 82) {
        return null;
      }
      final data = ByteData.sublistView(bytes);
      final w = data.getUint32(16, Endian.big),
          h = data.getUint32(20, Endian.big);
      return w > 0 && h > 0 ? (w, h) : null;
    }
    if (!ext.endsWith('.tif') && !ext.endsWith('.tiff')) return null;
    final header = await raf.read(16);
    if (header.length < 8) return null;
    final little = header[0] == 0x49 && header[1] == 0x49;
    if (!little && !(header[0] == 0x4d && header[1] == 0x4d)) return null;
    final endian = little ? Endian.little : Endian.big;
    final head = ByteData.sublistView(header);
    final magic = head.getUint16(2, endian);
    final big = magic == 43;
    if (magic != 42 && !big) return null;
    if (big &&
        (header.length < 16 ||
            head.getUint16(4, endian) != 8 ||
            head.getUint16(6, endian) != 0)) {
      return null;
    }
    var ifdOffset = big ? head.getUint64(8, endian) : head.getUint32(4, endian);
    for (var page = 0; page < 128; page++) {
      if (ifdOffset > 0x7fffffffffffffff) return null;
      await raf.setPosition(ifdOffset);
      final countBytes = await raf.read(big ? 8 : 2);
      if (countBytes.length != (big ? 8 : 2)) return null;
      final countData = ByteData.sublistView(countBytes);
      final count = big
          ? countData.getUint64(0, endian)
          : countData.getUint16(0, endian);
      if (count > 4096) return null;
      int? width;
      int? height;
      final entrySize = big ? 20 : 12;
      for (var i = 0; i < count; i++) {
        final entry = await raf.read(entrySize);
        if (entry.length != entrySize) return null;
        final e = ByteData.sublistView(entry);
        final tag = e.getUint16(0, endian);
        if (tag != 256 && tag != 257) continue;
        final type = e.getUint16(2, endian);
        final valueCount = big
            ? e.getUint64(4, endian)
            : e.getUint32(4, endian);
        if (valueCount < 1 || valueCount > 1) continue;
        final valueSize = switch (type) {
          3 => 2,
          4 => 4,
          16 => 8,
          _ => 0,
        };
        if (valueSize == 0 || (big && valueSize > 8)) continue;
        final fieldOffset = big ? 12 : 8;
        final inlineSize = big ? 8 : 4;
        int value;
        if (valueSize <= inlineSize) {
          value = switch (type) {
            3 => e.getUint16(fieldOffset, endian),
            4 => e.getUint32(fieldOffset, endian),
            16 => e.getUint64(fieldOffset, endian),
            _ => 0,
          };
        } else {
          final offset = big
              ? e.getUint64(fieldOffset, endian)
              : e.getUint32(fieldOffset, endian);
          if (offset > 0x7fffffffffffffff) return null;
          final saved = await raf.position();
          await raf.setPosition(offset);
          final val = await raf.read(valueSize);
          await raf.setPosition(saved);
          if (val.length != valueSize) return null;
          final d = ByteData.sublistView(val);
          value = type == 3
              ? d.getUint16(0, endian)
              : type == 4
              ? d.getUint32(0, endian)
              : d.getUint64(0, endian);
        }
        if (tag == 256) {
          width = value;
        } else {
          height = value;
        }
      }
      if (width != null && height != null) return (width, height);
      final nextOffsetPos = ifdOffset + (big ? 8 : 2) + count * entrySize;
      await raf.setPosition(nextOffsetPos);
      final next = await raf.read(big ? 8 : 4);
      if (next.length != (big ? 8 : 4)) return null;
      final nd = ByteData.sublistView(next);
      ifdOffset = big ? nd.getUint64(0, endian) : nd.getUint32(0, endian);
      if (ifdOffset == 0) return null;
    }
    return null;
  } on Object {
    return null;
  } finally {
    await raf.close();
  }
}

class OutputPixelTrace {
  const OutputPixelTrace({
    required this.outputX,
    required this.outputY,
    required this.yawRad,
    required this.pitchRad,
    required this.cameras,
    required this.rendererChoice,
    required this.exposureAndColorGains,
  });
  final double outputX, outputY, yawRad, pitchRad;
  final List<OutputCameraCoverage> cameras;

  /// Always null: layout geometry does not expose final blend ownership.
  final Object? rendererChoice;

  /// Always null: exposure/color gain compensation is not applied.
  final Object? exposureAndColorGains;
}

class OutputCameraCoverage {
  const OutputCameraCoverage({
    required this.row,
    required this.column,
    required this.originalName,
    required this.sourcePath,
    required this.sourceX,
    required this.sourceY,
    required this.positionSource,
    required this.placementKind,
    required this.placementOrigin,
    required this.directVisualEvidence,
    required this.neighborEdges,
  });
  final int row, column;
  final String originalName,
      sourcePath,
      positionSource,
      placementKind,
      placementOrigin;
  final double sourceX, sourceY;
  final bool directVisualEvidence;
  final List<OutputNeighborEdge> neighborEdges;
}

class OutputNeighborEdge {
  const OutputNeighborEdge({
    required this.row,
    required this.column,
    required this.disposition,
    required this.medianResidualPx,
    required this.rmsResidualPx,
  });
  final int row, column;
  final String disposition;
  final double? medianResidualPx, rmsResidualPx;
}

class _LayoutTile {
  const _LayoutTile({
    required this.index,
    required this.layoutIndex,
    required this.row,
    required this.column,
    required this.values,
    required this.width,
    required this.height,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.warp,
    required this.raw,
  });
  final int index, layoutIndex, row, column, width, height;
  final double fx, fy, cx, cy;
  final List<double> values;
  final Object? warp;
  final Map<String, Object?> raw;
}
