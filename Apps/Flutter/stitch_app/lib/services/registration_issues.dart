import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/grid_options.dart';
import '../models/stitch_task.dart';

class RegistrationIssue {
  const RegistrationIssue({
    required this.fromPhotoPath,
    required this.toPhotoPath,
    required this.fromName,
    required this.toName,
    required this.rmsPx,
    required this.limitPx,
  });

  final String fromPhotoPath;
  final String toPhotoPath;
  final String fromName;
  final String toName;
  final double rmsPx;
  final double limitPx;

  bool get exceedsLimit => rmsPx > limitPx;
}

/// Loads registration failures only when their tile indexes can be safely
/// associated with the task's current grid and source photos.
Future<List<RegistrationIssue>> loadRegistrationIssues(StitchTask task) async {
  try {
    final failurePath = _failureFilePath(task);
    if (failurePath == null) return const [];
    final failureFile = File(failurePath);
    if (!await failureFile.exists()) return const [];

    final decoded = jsonDecode(await failureFile.readAsString());
    if (decoded is! Map<String, dynamic>) return const [];
    final diagnostics = decoded['diagnostics'];
    if (diagnostics is! Map<String, dynamic>) return const [];
    final rawEdges = diagnostics['worstEdges'];
    if (rawEdges is! List) return const [];

    final limitValue = diagnostics['maximumEdgeReprojectionRmsLimitPx'];
    final limit = limitValue == null
        ? task.maxEdgeReprojectionRmsPixels
        : _finiteDouble(limitValue);
    if (limit == null || limit <= 0) return const [];

    final indexToPhoto = await _resolveDiagnosticPhotos(task, diagnostics);
    if (indexToPhoto == null) return const [];

    final candidates = <_EdgeCandidate>[];
    for (final rawEdge in rawEdges) {
      if (rawEdge is! Map<String, dynamic>) continue;
      final from = _nonNegativeInt(rawEdge['from']);
      final to = _nonNegativeInt(rawEdge['to']);
      final rms = _finiteDouble(rawEdge['rmsPx']);
      if (from == null || to == null || from == to || rms == null || rms < 0) {
        continue;
      }
      final fromPhoto = indexToPhoto[from];
      final toPhoto = indexToPhoto[to];
      if (fromPhoto == null || toPhoto == null) continue;
      candidates.add(_EdgeCandidate(from, to, fromPhoto, toPhoto, rms));
    }
    candidates.sort((a, b) => b.rmsPx.compareTo(a.rmsPx));

    final seen = <String>{};
    final issues = <RegistrationIssue>[];
    for (final edge in candidates) {
      if (edge.rmsPx <= limit) continue;
      final key = edge.fromIndex < edge.toIndex
          ? '${edge.fromIndex}:${edge.toIndex}'
          : '${edge.toIndex}:${edge.fromIndex}';
      if (!seen.add(key)) continue;
      issues.add(
        RegistrationIssue(
          fromPhotoPath: edge.fromPhoto.path,
          toPhotoPath: edge.toPhoto.path,
          fromName: edge.fromPhoto.name,
          toName: edge.toPhoto.name,
          rmsPx: edge.rmsPx,
          limitPx: limit,
        ),
      );
    }
    return List.unmodifiable(issues);
  } on Object {
    // Diagnostic files are optional and must never prevent task navigation.
    return const [];
  }
}

String? _failureFilePath(StitchTask task) {
  final output = p.normalize(p.absolute(task.outputDirectory));
  final resultStats = task.resultStats;
  final configured = resultStats?['registrationFailurePath'];
  if (resultStats?.containsKey('registrationFailurePath') == true &&
      configured is! String) {
    return null;
  }
  final relative = configured as String? ?? 'registration-failure.json';
  if (relative.isEmpty || p.isAbsolute(relative)) return null;
  final normalizedRelative = p.normalize(relative);
  if (normalizedRelative == '..' ||
      normalizedRelative.startsWith('..${p.separator}') ||
      normalizedRelative.split(RegExp(r'[/\\]')).any((part) => part == '..')) {
    return null;
  }
  final target = p.normalize(p.join(output, normalizedRelative));
  if (!p.isWithin(output, target)) return null;
  return target;
}

