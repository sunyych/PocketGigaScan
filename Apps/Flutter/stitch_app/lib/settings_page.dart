import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'models/app_settings.dart';
import 'models/stitch_quality.dart';
import 'services/settings_controller.dart';
import 'services/mobile_storage_service.dart';
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
  });
  final SettingsController controller;
  final bool android;
  final bool mobile;
  final MemoryResourceReading? memoryReading;
  final MobileStorageService? mobileStorageService;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int? _draggingMemoryMiB;

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
          return ListView(
            children: [
              ListTile(
                title: Text(l.language),
                trailing: DropdownButton<AppLanguage>(
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
              ),
              ListTile(
                title: Text(l.appearance),
                trailing: DropdownButton<AppThemeMode>(
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
              ),
              ListTile(
                title: Text(l.accentColor),
                trailing: DropdownButton<AppAccent>(
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
              ),
              ExpansionTile(
                title: Text(l.outputQuality),
                children: [
                  ListTile(
                    title: Text(l.outputFormat),
                    trailing: DropdownButton<ExportFormat>(
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
                          widget.controller.update(s.copyWith(exportFormat: v));
                        }
                      },
                    ),
                  ),
                  SwitchListTile(
                    title: Text(l.refineNeighbors),
                    value: s.refineGridNeighbors,
                    onChanged: (v) => widget.controller.update(
                      s.copyWith(refineGridNeighbors: v),
                    ),
                  ),
                  ListTile(
                    title: Text(l.seamBlend),
                    trailing: DropdownButton<SeamBlendMode>(
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
                          widget.controller.update(
                            s.copyWith(seamBlendMode: v),
                          );
                        }
                      },
                    ),
                  ),
                  SwitchListTile(
                    title: Text(l.localTextureWarp),
                    value: s.localTextureWarp,
                    onChanged: (v) => widget.controller.update(
                      s.copyWith(localTextureWarp: v),
                    ),
                  ),
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
                              : await FilePicker.platform.getDirectoryPath();
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

  Widget _toggle(String label, bool value, dynamic Function(bool) update) =>
      SwitchListTile(
        title: Text(label),
        value: value,
        onChanged: (v) => widget.controller.updateWith(
          (latest) => latest.copyWith(performance: update(v)),
        ),
      );
}
