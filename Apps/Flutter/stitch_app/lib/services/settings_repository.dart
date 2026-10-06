import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

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
          return AppSettings.decode(
            await (await target.exists() ? target : backup).readAsString(),
          );
        }
        return defaults;
      }
      return AppSettings.decode(await target.readAsString());
    } catch (_) {
      return defaults;
    }
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
