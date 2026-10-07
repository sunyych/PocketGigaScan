import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;

import 'models/batch_queue.dart';
import 'models/stitch_quality.dart';
import 'services/batch_queue_controller.dart';
import 'services/native_job_api.dart';
import 'services/mobile_storage_service.dart';
import 'services/mobile_runtime_service.dart';
import 'services/platform_file_dialogs.dart';
import 'services/settings_controller.dart';
import 'services/power_service.dart';
import 'models/stitch_task.dart';
import 'dwarf_device_page.dart';
import 'services/dwarf_download_service.dart';
import 'widgets/exported_image_viewer.dart';
import 'l10n/localized_text.dart';
import 'l10n/stitch_localizations.dart';

class BatchQueuePage extends StatefulWidget {
  const BatchQueuePage({
    super.key,
    required this.api,
    this.controller,
    this.mobileOverride,
    this.androidOverride,
    this.mobileStorageService,
    this.runtimeService,
    this.resourceBudget,
    this.settingsController,
    this.deviceDownloader,
    this.onTransferStatus,
    this.onDeviceTaskReady,
  });
  final JobApi api;
  final BatchQueueController? controller;
  final bool? mobileOverride;
  final bool? androidOverride;
  final MobileStorageService? mobileStorageService;
  final MobileRuntimeService? runtimeService;
  final MobileResourceBudget? resourceBudget;
  final SettingsController? settingsController;
  final DwarfDownloadService? deviceDownloader;
  final ValueChanged<DwarfTransferStatus>? onTransferStatus;
  final Future<void> Function(String taskId)? onDeviceTaskReady;

  @override
  State<BatchQueuePage> createState() => _BatchQueuePageState();
}

class _BatchQueuePageState extends State<BatchQueuePage> {
  late final bool _ownsController = widget.controller == null;
  late final BatchQueueController _controller =
      widget.controller ??
      BatchQueueController(
        api: widget.api,
        storageService:
            widget.mobileStorageService ?? const MobileStorageService(),
      );
  bool _busy = false;
  bool _jxlAvailable = false;
  late final MobileStorageService _storage =
      widget.mobileStorageService ?? const MobileStorageService();
  bool get _mobile =>
      widget.mobileOverride ?? (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _controller.requireLargeJobApproval = _mobile;
    if (_ownsController) _controller.initialize();
    _refreshFormatCapabilities();
  }

