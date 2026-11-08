import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/services/power_service.dart';

void main() {
  group('Windows foreground power request', () {
    test(
      'enable and disable are idempotent and release both request types',
      () async {
        final api = _FakePowerRequestApi();
        final lock = PlatformForegroundWorkLock(
          isWindows: true,
          windowsApi: api,
        );

        await lock.enable();
        await lock.enable();

        expect(api.createCount, 1);
        expect(api.requestTypesSet, [0, 1]);
        expect(api.reason, contains('panorama'));

        await lock.disable();
        await lock.disable();

        expect(api.requestTypesCleared, [1, 0]);
        expect(api.closeCount, 1);
      },
    );

    test(
      'partial request failure rolls back the display request and handle',
      () async {
        final api = _FakePowerRequestApi()..failSetType = 1;
        final lock = PlatformForegroundWorkLock(
          isWindows: true,
          windowsApi: api,
        );

        await expectLater(lock.enable(), throwsStateError);

        expect(api.requestTypesSet, [0, 1]);
        expect(api.requestTypesCleared, [0]);
        expect(api.closeCount, 1);
        expect(api.closedHandles, [123]);
      },
    );

    test('display request failure still closes the created handle', () async {
      final api = _FakePowerRequestApi()..failSetType = 0;
      final lock = PlatformForegroundWorkLock(isWindows: true, windowsApi: api);

      await expectLater(lock.enable(), throwsStateError);

      expect(api.requestTypesCleared, isEmpty);
      expect(api.closeCount, 1);
    });

    test('real Windows API accepts and releases the reason context', () async {
      if (!Platform.isWindows) return;
      final lock = PlatformForegroundWorkLock(isWindows: true);

      await lock.enable();
      await lock.disable();
    });
  });
}

class _FakePowerRequestApi implements WindowsPowerRequestApi {
  static final _handle = Pointer<Void>.fromAddress(123);

  final requestTypesSet = <int>[];
  final requestTypesCleared = <int>[];
  final closedHandles = <int>[];
  int createCount = 0;
  int closeCount = 0;
  int? failSetType;
  String? reason;

  @override
  Pointer<Void> create(String value) {
    createCount++;
    reason = value;
    return _handle;
  }

  @override
  bool set(Pointer<Void> request, int requestType) {
    requestTypesSet.add(requestType);
    return requestType != failSetType;
  }

  @override
  bool clear(Pointer<Void> request, int requestType) {
    requestTypesCleared.add(requestType);
    return true;
  }

  @override
  bool close(Pointer<Void> request) {
    closeCount++;
    closedHandles.add(request.address);
    return true;
  }
}
