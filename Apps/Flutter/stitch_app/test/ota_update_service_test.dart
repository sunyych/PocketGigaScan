import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stitch_app/models/app_settings.dart';
import 'package:stitch_app/services/ota_update_service.dart';
import 'package:stitch_app/services/settings_controller.dart';
import 'package:stitch_app/services/settings_repository.dart';
import 'package:stitch_app/settings_page.dart';

void main() {
  test('manifest accepts only expected platform asset and strict version', () {
    final parsed = OtaManifest.parse(_manifest(), OtaPlatform.windowsX64);
    expect(parsed.version.toString(), '1.5.7+36');
    expect(
      () => OtaManifest.parse(
        _manifest(platform: 'android-arm64'),
        OtaPlatform.windowsX64,
      ),
      throwsFormatException,
    );
    expect(
      () => OtaManifest.parse(
        _manifest(version: '1.5.7'),
        OtaPlatform.windowsX64,
      ),
      throwsFormatException,
    );
    expect(
      () => OtaManifest.parse(
        _manifest(asset: 'other.exe'),
        OtaPlatform.windowsX64,
      ),
      throwsFormatException,
    );
  });

  test(
    'automatic update preference persists and old settings default to manual',
    () {
      final old = AppSettings.fromJson({'version': 2, 'language': 'en'});
      expect(old.updateCheckMode, UpdateCheckMode.manual);
      final when = DateTime.utc(2026, 11, 13);
      final saved = old.copyWith(
        updateCheckMode: UpdateCheckMode.automatic,
        lastUpdateCheckAt: when,
      );
      final restored = AppSettings.decode(jsonEncode(saved.toJson()));
      expect(restored.updateCheckMode, UpdateCheckMode.automatic);
      expect(restored.lastUpdateCheckAt, when);
    },
  );

  testWidgets(
    'settings exposes manual update checks and persists automatic mode',
    (tester) async {
      final controller = SettingsController(
        repository: _MemorySettingsRepository(),
        initial: const AppSettings(),
      );
      addTearDown(controller.dispose);
      final service = OtaUpdateService(
        client: MockClient((_) async => http.Response('', 404)),
        platform: OtaPlatform.windowsX64,
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(controller: controller, updateService: service),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Check automatically at launch (at most daily)'),
        300,
      );
      expect(find.text('Check for updates'), findsOneWidget);
      await tester.tap(
        find.text('Check automatically at launch (at most daily)'),
      );
      await tester.pumpAndSettle();
      expect(controller.settings.updateCheckMode, UpdateCheckMode.automatic);
    },
  );

  test(
    'checks only pinned release and verifies downloaded size and checksum',
    () async {
      final payload = [1, 2, 3, 4];
      final hash = sha256.convert(payload).toString();
      final manifest = jsonEncode(
        _manifest(sizeBytes: payload.length, sha256: hash),
      );
      final release = _release(
        manifestSize: utf8.encode(manifest).length,
        payloadSize: payload.length,
        hash: hash,
      );
      final client = MockClient((request) async {
        expect(
          request.headers['Accept'],
          request.url.host == 'api.github.com'
              ? 'application/vnd.github+json'
              : 'application/octet-stream',
        );
        if (request.url.path.endsWith('/releases/tags/latest')) {
          return http.Response(jsonEncode(release), 200);
        }
        if (request.url.path.endsWith('.json')) {
          return http.Response(manifest, 200);
        }
        if (request.url.path.endsWith('.zip')) {
          return http.Response.bytes(payload, 200);
        }
        return http.Response('not found', 404);
      });
      final temp = await Directory.systemTemp.createTemp('ota-test');
      addTearDown(() async {
        client.close();
        await temp.delete(recursive: true);
      });
      final service = OtaUpdateService(
        client: client,
        platform: OtaPlatform.windowsX64,
        supportDirectory: () async => temp,
      );
      final found = await service.check(installedVersion: '1.5.6+35');
      expect(found.manifest.version.toString(), '1.5.7+36');
      final file = await service.download(found);
      expect(await file.readAsBytes(), payload);
      expect(file.path, contains('updates'));
      await expectLater(
        service.check(installedVersion: '1.5.7+36'),
        throwsFormatException,
      );
    },
  );

  test('rejects HTTP failures and untrusted release URL', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.json')) {
        return http.Response('failure', 503);
      }
      return http.Response('', 404);
    });
    addTearDown(client.close);
    final service = OtaUpdateService(
      client: client,
      platform: OtaPlatform.windowsX64,
    );
    await expectLater(
      service.check(installedVersion: '1.5.6+35'),
      throwsA(isA<HttpException>()),
    );

    final badRelease = _release(
      manifestSize: 1,
      payloadSize: 1,
      hash: '0000000000000000000000000000000000000000000000000000000000000000',
      manifestUrl: 'https://evil.example/pocketgigascan-ota-windows-x64.json',
    );
    final badClient = MockClient(
      (request) async => http.Response(jsonEncode(badRelease), 200),
    );
    addTearDown(badClient.close);
    final badService = OtaUpdateService(
      client: badClient,
      platform: OtaPlatform.windowsX64,
    );
    await expectLater(
      badService.check(installedVersion: '1.5.6+35'),
      throwsFormatException,
    );
  });

  test('rejects redirects to untrusted hosts', () async {
    final payload = [1, 2, 3, 4];
    final hash = sha256.convert(payload).toString();
    final manifest = jsonEncode(
      _manifest(sizeBytes: payload.length, sha256: hash),
    );
    final release = _release(
      manifestSize: utf8.encode(manifest).length,
      payloadSize: payload.length,
      hash: hash,
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/releases/tags/latest')) {
        return http.Response(jsonEncode(release), 200);
      }
      if (request.url.path.endsWith('.json')) {
        return http.Response(manifest, 200);
      }
      return http.Response(
        '',
        302,
        headers: {'location': 'https://evil.example/file'},
      );
    });
    addTearDown(client.close);
    final service = OtaUpdateService(
      client: client,
      platform: OtaPlatform.windowsX64,
    );
    final found = await service.check(installedVersion: '1.5.6+35');
    final temp = await Directory.systemTemp.createTemp('ota-redirect-test');
    addTearDown(() async => temp.delete(recursive: true));
    final testService = OtaUpdateService(
      client: client,
      platform: OtaPlatform.windowsX64,
      supportDirectory: () async => temp,
    );
    await expectLater(testService.download(found), throwsFormatException);
    expect(await Directory('${temp.path}/updates').list().toList(), isEmpty);
  });

  test(
    'checksum failure removes incomplete download and preserves other verified files',
    () async {
      final payload = [4, 3, 2, 1];
      final manifest = jsonEncode(
        _manifest(
          sizeBytes: payload.length,
          sha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
        ),
      );
      final release = _release(
        manifestSize: utf8.encode(manifest).length,
        payloadSize: payload.length,
        hash:
            '0000000000000000000000000000000000000000000000000000000000000000',
      );
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/releases/tags/latest')) {
          return http.Response(jsonEncode(release), 200);
        }
        if (request.url.path.endsWith('.json')) {
          return http.Response(manifest, 200);
        }
        return http.Response.bytes(payload, 200);
      });
      final temp = await Directory.systemTemp.createTemp('ota-checksum-test');
      addTearDown(() async {
        client.close();
        await temp.delete(recursive: true);
      });
      final service = OtaUpdateService(
        client: client,
        platform: OtaPlatform.windowsX64,
        supportDirectory: () async => temp,
      );
      final found = await service.check(installedVersion: '1.5.6+35');
      final old = File(
        '${temp.path}/updates/keep/PocketGigaScan-Windows-x64.zip',
      )..createSync(recursive: true);
      await old.writeAsString('old verified file');
      await expectLater(service.download(found), throwsFormatException);
      expect(await old.readAsString(), 'old verified file');
      final children = await Directory(
        '${temp.path}/updates',
      ).list(recursive: true).toList();
      expect(
        children
            .whereType<File>()
            .map((file) => file.path.replaceAll('\\', '/'))
            .toSet(),
        {old.path.replaceAll('\\', '/')},
      );
    },
  );
}

