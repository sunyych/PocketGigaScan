import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the local PocketGigaScan data folder while keeping access to task
/// records created when the Windows product directory was named Lumia Stitch.
/// Existing legacy data wins when both roots exist so new work stays alongside
/// the history the user already has.
Future<Directory> legacyCompatibleSupportDirectory({
  required Directory platformSupportRoot,
  required String dataFolder,
  bool? isWindows,
  Map<String, String>? environment,
}) async {
  final current = Directory(
    p.join(platformSupportRoot.path, 'LumiaStitch', dataFolder),
  );
  if (!(isWindows ?? Platform.isWindows)) return current;

  final appData = (environment ?? Platform.environment)['APPDATA'];
  if (appData == null || appData.trim().isEmpty) return current;
  final legacyBase = Directory(
    p.join(appData, 'com.lumia', 'Lumia Stitch', 'LumiaStitch'),
  );
  final hasLegacyData =
      await Directory(p.join(legacyBase.path, 'tasks')).exists() ||
      await Directory(p.join(legacyBase.path, 'batches')).exists();
  if (hasLegacyData) return Directory(p.join(legacyBase.path, dataFolder));
  return current;
}
