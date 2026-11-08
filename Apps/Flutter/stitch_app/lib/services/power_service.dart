import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
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
  PlatformForegroundWorkLock({bool? isWindows, this.windowsApi})
    : _isWindows = isWindows ?? Platform.isWindows;

  static const _displayRequired = 0;
  static const _systemRequired = 1;
  static const _reason = 'PocketGigaScan is processing panorama tasks';

  final bool _isWindows;
  final WindowsPowerRequestApi? windowsApi;
  late final WindowsPowerRequestApi _api =
      windowsApi ?? _Kernel32PowerRequestApi();
  Pointer<Void>? _request;

  @override
  Future<void> enable() async {
    if (!_isWindows) {
      await WakelockPlus.enable();
      return;
    }
    if (_request != null) return;

    final api = _api;
    final request = api.create(_reason);
    if (_isInvalidHandle(request)) {
      throw StateError('PowerCreateRequest failed.');
    }

    var displayRequested = false;
    try {
      if (!api.set(request, _displayRequired)) {
        throw StateError('PowerSetRequest(DisplayRequired) failed.');
      }
      displayRequested = true;
      if (!api.set(request, _systemRequired)) {
        throw StateError('PowerSetRequest(SystemRequired) failed.');
      }
      _request = request;
    } on Object {
      if (displayRequested) {
        try {
          api.clear(request, _displayRequired);
        } on Object {
          // Keep rolling back and preserve the original request failure.
        }
      }
      try {
        api.close(request);
      } on Object {
        // Best-effort rollback must not mask the request failure.
      }
      rethrow;
    }
  }

  @override
  Future<void> disable() async {
    if (!_isWindows) {
      await WakelockPlus.disable();
      return;
    }
    final request = _request;
    if (request == null) return;
    _request = null;

    final api = _api;
    var succeeded = _tryCleanup(() => api.clear(request, _systemRequired));
    if (!_tryCleanup(() => api.clear(request, _displayRequired))) {
      succeeded = false;
    }
    if (!_tryCleanup(() => api.close(request))) succeeded = false;
    if (!succeeded) throw StateError('Power request cleanup failed.');
  }

  bool _tryCleanup(bool Function() action) {
    try {
      return action();
    } on Object {
      return false;
    }
  }

  bool _isInvalidHandle(Pointer<Void> handle) =>
      handle.address == 0 ||
      handle.address == -1 ||
      handle.address == 0xFFFFFFFF ||
      handle.address == 0xFFFFFFFFFFFFFFFF;
}

/// Small injectable surface for testing Windows power request lifecycle.
abstract interface class WindowsPowerRequestApi {
  Pointer<Void> create(String reason);
  bool set(Pointer<Void> request, int requestType);
  bool clear(Pointer<Void> request, int requestType);
  bool close(Pointer<Void> request);
}

final class _DetailedPowerReasonContext extends Struct {
  external Pointer<Void> localizedReasonModule;

  @Uint32()
  external int localizedReasonId;

  @Uint32()
  external int reasonStringCount;

  external Pointer<Pointer<Utf16>> reasonStrings;
}

final class _PowerReasonUnion extends Union {
  external _DetailedPowerReasonContext detailed;

  external Pointer<Utf16> simpleReasonString;
}

final class _PowerReasonContext extends Struct {
  @Uint32()
  external int version;

  @Uint32()
  external int flags;

  external _PowerReasonUnion reason;
}

final class _Kernel32PowerRequestApi implements WindowsPowerRequestApi {
  _Kernel32PowerRequestApi() : _kernel32 = DynamicLibrary.open('kernel32.dll') {
    _create = _kernel32
        .lookupFunction<
          Pointer<Void> Function(Pointer<_PowerReasonContext>),
          Pointer<Void> Function(Pointer<_PowerReasonContext>)
        >('PowerCreateRequest');
    _set = _kernel32
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)
        >('PowerSetRequest');
    _clear = _kernel32
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)
        >('PowerClearRequest');
    _close = _kernel32
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('CloseHandle');
  }

  final DynamicLibrary _kernel32;
  late final Pointer<Void> Function(Pointer<_PowerReasonContext>) _create;
  late final int Function(Pointer<Void>, int) _set;
  late final int Function(Pointer<Void>, int) _clear;
  late final int Function(Pointer<Void>) _close;

  @override
  Pointer<Void> create(String reason) {
    final context = calloc<_PowerReasonContext>();
    final nativeReason = reason.toNativeUtf16();
    try {
      context.ref
        ..version = 0
        ..flags =
            1 // POWER_REQUEST_CONTEXT_SIMPLE_STRING
        ..reason.simpleReasonString = nativeReason;
      return _create(context);
    } finally {
      calloc.free(nativeReason);
      calloc.free(context);
    }
  }

  @override
  bool set(Pointer<Void> request, int requestType) =>
      _set(request, requestType) != 0;

  @override
  bool clear(Pointer<Void> request, int requestType) =>
      _clear(request, requestType) != 0;

  @override
  bool close(Pointer<Void> request) => _close(request) != 0;
}