Map<String, Object?> _manifest({
  String platform = 'windows-x64',
  String version = '1.5.7+36',
  String? asset,
  int sizeBytes = 4,
  String sha256 =
      '0000000000000000000000000000000000000000000000000000000000000000',
}) => {
  'schemaVersion': 1,
  'platform': platform,
  'version': version,
  'asset': asset ?? 'PocketGigaScan-Windows-x64.zip',
  'sizeBytes': sizeBytes,
  'sha256': sha256,
};

Map<String, Object?> _release({
  required int manifestSize,
  required int payloadSize,
  required String hash,
  String? manifestUrl,
}) => {
  'tag_name': 'latest',
  'assets': [
    {
      'name': 'pocketgigascan-ota-windows-x64.json',
      'size': manifestSize,
      'browser_download_url':
          manifestUrl ??
          'https://github.com/sunyych/PocketGigaScan/releases/download/latest/pocketgigascan-ota-windows-x64.json',
    },
    {
      'name': 'PocketGigaScan-Windows-x64.zip',
      'size': payloadSize,
      'digest': 'sha256:$hash',
      'browser_download_url':
          'https://github.com/sunyych/PocketGigaScan/releases/download/latest/PocketGigaScan-Windows-x64.zip',
    },
  ],
};

class _MemorySettingsRepository extends SettingsRepository {
  @override
  Future<void> save(AppSettings settings) async {}
}
