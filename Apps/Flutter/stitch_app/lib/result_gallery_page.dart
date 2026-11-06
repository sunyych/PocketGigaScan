import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;

import 'l10n/localized_text.dart';
import 'l10n/stitch_localizations.dart';
import 'models/app_settings.dart';
import 'models/stitch_task.dart';
import 'services/mobile_storage_service.dart';
import 'services/platform_file_dialogs.dart';
import 'services/result_library_service.dart';
import 'services/settings_controller.dart';
import 'services/task_repository.dart';
import 'services/task_thumbnail_service.dart';
import 'models/stitch_quality.dart';

class ResultGalleryPage extends StatefulWidget {
  const ResultGalleryPage({
    super.key,
    required this.repository,
    required this.service,
    required this.refreshListenable,
    required this.mobileStorageService,
    required this.isTaskBusy,
    required this.onTaskUpdated,
    required this.onOpenViewer,
    this.onAddBatch,
    this.settingsController,
    this.mobileOverride,
    this.androidOverride,
    this.directoryPickerOverride,
    this.mobileFolderPickerOverride,
  });

  final TaskRepository repository;
  final ResultLibraryService service;
  final ValueListenable<int> refreshListenable;
  final SettingsController? settingsController;
  final MobileStorageService mobileStorageService;
  final bool? mobileOverride;
  final bool? androidOverride;
  final Future<String?> Function()? directoryPickerOverride;
  final Future<OutputFolderSelection?> Function()? mobileFolderPickerOverride;
  final bool Function(String taskId) isTaskBusy;
  final Future<void> Function(StitchTask task) onTaskUpdated;
  final Future<void> Function(StitchTask task) onOpenViewer;
  final VoidCallback? onAddBatch;

  @override
  State<ResultGalleryPage> createState() => _ResultGalleryPageState();
}

class _ResultGalleryPageState extends State<ResultGalleryPage> {
  final TaskThumbnailService _thumbnails = TaskThumbnailService();
  final Set<String> _busyTasks = {};
  final Map<String, Future<File?>> _thumbnailFutures = {};
  final Map<String, Future<bool>> _exportExistsFutures = {};
  final Map<String, String> _taskDisplaySignatures = {};
  final Map<String, double> _exportProgress = {};
  List<StitchTask> _tasks = const [];
  late ResultGallerySort _sort =
      widget.settingsController?.settings.resultGallerySort ??
      ResultGallerySort.newestFirst;
  bool _loading = true;
  bool _savingSort = false;
  Object? _loadError;
  int _generation = 0;

