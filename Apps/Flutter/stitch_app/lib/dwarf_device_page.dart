import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models/dwarf_download.dart';
import 'services/batch_queue_controller.dart';
import 'services/device_network_service.dart';
import 'services/dwarf_device_client.dart';
import 'services/dwarf_download_service.dart';
import 'services/settings_controller.dart';
import 'l10n/localized_text.dart';
import 'l10n/stitch_localizations.dart';

class DwarfDevicePage extends StatefulWidget {
  const DwarfDevicePage({
    super.key,
    required this.queueController,
    this.settingsController,
    this.host = '192.168.88.1',
    this.client,
    this.downloader,
    this.networkService,
    this.storageRoot,
    this.onTransferStatus,
    this.onTaskReady,
  });

  final BatchQueueController queueController;
  final SettingsController? settingsController;
  final String host;
  final DwarfDeviceClient? client;
  final DwarfDownloadService? downloader;
  final DeviceNetworkService? networkService;
  final String? storageRoot;
  final ValueChanged<DwarfTransferStatus>? onTransferStatus;
  final FutureOr<void> Function(String taskId)? onTaskReady;

  @override
  State<DwarfDevicePage> createState() => _DwarfDevicePageState();
}

class DwarfTransferStatus {
  const DwarfTransferStatus({
    required this.batchId,
    required this.title,
    required this.state,
    required this.completedBytes,
    required this.totalBytes,
    required this.completedFiles,
    required this.totalFiles,
  });

  final String batchId;
  final String title;
  final DwarfDownloadState state;
  final int completedBytes;
  final int totalBytes;
  final int completedFiles;
  final int totalFiles;
}

