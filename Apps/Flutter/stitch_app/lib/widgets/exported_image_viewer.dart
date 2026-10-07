import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;

import '../models/export_fingerprint.dart';
import '../services/mobile_storage_service.dart';
import '../services/output_source_locator.dart';
import '../services/task_record_service.dart';
import '../l10n/localized_text.dart';
import '../l10n/stitch_localizations.dart';

/// Shows the render pyramid associated with a completed exported image.
///
/// The output file is checked for existence and, for current tasks, against the
/// size and modification time recorded after export. The visible pixels come
/// from this task's lossless PNG pyramid so gigapixel outputs are never decoded
/// as one allocation. The page labels that preview source explicitly.
class ExportedImageViewer extends StatefulWidget {
  const ExportedImageViewer({
    super.key,
    required this.exportFilePath,
    required this.pyramidDirectory,
    required this.expectedExportFingerprint,
    required this.legacyTaskAssociationPresent,
    required this.legacyTaskBindingVerified,
    this.mobileStorageService,
    this.exportMimeType,
    this.traceRecord,
  });

  final String exportFilePath;
  final String pyramidDirectory;
  final ExportFileFingerprint? expectedExportFingerprint;
  final bool legacyTaskAssociationPresent;
  final bool legacyTaskBindingVerified;
  final MobileStorageService? mobileStorageService;
  final String? exportMimeType;
  final TaskRecordSnapshot? traceRecord;

  Future<void> _saveExport(BuildContext context) async {
    final service = mobileStorageService;
    if (service == null || exportMimeType == null) return;
    final saved = await service.saveExport(
      exportFilePath,
      mimeType: exportMimeType!,
      suggestedName: p.basename(exportFilePath),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '已保存整图' : '保存已取消或失败')));
    }
  }

  Future<void> _shareExport(BuildContext context) async {
    final service = mobileStorageService;
    if (service == null || exportMimeType == null) return;
    final shared = await service.shareExport(
      exportFilePath,
      mimeType: exportMimeType!,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(shared ? '已发送整图' : '分享已取消或失败')));
    }
  }

  @override
  State<ExportedImageViewer> createState() => _ExportedImageViewerState();
}

