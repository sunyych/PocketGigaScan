import 'dart:io';

import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum PowerState { externalPower, battery, unknown, notRequired }

abstract interface class PowerGate {
  Future<PowerState> readState();
}

class PlatformPowerGate implements PowerGate {
  static const channelName = 'com.lumiaiq.pocketgigascan/power';
  static const _channel = MethodChannel(channelName);

  @override
  Future<PowerState> readState() async {
    if (!Platform.isAndroid && !Platform.isIOS) return PowerState.notRequired;
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'readPowerState',
      );
      return switch (response?['state']) {
        'external' => PowerState.externalPower,
        'battery' => PowerState.battery,
        _ => PowerState.unknown,
      };
    } on PlatformException {
      return PowerState.unknown;
    } on MissingPluginException {
      return PowerState.unknown;
    }
  }
}

abstract interface class ForegroundWorkLock {
  Future<void> enable();
  Future<void> disable();
}

class PlatformForegroundWorkLock implements ForegroundWorkLock {
  @override
  Future<void> enable() => WakelockPlus.enable();
  @override
  Future<void> disable() => WakelockPlus.disable();
}
