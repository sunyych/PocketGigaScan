import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/stitch_task.dart';
import '../models/grid_options.dart';
import 'task_repository.dart';

/// Read-only snapshot of the task's single authoritative task.json envelope.
class TaskRecordSnapshot {
  const TaskRecordSnapshot({
    required this.task,
    required this.record,
    required this.schemaVersion,
  });

  final StitchTask task;
  final Map<String, Object?> record;
  final int schemaVersion;
}

/// Versioned diagnostic record stored alongside the normal task fields in task.json.
class TaskRecordService {
  TaskRecordService(
    this.repository, {
    int? maxDiagnosticBytes,
    int? parsedCacheBudgetBytes,
  }) : _maxDiagnosticBytes =
           maxDiagnosticBytes ??
           (Platform.isAndroid || Platform.isIOS ? 32 : 128) * 1024 * 1024,
       _parsedCacheBudgetBytes =
           parsedCacheBudgetBytes ??
           (Platform.isAndroid || Platform.isIOS ? 32 : 64) * 1024 * 1024;

  final TaskRepository repository;
  final int _maxDiagnosticBytes;
  final int _parsedCacheBudgetBytes;
  int _parsedCacheBytes = 0;
  final Map<String, ({int size, int modified, TaskRecordSnapshot snapshot})>
  _cache = {};
  final Map<String, ({int size, int modified, Map<String, Object?> value})>
  _artifactCache = {};
  final Map<
    String,
    ({int size, int modified, int bytes, Map<String, Object?>? value})
  >
  _parsedArtifactCache = {};
  final Map<String, ({int size, int modified, String digest})>
  _exportHashCache = {};

  /// Builds a refreshed record without writing. TaskRepository calls this inside
  /// its serialized atomic save so completed native geometry is not viewer-dependent.
  Future<Map<String, Object?>> buildRecordForTask(
    StitchTask task,
    Map<String, Object?> prior,
  ) async {
    final current = updateRequestedTaskFields(task, prior);
    final snapshot = TaskRecordSnapshot(
      task: task,
      record: current,
      schemaVersion: 2,
    );
    return (await _withCurrentDiagnosticRefs(snapshot)).record;
  }

