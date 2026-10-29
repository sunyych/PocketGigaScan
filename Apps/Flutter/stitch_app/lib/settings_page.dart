import 'package:flutter/material.dart';
import 'services/scene_model_service.dart';
import 'widgets/scene_model_dialog.dart';
import 'models/app_settings.dart';
import 'models/stitch_quality.dart';
import 'services/settings_controller.dart';
import 'services/mobile_storage_service.dart';
import 'services/platform_file_dialogs.dart';
import 'services/memory_budget_policy.dart';
import 'l10n/stitch_localizations.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    this.android = false,
    this.mobile = false,
    this.memoryReading,
    this.mobileStorageService,
    this.sceneModelService,
    this.supportsSceneOptions = false,
    this.activeTasks = false,
  });
  final SettingsController controller;
  final bool android;
  final bool mobile;
  final MemoryResourceReading? memoryReading;
  final MobileStorageService? mobileStorageService;
  final Future<SceneModelService>? sceneModelService;
  final bool supportsSceneOptions;
  final bool activeTasks;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int? _draggingMemoryMiB;
  double? _draggingTextScale;

  @override
  Widget build(BuildContext context) {
    final l = StitchLocalizations.of(context);
    final reading =
        widget.memoryReading ??
        MemoryResourceReading(
          totalMemoryMiB: 0,
          availableMemoryMiB: 0,
          valid: false,
          source: 'fallback',
        );
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final s = widget.controller.settings;
          final memory = MemoryBudgetPolicy.evaluate(
            s,
            reading,
            mobile: widget.mobile,
          );
          final memorySliderValue = MemoryBudgetPolicy.sliderValue(
            _draggingMemoryMiB ?? memory.selectedMiB,
            memory.maximumMiB,
          );
          final stackedDropdowns = _useStackedDropdowns(context);
          return ListView(
            children: [
              _selectionControl<AppLanguage>(
                context: context,
                title: l.language,
                stacked: stackedDropdowns,
                value: s.language,
                items: AppLanguage.values
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(l.settingsOption(v.name)),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    widget.controller.update(s.copyWith(language: v));
                  }
                },
              ),
              _selectionControl<AppThemeMode>(
                context: context,
                title: l.appearance,
                stacked: stackedDropdowns,
                value: s.themeMode,
                items: AppThemeMode.values
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(l.settingsOption(v.name)),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    widget.controller.update(s.copyWith(themeMode: v));
                  }
                },
              ),
              _selectionControl<AppAccent>(
                context: context,
                title: l.accentColor,
                stacked: stackedDropdowns,
                value: s.accent,
                items: AppAccent.values
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(l.settingsOption(v.name)),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    widget.controller.update(s.copyWith(accent: v));
                  }
                },
              ),
              ExpansionTile(
                key: const Key('text-size-settings'),
                title: Text(l.text('文字大小')),
                subtitle: Text(
                  s.textSizeMode == TextSizeMode.system
                      ? l.text('跟随系统')
                      : '${l.text('手动')} · ${_textScaleLabel(s.effectiveTextScale)}',
                ),
                children: [
                  SwitchListTile(
                    key: const Key('text-size-follow-system'),
                    title: Text(l.text('跟随系统文字大小')),
                    subtitle: Text(l.text('关闭后可手动调整应用内文字大小。')),
                    value: s.textSizeMode == TextSizeMode.system,
                    onChanged: (followSystem) {
                      _draggingTextScale = null;
                      widget.controller.updateWith(
                        (latest) => latest.copyWith(
                          textSizeMode: followSystem
                              ? TextSizeMode.system
                              : TextSizeMode.custom,
                        ),
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('text-size-150'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          icon: const Icon(Icons.text_increase),
                          label: Text(l.text('大字体 150%')),
                          onPressed: () => _setTextScale(1.5),
                        ),
                        TextButton.icon(
                          key: const Key('text-size-100'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          icon: const Icon(Icons.restart_alt),
                          label: Text(l.text('恢复 100%')),
                          onPressed: () => _setTextScale(1.0),
                        ),
                      ],
                    ),
                  ),
                  if (s.textSizeMode == TextSizeMode.custom) ...[
                    ListTile(
                      title: Text(l.text('当前大小')),
                      trailing: Text(
                        _textScaleLabel(
                          _draggingTextScale ?? s.effectiveTextScale,
                        ),
                        key: const Key('text-size-value'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Slider(
                      key: const Key('text-size-slider'),
                      value: (_draggingTextScale ?? s.effectiveTextScale).clamp(
                        1.0,
                        2.0,
                      ),
                      min: 1.0,
                      max: 2.0,
                      divisions: 10,
                      label: _textScaleLabel(
                        _draggingTextScale ?? s.effectiveTextScale,
                      ),
                      onChanged: (value) => setState(
                        () => _draggingTextScale = value.clamp(1.0, 2.0),
                      ),
                      onChangeEnd: (value) {
                        _draggingTextScale = null;
                        widget.controller.updateWith(
                          (latest) => latest.copyWith(
                            textSizeMode: TextSizeMode.custom,
                            textScale: value.clamp(1.0, 2.0),
                          ),
                        );
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: MediaQuery(
                            data: s.textSizeMode == TextSizeMode.custom
                                ? MediaQuery.of(context).copyWith(
                                    textScaler: TextScaler.linear(
                                      _draggingTextScale ??
                                          s.effectiveTextScale,
                                    ),
                                  )
                                : MediaQuery.of(context),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.text('实时预览')),
                                const SizedBox(height: 8),
                                Text(
                                  l.text('文字会按当前大小显示。'),
                                  key: const Key('text-size-preview'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              ExpansionTile(
                title: Text(l.outputQuality),
                children: [
                  _selectionControl<ExportFormat>(
                    context: context,
                    title: l.outputFormat,
                    subtitle: s.exportFormat == ExportFormat.jpeg
                        ? l.text(
                            'JPEG：质量 90，有损压缩；透明区域铺白底；超过 65500 像素的边长会按比例缩小。',
                          )
                        : null,
                    stacked: stackedDropdowns,
                    value: s.exportFormat,
                    items: ExportFormat.values
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(l.text(v.label)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        widget.controller.update(
                          s.copyWith(
                            exportFormat: v,
                            exportFormatExplicitlySet: true,
                          ),
                        );
                      }
                    },
                  ),
                  SwitchListTile(
                    title: Text(l.refineNeighbors),
                    value: s.refineGridNeighbors,
                    onChanged: (v) => widget.controller.update(
                      s.copyWith(refineGridNeighbors: v),
                    ),
                  ),
                  _selectionControl<SeamBlendMode>(
                    context: context,
                    title: l.seamBlend,
                    stacked: stackedDropdowns,
                    value: s.seamBlendMode,
                    items: SeamBlendMode.values
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(l.settingsOption(v.name)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        widget.controller.update(s.copyWith(seamBlendMode: v));
                      }
                    },
                  ),
                  SwitchListTile(
                    title: Text(l.localTextureWarp),
                    value: s.localTextureWarp,
                    onChanged: (v) => widget.controller.update(
                      s.copyWith(localTextureWarp: v),
                    ),
                  ),
                  if (widget.supportsSceneOptions) ...[
                    SwitchListTile(
                      key: const Key('protect-people-default'),
                      title: Text(l.protectPeople),
                      subtitle: Text(l.protectPeopleHelp),
                      value: s.protectPeople,
                      onChanged: (value) async {
                        await widget.controller.update(
                          s.copyWith(protectPeople: value),
                        );
                        if (value &&
                            widget.sceneModelService != null &&
                            context.mounted) {
                          await showSceneModelDialog(
                            context,
                            widget.sceneModelService!,
                          );
                        }
                      },
                    ),
                    SwitchListTile(
                      key: const Key('smooth-water-default'),
                      title: Text(l.smoothWater),
                      subtitle: Text(l.smoothWaterHelp),
                      value: s.smoothWater,
                      onChanged: (value) async {
                        await widget.controller.update(
                          s.copyWith(smoothWater: value),
                        );
                        if (value &&
                            widget.sceneModelService != null &&
                            context.mounted) {
                          await showSceneModelDialog(
                            context,
                            widget.sceneModelService!,
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
              ExpansionTile(
                title: Text(l.performanceDefaults),
                children: [
                  _toggle(
                    l.parallelMatching,
                    s.performance.parallelMatching,
                    (v) => s.performance.copyWith(parallelMatching: v),
                  ),
                  _toggle(
                    l.parallelRendering,
                    s.performance.parallelRendering,
                    (v) => s.performance.copyWith(parallelRendering: v),
                  ),
                  _toggle(
                    l.sourceCache,
                    s.performance.useSourceCache,
                    (v) => s.performance.copyWith(useSourceCache: v),
                  ),
                  _toggle(
                    l.alignmentCache,
                    s.performance.useAlignmentCache,
                    (v) => s.performance.copyWith(useAlignmentCache: v),
                  ),
                  _toggle(
                    l.fastRegistration,
                    s.performance.fastRegistration,
                    (v) => s.performance.copyWith(fastRegistration: v),
                  ),
                  _toggle(
                    l.orbFeatures,
                    s.performance.orbFeatures,
                    (v) => s.performance.copyWith(
                      orbFeatures: v,
                      flannMatching: v ? false : s.performance.flannMatching,
                    ),
                  ),
                  SwitchListTile(
                    title: Text(l.flannMatching),
                    value: s.performance.effectiveFlannMatching,
                    onChanged: s.performance.orbFeatures
                        ? null
                        : (v) => widget.controller.updateWith(
                            (latest) => latest.copyWith(
                              performance: latest.performance.copyWith(
                                flannMatching: v,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
              if (widget.supportsSceneOptions &&
                  widget.sceneModelService != null)
                SceneModelManagerTile(
                  service: widget.sceneModelService!,
                  activeTasks: widget.activeTasks,
                ),
              ExpansionTile(
                title: Text(l.text('应用内存预算')),
                subtitle: Text(l.text('为整个应用设置共享预算；不会预先占用所选内存，也不代表操作系统硬内存限制。')),
                children: [
                  RadioGroup<MemoryBudgetMode>(
                    groupValue: s.memoryBudgetMode,
                    onChanged: (mode) {
                      if (mode != null) {
                        _draggingMemoryMiB = null;
                        widget.controller.updateWith(
                          (latest) => latest.copyWith(memoryBudgetMode: mode),
                        );
                      }
                    },
                    child: Column(
                      children: [
                        RadioListTile<MemoryBudgetMode>(
                          title: Text(l.text('自动分配')),
                          subtitle: Text(l.text('根据当前可用内存自动推荐。')),
                          value: MemoryBudgetMode.automatic,
                        ),
                        RadioListTile<MemoryBudgetMode>(
                          title: Text(l.text('手动设置')),
                          subtitle: Text(l.text('限制所有并行任务共享的总预算。')),
                          value: MemoryBudgetMode.manual,
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    title: Text(
                      '${l.text('已选')}: ${_memoryLabel(memory.selectedMiB)}, '
                      '${l.text('总内存')}: ${_memoryLabel(reading.totalMemoryMiB)}, '
                      '${l.text('可用')}: ${_memoryLabel(reading.availableMemoryMiB)}',
                    ),
                    subtitle: Text(
                      '${l.text('推荐')}: ${_memoryLabel(memory.recommendedMiB)} · '
                      '${l.text('本次上限')}: ${_memoryLabel(memory.maximumMiB)}'
                      '${memory.readingValid ? '' : ' · ${l.text('使用保守回退值')}'}',
                    ),
                  ),
                  if (s.memoryBudgetMode == MemoryBudgetMode.manual) ...[
                    Slider(
                      key: const Key('total-memory-budget-slider'),
                      value: memorySliderValue.toDouble(),
                      min: memory.minimumMiB.toDouble(),
                      max: memory.maximumMiB.toDouble(),
                      divisions: memory.maximumMiB > memory.minimumMiB
                          ? ((memory.maximumMiB - memory.minimumMiB) ~/ 128)
                                .clamp(1, 1000)
                          : null,
                      label: _memoryLabel(memorySliderValue),
                      onChanged: memory.maximumMiB > memory.minimumMiB
                          ? (value) => setState(
                              () => _draggingMemoryMiB = value.round(),
                            )
                          : null,
                      onChangeEnd: (value) {
                        final snapped = (value / 128).round() * 128;
                        _draggingMemoryMiB = null;
                        widget.controller.updateWith(
                          (latest) => latest.copyWith(
                            memoryBudgetMode: MemoryBudgetMode.manual,
                            totalMemoryBudgetMiB:
                                MemoryBudgetPolicy.sliderValue(
                                  snapped,
                                  memory.maximumMiB,
                                ),
                          ),
                        );
                      },
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final mark in memory.markMiB)
                          ActionChip(
                            label: Text(_memoryLabel(mark)),
                            onPressed: () => widget.controller.updateWith(
                              (latest) => latest.copyWith(
                                memoryBudgetMode: MemoryBudgetMode.manual,
                                totalMemoryBudgetMiB: mark,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
              ListTile(
                title: Text(l.outputFolder),
                subtitle: Text(s.outputDirectory ?? l.defaultOutputFolder),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.outputDirectory != null)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: l.useDefaultFolder,
                        onPressed: () => widget.controller.updateWith(
                          (latest) =>
                              latest.copyWith(clearOutputDirectory: true),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.folder_open),
                      tooltip: l.chooseFolder,
                      onPressed: () async {
                        try {
                          final path = widget.android
                              ? (await (widget.mobileStorageService ??
                                            (throw StateError(
                                              'Android output folder picker unavailable',
                                            )))
                                        .pickOutputFolder())
                                    ?.uri
                              : await PlatformFileDialogs().getDirectoryPath(
                                  confirmButtonText: l.chooseFolder,
                                );
                          if (path != null) {
                            await widget.controller.updateWith(
                              (latest) =>
                                  latest.copyWith(outputDirectory: path),
                            );
                          }
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l.settingsSaveFailed(error.toString()),
                                ),
                              ),
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
              _selectionControl<TaskDateFormat>(
                context: context,
                title: l.text('本地任务日期格式'),
                stacked: stackedDropdowns,
                value: s.taskDateFormat,
                items: TaskDateFormat.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(
                          value == TaskDateFormat.yearMonthDay
                              ? 'YYYY-MM-DD'
                              : 'MM/DD/YYYY',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    widget.controller.update(s.copyWith(taskDateFormat: value));
                  }
                },
              ),
              if (widget.controller.error case final error?)
                ListTile(
                  title: Text(
                    l.settingsSaveFailed(error),
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _memoryLabel(int memoryMiB) =>
      memoryMiB >= 1024 && memoryMiB % 1024 == 0
      ? '${memoryMiB ~/ 1024} GiB'
      : '$memoryMiB MiB';

  bool _useStackedDropdowns(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final scaledBodySize = MediaQuery.textScalerOf(context).scale(14);
    return width < 600 || scaledBodySize >= 18;
  }

  Widget _selectionControl<T>({
    required BuildContext context,
    required String title,
    String? subtitle,
    required bool stacked,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final dropdown = DropdownButton<T>(
      value: value,
      isExpanded: stacked,
      itemHeight: stacked ? null : kMinInteractiveDimension,
      items: items,
      onChanged: onChanged,
    );
    if (!stacked) {
      return ListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: dropdown,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          ],
          const SizedBox(height: 8),
          dropdown,
        ],
      ),
    );
  }

  String _textScaleLabel(double scale) => '${(scale * 100).round()}%';

  void _setTextScale(double scale) {
    _draggingTextScale = null;
    widget.controller.updateWith(
      (latest) =>
          latest.copyWith(textSizeMode: TextSizeMode.custom, textScale: scale),
    );
  }

  Widget _toggle(String label, bool value, dynamic Function(bool) update) =>
      SwitchListTile(
        title: Text(label),
        value: value,
        onChanged: (v) => widget.controller.updateWith(
          (latest) => latest.copyWith(performance: update(v)),
        ),
      );
}
