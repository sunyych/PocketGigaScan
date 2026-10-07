import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/services/mobile_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/mobile-storage');
  const productionChannel = MethodChannel('com.lumiaiq.pocketgigascan/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(productionChannel, null);
  });

  test('default service uses the production storage channel', () async {
    messenger.setMockMethodCallHandler(productionChannel, (call) async {
      expect(call.method, 'pickBatchParent');
      return '/private/staged';
    });

    expect(
      await const MobileStorageService().pickBatchParent(),
      '/private/staged',
    );
  });

  test(
    'folder picker returns staged path and preserves cancellation',
    () async {
      final service = MobileStorageService(channel: channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickBatchParent');
        return '/private/staged-batches/abc';
      });
      expect(await service.pickBatchParent(), '/private/staged-batches/abc');

      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await service.pickBatchParent(), isNull);
    },
  );

  test('save and share pass through explicit MIME and filenames', () async {
    final service = MobileStorageService(channel: channel);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    expect(
      await service.saveExport(
        '/private/result.tif',
        mimeType: 'image/tiff',
        suggestedName: 'panorama.tif',
      ),
      isTrue,
    );
    expect(
      await service.shareExport('/private/result.jxl', mimeType: 'image/jxl'),
      isTrue,
    );
    expect(calls.map((call) => call.method), ['saveExport', 'shareExport']);
    expect(calls[0].arguments, {
      'path': '/private/result.tif',
      'mimeType': 'image/tiff',
      'suggestedName': 'panorama.tif',
    });
    expect(calls[1].arguments, {
      'path': '/private/result.jxl',
      'mimeType': 'image/jxl',
    });
  });

  test('save and share map null native results to cancellation', () async {
    final service = MobileStorageService(channel: channel);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(
      await service.saveExport(
        '/private/result.png',
        mimeType: 'image/png',
        suggestedName: 'panorama.png',
      ),
      isFalse,
    );
    expect(
      await service.shareExport('/private/result.png', mimeType: 'image/png'),
      isFalse,
    );
  });

  test(
    'completed staged parents can be released after durable import',
    () async {
      final service = MobileStorageService(channel: channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'releaseBatchParent');
        expect(call.arguments, {'path': '/private/staged-batches/abc'});
        return true;
      });
      expect(
        await service.releaseBatchParent('/private/staged-batches/abc'),
        isTrue,
      );
    },
  );

  test(
    'output folder selection returns URI and display name without path conversion',
    () async {
      final service = MobileStorageService(channel: channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickOutputFolder');
        return {
          'uri': 'content://provider/tree/primary%3APictures',
          'displayName': 'Pictures',
        };
      });
      final folder = await service.pickOutputFolder();
      expect(folder?.uri, 'content://provider/tree/primary%3APictures');
      expect(folder?.displayName, 'Pictures');
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await service.pickOutputFolder(), isNull);
    },
  );

  test(
    'publish sends the snapshotted SAF tree and returns document identity',
    () async {
      final service = MobileStorageService(channel: channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'publishExport');
        expect(call.arguments, {
          'path': '/private/result.tif',
          'treeUri': 'content://provider/tree/abc',
          'mimeType': 'image/tiff',
          'suggestedName': 'result.tif',
        });
        return {
          'uri': 'content://provider/document/xyz',
          'displayName': 'result.tif',
        };
      });
      final result = await service.publishExport(
        '/private/result.tif',
        destinationUri: 'content://provider/tree/abc',
        mimeType: 'image/tiff',
        suggestedName: 'result.tif',
      );
      expect(result.uri, 'content://provider/document/xyz');
      expect(result.displayName, 'result.tif');
    },
  );
}
