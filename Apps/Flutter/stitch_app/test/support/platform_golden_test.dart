import 'package:flutter_test/flutter_test.dart';
import 'platform_golden.dart';

void main() {
  test('keeps existing Windows and non-macOS golden paths unchanged', () {
    expect(
      platformGoldenPath(
        'goldens/scene-options-settings-en.png',
        isMacOS: false,
      ),
      'goldens/scene-options-settings-en.png',
    );
  });

  test('routes macOS golden paths below the macOS baseline directory', () {
    expect(
      platformGoldenPath(
        'goldens/scene-options-settings-en.png',
        isMacOS: true,
      ),
      'goldens/macos/scene-options-settings-en.png',
    );
  });

  test('rejects macOS paths outside the goldens directory', () {
    expect(
      () => platformGoldenPath('other/example.png', isMacOS: true),
      throwsArgumentError,
    );
  });
}
