import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'models/app_settings.dart';
import 'models/stitch_quality.dart';
import 'services/settings_controller.dart';
import 'services/mobile_storage_service.dart';
import 'l10n/stitch_localizations.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    this.android = false,
    this.mobileStorageService,
  });
  final SettingsController controller;
  final bool android;
  final MobileStorageService? mobileStorageService;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final l = StitchLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final s = widget.controller.settings;
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
                    l.fourNeighborFirst,
                    s.performance.fourNeighborFirst,
                    (v) => s.performance.copyWith(fourNeighborFirst: v),
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

  Widget _toggle(String label, bool value, dynamic Function(bool) update) =>
      SwitchListTile(
        title: Text(label),
        value: value,
        onChanged: (v) => widget.controller.updateWith(
          (latest) => latest.copyWith(performance: update(v)),
        ),
      );
}