  Future<void> _refreshFormatCapabilities() async {
    try {
      final response = await widget.api.capabilities();
      final caps = response['capabilities'] as Map<String, Object?>?;
      if (mounted) {
        setState(() => _jxlAvailable = caps?['jpegXlAvailable'] == true);
      }
    } on Object {
      if (mounted) setState(() => _jxlAvailable = false);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _openDwarfDevice() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => DwarfDevicePage(
          queueController: _controller,
          settingsController: widget.settingsController,
          downloader: widget.deviceDownloader,
          onTransferStatus: widget.onTransferStatus,
          onTaskReady: (taskId) async {
            if (mounted && ModalRoute.of(context)?.isCurrent == true) {
              Navigator.of(context).pop<String>(taskId);
            } else {
              await widget.onDeviceTaskReady?.call(taskId);
            }
          },
        ),
      ),
    );
    if (result != null &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true &&
        Navigator.of(context).canPop()) {
      Navigator.of(context).pop<String>(result);
    } else if (result != null) {
      await widget.onDeviceTaskReady?.call(result);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _selectParent() async {
    if (_busy) return;
    await widget.settingsController?.ready;
    if (!mounted) return;
    String? path;
    try {
      path = _mobile
          ? await _storage.pickBatchParent()
          : await PlatformFileDialogs().getDirectoryPath(
              dialogTitle: StitchLocalizations.of(
                context,
              ).chooseBatchParentFolder,
              confirmButtonText: StitchLocalizations.of(context).chooseFolder,
            );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              StitchLocalizations.of(
                context,
              ).folderSelectionFailed(error.toString()),
            ),
          ),
        );
      }
      return;
    }
    if (path == null) return;
    if (!mounted) {
      if (_mobile) await _storage.releaseBatchParent(path);
      return;
    }
    var selectedFormat =
        widget.settingsController?.settings.exportFormat ?? ExportFormat.tiff;
    final format = await showDialog<ExportFormat>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('批量整图格式'),
          content: RadioGroup<ExportFormat>(
            groupValue: selectedFormat,
            onChanged: (value) {
              if (value != null &&
                  (value != ExportFormat.jpegXl || _jxlAvailable)) {
                setDialogState(() => selectedFormat = value);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final candidate in ExportFormat.values)
                  RadioListTile<ExportFormat>(
                    value: candidate,
                    enabled: candidate != ExportFormat.jpegXl || _jxlAvailable,
                    title: Text(
                      candidate == ExportFormat.jpegXl && !_jxlAvailable
                          ? 'JPEG XL（需随程序加载 libjxl）'
                          : candidate.label,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selectedFormat),
              child: const Text('继续'),
            ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) {
      if (_mobile) await _storage.releaseBatchParent(path);
      return;
    }
    setState(() => _busy = true);
    try {
      await _controller.addParent(
        path,
        outputFormat: format,
        settings: widget.settingsController?.settings,
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法加入批处理：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _settings(BatchQueue queue, BatchQueueItem item) async {
    final initial = await _controller.settingsFor(queue.id, item.id);
    if (!mounted) return;
    final rows = TextEditingController(text: '${initial.$1}');
    final columns = TextEditingController(text: '${initial.$2}');
    final fov = TextEditingController(text: '${initial.$3}');
    final result = await showDialog<(int, int, double)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('设置 ${item.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: rows,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: StitchLocalizations.of(context).text('行数'),
              ),
            ),
            TextField(
              controller: columns,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: StitchLocalizations.of(context).text('列数'),
              ),
            ),
            TextField(
              controller: fov,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: StitchLocalizations.of(context).text('水平视角（度）'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () {
              final r = int.tryParse(rows.text),
                  c = int.tryParse(columns.text),
                  f = double.tryParse(fov.text);
              if (r != null && c != null && f != null) {
                Navigator.pop(context, (r, c, f));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    rows.dispose();
    columns.dispose();
    fov.dispose();
    if (result == null) return;
    try {
      await _controller.setSettings(
        queueId: queue.id,
        itemId: item.id,
        rows: result.$1,
        columns: result.$2,
        horizontalFovDegrees: result.$3,
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _resourceSettings() async {
    try {
      var budget = widget.resourceBudget;
      if (_mobile && widget.runtimeService != null) {
        try {
          budget = await widget.runtimeService!.readResourceBudget();
        } on Object {
          // Use the last valid reading and the native configured values.
        }
      }
      final response = await widget.api.capabilities();
      final caps =
          response['capabilities'] as Map<String, Object?>? ?? const {};
      if (!mounted) return;
      final cpu = TextEditingController(
        text:
            '${budget?.recommendedTotalCpuWorkers ?? caps['totalCpuWorkers'] ?? 1}',
      );
      final memory = TextEditingController(
        text:
            '${budget?.recommendedTotalMemoryBudgetMiB ?? caps['totalMemoryBudgetMiB'] ?? (_mobile ? 128 : 1024)}',
      );
      final jobs = TextEditingController(
        text:
            '${budget?.recommendedMaxConcurrentJobs ?? caps['maxConcurrentJobs'] ?? (_mobile ? 1 : 2)}',
      );
      final values = await showDialog<(int, int, int)>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('批处理资源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: cpu,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: StitchLocalizations.of(context).text('总 CPU 工作线程'),
                ),
              ),
              TextField(
                controller: memory,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: StitchLocalizations.of(context).text('总内存预算（MiB）'),
                ),
              ),
              TextField(
                controller: jobs,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: StitchLocalizations.of(
                    context,
                  ).text('并发任务数（最多 8）'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final a = int.tryParse(cpu.text),
                    b = int.tryParse(memory.text),
                    c = int.tryParse(jobs.text);
                if (a != null && b != null && c != null) {
                  Navigator.pop(context, (a, b, c));
                }
              },
              child: const Text('应用'),
            ),
          ],
        ),
      );
      cpu.dispose();
      memory.dispose();
      jobs.dispose();
      if (values == null) return;
      final safeValues = budget == null
          ? values
          : (
              values.$1.clamp(1, budget.recommendedTotalCpuWorkers).toInt(),
              values.$2
                  .clamp(128, budget.recommendedTotalMemoryBudgetMiB)
                  .toInt(),
              values.$3.clamp(1, budget.recommendedMaxConcurrentJobs).toInt(),
            );
      await widget.api.configureResources(
        totalCpuWorkers: safeValues.$1,
        totalMemoryBudgetMiB: safeValues.$2,
        maxConcurrentJobs: safeValues.$3,
      );
      if (safeValues != values && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已按设备当前资源限制并发参数。')));
      }
      await _controller.tick();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('资源设置失败：$error')));
      }
    }
  }

  Future<void> _removeItem(BatchQueue queue, BatchQueueItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地任务？'),
        content: const Text('只移除任务记录和队列项目。原片、渲染瓦片及已导出照片都会保留。处理中任务会先请求停止。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除任务记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _controller.removeQueueItem(queue.id, item.id);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('没有删除队列项目：$error')));
      }
    }
  }

  Future<void> _openCompleted(BatchQueueItem item) async {
    final task = await _controller.taskForItem(item);
    if (!mounted) return;
    if (task == null ||
        task.phase != StitchPhase.completed ||
        task.exportPath == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('找不到已完成任务的导出照片。')));
      return;
    }
    var nativeVerified = false;
    if (task.exportFingerprint == null && task.nativeJobId != null) {
      try {
        final status = await widget.api.status(task.nativeJobId!);
        nativeVerified =
            status['state'] == 'completed' &&
            status['operation'] == 'export' &&
            status['exportDestination'] is String &&
            nativeJobPathsMatch(
              status['exportDestination']! as String,
              task.exportPath!,
            );
      } on Object {
        // The viewer identifies this retained task-record link as unverified.
      }
    }
    if (!mounted) return;
    final traceRecord = await _controller
        .taskRecordFor(task.id)
        .catchError((Object _) => null);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ExportedImageViewer(
          exportFilePath: task.exportPath!,
          pyramidDirectory: task.outputDirectory,
          expectedExportFingerprint: task.exportFingerprint,
          legacyTaskAssociationPresent: true,
          legacyTaskBindingVerified: nativeVerified,
          traceRecord: traceRecord,
          mobileStorageService: _mobile ? _storage : null,
          exportMimeType: switch (task.exportFormat) {
            ExportFormat.png => 'image/png',
            ExportFormat.tiff => 'image/tiff',
            ExportFormat.jpegXl => 'image/jxl',
          },
        ),
      ),
    );
  }

  Future<void> _confirmBatchJob(BatchQueue queue, BatchQueueItem item) async {
    final task = await _controller.taskForItem(item);
    if (!mounted || task == null || !task.needsLargeJobConfirmation) return;
    final power = await PlatformPowerGate().readState();
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(StitchLocalizations.of(context).text('确认大型任务')),
        content: Text(
          StitchLocalizations.of(context).largeJobConfirmation(
            rows: task.grid.rows,
            columns: task.grid.columns,
            photoCount: task.photos.length,
            onBattery: power != PowerState.externalPower && _mobile,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(StitchLocalizations.of(context).text('批准并开始')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _controller.approveLargeJob(queue.id, item.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('批处理队列'),
      actions: [
        if (_mobile)
          IconButton(
            tooltip: StitchLocalizations.of(context).dwarfDeviceImport,
            onPressed: _openDwarfDevice,
            icon: const Icon(Icons.camera_alt_outlined),
          ),
        IconButton(
          tooltip: StitchLocalizations.of(context).text('批处理资源设置'),
          onPressed: _resourceSettings,
          icon: const Icon(Icons.tune),
        ),
        IconButton(
          tooltip: StitchLocalizations.of(context).text('选择母目录'),
          onPressed: _busy ? null : _selectParent,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
      ],
    ),
    body: _controller.loading && _controller.queues.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_controller.error != null) _errorBanner(_controller.error!),
              if (_busy || _controller.loading) ...[
                const LinearProgressIndicator(),
                const ListTile(
                  dense: true,
                  leading: Icon(Icons.folder_open),
                  title: Text('正在导入子目录；已加入队列的任务会继续处理。'),
                ),
              ],
              if (_controller.queues.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      children: [
                        const Icon(Icons.queue, size: 44),
                        const SizedBox(height: 12),
                        const Text('选择一个母目录；每个直接子目录会成为独立全景任务。'),
                        if (_mobile)
                          Text(
                            StitchLocalizations.of(
                              context,
                            ).text('移动端将文件夹复制到应用私有暂存目录，再逐个导入其中的原片。'),
                          ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _busy ? null : _selectParent,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('选择母目录'),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _selectParent,
                    icon: const Icon(Icons.add),
                    label: const Text('添加批次'),
                  ),
                ),
                for (final queue in _controller.queues) ...[
                  _queueHeader(queue),
                  for (final item in queue.items) _itemCard(queue, item),
                  const SizedBox(height: 12),
                ],
              ],
            ],
          ),
  );

  Widget _queueHeader(BatchQueue queue) {
    final completed = queue.items
        .where((item) => item.state == BatchItemState.completed)
        .length;
    final active = queue.items
        .where(
          (item) =>
              item.state == BatchItemState.running ||
              item.state == BatchItemState.exporting,
        )
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          const Icon(Icons.folder_copy_outlined),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(queue.parentDirectory),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '$completed/${queue.items.length} 已导出 · $active 项处理中',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '整图格式：${queue.outputFormat.label}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: StitchLocalizations.of(context).text('资源设置'),
            onPressed: _resourceSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }

  Widget _itemCard(BatchQueue queue, BatchQueueItem item) {
    final active =
        item.state == BatchItemState.running ||
        item.state == BatchItemState.exporting;
    final progress = item.progress.clamp(0, 1).toDouble();
    return Card(
      key: Key('batch-item-${item.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                Icon(_iconFor(item.state), color: _colorFor(item.state)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        translate: false,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _detail(item),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (item.state == BatchItemState.needsSettings)
                  IconButton(
                    tooltip: StitchLocalizations.of(context).text('设置行列与相机视角'),
                    onPressed: () => _settings(queue, item),
                    icon: const Icon(Icons.tune),
                  )
                else if (item.state == BatchItemState.needsApproval)
                  IconButton(
                    tooltip: StitchLocalizations.of(context).text('确认大型任务'),
                    onPressed: () => _confirmBatchJob(queue, item),
                    icon: const Icon(Icons.warning_amber_outlined),
                  )
                else if (active || item.state == BatchItemState.ready) ...[
                  IconButton(
                    tooltip: StitchLocalizations.of(context).text('暂停任务'),
                    onPressed: () => _controller.pause(queue.id, item.id),
                    icon: const Icon(Icons.pause_circle_outline),
                  ),
                  IconButton(
                    tooltip: StitchLocalizations.of(context).text('取消任务'),
                    onPressed: () => _controller.cancel(queue.id, item.id),
                    icon: const Icon(Icons.cancel_outlined),
                  ),
                ] else if (item.state == BatchItemState.failed ||
                    item.state == BatchItemState.cancelled ||
                    item.state == BatchItemState.paused)
                  IconButton(
                    tooltip: StitchLocalizations.of(context).text('重试或继续'),
                    onPressed: () => _controller.retry(queue.id, item.id),
                    icon: const Icon(Icons.refresh),
                  ),
                if (item.state == BatchItemState.completed)
                  IconButton(
                    tooltip: StitchLocalizations.of(context).text('打开全景查看器'),
                    onPressed: () => _openCompleted(item),
                    icon: const Icon(Icons.zoom_in),
                  ),
                if (item.state == BatchItemState.completed &&
                    (item.message?.contains('发布失败') ?? false))
                  IconButton(
                    tooltip: StitchLocalizations.of(context).text('重试发布整图'),
                    onPressed: () =>
                        _controller.retryPublish(queue.id, item.id),
                    icon: const Icon(Icons.upload_file),
                  ),
                IconButton(
                  tooltip: StitchLocalizations.of(context).text('删除本地任务记录'),
                  onPressed: () => _removeItem(queue, item),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (active ||
                (item.state != BatchItemState.completed &&
                    item.progress > 0)) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress.clamp(0, 1)),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${(progress * 100).round()}%${item.etaSeconds == null ? '' : ' · 本阶段预计剩余 ${_formatEta(item.etaSeconds!)}'}',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _detail(BatchQueueItem item) {
    if (item.state == BatchItemState.ready && item.estimatedLayout) {
      return '${item.message ?? '估算布局'} · 估算排列，建议检查';
    }
    final stateText =
        item.message ??
        switch (item.state) {
          BatchItemState.pending => '等待资源',
          BatchItemState.needsSettings => '需要处理设置',
          BatchItemState.needsApproval => '等待大型任务确认',
          BatchItemState.skipped => '已跳过',
          BatchItemState.ready => '等待开始',
          BatchItemState.running => '合成中',
          BatchItemState.exporting => '导出整图',
          BatchItemState.paused => '已暂停',
          BatchItemState.cancelled => '已取消',
          BatchItemState.failed => '需要处理',
          BatchItemState.completed => '整图已导出',
        };
    if (item.pauseRequested && item.state == BatchItemState.running) {
      return '正在暂停 · ${_formatElapsed(item.elapsedSeconds)}';
    }
    if (item.state == BatchItemState.running ||
        item.state == BatchItemState.exporting) {
      return '$stateText · ${_formatElapsed(item.elapsedSeconds)}';
    }
    return stateText;
  }

  IconData _iconFor(BatchItemState state) => switch (state) {
    BatchItemState.completed => Icons.check_circle,
    BatchItemState.failed => Icons.error_outline,
    BatchItemState.skipped => Icons.remove_circle_outline,
    BatchItemState.running || BatchItemState.exporting => Icons.autorenew,
    BatchItemState.paused ||
    BatchItemState.cancelled => Icons.pause_circle_outline,
    BatchItemState.needsSettings => Icons.tune,
    BatchItemState.needsApproval => Icons.warning_amber_outlined,
    _ => Icons.schedule,
  };

  Color? _colorFor(BatchItemState state) => switch (state) {
    BatchItemState.completed => Colors.green,
    BatchItemState.failed ||
    BatchItemState.needsSettings => Theme.of(context).colorScheme.error,
    BatchItemState.needsApproval => Theme.of(context).colorScheme.tertiary,
    BatchItemState.skipped => Theme.of(context).disabledColor,
    _ => null,
  };

  String _formatEta(int seconds) =>
      seconds < 60 ? '$seconds 秒' : '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  String _formatElapsed(int seconds) => seconds < 60
      ? '已用 $seconds 秒'
      : '已用 ${seconds ~/ 60} 分 ${seconds % 60} 秒';
  Widget _errorBanner(String value) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(padding: const EdgeInsets.all(12), child: Text(value)),
  );
}