Future<Map<int, _PhotoRef>?> _resolveDiagnosticPhotos(
  StitchTask task,
  Map<String, dynamic> diagnostics,
) async {
  final mapping = task.grid.mode == GridMode.filename
      ? GridMapping.fromFilenames(task.photos)
      : GridMapping.sequence(task.photos, task.grid);
  if (!mapping.isValid || mapping.cells.length != task.photos.length) {
    return null;
  }

  final currentByCell = <String, _PhotoRef>{};
  for (var i = 0; i < task.photos.length; i++) {
    final cell = mapping.cells[i];
    final photo = task.photos[i];
    final path = _normalizedPhotoPath(photo.storedPath, task.sourceDirectory);
    currentByCell[_cellKey(cell.row, cell.column)] = _PhotoRef(
      photo.storedPath,
      path,
      photo.originalName,
    );
  }

  final stateFile = File(p.join(task.outputDirectory, 'job-state.json'));
  if (await stateFile.exists()) {
    final stateJson = jsonDecode(await stateFile.readAsString());
    if (stateJson is! Map<String, dynamic>) return null;
    final expectedJobId = task.nativeJobId;
    final savedJobId = stateJson['job_id'];
    if (expectedJobId != null &&
        (savedJobId is! String || !_sameDirectory(expectedJobId, savedJobId))) {
      return null;
    }
    final request = stateJson['request'];
    final rawTiles = request is Map<String, dynamic> ? request['tiles'] : null;
    if (rawTiles is! List || rawTiles.length != task.photos.length) return null;

    final tiles = <_DiagnosticTile>[];
    for (final raw in rawTiles) {
      if (raw is! Map<String, dynamic>) return null;
      final row = _nonNegativeInt(raw['row']);
      final column = _nonNegativeInt(raw['column']);
      final path = raw['path'];
      if (row == null || column == null || path is! String || path.isEmpty) {
        return null;
      }
      tiles.add(
        _DiagnosticTile(
          row,
          column,
          _normalizedPhotoPath(path, task.sourceDirectory),
        ),
      );
    }
    tiles.sort(
      (a, b) => a.row != b.row
          ? a.row.compareTo(b.row)
          : a.column.compareTo(b.column),
    );
    final byIndex = <int, _PhotoRef>{};
    final seenCells = <String>{};
    for (var index = 0; index < tiles.length; index++) {
      final tile = tiles[index];
      final key = _cellKey(tile.row, tile.column);
      if (!seenCells.add(key)) return null;
      final current = currentByCell[key];
      if (current == null || !_samePath(current.comparePath, tile.path)) {
        return null;
      }
      byIndex[index] = current;
    }
    if (!_posesMatch(diagnostics['diagnosticTilePoses'], tiles)) return null;
    return byIndex;
  }

  // Without the persisted native request, even complete row/column poses
  // cannot prove which source paths occupied those positions at solve time.
  return null;
}

bool _posesMatch(Object? rawPoses, List<_DiagnosticTile> tiles) {
  if (rawPoses == null) return true;
  if (rawPoses is! List || rawPoses.length != tiles.length) return false;
  final seen = <int>{};
  for (final rawPose in rawPoses) {
    if (rawPose is! Map<String, dynamic>) return false;
    final index = _nonNegativeInt(rawPose['index']);
    final row = _nonNegativeInt(rawPose['row']);
    final column = _nonNegativeInt(rawPose['column']);
    if (index == null ||
        row == null ||
        column == null ||
        index >= tiles.length ||
        !seen.add(index)) {
      return false;
    }
    final tile = tiles[index];
    if (tile.row != row || tile.column != column) return false;
  }
  return seen.length == tiles.length;
}

String _normalizedPhotoPath(String path, String sourceDirectory) {
  final resolved = p.isAbsolute(path) ? path : p.join(sourceDirectory, path);
  return _comparisonPath(resolved);
}

bool _samePath(String a, String b) => a == b;

bool _sameDirectory(String a, String b) {
  return _comparisonPath(a) == _comparisonPath(b);
}

String _comparisonPath(String value) {
  var path = value;
  if (Platform.isWindows) {
    path = path.replaceFirst(
      RegExp(r'^\\\\\?\\UNC\\', caseSensitive: false),
      r'\\',
    );
    path = path.replaceFirst(RegExp(r'^\\\\\?\\'), '');
  }
  final normalized = p.normalize(p.absolute(path));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String _cellKey(int row, int column) => '$row:$column';

int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

double? _finiteDouble(Object? value) {
  if (value is! num) return null;
  final converted = value.toDouble();
  return converted.isFinite ? converted : null;
}

class _PhotoRef {
  const _PhotoRef(this.path, this.comparePath, this.name);

  final String path;
  final String comparePath;
  final String name;
}

class _DiagnosticTile {
  const _DiagnosticTile(this.row, this.column, this.path);

  final int row;
  final int column;
  final String path;
}

class _EdgeCandidate {
  const _EdgeCandidate(
    this.fromIndex,
    this.toIndex,
    this.fromPhoto,
    this.toPhoto,
    this.rmsPx,
  );

  final int fromIndex;
  final int toIndex;
  final _PhotoRef fromPhoto;
  final _PhotoRef toPhoto;
  final double rmsPx;
}
