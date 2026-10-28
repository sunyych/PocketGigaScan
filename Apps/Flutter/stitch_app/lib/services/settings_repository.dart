import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/stitch_quality.dart';

class SettingsRepository {
  SettingsRepository({this.file, this.defaults = const AppSettings()});
  final File? file;
  final AppSettings defaults;
  static Future<void> _writeTail = Future.value();

  Future<File> _target() async {
    if (file case final target?) {
      return target;
    }
    final root = await getApplicationSupportDirectory();
    return File(p.join(root.path, 'app-settings.json'));
  }

  Future<AppSettings> load() async {
    try {
      final target = await _target();
      if (!await target.exists()) {
        final backup = File('${target.path}.previous');
        if (await backup.exists()) {
          try {
            await backup.rename(target.path);
          } catch (_) {}
          return _decodeSaved(
            await (await target.exists() ? target : backup).readAsString(),
          );
        }
        return defaults;
      }
      final saved = await target.readAsString();
      return _decodeSaved(saved);
    } catch (_) {
      return defaults;
    }
  }

  Future<AppSettings> _decodeSaved(String saved) async {
    final decoded = AppSettings.decode(saved);
    final raw = (jsonDecode(saved) as Map).cast<String, Object?>();
    final oldSchema = (raw['version'] as num? ?? 1).toInt() < 2;
    // The old desktop default was TIFF and was not tagged as a user choice.
    // Migrate that one legacy default once; other saved formats stay intact.
    if (oldSchema &&
        !decoded.exportFormatExplicitlySet &&
        decoded.exportFormat == ExportFormat.tiff &&
        defaults.exportFormat == ExportFormat.jpeg) {
      final migrated = decoded.copyWith(exportFormat: ExportFormat.jpeg);
      await save(migrated);
      return migrated;
    }
    return decoded;
  }

  Future<void> save(AppSettings settings) {
    final result = _writeTail.then((_) async {
      final target = await _target();
      await target.parent.create(recursive: true);
      final temp = File('${target.path}.tmp');
      await temp.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(settings.toJson())}\n',
        flush: true,
      );
      final backup = File('${target.path}.previous');
      final hadTarget = await target.exists();
      if (hadTarget) {
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
      }
      try {
        await temp.rename(target.path);
      } catch (_) {
        if (hadTarget && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) {
        try {
          await backup.delete();
        } catch (_) {}
      }
    });
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }
}