  Future<TaskRecordSnapshot?> loadRecord(String id) async {
    if (await repository.isRemoved(id)) return null;
    final directory = await repository.directoryFor(id);
    final file = File(p.join(directory.path, 'task.json'));
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final cached = _cache[id];
    TaskRecordSnapshot snapshot;
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified.microsecondsSinceEpoch) {
      snapshot = cached.snapshot;
      _cache.remove(id);
      _cache[id] = cached;
    } else {
      Object? decoded;
      try {
        decoded = jsonDecode(await file.readAsString());
      } on Object {
        return null;
      }
      if (decoded is! Map ||
          decoded['id'] != id ||
          (decoded['schemaVersion'] != 1 && decoded['schemaVersion'] != 2)) {
        return null;
      }
      final envelope = decoded.cast<String, Object?>();
      late final StitchTask task;
      try {
        task = StitchTask.fromJson(envelope);
      } on Object {
        return null;
      }
      final record =
          envelope['schemaVersion'] == 2 &&
              envelope['record'] is Map &&
              (envelope['record'] as Map)['schemaVersion'] == 1
          ? (envelope['record'] as Map).cast<String, Object?>()
          : initialRecord(task);
      snapshot = TaskRecordSnapshot(
        task: task,
        record: record,
        schemaVersion: envelope['schemaVersion'] is int
            ? envelope['schemaVersion']! as int
            : 1,
      );
      _cache.remove(id);
      _cache[id] = (
        size: stat.size,
        modified: stat.modified.microsecondsSinceEpoch,
        snapshot: snapshot,
      );
      if (_cache.length > 4) _cache.remove(_cache.keys.first);
    }
    if (snapshot.record['identity'] != identityForTask(snapshot.task)) {
      snapshot = TaskRecordSnapshot(
        task: snapshot.task,
        record: initialRecord(snapshot.task),
        schemaVersion: 2,
      );
      _cache.remove(id);
    }
    final refreshed = await _withCurrentDiagnosticRefs(snapshot);
    if (snapshot.schemaVersion != 2 ||
        jsonEncode(refreshed.record) != jsonEncode(snapshot.record)) {
      await repository.writeRecord(id, refreshed.record);
      _cache.remove(id);
    }
    return TaskRecordSnapshot(
      task: refreshed.task,
      record: refreshed.record,
      schemaVersion: 2,
    );
  }

  Future<TaskRecordSnapshot> refreshRecord(String id) async {
    final snapshot = await loadRecord(id);
    if (snapshot == null) throw StateError('Task record not found: $id');
    final refreshed = await _withCurrentDiagnosticRefs(snapshot);
    await repository.writeRecord(id, refreshed.record);
    _cache.remove(id);
    return refreshed;
  }

  Future<TaskRecordSnapshot> _withCurrentDiagnosticRefs(
    TaskRecordSnapshot snapshot,
  ) async {
    final diagnostics = <String, Object?>{
      ...(snapshot.record['diagnostics'] is Map
          ? (snapshot.record['diagnostics'] as Map).cast<String, Object?>()
          : const <String, Object?>{}),
    };
    Map<String, Object?>? layout;
    Map<String, Object?>? manifest;
    Map<String, Object?>? jobState;
    for (final name in ['layout', 'manifest']) {
      final path = p.join(snapshot.task.outputDirectory, '$name.json');
      diagnostics['${name}Ref'] = await _artifactRef(
        path,
        snapshot.task.outputDirectory,
      );
      if (name == 'layout') layout = await _readArtifact(path);
      if (name == 'manifest') manifest = await _readArtifact(path);
    }
    final statePath = p.join(snapshot.task.outputDirectory, 'job-state.json');
    diagnostics['jobStateRef'] = await _artifactRef(
      statePath,
      snapshot.task.outputDirectory,
    );
    final rawJobState = await _readArtifact(statePath);
    jobState = rawJobState == null ? null : _normalizeJobState(rawJobState);
    final failurePath = p.join(
      snapshot.task.outputDirectory,
      'registration-failure.json',
    );
    // Keep potentially large feature-correspondence diagnostics opaque. The native
    // job state links the exact path and carries the matching failure summary.
    final failureRef = await _registrationFailureRef(
      snapshot.task,
      jobState,
      failurePath,
    );
    diagnostics['registrationFailureRef'] = failureRef;
    final record = _reconcileNative(
      snapshot.task,
      snapshot.record,
      layout,
      diagnostics['layoutRef'],
      manifest,
      jobState,
    );
    record['diagnostics'] = diagnostics;
    record['nativeFailure'] = _nativeFailureRecord(
      snapshot.task,
      jobState,
      failureRef,
    );
    await _reconcileExport(snapshot.task, record, manifest, jobState);
    return TaskRecordSnapshot(
      task: snapshot.task,
      record: record,
      schemaVersion: snapshot.schemaVersion,
    );
  }

  Future<Map<String, Object?>> _registrationFailureRef(
    StitchTask task,
    Map<String, Object?>? jobState,
    String path,
  ) async {
    if (!_isVerifiedRegistrationFailure(task, jobState)) {
      return {
        'path': path,
        'relativePath': null,
        'ownedByTask': false,
        'integrityStatus': 'unassociated',
      };
    }
    return _artifactRef(path, task.outputDirectory, allowLarge: true);
  }

  Map<String, Object?>? _nativeFailureRecord(
    StitchTask task,
    Map<String, Object?>? jobState,
    Map<String, Object?> reference,
  ) {
    if (!_isVerifiedRegistrationFailure(task, jobState) ||
        reference['integrityStatus'] != 'verified' ||
        reference['ownedByTask'] != true) {
      return null;
    }
    final error = (jobState!['error'] as Map).cast<String, Object?>();
    return {
      'code': error['code'],
      'message': error['message'],
      'state': jobState['state'],
      'stage': jobState['stage'],
      'diagnosticsPath': error['diagnosticsPath'],
      'relativePath': reference['relativePath'],
      'requestHash': jobState['requestHash'],
      'sourceIdentity': 'verifiedAgainstTaskPhotoHashes',
      'evidenceSha256': reference['sha256'],
      'sizeBytes': reference['sizeBytes'],
      'modifiedAtMicros': reference['modifiedAtMicros'],
    };
  }

  bool _isVerifiedRegistrationFailure(
    StitchTask task,
    Map<String, Object?>? jobState,
  ) {
    if (jobState == null ||
        jobState['state'] != 'failed' ||
        jobState['operation'] != 'render' ||
        jobState['stage'] != 'registration-failed' ||
        jobState['requestHash'] is! String ||
        (jobState['requestHash'] as String).isEmpty) {
      return false;
    }
    final error = jobState['error'];
    if (error is! Map ||
        error['diagnosticsPath'] != 'registration-failure.json' ||
        error['code'] is! String ||
        error['message'] is! String) {
      return false;
    }
    final sourceHashes = jobState['sourceHashes'];
    if (sourceHashes is! Map || sourceHashes.length != task.photos.length) {
      return false;
    }
    for (final photo in task.photos) {
      Object? value;
      for (final entry in sourceHashes.entries) {
        if (entry.key is String &&
            _sameSourcePath(entry.key as String, photo.storedPath)) {
          value = entry.value;
          break;
        }
      }
      if (!_isFilesystemPath(photo.storedPath) ||
          value is! String ||
          value.toLowerCase() != photo.sha256.toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  Future<Map<String, Object?>?> _readArtifact(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    if (stat.size > _maxDiagnosticBytes) return null;
    final cached = _parsedArtifactCache[path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified.microsecondsSinceEpoch) {
      _parsedArtifactCache.remove(path);
      _parsedArtifactCache[path] = cached;
      return cached.value;
    }
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return null;
      final parsed = value.cast<String, Object?>();
      _cacheParsedArtifact(path, stat, parsed);
      return parsed;
    } on Object {
      _cacheParsedArtifact(path, stat, null);
      return null;
    }
  }

  void _cacheParsedArtifact(
    String path,
    FileStat stat,
    Map<String, Object?>? value,
  ) {
    final previous = _parsedArtifactCache.remove(path);
    if (previous != null) _parsedCacheBytes -= previous.bytes;
    if (stat.size > _parsedCacheBudgetBytes) return;
    _parsedArtifactCache[path] = (
      size: stat.size,
      modified: stat.modified.microsecondsSinceEpoch,
      bytes: stat.size,
      value: value,
    );
    _parsedCacheBytes += stat.size;
    while (_parsedCacheBytes > _parsedCacheBudgetBytes &&
        _parsedArtifactCache.isNotEmpty) {
      final oldest = _parsedArtifactCache.keys.first;
      _parsedCacheBytes -= _parsedArtifactCache.remove(oldest)!.bytes;
    }
  }

  Future<void> _reconcileExport(
    StitchTask task,
    Map<String, Object?> record,
    Map<String, Object?>? manifest,
    Map<String, Object?>? jobState,
  ) async {
    final outputs = (record['outputs'] as Map).cast<String, Object?>();
    outputs['exportSha256'] = null;
    outputs['exportDigestStatus'] = 'notComputed';
    outputs.remove('producerReceipt');
    final expectedPath = task.exportPath;
    final fingerprint = task.exportFingerprint;
    if (manifest == null ||
        jobState == null ||
        expectedPath == null ||
        _exportFormatForPath(expectedPath) != 'jxl' ||
        fingerprint == null ||
        jobState['state'] != 'completed' ||
        jobState['operation'] != 'export' ||
        jobState['exportDestination'] is! String ||
        !_sameSourcePath(
          jobState['exportDestination'] as String,
          expectedPath,
        ) ||
        jobState['exportFormat'] != _exportFormatForPath(expectedPath)) {
      return;
    }
    final expectedWidth = manifest['width'];
    final expectedHeight = manifest['height'];
    final jobDimensions = jobState['dimensions'];
    final actualWidth =
        jobState['width'] ??
        (jobDimensions is List && jobDimensions.length == 2
            ? jobDimensions[0]
            : null);
    final actualHeight =
        jobState['height'] ??
        (jobDimensions is List && jobDimensions.length == 2
            ? jobDimensions[1]
            : null);
    final stateHashes = jobState['sourceHashes'];
    final requestHash = manifest['requestHash'];
    if (expectedWidth is! int ||
        expectedHeight is! int ||
        actualWidth != expectedWidth ||
        actualHeight != expectedHeight ||
        outputs['sourceManifestAssociation'] != 'verified' ||
        requestHash is! String ||
        jobState['requestHash'] != requestHash ||
        !_sourceHashMapsEquivalent(stateHashes, manifest['sourceHashes'])) {
      return;
    }
    final file = File(expectedPath);
    if (!await file.exists()) return;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size != fingerprint.sizeBytes ||
        stat.modified.microsecondsSinceEpoch != fingerprint.modifiedAtMicros) {
      return;
    }
    final stateRef = (record['diagnostics'] as Map)['jobStateRef'];
    if (stateRef is! Map || stateRef['sha256'] is! String) return;
    final cached = _exportHashCache[expectedPath];
    final digest =
        cached != null &&
            cached.size == stat.size &&
            cached.modified == stat.modified.microsecondsSinceEpoch
        ? cached.digest
        : await _hashFile(file);
    if (digest == null) return;
    final afterHash = await file.stat();
    if (afterHash.size != stat.size ||
        afterHash.modified.microsecondsSinceEpoch !=
            stat.modified.microsecondsSinceEpoch) {
      return;
    }
    _exportHashCache[expectedPath] = (
      size: stat.size,
      modified: stat.modified.microsecondsSinceEpoch,
      digest: digest,
    );
    if (_exportHashCache.length > 16) {
      _exportHashCache.remove(_exportHashCache.keys.first);
    }
    outputs['exportSha256'] = digest;
    outputs['exportDigestStatus'] = 'verifiedProducerReceipt';
    outputs['producerReceipt'] = {
      'status': 'verified',
      'jobStateSha256': stateRef['sha256'],
      'layoutSha256': outputs['layoutSha256'],
      'requestHash': requestHash,
      'sourceManifestMatch': true,
      'destination': expectedPath,
      'format': jobState['exportFormat'],
      'dimensions': {'width': expectedWidth, 'height': expectedHeight},
      'exportSha256': digest,
      'exportFingerprint': {
        'sizeBytes': stat.size,
        'modifiedAtMicros': stat.modified.microsecondsSinceEpoch,
      },
    };
  }

  Map<String, Object?> _reconcileNative(
    StitchTask task,
    Map<String, Object?> prior,
    Map<String, Object?>? layout,
    Object? layoutRef,
    Map<String, Object?>? manifest,
    Map<String, Object?>? jobState,
  ) {
    final record = <String, Object?>{...prior};
    final output = <String, Object?>{
      ...(prior['outputs'] is Map
          ? (prior['outputs'] as Map).cast<String, Object?>()
          : const <String, Object?>{}),
    };
    final sourceHashes = manifest?['sourceHashes'];
    var sourceMatch =
        sourceHashes is Map && sourceHashes.length == task.photos.length;
    if (sourceMatch) {
      for (final photo in task.photos) {
        Object? value;
        for (final entry in sourceHashes.entries) {
          if (entry.key is String &&
              _sameSourcePath(entry.key as String, photo.storedPath)) {
            value = entry.value;
            break;
          }
        }
        if (!_isFilesystemPath(photo.storedPath) ||
            value is! String ||
            value.toLowerCase() != photo.sha256.toLowerCase()) {
          sourceMatch = false;
          break;
        }
      }
    }
    final requestHashesMatch =
        manifest?['requestHash'] is String &&
        jobState?['requestHash'] == manifest?['requestHash'] &&
        jobState?['sourceHashes'] != null &&
        _sourceHashMapsEquivalent(jobState?['sourceHashes'], sourceHashes);
    final layoutRefMap = layoutRef is Map
        ? layoutRef.cast<String, Object?>()
        : null;
    final stateLayoutHash = jobState?['layoutHash'];
    final layoutHashKnown =
        stateLayoutHash is String && stateLayoutHash.isNotEmpty;
    final layoutHashMatches =
        stateLayoutHash is String &&
        stateLayoutHash.isNotEmpty &&
        layoutRefMap != null &&
        layoutRefMap['ownedByTask'] == true &&
        layoutRefMap['integrityStatus'] == 'verified' &&
        layoutRefMap['sha256'] is String &&
        (layoutRefMap['sha256'] as String).toLowerCase() ==
            stateLayoutHash.toLowerCase();
    final associationVerified =
        sourceMatch && requestHashesMatch && layoutHashMatches;
    final layoutAssociation =
        !layoutHashKnown || layoutRefMap?['sha256'] == null
        ? 'unknown'
        : layoutHashMatches
        ? 'verified'
        : 'mismatch';
    output['layoutStateAssociation'] = layoutAssociation;
    output['layoutSha256'] = layoutHashMatches ? stateLayoutHash : null;
    output['sourceManifestAssociation'] = manifest == null || jobState == null
        ? 'unknown'
        : !layoutHashKnown || layoutRefMap?['sha256'] == null
        ? 'unknown'
        : associationVerified
        ? 'verified'
        : 'mismatch';
    output['dimensions'] =
        manifest?['width'] is int && manifest?['height'] is int
        ? {'width': manifest!['width'], 'height': manifest['height']}
        : null;
    record['outputs'] = output;

    if (layout == null || !associationVerified || layout['tiles'] is! List) {
      final fresh = initialRecord(task);
      fresh['outputs'] = output;
      return fresh;
    }
    final cells = <String, (int, Map<String, Object?>)>{};
    final tileArray = layout['tiles'] as List;
    for (var tileIndex = 0; tileIndex < tileArray.length; tileIndex++) {
      final item = tileArray[tileIndex];
      if (item is Map && item['row'] is int && item['column'] is int) {
        cells['${item['row']}:${item['column']}'] = (
          tileIndex,
          item.cast<String, Object?>(),
        );
      }
    }
    final edges =
        (layout['report'] is Map &&
            (layout['report'] as Map)['edgeDiagnostics'] is List)
        ? ((layout['report'] as Map)['edgeDiagnostics'] as List)
        : const <Object?>[];
    final mapping = task.grid.mode == GridMode.filename
        ? GridMapping.fromFilenames(task.photos)
        : GridMapping.sequence(task.photos, task.grid);
    if (!mapping.isValid || mapping.cells.length != task.photos.length) {
      final fresh = initialRecord(task);
      fresh['outputs'] = output;
      return fresh;
    }
    final photos = <Map<String, Object?>>[];
    final initialPhotos = (initialRecord(task)['photos'] as List)
        .cast<Map<String, Object?>>();
    final priorByPath = <String, Map<String, Object?>>{};
    if (prior['photos'] is List) {
      for (final item in prior['photos'] as List) {
        if (item is Map && item['storedPath'] is String) {
          priorByPath[item['storedPath'] as String] = item
              .cast<String, Object?>();
        }
      }
    }
    final incidentByTile = <int, List<Object?>>{};
    for (final edge in edges) {
      if (edge is! Map) continue;
      for (final key in ['from', 'to']) {
        final index = edge[key];
        if (index is int && index >= 0 && index < tileArray.length) {
          (incidentByTile[index] ??= <Object?>[]).add(
            edge.cast<String, Object?>(),
          );
        }
      }
    }
    for (var i = 0; i < task.photos.length; i++) {
      final cell = mapping.cells[i];
      final nativeEntry = cells['${cell.row}:${cell.column}'];
      final native = nativeEntry?.$2;
      final base = priorByPath[task.photos[i].storedPath];
      final tileIndex = nativeEntry?.$1 ?? -1;
      if (native != null &&
          (native['path'] is! String ||
              !_sameSourcePath(
                native['path'] as String,
                task.photos[i].storedPath,
              ))) {
        final fresh = initialRecord(task);
        fresh['outputs'] = output;
        return fresh;
      }
      if (native != null && tileIndex < 0) {
        final fresh = initialRecord(task);
        fresh['outputs'] = output;
        return fresh;
      }
      final incident = incidentByTile[tileIndex] ?? const <Object?>[];
      photos.add({
        ...(base ?? initialPhotos[i]),
        if (native != null) ...{
          'row': cell.row,
          'column': cell.column,
          'placement': native['placementConstraint'] ?? base?['placement'],
          'positionSource': native['positionSource'],
          'hardLock': native['placementConstraint'] is Map
              ? (native['placementConstraint'] as Map)['kind'] ==
                        'hardGridLock' ||
                    native['forceGrid'] == true
              : native['forceGrid'] == true,
          'directVisualEvidence': native['directVisualEvidence'] == true,
          'visualConnectedToReference':
              native['visualConnectedToReference'] == true,
          'gridBridgeRequired': native['gridBridgeRequired'] == true,
          'visualComponentId': native['visualComponentId'],
          'cameraToWorld': native['cameraToWorld'],
          'intrinsics': {
            'fx': native['fx'],
            'fy': native['fy'],
            'cx': native['cx'],
            'cy': native['cy'],
            'width': native['width'],
            'height': native['height'],
          },
          'sourcePlaneWarp': native['sourcePlaneWarp'],
          'geometryStatus': 'reconciled',
          'incidentEdges': incident,
        },
      });
    }
    record['photos'] = photos;
    final report = layout['report'] is Map
        ? (layout['report'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    record['algorithm'] = <String, Object?>{
      ...(prior['algorithm'] is Map
          ? (prior['algorithm'] as Map).cast<String, Object?>()
          : const <String, Object?>{}),
      'adoptedParameters': {
        'layoutSchemaVersion': layout['schemaVersion'],
        'backend': manifest?['backend'],
        'renderBlendMode': layout['renderBlendMode'],
        'memoryBudgetMiB': manifest?['memoryBudgetMiB'],
        'workersEffective': manifest?['workersEffective'],
        'renderWorkers': manifest?['renderWorkers'],
        'pyramidWorkersEffective': manifest?['pyramidWorkersEffective'],
      },
      'version': _manifestRendererVersion(manifest),
      'correspondenceQuality': report['qualityStatus'],
      'worstEdge': report['worstMeasuredEdges'],
      'reprojectionRms': report['globalRayReprojectionRmsPx'],
      'maximumEdgeReprojectionRms': report['maximumEdgeReprojectionRmsPx'],
      'provenance':
          'native layout and manifest; source and request hashes matched job state',
    };
    return record;
  }

  /// Revalidates the current on-disk artifact against the record's saved stat/hash.
  /// Returns false for missing, changed, or unowned paths; it never trusts path text alone.
  Future<bool> verifyArtifactRef(
    TaskRecordSnapshot snapshot, {
    required String kind,
  }) async {
    if (kind != 'layout' && kind != 'manifest' && kind != 'job-state') {
      return false;
    }
    final diagnostics = snapshot.record['diagnostics'];
    if (diagnostics is! Map) return false;
    final ref = diagnostics['${kind}Ref'];
    if (ref is! Map ||
        ref['integrityStatus'] != 'verified' ||
        ref['ownedByTask'] != true) {
      return false;
    }
    final relative = ref['relativePath'];
    if (relative is! String ||
        p.isAbsolute(relative) ||
        relative.startsWith('..')) {
      return false;
    }
    final path = p.normalize(p.join(snapshot.task.outputDirectory, relative));
    final expectedName = kind == 'job-state' ? 'job-state.json' : '$kind.json';
    if (p.normalize(path) !=
        p.normalize(p.join(snapshot.task.outputDirectory, expectedName))) {
      return false;
    }
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      final canonicalRoot = await Directory(
        snapshot.task.outputDirectory,
      ).resolveSymbolicLinks();
      final canonicalFile = await file.resolveSymbolicLinks();
      final canonicalRelative = p.relative(canonicalFile, from: canonicalRoot);
      if (canonicalRelative.startsWith('..') ||
          p.normalize(canonicalRelative) != expectedName) {
        return false;
      }
    } on Object {
      return false;
    }
    final stat = await file.stat();
    if (stat.size != ref['sizeBytes'] ||
        stat.modified.microsecondsSinceEpoch != ref['modifiedAtMicros']) {
      return false;
    }
    try {
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString() == ref['sha256'];
    } on Object {
      return false;
    }
  }

  Future<Map<String, Object?>> _artifactRef(
    String path,
    String ownerRoot, {
    bool allowLarge = false,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return {
        'path': path,
        'relativePath': null,
        'ownedByTask': false,
        'integrityStatus': 'missing',
      };
    }
    final stat = await file.stat();
    final modified = stat.modified.microsecondsSinceEpoch;
    if (!allowLarge && stat.size > _maxDiagnosticBytes) {
      return {
        'path': path,
        'relativePath': null,
        'ownedByTask': false,
        'sizeBytes': stat.size,
        'modifiedAtMicros': modified,
        'integrityStatus': 'tooLarge',
      };
    }
    var relative = '..';
    String canonicalFile;
    try {
      final canonicalRoot = await Directory(ownerRoot).resolveSymbolicLinks();
      canonicalFile = await file.resolveSymbolicLinks();
      relative = p.relative(canonicalFile, from: canonicalRoot);
    } on Object {
      return {
        'path': path,
        'relativePath': null,
        'ownedByTask': false,
        'integrityStatus': 'unresolved',
      };
    }
    if (relative.startsWith('..')) {
      return {
        'path': path,
        'relativePath': null,
        'ownedByTask': false,
        'sizeBytes': stat.size,
        'modifiedAtMicros': modified,
        'integrityStatus': 'unowned',
      };
    }
    final cacheKey = '$path\n$canonicalFile';
    final cached = _artifactCache[cacheKey];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == modified) {
      _artifactCache.remove(cacheKey);
      _artifactCache[cacheKey] = cached;
      return cached.value;
    }
    final digest = await _hashFile(file);
    if (digest == null) {
      return {
        'path': path,
        'relativePath': null,
        'ownedByTask': false,
        'integrityStatus': 'unreadable',
      };
    }
    final afterHash = await file.stat();
    if (afterHash.size != stat.size ||
        afterHash.modified.microsecondsSinceEpoch != modified) {
      return {
        'path': path,
        'relativePath': null,
        'ownedByTask': false,
        'integrityStatus': 'changedDuringRead',
      };
    }
    final value = <String, Object?>{
      'path': path,
      'relativePath': relative,
      'ownedByTask': true,
      'sizeBytes': stat.size,
      'modifiedAtMicros': modified,
      'sha256': digest,
      'integrityStatus': 'verified',
    };
    _artifactCache[cacheKey] = (
      size: stat.size,
      modified: modified,
      value: value,
    );
    if (_artifactCache.length > 128) {
      _artifactCache.remove(_artifactCache.keys.first);
    }
    return value;
  }

  Future<String?> _hashFile(File file) async {
    try {
      return (await sha256.bind(file.openRead()).first).toString();
    } on Object {
      return null;
    }
  }

  static Map<String, Object?> initialRecord(StitchTask task) {
    final mapping = task.grid.mode == GridMode.filename
        ? GridMapping.fromFilenames(task.photos)
        : GridMapping.sequence(task.photos, task.grid);
    return {
      'schemaVersion': 1,
      'identity': identityForTask(task),
      'photos': List.generate(task.photos.length, (index) {
        final photo = task.photos[index];
        final cell = mapping.isValid ? mapping.cells[index] : null;
        final placement = cell == null
            ? null
            : task.grid.placementFor(photo, cell).toJson();
        return <String, Object?>{
          'originalName': photo.originalName,
          'storedPath': photo.storedPath,
          'sha256': photo.sha256,
          'sourceWidth': photo.width,
          'sourceHeight': photo.height,
          'row': cell?.row,
          'column': cell?.column,
          'placement': placement,
          'positionSource': 'uncomputed',
          'hardLock': placement?['kind'] == 'hardGridLock',
          'directVisualEvidence': false,
          'visualConnectedToReference': false,
          'gridBridgeRequired': false,
          'visualComponentId': null,
          'cameraToWorld': null,
          'intrinsics': null,
          'sourcePlaneWarp': null,
          'geometryStatus': 'uncomputed',
          'incidentEdges': <Object?>[],
          'exposureAdjustment': {'status': 'notApplied', 'value': null},
          'brightnessAdjustment': {'status': 'notApplied', 'value': null},
          'colorAdjustment': {'status': 'notApplied', 'gains': null},
        };
      }),
      'algorithm': {
        'version': null,
        'parameters': {
          'horizontalFovDegrees': task.horizontalFovDegrees,
          'memoryBudgetMiB': task.memoryBudgetMiB,
          'workers': task.workers,
          'performanceOptions': task.performanceOptions.toJson(),
          'autoGridOverlap': task.autoGridOverlap,
          'gridHorizontalOverlap': task.gridHorizontalOverlap,
          'gridVerticalOverlap': task.gridVerticalOverlap,
          'refineGridNeighbors': task.refineGridNeighbors,
          'seamBlendMode': task.seamBlendMode.name,
          'localTextureWarp': task.localTextureWarp,
        },
        'correspondenceQuality': null,
        'worstEdge': null,
        'reprojectionRms': null,
        'provenance': 'task options; native geometry not yet reconciled',
      },
      'outputs': {
        'renderDirectory': task.outputDirectory,
        'exportPath': task.exportPath,
        'exportDirectory': task.exportDirectory,
        'publishedExportPath': task.publishedExportPath,
        'exportFingerprint': task.exportFingerprint?.toJson(),
        'dimensions': null,
        'exportSha256': null,
        'exportDigestStatus': 'notComputed',
        'sourceManifestAssociation': 'unknown',
        'layoutStateAssociation': 'unknown',
        'layoutSha256': null,
        'timeline': task.timeline.toJson(),
        'colorAdjustment': {'status': 'notApplied', 'gains': null},
      },
      'diagnostics': {
        'layoutRef': null,
        'manifestRef': null,
        'jobStateRef': null,
        'registrationFailureRef': null,
      },
      'nativeFailure': null,
    };
  }

  static Map<String, Object?> updateRequestedTaskFields(
    StitchTask task,
    Map<String, Object?> prior,
  ) {
    final fresh = initialRecord(task);
    final merged = <String, Object?>{...fresh, ...prior};
    final freshAlgorithm = fresh['algorithm'] as Map<String, Object?>;
    final oldAlgorithm = prior['algorithm'] is Map
        ? (prior['algorithm'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    merged['algorithm'] = <String, Object?>{
      ...freshAlgorithm,
      ...oldAlgorithm,
      'parameters': freshAlgorithm['parameters'],
    };
    final freshOutputs = fresh['outputs'] as Map<String, Object?>;
    final oldOutputs = prior['outputs'] is Map
        ? (prior['outputs'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    merged['outputs'] = <String, Object?>{
      ...oldOutputs,
      ...freshOutputs,
      if (oldOutputs['exportPath'] == freshOutputs['exportPath'] &&
          jsonEncode(oldOutputs['exportFingerprint']) ==
              jsonEncode(freshOutputs['exportFingerprint']))
        for (final key in [
          'dimensions',
          'exportSha256',
          'exportDigestStatus',
          'sourceManifestAssociation',
          'layoutStateAssociation',
          'layoutSha256',
          'producerReceipt',
        ])
          if (oldOutputs.containsKey(key) && !freshOutputs.containsKey(key))
            key: oldOutputs[key],
    };
    merged['identity'] = fresh['identity'];
    return merged;
  }

  static String identityForTask(StitchTask task) => _identity({
    'id': task.id,
    'createdAt': task.createdAt.toUtc().toIso8601String(),
    'outputDirectory': task.outputDirectory,
    'photos': task.photos
        .map((photo) => [photo.storedPath, photo.sha256])
        .toList(),
    'grid': task.grid.toJson(),
    'fov': task.horizontalFovDegrees,
    'memoryBudgetMiB': task.memoryBudgetMiB,
    'workers': task.workers,
    'renderOptions': [
      task.performanceOptions.toJson(),
      task.autoGridOverlap,
      task.gridHorizontalOverlap,
      task.gridVerticalOverlap,
      task.refineGridNeighbors,
      task.seamBlendMode.name,
      task.localTextureWarp,
    ],
  });

  static String identityForJson(Map<String, Object?> json) {
    try {
      return identityForTask(StitchTask.fromJson(json));
    } on Object {
      return '';
    }
  }

  static String _identity(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static bool _isFilesystemPath(String value) =>
      !value.startsWith('content://') && !value.startsWith('file-picker://');

  static bool _sameSourcePath(String left, String right) {
    if (!_isFilesystemPath(left) || !_isFilesystemPath(right)) return false;
    if (_looksWindowsPath(left) || _looksWindowsPath(right)) {
      if (!_looksWindowsPath(left) || !_looksWindowsPath(right)) return false;
      return _normalizeWindowsPath(left) == _normalizeWindowsPath(right);
    }
    return p.normalize(p.absolute(left)) == p.normalize(p.absolute(right));
  }

  static bool _sourceHashMapsEquivalent(Object? left, Object? right) {
    if (left is! Map || right is! Map || left.length != right.length) {
      return false;
    }
    final normalizedLeft = <String, String>{};
    final normalizedRight = <String, String>{};
    for (final entry in left.entries) {
      if (entry.key is! String || entry.value is! String) return false;
      final key = _normalizedSourceKey(entry.key as String);
      if (key == null) return false;
      normalizedLeft[key] = (entry.value as String).toLowerCase();
    }
    for (final entry in right.entries) {
      if (entry.key is! String || entry.value is! String) return false;
      final key = _normalizedSourceKey(entry.key as String);
      if (key == null) return false;
      normalizedRight[key] = (entry.value as String).toLowerCase();
    }
    return normalizedLeft.length == left.length &&
        normalizedRight.length == right.length &&
        _mapsEqual(normalizedLeft, normalizedRight);
  }

  static bool _mapsEqual(Map<String, String> left, Map<String, String> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  static String? _normalizedSourceKey(String path) {
    if (!_isFilesystemPath(path)) return null;
    return _looksWindowsPath(path)
        ? _normalizeWindowsPath(path)
        : p.normalize(p.absolute(path));
  }

  static bool _looksWindowsPath(String path) =>
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) ||
      path.startsWith('\\\\') ||
      path.startsWith('\\??\\');

  static String _normalizeWindowsPath(String input) {
    var path = input.replaceAll('/', '\\');
    if (path.toLowerCase().startsWith('\\\\?\\unc\\')) {
      path = '\\\\${path.substring(8)}';
    } else if (path.startsWith('\\\\?\\')) {
      path = path.substring(4);
    } else if (path.startsWith('\\??\\')) {
      path = path.substring(4);
    }
    return p.windows.normalize(path).toLowerCase();
  }

  static Map<String, Object?> _normalizeJobState(Map<String, Object?> raw) {
    final state = <String, Object?>{...raw};
    state['requestHash'] = raw['request_hash'] ?? raw['requestHash'];
    state['sourceHashes'] = raw['source_hashes'] ?? raw['sourceHashes'];
    state['exportDestination'] =
        raw['export_destination'] ?? raw['exportDestination'];
    state['memoryBudgetMiB'] =
        raw['memory_budget_mib'] ?? raw['memoryBudgetMiB'];
    state['workersEffective'] =
        raw['workers_effective'] ?? raw['workersEffective'];
    state['layoutHash'] = raw['layout_hash'] ?? raw['layoutHash'];
    if (state['exportFormat'] == null && state['exportDestination'] is String) {
      state['exportFormat'] = _exportFormatForPath(
        state['exportDestination'] as String,
      );
    }
    return state;
  }

  static Object? _manifestRendererVersion(Map<String, Object?>? manifest) {
    final stats = manifest?['rendererStats'];
    return stats is Map ? stats['algorithmVersion'] : null;
  }

  static String? _exportFormatForPath(String path) =>
      switch (p.extension(path).replaceFirst('.', '').toLowerCase()) {
        'tif' || 'tiff' => 'tiff',
        'png' => 'png',
        'jxl' => 'jxl',
        _ => null,
      };
}