  bool get _mobile =>
      widget.mobileOverride ?? (Platform.isAndroid || Platform.isIOS);
  bool get _android => widget.androidOverride ?? Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    widget.refreshListenable.addListener(_refreshFromRevision);
    unawaited(_loadSortPreference());
    unawaited(_loadTasks());
  }

  @override
  void dispose() {
    widget.refreshListenable.removeListener(_refreshFromRevision);
    super.dispose();
  }

  Future<void> _loadSortPreference() async {
    final settings = widget.settingsController;
    if (settings == null) return;
    await settings.ready;
    if (mounted) setState(() => _sort = settings.settings.resultGallerySort);
  }

  void _refreshFromRevision() => unawaited(_loadTasks());

  Future<void> _loadTasks() async {
    final generation = ++_generation;
    if (mounted) setState(() => _loading = true);
    try {
      final loaded = await widget.repository.loadAll();
      final completed = loaded.where(_isGalleryResult).toList(growable: false);
      if (!mounted || generation != _generation) return;
      final ids = completed.map((task) => task.id).toSet();
      final signatures = {
        for (final task in completed) task.id: _taskSignature(task),
      };
      final activeDisplaySignatures = signatures.values.toSet();
      _thumbnailFutures.removeWhere(
        (id, _) =>
            !ids.contains(id) || _taskDisplaySignatures[id] != signatures[id],
      );
      _exportExistsFutures.removeWhere(
        (signature, _) => !activeDisplaySignatures.contains(signature),
      );
      _taskDisplaySignatures
        ..removeWhere((id, _) => !ids.contains(id))
        ..addAll(signatures);
      setState(() {
        _tasks = completed;
        _loadError = null;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _changeSort(ResultGallerySort value) async {
    if (_savingSort) return;
    final previous = _sort;
    setState(() => _sort = value);
    final settings = widget.settingsController;
    if (settings == null) return;
    setState(() => _savingSort = true);
    try {
      await settings.updateWith(
        (current) => current.copyWith(resultGallerySort: value),
      );
      final saveError = settings.error;
      if (saveError != null) {
        await settings.updateWith(
          (current) => current.copyWith(resultGallerySort: previous),
        );
        if (mounted) {
          setState(() => _sort = previous);
          final rollbackError = settings.error;
          _showMessage(
            '${StitchLocalizations.of(context).text('无法保存排序偏好：')}'
            '$saveError${rollbackError == null ? '' : ' / $rollbackError'}',
          );
        }
      }
    } finally {
      if (mounted) setState(() => _savingSort = false);
    }
  }

  List<StitchTask> get _sortedTasks {
    final tasks = List<StitchTask>.of(_tasks);
    tasks.sort((left, right) {
      final leftName = ResultLibraryService.resultName(left).toLowerCase();
      final rightName = ResultLibraryService.resultName(right).toLowerCase();
      final nameOrder = leftName.compareTo(rightName);
      final dateOrder = right.createdAt.compareTo(left.createdAt);
      final order = switch (_sort) {
        ResultGallerySort.nameAscending =>
          nameOrder != 0 ? nameOrder : dateOrder,
        ResultGallerySort.nameDescending =>
          nameOrder != 0 ? -nameOrder : dateOrder,
        ResultGallerySort.newestFirst => dateOrder != 0 ? dateOrder : nameOrder,
        ResultGallerySort.oldestFirst =>
          left.createdAt.compareTo(right.createdAt) != 0
              ? left.createdAt.compareTo(right.createdAt)
              : nameOrder,
      };
      return order != 0 ? order : left.id.compareTo(right.id);
    });
    return tasks;
  }

  Future<File?> _thumbnailFor(StitchTask task) => _thumbnailFutures.putIfAbsent(
    task.id,
    () => _thumbnails.resultThumbnailFor(task),
  );

  bool _isGalleryResult(StitchTask task) =>
      task.phase == StitchPhase.completed ||
      (task.phase == StitchPhase.interrupted &&
          task.stage == 'result-library-export' &&
          task.exportCheckpointPath != null);

  String _taskSignature(StitchTask task) =>
      '${task.phase.name}|${task.stage}|${task.outputDirectory}|'
      '${task.exportPath}|${task.exportCheckpointPath}|'
      '${task.exportFingerprint?.toJson()}|${task.displayName ?? ''}';

  Future<bool> _exportExists(StitchTask task) =>
      _exportExistsFutures.putIfAbsent(_taskSignature(task), () async {
        final path = task.exportPath;
        if (path == null || path.isEmpty) return false;
        try {
          return await File(path).exists();
        } on Object {
          return false;
        }
      });

  bool _isBusy(StitchTask task) =>
      _busyTasks.contains(task.id) ||
      (!_isExportHandoff(task) && widget.isTaskBusy(task.id));

  bool _isExportHandoff(StitchTask task) =>
      task.phase == StitchPhase.interrupted &&
      task.stage == 'result-library-export' &&
      task.exportCheckpointPath != null;

  Future<void> _rename(StitchTask task) async {
    if (_isBusy(task) || task.phase != StitchPhase.completed) return;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _ResultRenameDialog(
        initialName: ResultLibraryService.resultName(task),
      ),
    );
    if (newName == null || newName.trim().isEmpty || !mounted) return;
    if (newName.trim() == ResultLibraryService.resultName(task)) return;
    await _runTaskOperation(
      task,
      () => widget.service.renameResult(task, newName.trim()),
      successMessage: '结果已重命名',
    );
  }

  Future<void> _export(StitchTask task) async {
    if (_isBusy(task) ||
        (task.phase != StitchPhase.completed && !_isExportHandoff(task))) {
      return;
    }
    final strings = StitchLocalizations.of(context);
    if (_mobile) {
      OutputFolderSelection? selection;
      try {
        selection = widget.mobileFolderPickerOverride != null
            ? await widget.mobileFolderPickerOverride!.call()
            : await widget.mobileStorageService.pickOutputFolder();
      } on Object catch (error) {
        _showMessage('${strings.text('选择导出文件夹失败：')}$error');
        return;
      }
      if (selection == null || !mounted) return;
      final sourcePath = task.exportPath;
      if (sourcePath == null || sourcePath.isEmpty) {
        _showMessage(strings.text('此结果没有可另存的整图文件'));
        return;
      }
      await _runMobileExport(task, selection, sourcePath);
      return;
    }
    String? directory;
    try {
      directory = widget.directoryPickerOverride != null
          ? await widget.directoryPickerOverride!.call()
          : await PlatformFileDialogs().getDirectoryPath(
              dialogTitle: strings.text('选择导出文件夹'),
              confirmButtonText: strings.chooseFolder,
            );
    } on Object catch (error) {
      _showMessage('${strings.text('选择导出文件夹失败：')}$error');
      return;
    }
    if (directory == null || directory.isEmpty || !mounted) return;
    await _runTaskOperation(
      task,
      () => widget.service.exportResultToDirectory(
        task,
        directory!,
        onProgress: (progress) {
          if (mounted) setState(() => _exportProgress[task.id] = progress);
        },
      ),
      successMessage: '结果已导出',
    );
  }

  Future<void> _runMobileExport(
    StitchTask task,
    OutputFolderSelection selection,
    String sourcePath,
  ) async {
    final strings = StitchLocalizations.of(context);
    if (!_beginTaskOperation(task)) return;
    try {
      final published = await widget.mobileStorageService.publishExport(
        sourcePath,
        destinationUri: selection.uri,
        mimeType: _mimeType(task.exportFormat),
        suggestedName:
            '${ResultLibraryService.resultName(task)}.${task.exportFormat.extension}',
      );
      _showMessage('${strings.text('已导出到')} ${published.displayName}');
    } on Object catch (error) {
      _showMessage('${strings.text('导出失败：')}$error');
    } finally {
      _endTaskOperation(task);
    }
  }

  Future<void> _runTaskOperation(
    StitchTask task,
    Future<StitchTask> Function() operation, {
    required String successMessage,
  }) async {
    if (!_beginTaskOperation(task)) return;
    final strings = StitchLocalizations.of(context);
    try {
      final updated = await operation();
      await widget.onTaskUpdated(updated);
      if (!mounted) return;
      _thumbnailFutures.remove(task.id);
      final staleSignature = _taskDisplaySignatures[task.id];
      if (staleSignature != null) {
        _exportExistsFutures.remove(staleSignature);
      }
      unawaited(_loadTasks());
      _showMessage(successMessage);
    } on Object catch (error) {
      if (mounted) {
        try {
          final latest = await widget.repository.loadById(task.id);
          if (latest != null) await widget.onTaskUpdated(latest);
        } on Object {
          // Keep the original operation error visible even if refreshing the
          // repository/cache also fails.
        }
        _thumbnailFutures.remove(task.id);
        final staleSignature = _taskDisplaySignatures.remove(task.id);
        if (staleSignature != null) {
          _exportExistsFutures.remove(staleSignature);
        }
        await _loadTasks();
        _showMessage('${strings.text('操作失败：')}$error');
      }
    } finally {
      _endTaskOperation(task);
    }
  }

  bool _beginTaskOperation(StitchTask task) {
    if (!mounted || _isBusy(task)) return false;
    setState(() {
      _busyTasks.add(task.id);
      _exportProgress.remove(task.id);
    });
    return true;
  }

  void _endTaskOperation(StitchTask task) {
    if (!mounted) return;
    setState(() {
      _busyTasks.remove(task.id);
      _exportProgress.remove(task.id);
    });
  }

  Future<void> _openViewer(StitchTask task) async {
    final path = task.exportPath;
    final exists = path != null && path.isNotEmpty && await File(path).exists();
    if (!mounted) return;
    if (!exists) {
      _showMessage(
        StitchLocalizations.of(context).text('整图文件不可用，请先导出到文件夹恢复整图'),
      );
      return;
    }
    if (_mobile && !_android) {
      _showMessage(
        StitchLocalizations.of(context).text('本期大图查看器仅在 Windows 桌面版提供。'),
      );
      return;
    }
    await widget.onOpenViewer(task);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(StitchLocalizations.of(context).text(message))),
    );
  }

  Widget _resultCard(StitchTask task) {
    final strings = StitchLocalizations.of(context);
    final busy = _isBusy(task);
    final progress = _exportProgress[task.id];
    return Card(
      key: Key('result-card-${task.id}'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 176,
            child: InkWell(
              key: Key('result-thumbnail-${task.id}'),
              onTap: () => _openViewer(task),
              child: FutureBuilder<File?>(
                future: _thumbnailFor(task),
                builder: (context, snapshot) {
                  final file = snapshot.data;
                  if (file == null) return _thumbnailPlaceholder(strings);
                  return Image.file(
                    file,
                    cacheWidth: 480,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) =>
                        _thumbnailPlaceholder(strings),
                  );
                },
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => _openViewer(task),
                    child: Text(
                      ResultLibraryService.resultName(task),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (_sourceDirectoryName(task).isNotEmpty &&
                      _sourceDirectoryName(task).toLowerCase() !=
                          ResultLibraryService.resultName(task).toLowerCase())
                    Text(
                      '${strings.text('来源：')}${_sourceDirectoryName(task)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 4),
                  Text(
                    formatTaskDateTime(
                      task.createdAt,
                      widget.settingsController?.settings.taskDateFormat ??
                          TaskDateFormat.yearMonthDay,
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(
                          Icons.check_circle_outline,
                          size: 18,
                        ),
                        label: Text(
                          strings.text(
                            task.phase == StitchPhase.completed
                                ? '已完成'
                                : '导出待恢复',
                          ),
                        ),
                      ),
                      FutureBuilder<bool>(
                        future: _exportExists(task),
                        builder: (context, snapshot) => Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(
                            snapshot.data == false
                                ? Icons.warning_amber_outlined
                                : Icons.image_outlined,
                            size: 18,
                          ),
                          label: Text(
                            snapshot.data == false
                                ? strings.text('导出文件不可用')
                                : task.exportFormat.label,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (busy) LinearProgressIndicator(value: progress),
                  Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      IconButton(
                        key: Key('result-rename-${task.id}'),
                        tooltip: strings.text('修改结果名称'),
                        onPressed: busy ? null : () => _rename(task),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        key: Key('result-export-${task.id}'),
                        tooltip: strings.text('导出到文件夹'),
                        onPressed: busy ? null : () => _export(task),
                        icon: const Icon(Icons.drive_file_move_outlined),
                      ),
                      IconButton(
                        key: Key('result-view-${task.id}'),
                        tooltip: strings.text('打开全景查看器'),
                        onPressed: () => _openViewer(task),
                        icon: const Icon(Icons.zoom_in),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumbnailPlaceholder(StitchLocalizations strings) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.panorama_outlined, size: 42),
          const SizedBox(height: 6),
          Text(strings.text('预览不可用；点击查看详情')),
        ],
      ),
    ),
  );

  String _sourceDirectoryName(StitchTask task) {
    final normalized = task.sourceDirectory
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty) return '';
    return p.posix.basename(normalized);
  }

  Widget _emptyState(StitchLocalizations strings) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined, size: 52),
          const SizedBox(height: 12),
          Text(strings.text('暂无已完成的合成结果')),
          Text(strings.text('完成单张或批量合成后，结果会显示在这里。')),
          if (widget.onAddBatch != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('result-gallery-add-batch'),
              onPressed: widget.onAddBatch,
              icon: const Icon(Icons.add_to_photos_outlined),
              label: Text(strings.text('添加批量任务')),
            ),
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final strings = StitchLocalizations.of(context);
    final sorted = _sortedTasks;
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final columns = MediaQuery.sizeOf(context).width < 600
        ? 1
        : MediaQuery.sizeOf(context).width < 1080
        ? 2
        : 3;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.text('结果画廊')),
        actions: [
          PopupMenuButton<ResultGallerySort>(
            key: const Key('result-gallery-sort'),
            tooltip: strings.text('排序结果'),
            initialValue: _sort,
            onSelected: _savingSort ? null : _changeSort,
            itemBuilder: (context) => [
              for (final sort in ResultGallerySort.values)
                PopupMenuItem(
                  value: sort,
                  child: Text(strings.text(_sortLabel(sort))),
                ),
            ],
            icon: const Icon(Icons.sort),
          ),
          IconButton(
            key: const Key('result-gallery-refresh'),
            tooltip: strings.text('刷新结果'),
            onPressed: _loading ? null : _loadTasks,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading && _tasks.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null && _tasks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(strings.text('无法读取已保存的合成记录')),
                  TextButton.icon(
                    onPressed: _loadTasks,
                    icon: const Icon(Icons.refresh),
                    label: Text(strings.text('重试')),
                  ),
                ],
              ),
            )
          : sorted.isEmpty
          ? _emptyState(strings)
          : LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                key: const Key('result-gallery-grid'),
                padding: const EdgeInsets.all(16),
                itemCount: sorted.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: 390 + ((textScale - 1) * 260).clamp(0, 480),
                ),
                itemBuilder: (context, index) => _resultCard(sorted[index]),
              ),
            ),
    );
  }

  String _sortLabel(ResultGallerySort sort) => switch (sort) {
    ResultGallerySort.nameAscending => '名称 A–Z',
    ResultGallerySort.nameDescending => '名称 Z–A',
    ResultGallerySort.newestFirst => '最新优先',
    ResultGallerySort.oldestFirst => '最早优先',
  };

  String _mimeType(ExportFormat format) => switch (format) {
    ExportFormat.png => 'image/png',
    ExportFormat.tiff => 'image/tiff',
    ExportFormat.jpeg => 'image/jpeg',
    ExportFormat.jpegXl => 'image/jxl',
  };
}

class _ResultRenameDialog extends StatefulWidget {
  const _ResultRenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_ResultRenameDialog> createState() => _ResultRenameDialogState();
}

class _ResultRenameDialogState extends State<_ResultRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(StitchLocalizations.of(context).text('修改结果名称')),
    content: TextField(
      key: const Key('result-rename-field'),
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: StitchLocalizations.of(context).text('名称'),
      ),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(StitchLocalizations.of(context).text('取消')),
      ),
      FilledButton(
        key: const Key('result-rename-save'),
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(StitchLocalizations.of(context).text('保存')),
      ),
    ],
  );
}
