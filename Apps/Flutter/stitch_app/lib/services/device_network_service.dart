import 'package:flutter/services.dart';

/// Offers platform-appropriate help for joining a DWARF access point.
///
/// Android can open the system Wi-Fi panel. iOS intentionally returns manual
/// steps because public iOS APIs cannot navigate directly to the Wi-Fi pane or
/// join an unknown-protection network on the user's behalf.
class DeviceNetworkService {
  const DeviceNetworkService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.lumiaiq.pocketgigascan/deviceNetwork';
  final MethodChannel _channel;

  Future<WifiSettingsHelpResult> openWifiSettings() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'openWifiSettings',
    );
    if (result == null ||
        result['opened'] is! bool ||
        result['guidance'] is! String) {
      throw const FormatException('Invalid Wi-Fi settings response');
    }
    return WifiSettingsHelpResult(
      opened: result['opened']! as bool,
      guidance: result['guidance']! as String,
    );
  }
}

class WifiSettingsHelpResult {
  const WifiSettingsHelpResult({required this.opened, required this.guidance});

  /// True when the platform opened a system Wi-Fi settings screen.
  final bool opened;

  /// User-facing connection steps, including platforms that require manual navigation.
  final String guidance;
}
