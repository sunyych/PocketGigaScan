import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;

import '../models/export_fingerprint.dart';
import '../services/mobile_storage_service.dart';
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
  });

  final String exportFilePath;
  final String pyramidDirectory;
  final ExportFileFingerprint? expectedExportFingerprint;
  final bool legacyTaskAssociationPresent;
  final bool legacyTaskBindingVerified;
  final MobileStorageService? mobileStorageService;
  final String? exportMimeType;

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
            widget.legacyTaskBindingVerified) {
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
        ],
      ),
      body: Column(
        children: [
          if (_showSourceInformation) _sourceInformation(),
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
