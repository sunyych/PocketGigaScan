import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Uses separate exact baselines for macOS while keeping existing paths on
/// Windows and other test hosts unchanged.
Matcher platformGoldenFile(String goldenPath) =>
    matchesGoldenFile(platformGoldenPath(goldenPath));

/// Inserts `macos/` immediately below `goldens/` on macOS.
/// The optional flag keeps path routing testable on every host.
String platformGoldenPath(String goldenPath, {bool? isMacOS}) {
  if (!(isMacOS ?? Platform.isMacOS)) {
    return goldenPath;
  }

  const prefix = 'goldens/';
  if (!goldenPath.startsWith(prefix) || goldenPath.length == prefix.length) {
    throw ArgumentError.value(
      goldenPath,
      'goldenPath',
      'Must name a file below the goldens directory',
    );
  }

  return 'goldens/macos/${goldenPath.substring(prefix.length)}';
}