class _ExportedImageViewerState extends State<ExportedImageViewer>
    with WidgetsBindingObserver {
  static const _maxScale = 32.0;
  static const _tileSize = 512;
  static const _maxTileChecks = 128;
  static const _tileCacheMargin = 1;
  static const _maxManifestBytes = 32 * 1024 * 1024;
  static const _maxTotalTiles = 250000;

  final TransformationController _transform = TransformationController();
  final LinkedHashMap<String, Future<File?>> _tileChecks =
      LinkedHashMap<String, Future<File?>>();
  Map<String, Future<File?>> _visibleTileFutures = {};
  _Pyramid? _pyramid;
  String? _error;
  String? _staleReason;
  bool _loading = true;
  bool _showSourceInformation = false;
  bool _inspectMode = false;
  Map<String, Object?>? _traceLayout;
  String? _traceUnavailableReason;
  OutputPixelTrace? _pixelTrace;
  bool _initialTransformSet = false;
  int _sourceGeneration = 0;
  Size? _viewportSize;
  double _scale = 1;
  int? _level;
  StreamSubscription<FileSystemEvent>? _fileWatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transform.addListener(_onTransformChanged);
    unawaited(_loadSource());
    _watchExportFile();
  }

  @override
  void didUpdateWidget(covariant ExportedImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exportFilePath != widget.exportFilePath ||
        oldWidget.pyramidDirectory != widget.pyramidDirectory ||
        oldWidget.expectedExportFingerprint !=
            widget.expectedExportFingerprint ||
        oldWidget.legacyTaskAssociationPresent !=
            widget.legacyTaskAssociationPresent ||
        oldWidget.legacyTaskBindingVerified !=
            widget.legacyTaskBindingVerified ||
        oldWidget.traceRecord?.task.id != widget.traceRecord?.task.id ||
        !identical(oldWidget.traceRecord, widget.traceRecord)) {
      _showSourceInformation = false;
      unawaited(_fileWatch?.cancel());
      _pyramid = null;
      _error = null;
      _staleReason = null;
      _loading = true;
      _initialTransformSet = false;
      _tileChecks.clear();
      _transform.value = Matrix4.identity();
      unawaited(_loadSource());
      _watchExportFile();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_error != null) {
        unawaited(_loadSource());
      } else {
        unawaited(_recheckExport());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_fileWatch?.cancel());
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    for (final future in _visibleTileFutures.values) {
      _evictTileFuture(future);
    }
    super.dispose();
  }

  Future<void> _loadSource() async {
    final generation = ++_sourceGeneration;
    final exportPath = widget.exportFilePath;
    final pyramidDirectory = widget.pyramidDirectory;
    _clearVisibleTileCache();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _staleReason = null;
        _traceLayout = null;
        _traceUnavailableReason = null;
        _inspectMode = false;
        _pixelTrace = null;
      });
    }
    try {
      final valid = await _validateExport(
        generation: generation,
        exportPath: exportPath,
        pyramidDirectory: pyramidDirectory,
        fingerprint: widget.expectedExportFingerprint,
        associationPresent: widget.legacyTaskAssociationPresent,
      );
      if (!valid ||
          !_isCurrentSource(generation, exportPath, pyramidDirectory)) {
        return;
      }
      final root = await Directory(pyramidDirectory).resolveSymbolicLinks();
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      final manifestPath = p.join(root, 'manifest.json');
      final entryType = await FileSystemEntity.type(
        manifestPath,
        followLinks: false,
      );
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      if (entryType == FileSystemEntityType.notFound) {
        throw const FormatException('此任务没有可用的分块预览清单。');
      }
      final canonicalManifest = await File(manifestPath).resolveSymbolicLinks();
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      if (!_isWithin(root, canonicalManifest)) {
        throw const FormatException('预览清单路径超出任务目录，已拒绝读取。');
      }
      if (!await File(canonicalManifest).exists()) {
        throw const FormatException('此任务没有可用的分块预览清单。');
      }
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      final canonicalFile = File(canonicalManifest);
      if ((await canonicalFile.length()) > _maxManifestBytes) {
        throw const FormatException('预览清单过大，已拒绝读取。');
      }
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      final manifestText = await canonicalFile.readAsString();
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      final decoded = jsonDecode(manifestText);
      final pyramid = _Pyramid.parse(decoded);
      Map<String, Object?>? traceLayout;
      try {
        traceLayout = await _loadTraceLayout(
          decodedManifest: decoded,
          pyramid: pyramid,
          generation: generation,
          exportPath: exportPath,
        );
      } on Object {
        _traceUnavailableReason = 'traceLoadFailed';
      }
      if (!await _validateExport(
        generation: generation,
        exportPath: exportPath,
        pyramidDirectory: pyramidDirectory,
        fingerprint: widget.expectedExportFingerprint,
        associationPresent: widget.legacyTaskAssociationPresent,
      )) {
        return;
      }
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      if (!mounted) return;
      setState(() {
        _pyramid = pyramid;
        _loading = false;
        _error = null;
        _level = null;
        _traceLayout = traceLayout;
        _inspectMode = false;
        _pixelTrace = null;
      });
      _applyFitWhenLaidOut();
    } on Object catch (error) {
      if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) return;
      setState(() {
        _loading = false;
        _error = error is FormatException ? error.message : '无法安全读取任务预览：$error';
      });
    }
  }

  Future<Map<String, Object?>?> _loadTraceLayout({
    required Object? decodedManifest,
    required _Pyramid pyramid,
    required int generation,
    required String exportPath,
  }) async {
    final snapshot = widget.traceRecord;
    _traceUnavailableReason = null;
    if (snapshot == null) return null;
    final outputs = snapshot.record['outputs'];
    final diagnostics = snapshot.record['diagnostics'];
    if (outputs is! Map ||
        diagnostics is! Map ||
        outputs['sourceManifestAssociation'] != 'verified' ||
        outputs['exportPath'] is! String ||
        snapshot.task.exportPath == null ||
        !OutputSourceLocator.sameFilesystemPath(
          snapshot.task.exportPath!,
          exportPath,
        ) ||
        !OutputSourceLocator.sameFilesystemPath(
          snapshot.task.outputDirectory,
          widget.pyramidDirectory,
        ) ||
        !OutputSourceLocator.sameFilesystemPath(
          outputs['exportPath']! as String,
          exportPath,
        )) {
      _traceUnavailableReason = 'associationMismatch';
      return null;
    }
    var actual = await readExportDimensions(exportPath);
    if (!_isCurrentSource(generation, exportPath, widget.pyramidDirectory)) {
      return null;
    }
    if (actual == null) {
      if (p.extension(exportPath).toLowerCase() == '.jxl') {
        actual = await _verifiedJxlReceiptDimensions(
          snapshot,
          outputs,
          decodedManifest,
        );
      }
      if (actual == null) {
        _traceUnavailableReason = 'noVerifiedReceipt';
        return null;
      }
    }
    if (actual.$1 != pyramid.width || actual.$2 != pyramid.height) {
      _traceUnavailableReason = 'outputPreviewDimensionMismatch';
      return null;
    }
    final recordedDimensions = outputs['dimensions'];
    if (recordedDimensions is! Map ||
        recordedDimensions['width'] != actual.$1 ||
        recordedDimensions['height'] != actual.$2) {
      _traceUnavailableReason = 'outputRecordDimensionMismatch';
      return null;
    }
    if (decodedManifest is! Map ||
        decodedManifest['width'] != actual.$1 ||
        decodedManifest['height'] != actual.$2) {
      _traceUnavailableReason = 'outputManifestDimensionMismatch';
      return null;
    }
    final manifestRef = diagnostics['manifestRef'];
    final layoutRef = diagnostics['layoutRef'];
    final stateRef = diagnostics['jobStateRef'];
    if (!await _verifyRecordArtifact(snapshot, 'manifest', manifestRef) ||
        !await _verifyRecordArtifact(snapshot, 'layout', layoutRef) ||
        !await _verifyRecordArtifact(snapshot, 'job-state', stateRef)) {
      _traceUnavailableReason = 'layoutManifestIntegrityFailed';
      return null;
    }
    final layoutHash = layoutRef is Map ? layoutRef['sha256'] : null;
    final statePath = _recordArtifactPath(snapshot, 'job-state', stateRef);
    if (outputs['layoutStateAssociation'] != 'verified' ||
        outputs['layoutSha256'] is! String ||
        layoutHash is! String ||
        outputs['layoutSha256'] != layoutHash ||
        statePath == null) {
      _traceUnavailableReason = 'layoutStateAssociationMismatch';
      return null;
    }
    final stateValue = jsonDecode(await File(statePath).readAsString());
    final persistedLayoutHash = stateValue is Map
        ? (stateValue['layout_hash'] ?? stateValue['layoutHash'])
        : null;
    if (persistedLayoutHash != layoutHash) {
      _traceUnavailableReason = 'layoutStateAssociationMismatch';
      return null;
    }
    final manifestPath = _recordArtifactPath(snapshot, 'manifest', manifestRef);
    if (manifestPath == null) {
      _traceUnavailableReason = 'manifestPathMismatch';
      return null;
    }
    final canonicalRecordManifest = await File(
      manifestPath,
    ).resolveSymbolicLinks();
    final canonicalPyramidManifest = await File(
      p.join(widget.pyramidDirectory, 'manifest.json'),
    ).resolveSymbolicLinks();
    if (!OutputSourceLocator.sameFilesystemPath(
      canonicalRecordManifest,
      canonicalPyramidManifest,
    )) {
      _traceUnavailableReason = 'manifestPathMismatch';
      return null;
    }
    final layoutPath = _recordArtifactPath(snapshot, 'layout', layoutRef);
    if (layoutPath == null) return null;
    final canonicalOutputRoot = await Directory(
      snapshot.task.outputDirectory,
    ).resolveSymbolicLinks();
    final canonicalLayout = await File(layoutPath).resolveSymbolicLinks();
    if (!_isWithin(canonicalOutputRoot, canonicalLayout)) {
      _traceUnavailableReason = 'layoutOutsideTask';
      return null;
    }
    final layoutFile = File(canonicalLayout);
    if (await layoutFile.length() > _maxManifestBytes) {
      _traceUnavailableReason = 'layoutTooLarge';
      return null;
    }
    final value = jsonDecode(await layoutFile.readAsString());
    if (value is! Map<String, Object?> ||
        value['projection'] != 'spherical' ||
        value['width'] != actual.$1 ||
        value['height'] != actual.$2) {
      _traceUnavailableReason = 'layoutDimensionMismatch';
      return null;
    }
    return value;
  }

  String? _recordArtifactPath(
    TaskRecordSnapshot snapshot,
    String kind,
    Object? ref,
  ) {
    if (ref is! Map ||
        ref['integrityStatus'] != 'verified' ||
        ref['ownedByTask'] != true ||
        ref['relativePath'] is! String) {
      return null;
    }
    final relative = ref['relativePath']! as String;
    if (p.isAbsolute(relative) ||
        relative.replaceAll('\\', '/').split('/').contains('..')) {
      return null;
    }
    final path = p.normalize(p.join(snapshot.task.outputDirectory, relative));
    final filename = kind == 'job-state' ? 'job-state.json' : '$kind.json';
    final expected = p.normalize(
      p.join(snapshot.task.outputDirectory, filename),
    );
    return OutputSourceLocator.sameFilesystemPath(path, expected) ? path : null;
  }

  Future<(int, int)?> _verifiedJxlReceiptDimensions(
    TaskRecordSnapshot snapshot,
    Map outputs,
    Object? manifest,
  ) async {
    final receipt = outputs['producerReceipt'];
    final diagnostics = snapshot.record['diagnostics'];
    if (receipt is! Map ||
        diagnostics is! Map ||
        receipt['status'] != 'verified' ||
        receipt['sourceManifestMatch'] != true ||
        outputs['exportDigestStatus'] != 'verifiedProducerReceipt' ||
        receipt['format'] != 'jxl' ||
        receipt['destination'] is! String ||
        !OutputSourceLocator.sameFilesystemPath(
          receipt['destination']! as String,
          widget.exportFilePath,
        ) ||
        outputs['exportSha256'] is! String ||
        outputs['exportSha256'] != receipt['exportSha256'] ||
        outputs['sourceManifestAssociation'] != 'verified' ||
        outputs['layoutStateAssociation'] != 'verified' ||
        manifest is! Map ||
        receipt['requestHash'] != manifest['requestHash']) {
      return null;
    }
    final dimensions = receipt['dimensions'];
    if (dimensions is! Map ||
        dimensions['width'] is! int ||
        dimensions['height'] is! int ||
        dimensions['width'] != manifest['width'] ||
        dimensions['height'] != manifest['height']) {
      return null;
    }
    final stateRef = diagnostics['jobStateRef'];
    final statePath = _recordArtifactPath(snapshot, 'job-state', stateRef);
    if (statePath == null ||
        stateRef is! Map ||
        stateRef['sha256'] != receipt['jobStateSha256'] ||
        !await _verifyRecordArtifact(snapshot, 'job-state', stateRef)) {
      return null;
    }
    final state = jsonDecode(await File(statePath).readAsString());
    final layoutRef = diagnostics['layoutRef'];
    final layoutHash = layoutRef is Map ? layoutRef['sha256'] : null;
    final stateLayoutHash = state is Map
        ? (state['layout_hash'] ?? state['layoutHash'])
        : null;
    final stateDimensions = state is Map ? state['dimensions'] : null;
    final stateWidth = state is Map
        ? (state['width'] ??
              (stateDimensions is List && stateDimensions.length == 2
                  ? stateDimensions[0]
                  : null))
        : null;
    final stateHeight = state is Map
        ? (state['height'] ??
              (stateDimensions is List && stateDimensions.length == 2
                  ? stateDimensions[1]
                  : null))
        : null;
    final exportPath = receipt['destination']! as String;
    final stateExportPath = state is Map
        ? (state['export_destination'] ?? state['exportDestination'])
        : null;
    final stateRequestHash = state is Map
        ? (state['request_hash'] ?? state['requestHash'])
        : null;
    final stateSourceHashes = state is Map
        ? (state['source_hashes'] ?? state['sourceHashes'])
        : null;
    final stateFormat = state is Map
        ? (state['export_format'] ?? state['exportFormat'])
        : null;
    final expectedFormat = switch (p.extension(exportPath).toLowerCase()) {
      '.jxl' => 'jxl',
      '.tif' || '.tiff' => 'tiff',
      '.png' => 'png',
      _ => null,
    };
    final normalizedStateFormat = stateFormat == 'tif' ? 'tiff' : stateFormat;
    if (state is! Map ||
        state['state'] != 'completed' ||
        state['operation'] != 'export' ||
        expectedFormat != 'jxl' ||
        (normalizedStateFormat != null &&
            normalizedStateFormat != expectedFormat) ||
        stateExportPath is! String ||
        !OutputSourceLocator.sameFilesystemPath(stateExportPath, exportPath) ||
        stateRequestHash != receipt['requestHash'] ||
        stateRequestHash != manifest['requestHash'] ||
        stateWidth != dimensions['width'] ||
        stateHeight != dimensions['height'] ||
        layoutHash is! String ||
        receipt['layoutSha256'] != layoutHash ||
        outputs['layoutSha256'] != layoutHash ||
        stateLayoutHash != layoutHash ||
        !_sourceHashMapsMatch(stateSourceHashes, manifest['sourceHashes'])) {
      return null;
    }
    final taskFingerprint = widget.expectedExportFingerprint;
    final receiptFingerprint = receipt['exportFingerprint'];
    final savedFingerprint = snapshot.task.exportFingerprint;
    if (taskFingerprint == null ||
        receiptFingerprint is! Map ||
        savedFingerprint == null ||
        savedFingerprint.sizeBytes != taskFingerprint.sizeBytes ||
        savedFingerprint.modifiedAtMicros != taskFingerprint.modifiedAtMicros ||
        receiptFingerprint['sizeBytes'] != taskFingerprint.sizeBytes ||
        receiptFingerprint['modifiedAtMicros'] !=
            taskFingerprint.modifiedAtMicros) {
      return null;
    }
    final file = File(exportPath);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    if (stat.size != taskFingerprint.sizeBytes ||
        stat.modified.microsecondsSinceEpoch !=
            taskFingerprint.modifiedAtMicros) {
      return null;
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != receipt['exportSha256']) return null;
    return (dimensions['width']! as int, dimensions['height']! as int);
  }

  Future<bool> _verifyRecordArtifact(
    TaskRecordSnapshot snapshot,
    String kind,
    Object? ref,
  ) async {
    final path = _recordArtifactPath(snapshot, kind, ref);
    if (path == null || ref is! Map) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    final stat = await file.stat();
    if (stat.size != ref['sizeBytes'] ||
        stat.modified.microsecondsSinceEpoch != ref['modifiedAtMicros']) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == ref['sha256'];
  }

  bool _sourceHashMapsMatch(Object? left, Object? right) {
    if (left is! Map || right is! Map || left.length != right.length) {
      return false;
    }
    final unmatched = right.entries.toList();
    for (final entry in left.entries) {
      if (entry.key is! String || entry.value is! String) return false;
      final index = unmatched.indexWhere(
        (candidate) =>
            candidate.key is String &&
            candidate.value is String &&
            OutputSourceLocator.sameFilesystemPath(
              entry.key as String,
              candidate.key as String,
            ),
      );
      if (index < 0 ||
          (entry.value as String).toLowerCase() !=
              (unmatched[index].value as String).toLowerCase()) {
        return false;
      }
      unmatched.removeAt(index);
    }
    return unmatched.isEmpty;
  }

  void _inspectAt(Offset point) {
    final layout = _traceLayout;
    final pyramid = _pyramid;
    final snapshot = widget.traceRecord;
    if (!_inspectMode ||
        layout == null ||
        pyramid == null ||
        snapshot == null) {
      return;
    }
    try {
      final trace = OutputSourceLocator.locate(
        layout: layout,
        task: snapshot.task,
        outputWidth: pyramid.width,
        outputHeight: pyramid.height,
        outputX: point.dx.floorToDouble(),
        outputY: point.dy.floorToDouble(),
      );
      setState(() => _pixelTrace = trace);
    } on FormatException catch (error) {
      setState(
        () => _traceUnavailableReason = switch (error.message) {
          'Output coordinate or layout is invalid.' =>
            'invalidOutputCoordinate',
          'Layout tiles are missing.' => 'layoutTilesMissing',
          'Layout projection bounds are invalid.' => 'layoutBoundsInvalid',
          'Task grid mapping is invalid.' => 'taskGridInvalid',
          _ => 'traceGeometryInvalid',
        },
      );
    }
  }

  bool _isCurrentSource(
    int generation,
    String exportPath,
    String pyramidDirectory,
  ) =>
      mounted &&
      generation == _sourceGeneration &&
      exportPath == widget.exportFilePath &&
      pyramidDirectory == widget.pyramidDirectory;

  Future<bool> _validateExport({
    required int generation,
    required String exportPath,
    required String pyramidDirectory,
    required ExportFileFingerprint? fingerprint,
    required bool associationPresent,
  }) async {
    final output = File(exportPath);
    if (!await output.exists()) {
      if (_isCurrentSource(generation, exportPath, pyramidDirectory)) {
        _clearVisibleTileCache();
        setState(() {
          _loading = false;
          _error = '导出文件不存在：$exportPath';
        });
      }
      return false;
    }
    final stat = await output.stat();
    if (!_isCurrentSource(generation, exportPath, pyramidDirectory)) {
      return false;
    }
    final expected = fingerprint;
    if (expected != null &&
        (stat.size != expected.sizeBytes ||
            stat.modified.microsecondsSinceEpoch !=
                expected.modifiedAtMicros)) {
      if (_isCurrentSource(generation, exportPath, pyramidDirectory)) {
        _clearVisibleTileCache();
        setState(() {
          _loading = false;
          _staleReason = '导出文件的大小或修改时间已变化';
          _pyramid = null;
        });
      }
      return false;
    }
    if (expected == null && !associationPresent) {
      if (_isCurrentSource(generation, exportPath, pyramidDirectory)) {
        setState(() {
          _loading = false;
          _error = '无法确认导出文件与此任务的关联，已停止打开预览。';
        });
      }
      return false;
    }
    return true;
  }

  Future<void> _recheckExport() async {
    if (_pyramid == null || _staleReason != null) return;
    final generation = ++_sourceGeneration;
    final exportPath = widget.exportFilePath;
    final pyramidDirectory = widget.pyramidDirectory;
    await _validateExport(
      generation: generation,
      exportPath: exportPath,
      pyramidDirectory: pyramidDirectory,
      fingerprint: widget.expectedExportFingerprint,
      associationPresent: widget.legacyTaskAssociationPresent,
    );
  }

  void _fitToWindow() {
    final viewport = _viewportSize;
    if (viewport != null) _setScale(_fitScale(viewport), center: true);
  }

  void _watchExportFile() {
    try {
      _fileWatch = File(widget.exportFilePath).watch().listen((_) {
        unawaited(_recheckExport());
      }, onError: (_) {});
    } on Object {
      // Rechecked when the app resumes. Some file systems do not provide watches.
    }
  }

  bool _isWithin(String root, String candidate) {
    final normalizedRoot = p.normalize(p.absolute(root));
    final normalizedCandidate = p.normalize(p.absolute(candidate));
    return p.equals(normalizedRoot, normalizedCandidate) ||
        p.isWithin(normalizedRoot, normalizedCandidate);
  }

  Future<File?> _resolveTile(_PyramidTile tile) {
    final key = tile.path;
    final existing = _tileChecks.remove(key);
    if (existing != null) {
      _tileChecks[key] = existing;
      return existing;
    }
    final check = _resolveTilePath(tile);
    _tileChecks[key] = check;
    while (_tileChecks.length > _maxTileChecks) {
      _tileChecks.remove(_tileChecks.keys.first);
    }
    return check;
  }

  Future<File?> _resolveTilePath(_PyramidTile tile) async {
    final normalized = tile.path.replaceAll('\\', '/');
    // Pyramid paths are stored as portable slash-separated paths even on
    // Windows; normalize and reject traversal using the manifest's POSIX form.
    final pathContext = p.Context(style: p.Style.posix);
    final relative = pathContext.normalize(normalized);
    if (pathContext.isAbsolute(normalized) ||
        relative == '.' ||
        relative == '..' ||
        relative.startsWith('../') ||
        relative.contains('/../')) {
      return null;
    }
    try {
      final root = await Directory(
        widget.pyramidDirectory,
      ).resolveSymbolicLinks();
      final candidate = File(p.join(root, relative));
      final canonical = await candidate.resolveSymbolicLinks();
      if (!_isWithin(root, canonical)) return null;
      final safeFile = File(canonical);
      if (!await safeFile.exists()) return null;
      return safeFile;
    } on FileSystemException {
      return null;
    }
  }

  void _applyFitWhenLaidOut() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialTransformSet || _pyramid == null) return;
      final size = _viewportSize;
      if (size == null || size.isEmpty) return;
      _initialTransformSet = true;
      _setScale(_fitScale(size), center: true);
    });
  }

  double _fitScale(Size viewport) {
    final pyramid = _pyramid!;
    final oneToOne = 1 / MediaQuery.devicePixelRatioOf(context);
    return math
        .min(
          oneToOne,
          math.min(
            viewport.width / pyramid.width,
            viewport.height / pyramid.height,
          ),
        )
        .clamp(0.00001, 1)
        .toDouble();
  }

  void _setScale(double requested, {bool center = false, Offset? focal}) {
    final pyramid = _pyramid;
    final viewport = _viewportSize;
    if (pyramid == null || viewport == null || viewport.isEmpty) return;
    final fit = _fitScale(viewport);
    final maxScale = _maxScale / MediaQuery.devicePixelRatioOf(context);
    final nextScale = requested.clamp(fit, maxScale).toDouble();
    final old = _transform.value;
    final oldScale = old.getMaxScaleOnAxis();
    final tx = old.entry(0, 3), ty = old.entry(1, 3);
    final point = focal ?? Offset(viewport.width / 2, viewport.height / 2);
    final imageX = (point.dx - tx) / oldScale;
    final imageY = (point.dy - ty) / oldScale;
    var nextX = point.dx - imageX * nextScale;
    var nextY = point.dy - imageY * nextScale;
    if (center) {
      nextX = (viewport.width - pyramid.width * nextScale) / 2;
      nextY = (viewport.height - pyramid.height * nextScale) / 2;
    }
    nextX = _clampTranslation(nextX, viewport.width, pyramid.width, nextScale);
    nextY = _clampTranslation(
      nextY,
      viewport.height,
      pyramid.height,
      nextScale,
    );
    final next = Matrix4.identity()
      ..setEntry(0, 0, nextScale)
      ..setEntry(1, 1, nextScale)
      ..setEntry(2, 2, nextScale)
      ..setEntry(0, 3, nextX)
      ..setEntry(1, 3, nextY);
    _transform.value = next;
  }

  double _clampTranslation(
    double value,
    double viewport,
    int content,
    double scale,
  ) {
    final rendered = content * scale;
    if (rendered <= viewport) return (viewport - rendered) / 2;
    return value.clamp(viewport - rendered, 0).toDouble();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _pyramid == null) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (resolved is! PointerScrollEvent || !mounted) return;
      final factor = math.exp(-resolved.scrollDelta.dy * 0.0015);
      _setScale(
        _transform.value.getMaxScaleOnAxis() * factor,
        focal: resolved.localPosition,
      );
    });
  }

  void _onTransformChanged() {
    final pyramid = _pyramid;
    final viewport = _viewportSize;
    if (!mounted || pyramid == null || viewport == null) return;
    final scale = _transform.value.getMaxScaleOnAxis();
    final nextLevel = _chooseLevel(pyramid, scale);
    if (scale == _scale && nextLevel == _level) {
      // Panning still changes the visible tile set.
      setState(() {});
      return;
    }
    setState(() {
      _scale = scale;
      _level = nextLevel;
    });
  }

  int _chooseLevel(_Pyramid pyramid, double scale) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final targetWidth = pyramid.width * scale * pixelRatio;
    final targetHeight = pyramid.height * scale * pixelRatio;
    final sufficient = pyramid.levels.where(
      (level) => level.width >= targetWidth && level.height >= targetHeight,
    );
    if (sufficient.isEmpty) return pyramid.levels.first.number;
    return sufficient
        .reduce((a, b) => a.width * a.height <= b.width * b.height ? a : b)
        .number;
  }

  Rect _visibleRect(Size viewport) {
    final inverse = Matrix4.inverted(_transform.value);
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
      inverse,
      Offset(viewport.width, viewport.height),
    );
    return Rect.fromPoints(topLeft, bottomRight);
  }

  List<_PyramidTile> _visibleTiles(_Pyramid pyramid, Size viewport) {
    final levelNumber = _level ?? _chooseLevel(pyramid, _scale);
    final level = pyramid.levels.firstWhere(
      (item) => item.number == levelNumber,
    );
    final factorX = pyramid.width / level.width;
    final factorY = pyramid.height / level.height;
    final visible = _visibleRect(viewport).intersect(
      Rect.fromLTWH(0, 0, pyramid.width.toDouble(), pyramid.height.toDouble()),
    );
    if (visible.isEmpty) return const [];
    final source = Rect.fromLTRB(
      visible.left / factorX,
      visible.top / factorY,
      visible.right / factorX,
      visible.bottom / factorY,
    );
    final columns = (level.width + _tileSize - 1) ~/ _tileSize;
    final rows = (level.height + _tileSize - 1) ~/ _tileSize;
    final firstColumn = (source.left / _tileSize).floor();
    final firstColumnWithMargin = (firstColumn - _tileCacheMargin)
        .clamp(0, columns - 1)
        .toInt();
    final lastColumn =
        (((source.right / _tileSize).ceil() - 1) + _tileCacheMargin)
            .clamp(0, columns - 1)
            .toInt();
    final firstRow = (source.top / _tileSize).floor();
    final firstRowWithMargin = (firstRow - _tileCacheMargin)
        .clamp(0, rows - 1)
        .toInt();
    final lastRow =
        (((source.bottom / _tileSize).ceil() - 1) + _tileCacheMargin)
            .clamp(0, rows - 1)
            .toInt();
    final visibleTiles = <_PyramidTile>[];
    for (var row = firstRowWithMargin; row <= lastRow; row++) {
      for (var column = firstColumnWithMargin; column <= lastColumn; column++) {
        final tile = level.tileAt(row, column, columns);
        if (tile != null) visibleTiles.add(tile);
      }
    }
    return visibleTiles;
  }

  void _updateVisibleTileCache(Map<String, Future<File?>> nowVisible) {
    if (_visibleTileFutures.length == nowVisible.length &&
        _visibleTileFutures.keys.toSet().containsAll(nowVisible.keys)) {
      return;
    }
    final evict = _visibleTileFutures.entries
        .where((entry) => !nowVisible.containsKey(entry.key))
        .map((entry) => entry.value)
        .toList(growable: false);
    _visibleTileFutures = Map.of(nowVisible);
    if (evict.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final future in evict) {
        _evictTileFuture(future);
      }
    });
  }

  void _clearVisibleTileCache() {
    for (final future in _visibleTileFutures.values) {
      _evictTileFuture(future);
    }
    _visibleTileFutures = {};
    _tileChecks.clear();
  }

  void _evictTileFuture(Future<File?> future) {
    unawaited(
      future
          .then<void>((file) async {
            if (file != null) {
              await ResizeImage(
                FileImage(file),
                width: _tileSize,
                height: _tileSize,
              ).evict();
            }
          })
          .catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = p.basename(widget.exportFilePath);
    return Scaffold(
      appBar: AppBar(
        title: Text(title, translate: false, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.mobileStorageService != null &&
              widget.exportMimeType != null) ...[
            IconButton(
              tooltip: '保存整图',
              onPressed: () => widget._saveExport(context),
              icon: const Icon(Icons.download),
            ),
            IconButton(
              tooltip: '分享整图',
              onPressed: () => widget._shareExport(context),
              icon: const Icon(Icons.ios_share),
            ),
          ],
          IconButton(
            tooltip: StitchLocalizations.of(context).text('适合窗口'),
            onPressed: _pyramid == null ? null : _fitToWindow,
            icon: const Icon(Icons.fit_screen),
          ),
          TextButton(
            onPressed: _pyramid == null
                ? null
                : () => _setScale(
                    1 / MediaQuery.devicePixelRatioOf(context),
                    center: true,
                  ),
            child: const Text('100%'),
          ),
          IconButton(
            tooltip: StitchLocalizations.of(
              context,
            ).text(_showSourceInformation ? '收起输出信息' : '查看输出信息'),
            onPressed: () => setState(() {
              _showSourceInformation = !_showSourceInformation;
            }),
            icon: Icon(
              _showSourceInformation ? Icons.info : Icons.info_outline,
            ),
          ),
          if (widget.traceRecord != null)
            IconButton(
              key: const ValueKey('output-source-inspect-toggle'),
              tooltip: StitchLocalizations.of(context).isChinese
                  ? (_inspectMode ? '关闭来源检查' : '检查像素来源')
                  : (_inspectMode
                        ? 'Stop source inspection'
                        : 'Inspect pixel source'),
              onPressed: _pyramid == null
                  ? null
                  : () => setState(() {
                      _inspectMode = !_inspectMode;
                      _pixelTrace = null;
                    }),
              icon: Icon(
                _inspectMode ? Icons.location_searching : Icons.travel_explore,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_showSourceInformation) _sourceInformation(),
          if (_inspectMode) _traceInformation(),
          Expanded(child: _viewerBody()),
          if (_pyramid != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scale = Text(
                    '缩放 ${(_scale * MediaQuery.devicePixelRatioOf(context) * 100).round()}%',
                  );
                  final dimensions = Text(
                    '${_pyramid!.width} × ${_pyramid!.height} px',
                  );
                  final level = _level == null ? null : Text('预览层级 $_level');
                  if (constraints.maxWidth < 600) {
                    return SizedBox(
                      width: constraints.maxWidth,
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [scale, dimensions, ?level],
                      ),
                    );
                  }
                  return Row(
                    children: [
                      scale,
                      const SizedBox(width: 12),
                      dimensions,
                      const Spacer(),
                      ?level,
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _traceInformation() {
    final isChinese = StitchLocalizations.of(context).isChinese;
    final trace = _pixelTrace;
    final lines = <String>[];
    if (_traceUnavailableReason != null) {
      lines.add(_traceReasonText(_traceUnavailableReason!, isChinese));
    } else if (trace == null) {
      lines.add(
        isChinese
            ? '点击输出像素查看几何覆盖。'
            : 'Tap an output pixel to inspect geometric coverage.',
      );
    } else if (trace.cameras.isEmpty) {
      lines.add(
        isChinese ? '此射线没有覆盖相机。' : 'No camera geometrically covers this ray.',
      );
    } else {
      lines.add(
        isChinese
            ? '输出 (${trace.outputX.toStringAsFixed(1)}, ${trace.outputY.toStringAsFixed(1)}) · 覆盖 ${trace.cameras.length} 张原片（几何覆盖，不代表最终混合权重）'
            : 'Output (${trace.outputX.toStringAsFixed(1)}, ${trace.outputY.toStringAsFixed(1)}) · ${trace.cameras.length} geometric source coverage(s); final blend weights are not reported.',
      );
      for (final camera in trace.cameras) {
        lines.add(
          isChinese
              ? '${camera.originalName} · ${camera.sourcePath} · 网格 ${camera.row + 1},${camera.column + 1} · 原片 (${camera.sourceX.toStringAsFixed(1)}, ${camera.sourceY.toStringAsFixed(1)}) · ${_tracePosition(camera.positionSource, true)} · ${_tracePlacement(camera.placementKind, true)} / ${_traceOrigin(camera.placementOrigin, true)} · 直接视觉证据 ${camera.directVisualEvidence ? '有' : '无'}'
              : '${camera.originalName} · ${camera.sourcePath} · grid ${camera.row + 1},${camera.column + 1} · source (${camera.sourceX.toStringAsFixed(1)}, ${camera.sourceY.toStringAsFixed(1)}) · ${_tracePosition(camera.positionSource, false)} · ${_tracePlacement(camera.placementKind, false)} / ${_traceOrigin(camera.placementOrigin, false)} · direct visual evidence ${camera.directVisualEvidence ? 'yes' : 'no'}',
        );
        for (final edge in camera.neighborEdges) {
          lines.add(
            isChinese
                ? '  邻居 ${edge.row + 1},${edge.column + 1} · ${_traceDisposition(edge.disposition, true)} · 中位残差 ${edge.medianResidualPx?.toStringAsFixed(2) ?? '未知'} px · RMS ${edge.rmsResidualPx?.toStringAsFixed(2) ?? '未知'} px'
                : '  Neighbor ${edge.row + 1},${edge.column + 1} · ${_traceDisposition(edge.disposition, false)} · median ${edge.medianResidualPx?.toStringAsFixed(2) ?? 'unknown'} px · RMS ${edge.rmsResidualPx?.toStringAsFixed(2) ?? 'unknown'} px',
          );
        }
      }
      lines.add(
        isChinese
            ? '渲染器最终选择与曝光/颜色增益未提供。'
            : 'Renderer ownership and exposure/color gains are not available.',
      );
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SelectableText(
            lines.join('\n'),
            textAlign: TextAlign.start,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }

  String _traceReasonText(String key, bool isChinese) => switch (key) {
    'traceLoadFailed' =>
      isChinese
          ? '无法安全验证布局来源，像素追踪已停用。'
          : 'Could not verify the layout source; pixel tracing is disabled.',
    'associationMismatch' =>
      isChinese
          ? '任务记录未验证当前输出与布局清单的关联。'
          : 'The task record does not verify the output-to-layout association.',
    'noVerifiedReceipt' =>
      isChinese
          ? '此格式没有可验证的导出回执，来源追踪已停用。'
          : 'No verified export receipt is available for this format; source tracing is disabled.',
    'outputPreviewDimensionMismatch' =>
      isChinese
          ? '实际输出尺寸与分块预览清单不一致，来源追踪已停用。'
          : 'The output dimensions do not match the preview manifest; source tracing is disabled.',
    'outputRecordDimensionMismatch' =>
      isChinese
          ? '实际输出尺寸与任务记录不一致，来源追踪已停用。'
          : 'The output dimensions do not match the task record; source tracing is disabled.',
    'outputManifestDimensionMismatch' =>
      isChinese
          ? '输出尺寸与任务清单不一致，来源追踪已停用。'
          : 'The output dimensions do not match the task manifest; source tracing is disabled.',
    'layoutManifestIntegrityFailed' =>
      isChinese
          ? '任务布局或清单校验失败，来源追踪已停用。'
          : 'Task layout or manifest integrity verification failed; source tracing is disabled.',
    'manifestPathMismatch' =>
      isChinese
          ? '任务记录与当前预览清单不是同一文件。'
          : 'The task record and current preview do not use the same manifest file.',
    'layoutOutsideTask' =>
      isChinese
          ? '布局文件路径超出任务目录，已拒绝读取。'
          : 'The layout path is outside the task directory and was rejected.',
    'layoutTooLarge' =>
      isChinese
          ? '布局记录超过安全读取上限。'
          : 'The layout record exceeds the safe read limit.',
    'layoutDimensionMismatch' =>
      isChinese
          ? '布局投影或输出尺寸与实际文件不一致。'
          : 'The layout projection or dimensions do not match the output file.',
    'invalidOutputCoordinate' =>
      isChinese ? '输出坐标或布局无效。' : 'The output coordinate or layout is invalid.',
    'layoutTilesMissing' =>
      isChinese ? '布局缺少相机信息。' : 'The layout has no camera tiles.',
    'layoutBoundsInvalid' =>
      isChinese ? '布局投影范围无效。' : 'The layout projection bounds are invalid.',
    'taskGridInvalid' =>
      isChinese ? '任务网格映射无效。' : 'The task grid mapping is invalid.',
    _ =>
      isChinese
          ? '几何追踪数据无效，已停止检查。'
          : 'The geometry trace is invalid and inspection stopped.',
  };

  String _tracePosition(String value, bool isChinese) => switch (value) {
    'visual' => isChinese ? '视觉测量' : 'visually measured',
    'gridEstimated' => isChinese ? '网格估算' : 'grid estimated',
    _ => isChinese ? '位置来源未知' : 'position source unknown',
  };

  String _tracePlacement(String value, bool isChinese) => switch (value) {
    'hardGridLock' => isChinese ? '网格硬锁' : 'hard grid lock',
    'gridPrior' => isChinese ? '网格先验' : 'grid prior',
    'none' => isChinese ? '无放置约束' : 'no placement constraint',
    _ => isChinese ? '约束未知' : 'constraint unknown',
  };

  String _traceOrigin(String value, bool isChinese) => switch (value) {
    'operator' => isChinese ? '操作员' : 'operator',
    'systemFallback' => isChinese ? '系统回退' : 'system fallback',
    'legacyUnknown' => isChinese ? '旧记录来源未知' : 'legacy origin unknown',
    _ => isChinese ? '来源未知' : 'origin unknown',
  };

  String _traceDisposition(String value, bool isChinese) => switch (value) {
    'accepted' => isChinese ? '已接受' : 'accepted',
    'forced_grid_cell' =>
      isChinese
          ? '网格硬锁边，未参与视觉匹配'
          : 'hard-locked grid edge; visual matching skipped',
    'descriptor_missing_or_invalid' =>
      isChinese ? '描述子缺失或无效' : 'descriptor missing or invalid',
    'too_few_ratio_test_matches' =>
      isChinese ? '比率检验匹配不足' : 'too few ratio-test matches',
    'ransac_failed' => isChinese ? 'RANSAC 失败' : 'RANSAC failed',
    'too_few_inliers' => isChinese ? '内点不足' : 'too few inliers',
    'low_inlier_ratio' => isChinese ? '内点比例过低' : 'low inlier ratio',
    'ray_fit_pending' => isChinese ? '等待射线拟合' : 'ray fit pending',
    'weak_support_loop_conflict' =>
      isChinese ? '弱支持回环冲突' : 'weak-support loop conflict',
    'ray_fit_degenerate' => isChinese ? '射线拟合退化' : 'degenerate ray fit',
    'ray_residual_exceeds_12px' =>
      isChinese ? '射线残差超过 12 px 门限' : 'ray residual exceeds 12 px gate',
    'rejected_joint_pixel_leave_one_out_conflict' =>
      isChinese ? '联合像素留一冲突' : 'joint pixel leave-one-out conflict',
    'weak_support' => isChinese ? '支持不足' : 'weak support',
    _ => isChinese ? '状态未知' : 'unknown status',
  };

  Widget _sourceInformation() {
    final expected = widget.expectedExportFingerprint;
    final text = _staleReason != null
        ? '输出文件已变化，关联分块预览已停用。请重新合成以生成匹配的预览。'
        : _error != null
        ? _error!
        : expected == null
        ? widget.legacyTaskBindingVerified
              ? '旧任务没有导出指纹；核心记录确认此路径属于任务，但无法确认文件后来是否被外部修改。预览来自任务金字塔。'
              : '旧任务没有导出指纹，且核心未核验导出记录。预览来自保存任务的金字塔，可能与当前文件内容不同。'
        : '输出大小和修改时间与导出时记录一致（未做内容哈希）。预览来源：本任务的 PNG 分块金字塔（同一渲染像素）。';
    final warning = _staleReason != null || _error != null || expected == null;
    return Material(
      color: warning
          ? Theme.of(context).colorScheme.tertiaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '输出格式：${_formatName(widget.exportFilePath)}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            SelectableText(
              '输出文件：${widget.exportFilePath}',
              maxLines: 2,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(text, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  String _formatName(String path) => switch (p.extension(path).toLowerCase()) {
    '.png' => 'PNG',
    '.tif' || '.tiff' => 'TIFF / BigTIFF',
    '.jxl' => 'JPEG XL',
    final extension => '未知格式（$extension）',
  };

  Widget _viewerBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_staleReason != null || _error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber, size: 48),
              const SizedBox(height: 12),
              Text(_staleReason ?? _error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loadSource,
                icon: const Icon(Icons.refresh),
                label: const Text('重新检查'),
              ),
            ],
          ),
        ),
      );
    }
    final pyramid = _pyramid;
    if (pyramid == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (_viewportSize != viewport) {
          _viewportSize = viewport;
          if (!_initialTransformSet) {
            _applyFitWhenLaidOut();
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _setScale(
                  _transform.value.getMaxScaleOnAxis(),
                  focal: viewport.center(Offset.zero),
                );
              }
            });
          }
        }
        final visible = _visibleTiles(pyramid, viewport);
        final futures = <String, Future<File?>>{};
        for (final tile in visible) {
          futures[tile.path] = _resolveTile(tile);
        }
        _updateVisibleTileCache(futures);
        final levelNumber = _level ?? _chooseLevel(pyramid, _scale);
        final level = pyramid.levels.firstWhere(
          (item) => item.number == levelNumber,
        );
        final factorX = pyramid.width / level.width;
        final factorY = pyramid.height / level.height;
        return Listener(
          onPointerSignal: _handlePointerSignal,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              child: InteractiveViewer(
                key: const ValueKey('exported-image-interactive-viewer'),
                transformationController: _transform,
                constrained: false,
                panEnabled: true,
                scaleEnabled: true,
                minScale: _fitScale(viewport),
                maxScale: _maxScale / MediaQuery.devicePixelRatioOf(context),
                boundaryMargin: EdgeInsets.zero,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: pyramid.width.toDouble(),
                  height: pyramid.height.toDouble(),
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      for (final tile in visible)
                        Positioned(
                          key: ValueKey('viewer-tile-${tile.path}'),
                          left: tile.column * _tileSize * factorX,
                          top: tile.row * _tileSize * factorY,
                          width: tile.width * factorX,
                          height: tile.height * factorY,
                          child: FutureBuilder<File?>(
                            future: futures[tile.path],
                            builder: (context, snapshot) {
                              final file = snapshot.data;
                              if (snapshot.connectionState !=
                                  ConnectionState.done) {
                                return ColoredBox(
                                  key: ValueKey(
                                    'viewer-tile-pending-${tile.path}',
                                  ),
                                  color: Colors.black12,
                                );
                              }
                              if (file == null) {
                                return const ColoredBox(
                                  color: Colors.black12,
                                  child: Icon(Icons.broken_image_outlined),
                                );
                              }
                              return Image(
                                image: ResizeImage(
                                  FileImage(file),
                                  width: _tileSize,
                                  height: _tileSize,
                                ),
                                width: tile.width * factorX,
                                height: tile.height * factorY,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium,
                                frameBuilder: (context, child, frame, _) {
                                  if (frame == null) {
                                    return ColoredBox(
                                      key: ValueKey(
                                        'viewer-tile-decoding-${tile.path}',
                                      ),
                                      color: Colors.black12,
                                    );
                                  }
                                  return child;
                                },
                                errorBuilder: (_, _, _) => const ColoredBox(
                                  color: Colors.black12,
                                  child: Icon(Icons.broken_image_outlined),
                                ),
                              );
                            },
                          ),
                        ),
                      if (_inspectMode)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTapDown: (details) =>
                                _inspectAt(details.localPosition),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Pyramid {
  const _Pyramid({
    required this.width,
    required this.height,
    required this.levels,
  });

  final int width;
  final int height;
  final List<_PyramidLevel> levels;

  factory _Pyramid.parse(Object? decoded) {
    if (decoded is! Map<String, Object?> ||
        decoded['schemaVersion'] != 1 ||
        decoded['projection'] != 'spherical' ||
        decoded['complete'] != true) {
      throw const FormatException('预览清单格式无效或尚未完成。');
    }
    final width = _positiveInt(decoded['width']);
    final height = _positiveInt(decoded['height']);
    if (width > 131072 || height > 131072) {
      throw const FormatException('预览尺寸超出支持范围。');
    }
    if (decoded['tileSize'] != _ExportedImageViewerState._tileSize) {
      throw const FormatException('预览瓦片尺寸不受支持。');
    }
    final rawLevels = decoded['levels'];
    if (rawLevels is! List || rawLevels.isEmpty || rawLevels.length > 32) {
      throw const FormatException('预览层级清单无效。');
    }
    final levels = <_PyramidLevel>[];
    final seenLevels = <int>{};
    var totalTiles = 0;
    for (final rawLevel in rawLevels) {
      if (rawLevel is! Map<String, Object?>) {
        throw const FormatException('预览层级格式无效。');
      }
      final number = _nonNegativeInt(rawLevel['level']);
      final levelWidth = _positiveInt(rawLevel['width']);
      final levelHeight = _positiveInt(rawLevel['height']);
      if (!seenLevels.add(number)) {
        throw const FormatException('预览层级重复。');
      }
      final rawTiles = rawLevel['occupied'];
      if (rawTiles is! List || rawTiles.length > 1000000) {
        throw const FormatException('预览瓦片列表无效。');
      }
      totalTiles += rawTiles.length;
      if (totalTiles > _ExportedImageViewerState._maxTotalTiles) {
        throw const FormatException('预览瓦片数量过多，已拒绝读取。');
      }
      final tiles = <_PyramidTile>[];
      final seenCoordinates = <String>{};
      final seenPaths = <String>{};
      final columns =
          (levelWidth + _ExportedImageViewerState._tileSize - 1) ~/
          _ExportedImageViewerState._tileSize;
      final rows =
          (levelHeight + _ExportedImageViewerState._tileSize - 1) ~/
          _ExportedImageViewerState._tileSize;
      for (final rawTile in rawTiles) {
        if (rawTile is! Map<String, Object?> || rawTile['path'] is! String) {
          throw const FormatException('预览瓦片信息无效。');
        }
        final row = _nonNegativeInt(rawTile['row']);
        final column = _nonNegativeInt(rawTile['column']);
        final tileWidth = _positiveInt(rawTile['width']);
        final tileHeight = _positiveInt(rawTile['height']);
        final path = rawTile['path'] as String;
        final normalized = path.replaceAll('\\', '/');
        final context = p.Context(style: p.Style.posix);
        final relative = context.normalize(normalized);
        final expectedWidth =
            (levelWidth - column * _ExportedImageViewerState._tileSize).clamp(
              0,
              _ExportedImageViewerState._tileSize,
            );
        final expectedHeight =
            (levelHeight - row * _ExportedImageViewerState._tileSize).clamp(
              0,
              _ExportedImageViewerState._tileSize,
            );
        if (context.isAbsolute(normalized) ||
            normalized.split('/').contains('..') ||
            relative == '.' ||
            relative == '..' ||
            relative.startsWith('../') ||
            relative.contains('/../') ||
            !relative.toLowerCase().startsWith('level-$number/') ||
            !relative.toLowerCase().endsWith('.png') ||
            tileWidth > _ExportedImageViewerState._tileSize ||
            tileHeight > _ExportedImageViewerState._tileSize ||
            row >= rows ||
            column >= columns ||
            tileWidth != expectedWidth ||
            tileHeight != expectedHeight ||
            column * _ExportedImageViewerState._tileSize + tileWidth >
                levelWidth ||
            row * _ExportedImageViewerState._tileSize + tileHeight >
                levelHeight ||
            !seenCoordinates.add('$row:$column') ||
            !seenPaths.add(relative.toLowerCase())) {
          throw const FormatException('预览瓦片路径或坐标无效。');
        }
        tiles.add(
          _PyramidTile(
            row: row,
            column: column,
            width: tileWidth,
            height: tileHeight,
            path: relative,
          ),
        );
      }
      levels.add(
        _PyramidLevel(
          number: number,
          width: levelWidth,
          height: levelHeight,
          tilesByCoordinate: Map.unmodifiable({
            for (final tile in tiles) tile.row * columns + tile.column: tile,
          }),
        ),
      );
    }
    levels.sort((a, b) => a.number.compareTo(b.number));
    final level0 = levels.first;
    if (level0.number != 0 ||
        level0.width != width ||
        level0.height != height) {
      throw const FormatException('预览最高分辨率与清单尺寸不一致。');
    }
    for (var i = 1; i < levels.length; i++) {
      final previous = levels[i - 1];
      final current = levels[i];
      if (current.width != (previous.width + 1) ~/ 2 ||
          current.height != (previous.height + 1) ~/ 2) {
        throw const FormatException('预览层级尺寸顺序无效。');
      }
    }
    return _Pyramid(
      width: width,
      height: height,
      levels: List.unmodifiable(levels),
    );
  }
}

class _PyramidLevel {
  const _PyramidLevel({
    required this.number,
    required this.width,
    required this.height,
    required this.tilesByCoordinate,
  });

  final int number;
  final int width;
  final int height;
  final Map<int, _PyramidTile> tilesByCoordinate;

  _PyramidTile? tileAt(int row, int column, int columns) =>
      tilesByCoordinate[row * columns + column];
}

class _PyramidTile {
  const _PyramidTile({
    required this.row,
    required this.column,
    required this.width,
    required this.height,
    required this.path,
  });

  final int row;
  final int column;
  final int width;
  final int height;
  final String path;
}

int _positiveInt(Object? value) {
  if (value is int && value > 0) return value;
  throw const FormatException('预览尺寸必须是正整数。');
}

int _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  throw const FormatException('预览层级或坐标必须是非负整数。');
}