class _DwarfDevicePageState extends State<DwarfDevicePage>
    with WidgetsBindingObserver {
  late final TextEditingController _host = TextEditingController(
    text: widget.host,
  );
  DwarfDeviceClient? _client;
  DwarfDownloadService? _downloader;
  bool _opening = false;
  bool _connecting = false;
  bool _downloading = false;
  bool _importing = false;
  String? _error;
  String? _activePanoramaTitle;
  DwarfDeviceInfo? _device;
  List<DwarfPanorama> _panoramas = const [];
  final Set<String> _selected = {};
  final Map<String, List<DwarfOriginal>> _originals = {};
  final Map<String, DwarfDownloadBatch> _batches = {};
  final Map<String, DwarfDownloadProgress> _progress = {};
  final Set<String> _activeBatchIds = {};
  final Set<String> _importSelected = {};
  bool get _ownsClient => widget.client == null;
  bool get _ownsDownloader => widget.downloader == null;
  bool _closeOwnedDownloaderWhenIdle = false;
  String? _activeBatchId;
  bool _backgroundPaused = false;

  String _batchId(DwarfPanorama panorama) {
    final host = _client?.host ?? _host.text.trim().toLowerCase();
    final identity =
        _device?.serialNumber ?? _device?.deviceId ?? _device?.deviceName ?? '';
    final digest = sha256.convert(
      utf8.encode('$host\n$identity\n${panorama.id}'),
    );
    return 'dwarf-${digest.toString()}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepareDownloader();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _backgroundPaused = true;
      unawaited(_pauseForBackground());
    } else if (state == AppLifecycleState.resumed) {
      _backgroundPaused = false;
    }
  }

  Future<void> _pauseForBackground() async {
    final ids = _activeBatchIds.toList(growable: false);
    for (final id in ids) {
      await _pause(id);
    }
    final currentId = _activeBatchId;
    if (currentId != null && _batches[currentId] == null) {
      final progress = _progress[currentId];
      widget.onTransferStatus?.call(
        DwarfTransferStatus(
          batchId: currentId,
          title: _activePanoramaTitle ?? currentId,
          state: DwarfDownloadState.paused,
          completedBytes: progress?.fileBytes ?? 0,
          totalBytes: progress?.fileSize ?? 0,
          completedFiles: progress?.completedFiles ?? 0,
          totalFiles: progress?.totalFiles ?? 0,
        ),
      );
    }
    if (ids.isEmpty && currentId == null) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(StitchLocalizations.of(context).dwarfBackgroundPause),
        ),
      );
    }
  }

  Future<void> _prepareDownloader() async {
    try {
      final downloader =
          widget.downloader ??
          DwarfDownloadService(
            rootDirectory:
                widget.storageRoot ??
                p.join(
                  (await getApplicationSupportDirectory()).path,
                  'dwarf-downloads',
                ),
          );
      final batches = await downloader.listBatches();
      if (!mounted) return;
      setState(() {
        _downloader = downloader;
        for (final batch in batches) {
          _batches[batch.id] = batch;
        }
      });
      for (final batch in batches) {
        _publishStatus(batch);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
      if (_ownsClient) _client?.close(force: true);
      _client = null;
      _device = null;
      _panoramas = const [];
      _selected.clear();
      _originals.clear();
    });
    try {
      final client = widget.client ?? DwarfDeviceClient(_host.text.trim());
      final device = await client.probe();
      final panoramas = await client.listPanoramas();
      if (!mounted) return;
      setState(() {
        _client = client;
        _device = device;
        _panoramas = panoramas;
      });
      await _restoreKnownBatches();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _restoreKnownBatches() async {
    final client = _client;
    final downloader = _downloader;
    if (client == null || downloader == null) return;
    for (final panorama in _panoramas) {
      final existing = _batches[_batchId(panorama)];
      if (existing == null) continue;
      try {
        final originals = await client.listOriginals(panorama);
        if (!mounted) return;
        setState(() {
          _originals[panorama.id] = originals;
          if (!existing.isComplete) _selected.add(panorama.id);
        });
      } on Object {
        // A previously downloaded batch can still be imported while offline.
      }
    }
  }

  Future<void> _loadOriginals(DwarfPanorama panorama) async {
    if (_originals.containsKey(panorama.id)) return;
    try {
      final originals = await _client!.listOriginals(panorama);
      if (!mounted) return;
      setState(() => _originals[panorama.id] = originals);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _toggleSelection(DwarfPanorama panorama, bool selected) async {
    setState(() {
      if (selected) {
        _selected.add(panorama.id);
      } else {
        _selected.remove(panorama.id);
      }
    });
    if (selected) await _loadOriginals(panorama);
  }

  Future<void> _downloadSelected() async {
    if (_downloading || _downloader == null || _client == null) return;
    final selectedPanoramas = _panoramas
        .where((panorama) => _selected.contains(panorama.id))
        .toList();
    setState(() {
      _downloading = true;
      _error = null;
      _activePanoramaTitle = selectedPanoramas.isEmpty
          ? null
          : selectedPanoramas.first.title;
    });
    for (final panorama in selectedPanoramas) {
      widget.onTransferStatus?.call(
        DwarfTransferStatus(
          batchId: _batchId(panorama),
          title: panorama.title,
          state: DwarfDownloadState.queued,
          completedBytes: 0,
          totalBytes: 0,
          completedFiles: 0,
          totalFiles: _originals[panorama.id]?.length ?? 0,
        ),
      );
    }
    final startedIds = <String>{};
    try {
      for (final panorama in selectedPanoramas) {
        if (mounted) setState(() => _activePanoramaTitle = panorama.title);
        final id = _batchId(panorama);
        startedIds.add(id);
        _activeBatchId = id;
        _activeBatchIds.add(id);
        if (mounted) setState(() {});
        final originals =
            _originals[panorama.id] ?? await _client!.listOriginals(panorama);
        if (mounted) setState(() => _originals[panorama.id] = originals);
        if (_backgroundPaused) {
          _activeBatchIds.remove(id);
          widget.onTransferStatus?.call(
            DwarfTransferStatus(
              batchId: id,
              title: panorama.title,
              state: DwarfDownloadState.paused,
              completedBytes: 0,
              totalBytes: originals.fold<int>(
                0,
                (sum, original) => sum + (original.size ?? 0),
              ),
              completedFiles: 0,
              totalFiles: originals.length,
            ),
          );
          break;
        }
        widget.onTransferStatus?.call(
          DwarfTransferStatus(
            batchId: id,
            title: panorama.title,
            state: DwarfDownloadState.downloading,
            completedBytes: 0,
            totalBytes: originals.fold<int>(
              0,
              (sum, original) => sum + (original.size ?? 0),
            ),
            completedFiles: 0,
            totalFiles: originals.length,
          ),
        );
        late final DwarfDownloadBatch batch;
        try {
          batch = await _downloader!.downloadBatch(
            batchId: id,
            originals: originals,
            metadata: {
              'panoramaId': panorama.id,
              'host': _client!.host,
              'deviceName': _device?.deviceName,
              'deviceId': _device?.deviceId,
              'serialNumber': _device?.serialNumber,
              'title': panorama.title,
              'capturedAt': panorama.capturedAt?.toIso8601String(),
            },
            onProgress: _onProgress,
          );
        } finally {
          _activeBatchIds.remove(id);
        }
        _batches[id] = batch;
        if (batch.isComplete) _importSelected.add(id);
        if (mounted) {
          setState(() {});
        }
        _publishStatus(batch, title: panorama.title);
        if (batch.state == DwarfDownloadState.cancelled) break;
      }
      if (_importSelected.isNotEmpty) {
        await _queueCompleted(openFirstTask: true);
      }
    } on Object catch (error) {
      final failedId = _activeBatchId;
      if (failedId != null) {
        widget.onTransferStatus?.call(
          DwarfTransferStatus(
            batchId: failedId,
            title: _activePanoramaTitle ?? failedId,
            state: DwarfDownloadState.failed,
            completedBytes: 0,
            totalBytes: 0,
            completedFiles: 0,
            totalFiles: 0,
          ),
        );
      }
      if (mounted) setState(() => _error = error.toString());
    } finally {
      for (final panorama in selectedPanoramas) {
        final id = _batchId(panorama);
        if (!startedIds.contains(id)) {
          widget.onTransferStatus?.call(
            DwarfTransferStatus(
              batchId: id,
              title: panorama.title,
              state: DwarfDownloadState.paused,
              completedBytes: 0,
              totalBytes: 0,
              completedFiles: 0,
              totalFiles: _originals[panorama.id]?.length ?? 0,
            ),
          );
        }
      }
      if (_activeBatchId != null) {
        _activeBatchIds.remove(_activeBatchId);
      }
      _downloading = false;
      if (mounted) {
        setState(() {
          _activePanoramaTitle = null;
        });
      }
      _activeBatchId = null;
      _closeOwnedDownloaderIfIdle();
    }
  }

  void _onProgress(DwarfDownloadProgress progress) {
    String? title;
    for (final panorama in _panoramas) {
      if (_batchId(panorama) == progress.batchId) {
        title = panorama.title;
        break;
      }
    }
    if (mounted) {
      setState(() => _progress[progress.batchId] = progress);
    }
    widget.onTransferStatus?.call(
      DwarfTransferStatus(
        batchId: progress.batchId,
        title: title ?? progress.batchId,
        state: DwarfDownloadState.downloading,
        completedBytes: progress.fileBytes,
        totalBytes: progress.fileSize,
        completedFiles: progress.completedFiles,
        totalFiles: progress.totalFiles,
      ),
    );
  }

  void _publishStatus(DwarfDownloadBatch batch, {String? title}) {
    final savedTitle = batch.metadata['title'];
    widget.onTransferStatus?.call(
      DwarfTransferStatus(
        batchId: batch.id,
        title: title ?? (savedTitle is String ? savedTitle : batch.id),
        state: batch.state,
        completedBytes: batch.completedBytes,
        totalBytes: batch.totalBytes,
        completedFiles: batch.files.where((file) => file.complete).length,
        totalFiles: batch.files.length,
      ),
    );
  }

  Future<void> _pause(String batchId) async {
    try {
      await _downloader?.cancelBatch(batchId);
      final batch = await _downloader?.loadBatch(batchId);
      if (batch != null) {
        if (mounted) {
          setState(() => _batches[batchId] = batch);
        }
        _publishStatus(batch);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _resume(String batchId) async {
    if (_activeBatchIds.isNotEmpty || _downloader == null) return;
    setState(() {
      _downloading = true;
      _error = null;
    });
    _activeBatchId = batchId;
    final savedTitle = _batches[batchId]?.metadata['title'];
    _activePanoramaTitle = savedTitle is String ? savedTitle : batchId;
    widget.onTransferStatus?.call(
      DwarfTransferStatus(
        batchId: batchId,
        title: _activePanoramaTitle!,
        state: DwarfDownloadState.downloading,
        completedBytes: _batches[batchId]?.completedBytes ?? 0,
        totalBytes: _batches[batchId]?.totalBytes ?? 0,
        completedFiles: 0,
        totalFiles: _batches[batchId]?.files.length ?? 0,
      ),
    );
    try {
      _activeBatchIds.add(batchId);
      late final DwarfDownloadBatch batch;
      try {
        batch = await _downloader!.resumeBatch(
          batchId,
          onProgress: _onProgress,
        );
      } finally {
        _activeBatchIds.remove(batchId);
        _activeBatchId = null;
      }
      _batches[batchId] = batch;
      if (batch.isComplete) _importSelected.add(batchId);
      _publishStatus(batch);
      if (mounted) setState(() {});
      if (batch.isComplete) await _queueCompleted(openFirstTask: true);
    } on Object catch (error) {
      widget.onTransferStatus?.call(
        DwarfTransferStatus(
          batchId: batchId,
          title: _activePanoramaTitle ?? batchId,
          state: DwarfDownloadState.failed,
          completedBytes: _batches[batchId]?.completedBytes ?? 0,
          totalBytes: _batches[batchId]?.totalBytes ?? 0,
          completedFiles: 0,
          totalFiles: _batches[batchId]?.files.length ?? 0,
        ),
      );
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _downloading = false;
      if (mounted) setState(() => _activePanoramaTitle = null);
      _activeBatchId = null;
      _closeOwnedDownloaderIfIdle();
    }
  }

  Future<String?> _queueCompleted({bool openFirstTask = false}) async {
    final batches = _batches.values
        .where(
          (batch) => batch.isComplete && _importSelected.contains(batch.id),
        )
        .toList();
    if (batches.isEmpty || _importing) return null;
    batches.sort((left, right) {
      final leftTitle = left.metadata['title'] as String? ?? left.id;
      final rightTitle = right.metadata['title'] as String? ?? right.id;
      final leftPanoramaIndex = _panoramas.indexWhere(
        (panorama) => _batchId(panorama) == left.id,
      );
      final rightPanoramaIndex = _panoramas.indexWhere(
        (panorama) => _batchId(panorama) == right.id,
      );
      if (leftPanoramaIndex >= 0 && rightPanoramaIndex >= 0) {
        return leftPanoramaIndex.compareTo(rightPanoramaIndex);
      }
      return leftTitle.compareTo(rightTitle);
    });
    if (mounted) setState(() => _importing = true);
    String? firstTaskId;
    try {
      await widget.settingsController?.ready;
      await widget.queueController.addCompletedPanoramas(
        batches,
        settings: widget.settingsController?.settings,
      );
      final bySource = <String, String>{};
      for (final queue in widget.queueController.queues) {
        for (final item in queue.items) {
          final taskId = item.taskId;
          if (taskId != null) bySource[item.sourceDirectory] = taskId;
        }
      }
      for (final batch in batches) {
        firstTaskId ??= bySource[batch.directory];
      }
      if (mounted && widget.queueController.error == null) {
        setState(() {
          _importSelected.removeAll(batches.map((batch) => batch.id));
        });
      }
      if (mounted && widget.queueController.error != null) {
        setState(() => _error = widget.queueController.error);
        firstTaskId = null;
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _importing = false;
      if (mounted) setState(() {});
      _closeOwnedDownloaderIfIdle();
    }
    if (openFirstTask && firstTaskId != null) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop<String>(firstTaskId);
      } else {
        await widget.onTaskReady?.call(firstTaskId);
      }
    }
    return firstTaskId;
  }

  Future<void> _openWifi() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final result = await (widget.networkService ?? DeviceNetworkService())
          .openWifiSettings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.opened
                  ? StitchLocalizations.of(context).dwarfWifiOpened
                  : StitchLocalizations.of(context).dwarfWifiManual,
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    if (_downloading || _importing) {
      _closeOwnedDownloaderWhenIdle = true;
    } else {
      WidgetsBinding.instance.removeObserver(this);
    }
    if (_ownsClient && !_downloading && !_importing) {
      _client?.close(force: true);
    }
    if (_ownsDownloader && !_downloading && !_importing) {
      _downloader?.close(force: false);
    }
    _host.dispose();
    super.dispose();
  }

  void _closeOwnedDownloaderIfIdle() {
    if (!_closeOwnedDownloaderWhenIdle || _downloading || _importing) return;
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsClient) _client?.close(force: true);
    if (_ownsDownloader) _downloader?.close(force: false);
    _closeOwnedDownloaderWhenIdle = false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = StitchLocalizations.of(context);
    final completeCount = _batches.values
        .where(
          (batch) => batch.isComplete && _importSelected.contains(batch.id),
        )
        .length;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.dwarfDeviceTitle)),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              key: const Key('dwarf-device-error-banner'),
              content: Text(l10n.dwarfDeviceError(_error!)),
              leading: const Icon(Icons.error_outline),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: Text(l10n.dwarfDismissError),
                ),
              ],
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: l10n.dwarfHost,
                    hintText: l10n.dwarfDefaultHostHint,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _connecting ? null : _connect,
                      icon: _connecting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: Text(
                        _client == null
                            ? l10n.dwarfConnect
                            : l10n.dwarfReconnect,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _opening ? null : _openWifi,
                      icon: const Icon(Icons.wifi),
                      label: Text(l10n.dwarfOpenWifi),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(l10n.dwarfConnectHint),
                if (_device != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.camera_alt_outlined),
                      title: Text(_device!.deviceName),
                      subtitle: Text(
                        _device!.serialNumber ?? _host.text.trim(),
                      ),
                      trailing: _device!.sdCardAvailable == false
                          ? const Icon(Icons.sd_card_alert_outlined)
                          : const Icon(Icons.check_circle_outline),
                    ),
                  ),
                ],
                if (_panoramas.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.dwarfSelectPanoramas,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final panorama in _panoramas) _panoramaTile(panorama),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _selected.isEmpty || _downloading
                        ? null
                        : _downloadSelected,
                    icon: _downloading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: Text(
                      _downloading
                          ? l10n.dwarfDownloading
                          : l10n.dwarfDownloadSelected,
                    ),
                  ),
                  if (_downloading) ...[
                    const SizedBox(height: 8),
                    Card(
                      key: const Key('dwarf-download-status'),
                      child: ListTile(
                        leading: const Icon(Icons.downloading_outlined),
                        title: Text(l10n.dwarfDownloading),
                        subtitle: Text(
                          '${_activePanoramaTitle ?? l10n.dwarfWaiting}\n${l10n.dwarfForegroundPowerHint}',
                        ),
                      ),
                    ),
                  ],
                ] else if (_client != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text(l10n.dwarfNoPanoramas)),
                  ),
                if (_batches.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.dwarfDownloadRestored,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final batch in _batches.values.where(
                    (value) => value.isComplete,
                  ))
                    CheckboxListTile(
                      value: _importSelected.contains(batch.id),
                      onChanged: (selected) => setState(() {
                        if (selected == true) {
                          _importSelected.add(batch.id);
                        } else {
                          _importSelected.remove(batch.id);
                        }
                      }),
                      title: Text(
                        batch.metadata['title'] as String? ??
                            p.basename(batch.directory),
                      ),
                      subtitle: Text(
                        '${batch.files.length} ${l10n.dwarfOriginalCount.toLowerCase()} · ${batch.metadata['deviceName'] ?? batch.metadata['host'] ?? p.basename(batch.directory)}',
                      ),
                      secondary: const Icon(Icons.check_circle_outline),
                    ),
                  for (final batch in _batches.values.where(
                    (value) => !value.isComplete,
                  ))
                    _savedBatchTile(batch),
                ],
                if (completeCount > 0) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _importing ? null : _queueCompleted,
                    icon: _importing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.playlist_add),
                    label: Text(
                      '${l10n.dwarfQueueCompleted} · ${l10n.dwarfDownloadedCount(completeCount)}',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _panoramaTile(DwarfPanorama panorama) {
    final l10n = StitchLocalizations.of(context);
    final batchId = _batchId(panorama);
    final batch = _batches[batchId];
    final progress = _progress[batchId];
    final selected = _selected.contains(panorama.id);
    final originals = _originals[panorama.id];
    final capturedAt = panorama.capturedAt?.toLocal().toString().substring(
      0,
      16,
    );
    final subtitle = <String>[
      capturedAt ?? '',
      ...?originals
          ?.take(1)
          .map(
            (_) =>
                '${originals.length} ${l10n.dwarfOriginalCount.toLowerCase()}',
          ),
      if (batch?.isComplete == true) l10n.dwarfDownloadComplete,
      if (batch != null && !batch.isComplete)
        '${l10n.dwarfByteProgress(batch.completedBytes, batch.totalBytes)} · ${l10n.dwarfDownloadState(batch.state.name)}',
      if (progress != null)
        '${progress.completedFiles}/${progress.totalFiles} · ${p.basename(progress.fileName)} · ${l10n.dwarfByteProgress(progress.fileBytes, progress.fileSize)}',
    ].where((value) => value.isNotEmpty).toList();
    return Card(
      child: Column(
        children: [
          CheckboxListTile(
            value: selected,
            onChanged: (value) => _toggleSelection(panorama, value == true),
            title: Text(
              panorama.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              subtitle.isEmpty ? l10n.dwarfWaiting : subtitle.join(' · '),
            ),
            secondary: Icon(
              batch?.isComplete == true
                  ? Icons.check_circle
                  : Icons.panorama_outlined,
            ),
          ),
          if ((batch != null && !batch.isComplete) ||
              _activeBatchIds.contains(batchId)) ...[
            LinearProgressIndicator(
              value: batch != null && batch.totalBytes > 0
                  ? (batch.completedBytes / batch.totalBytes).clamp(0, 1)
                  : progress != null && progress.fileSize > 0
                  ? (progress.fileBytes / progress.fileSize).clamp(0, 1)
                  : null,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _activeBatchIds.contains(batchId)
                    ? () => _pause(batchId)
                    : _downloading
                    ? null
                    : batch?.state == DwarfDownloadState.paused ||
                          batch?.state == DwarfDownloadState.failed ||
                          batch?.state == DwarfDownloadState.cancelled
                    ? () => _resume(batchId)
                    : () => _pause(batchId),
                icon: Icon(
                  batch?.state == DwarfDownloadState.paused ||
                          batch?.state == DwarfDownloadState.failed ||
                          batch?.state == DwarfDownloadState.cancelled
                      ? Icons.play_arrow
                      : Icons.pause,
                ),
                label: Text(
                  batch?.state == DwarfDownloadState.failed
                      ? l10n.dwarfRetryDownload
                      : batch?.state == DwarfDownloadState.cancelled
                      ? l10n.dwarfResumeDownload
                      : batch?.state == DwarfDownloadState.paused
                      ? l10n.dwarfResumeDownload
                      : l10n.dwarfPauseDownload,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _savedBatchTile(DwarfDownloadBatch batch) {
    final l10n = StitchLocalizations.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.downloading_outlined),
            title: Text(
              batch.metadata['title'] as String? ?? p.basename(batch.directory),
            ),
            subtitle: Text(
              '${l10n.dwarfByteProgress(batch.completedBytes, batch.totalBytes)} · ${l10n.dwarfDownloadState(batch.state.name)}',
            ),
          ),
          LinearProgressIndicator(
            value: batch.totalBytes == 0
                ? null
                : (batch.completedBytes / batch.totalBytes).clamp(0, 1),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _activeBatchIds.contains(batch.id)
                  ? () => _pause(batch.id)
                  : _downloading
                  ? null
                  : batch.state == DwarfDownloadState.paused ||
                        batch.state == DwarfDownloadState.failed ||
                        batch.state == DwarfDownloadState.cancelled
                  ? () => _resume(batch.id)
                  : () => _pause(batch.id),
              icon: Icon(
                batch.state == DwarfDownloadState.paused ||
                        batch.state == DwarfDownloadState.failed ||
                        batch.state == DwarfDownloadState.cancelled
                    ? Icons.play_arrow
                    : Icons.pause,
              ),
              label: Text(
                batch.state == DwarfDownloadState.failed
                    ? l10n.dwarfRetryDownload
                    : batch.state == DwarfDownloadState.cancelled
                    ? l10n.dwarfResumeDownload
                    : batch.state == DwarfDownloadState.paused
                    ? l10n.dwarfResumeDownload
                    : l10n.dwarfPauseDownload,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
