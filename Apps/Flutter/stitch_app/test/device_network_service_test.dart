import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/services/device_network_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/device-network');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'opens platform Wi-Fi help and preserves manual platform guidance',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'openWifiSettings');
        return <String, Object?>{
          'opened': false,
          'guidance': 'Open Settings > Wi-Fi and join DWARF3.',
        };
      });

      final result = await DeviceNetworkService(
        channel: channel,
      ).openWifiSettings();

      expect(result.opened, isFalse);
      expect(result.guidance, contains('DWARF3'));
    },
  );

  test('rejects malformed native responses', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'opened': true});

    expect(
      DeviceNetworkService(channel: channel).openWifiSettings(),
      throwsA(isA<FormatException>()),
    );
  });
}
