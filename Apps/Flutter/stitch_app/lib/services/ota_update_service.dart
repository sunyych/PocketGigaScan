import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'dart:ffi' show Abi;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

enum OtaPlatform { windowsX64, androidArm64, macosArm64 }

class OtaVersion implements Comparable<OtaVersion> {
  const OtaVersion(this.major, this.minor, this.patch, this.build);
  final int major, minor, patch, build;
  static final _pattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)$',
  );
  factory OtaVersion.parse(String value) {
    final match = _pattern.firstMatch(value);
    if (match == null) {
      throw const FormatException('Invalid update version');
    }
    final n = [for (var i = 1; i <= 4; i++) int.parse(match[i]!)];
    return OtaVersion(n[0], n[1], n[2], n[3]);
  }
  @override
  int compareTo(OtaVersion other) {
    for (final pair in <(int, int)>[
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (build, other.build),
    ]) {
      final c = pair.$1.compareTo(pair.$2);
      if (c != 0) return c;
    }
    return 0;
  }

  int compareReleaseVersion(OtaVersion other) {
    for (final pair in <(int, int)>[
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final c = pair.$1.compareTo(pair.$2);
      if (c != 0) return c;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch+$build';
}

class OtaManifest {
  const OtaManifest({
    required this.platform,
    required this.version,
    required this.asset,
    required this.sizeBytes,
    required this.sha256,
  });
  final OtaPlatform platform;
  final OtaVersion version;
  final String asset;
  final int sizeBytes;
  final String sha256;

  static OtaManifest parse(Object? value, OtaPlatform expected) {
    if (value is! Map<String, dynamic> || value['schemaVersion'] != 1) {
      throw const FormatException('Unsupported update manifest');
    }
    final platform = switch (value['platform']) {
      'windows-x64' => OtaPlatform.windowsX64,
      'android-arm64' => OtaPlatform.androidArm64,
      'macos-arm64' => OtaPlatform.macosArm64,
      _ => throw const FormatException('Unsupported update platform'),
    };
    if (platform != expected) {
      throw const FormatException('Update platform mismatch');
    }
    final asset = switch (platform) {
      OtaPlatform.windowsX64 => 'PocketGigaScan-Windows-x64.zip',
      OtaPlatform.androidArm64 => 'PocketGigaScan-Android-arm64.apk',
      OtaPlatform.macosArm64 => 'PocketGigaScan-macOS-arm64.zip',
    };
    if (value['asset'] != asset) {
      throw const FormatException('Unexpected update asset');
    }
    final size = value['sizeBytes'];
    if (size is! int || size <= 0 || size > 2 * 1024 * 1024 * 1024) {
      throw const FormatException('Invalid update size');
    }
    final hash = value['sha256'];
    if (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid update checksum');
    }
    return OtaManifest(
      platform: platform,
      version: OtaVersion.parse(value['version'] as String? ?? ''),
      asset: asset,
      sizeBytes: size,
      sha256: hash,
    );
  }
}

class OtaRelease {
  const OtaRelease._(this.manifest, this.assetUri);
  final OtaManifest manifest;
  final Uri assetUri;
}

/// Checks only the pinned PocketGigaScan GitHub repository and literal `latest` tag.
/// Downloaded files are stored as inert files; this service never extracts or runs them.
class OtaUpdateService {
  OtaUpdateService({
    http.Client? client,
    Future<Directory> Function()? supportDirectory,
    OtaPlatform? platform,
  }) : _client = client ?? http.Client(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _platform = platform ?? _currentPlatform();
  final http.Client _client;
  final Future<Directory> Function() _supportDirectory;
  final OtaPlatform? _platform;
  static const maxDownloadBytes = 2 * 1024 * 1024 * 1024;

  static OtaPlatform? _currentPlatform() {
    final abi = Abi.current();
    if (Platform.isWindows && abi == Abi.windowsX64) {
      return OtaPlatform.windowsX64;
    }
    if (Platform.isAndroid && abi == Abi.androidArm64) {
      return OtaPlatform.androidArm64;
    }
    if (Platform.isMacOS && abi == Abi.macosArm64) {
      return OtaPlatform.macosArm64;
    }
    return null;
  }

  OtaPlatform? get platform => _platform;

  String manifestName(OtaPlatform platform) => switch (platform) {
    OtaPlatform.windowsX64 => 'pocketgigascan-ota-windows-x64.json',
    OtaPlatform.androidArm64 => 'pocketgigascan-ota-android-arm64.json',
    OtaPlatform.macosArm64 => 'pocketgigascan-ota-macos-arm64.json',
  };

  Future<OtaRelease> check({
    OtaPlatform? platform,
    required String installedVersion,
  }) async {
    final target = platform ?? _platform;
    if (target == null) {
      throw UnsupportedError('Updates are not supported on this platform');
    }
    final api = Uri.https(
      'api.github.com',
      '/repos/sunyych/PocketGigaScan/releases/tags/latest',
    );
    final release = await _getJson(api);
    if (release['tag_name'] != 'latest') {
      throw const FormatException('Unexpected GitHub release tag');
    }
    final assets = release['assets'];
    if (assets is! List) {
      throw const FormatException('Release assets are missing');
    }
    final manifestFile = manifestName(target);
    final manifestAsset = assets
        .whereType<Map<String, dynamic>>()
        .where((a) => a['name'] == manifestFile)
        .firstOrNull;
    if (manifestAsset == null) {
      throw const FormatException('No update is published for this platform');
    }
    final manifestUri = _releaseAssetUri(
      manifestAsset['browser_download_url'],
      manifestFile,
    );
    final manifestBytes = await _getBytes(manifestUri, 1024 * 1024);
    if (manifestAsset['size'] != manifestBytes.length) {
      throw const FormatException(
        'Release manifest size does not match GitHub asset',
      );
    }
    _verifyApiDigest(manifestAsset['digest'], manifestBytes);
    final manifest = OtaManifest.parse(
      jsonDecode(utf8.decode(manifestBytes)),
      target,
    );
    final assetEntry = assets
        .whereType<Map<String, dynamic>>()
        .where((a) => a['name'] == manifest.asset)
        .firstOrNull;
    if (assetEntry == null || assetEntry['size'] != manifest.sizeBytes) {
      throw const FormatException('Release asset size does not match manifest');
    }
    final apiDigest = assetEntry['digest'];
    if (apiDigest != null &&
        (apiDigest is! String || apiDigest != 'sha256:${manifest.sha256}')) {
      throw const FormatException(
        'Manifest checksum does not match GitHub asset digest',
      );
    }
    final installed = OtaVersion.parse(installedVersion);
    if (manifest.version.compareReleaseVersion(installed) < 0 ||
        manifest.version.build <= installed.build) {
      throw const FormatException('No newer update is available');
    }
    return OtaRelease._(
      manifest,
      _releaseAssetUri(assetEntry['browser_download_url'], manifest.asset),
    );
  }

  void _verifyApiDigest(Object? raw, List<int> bytes) {
    if (raw == null) {
      return;
    }
    if (raw is! String ||
        !raw.startsWith('sha256:') ||
        raw.substring(7) != sha256.convert(bytes).toString()) {
      throw const FormatException('GitHub API asset digest mismatch');
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async =>
      jsonDecode(utf8.decode(await _getBytes(uri, 2 * 1024 * 1024)))
          as Map<String, dynamic>;
  Uri _releaseAssetUri(Object? raw, String name) {
    if (raw is! String) {
      throw const FormatException('Invalid release asset URL');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/sunyych/PocketGigaScan/releases/download/latest/$name') {
      throw const FormatException('Untrusted GitHub release URL');
    }
    return uri;
  }

  bool _allowedDestination(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      !uri.hasFragment &&
      (uri.host == 'github.com'
          ? !uri.hasQuery
          : <String>{
              'release-assets.githubusercontent.com',
              'objects.githubusercontent.com',
            }.contains(uri.host));

  Future<List<int>> _getBytes(Uri initial, int limit) async {
    var uri = initial;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['User-Agent'] = 'PocketGigaScan-OTA';
      request.headers['Accept'] = uri.host == 'api.github.com'
          ? 'application/vnd.github+json'
          : 'application/octet-stream';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        await response.stream
            .timeout(const Duration(seconds: 10))
            .drain<void>();
        if (location == null || redirects == 5) {
          throw const HttpException('Too many or invalid redirects');
        }
        final next = uri.resolve(location);
        if (!_allowedDestination(next)) {
          throw const FormatException('Untrusted redirect destination');
        }
        uri = next;
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream
            .timeout(const Duration(seconds: 10))
            .drain<void>();
        throw HttpException('GitHub returned HTTP ${response.statusCode}');
      }
      final length = int.tryParse(response.headers['content-length'] ?? '');
      if (length != null && (length < 0 || length > limit)) {
        await response.stream
            .timeout(const Duration(seconds: 10))
            .drain<void>();
        throw const FormatException('Response exceeds size limit');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        if (bytes.length + chunk.length > limit) {
          throw const FormatException('Response exceeds size limit');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    }
    throw const HttpException('Redirect limit exceeded');
  }

  Future<File> download(OtaRelease release) async {
    if (_releaseAssetUri(release.assetUri.toString(), release.manifest.asset) !=
        release.assetUri) {
      throw const FormatException('Untrusted GitHub release URL');
    }
    final root = Directory(p.join((await _supportDirectory()).path, 'updates'));
    await root.create(recursive: true);
    final dir = await root.createTemp('download-');
    final temp = File(p.join(dir.path, '.${release.manifest.asset}.part'));
    final output = File(p.join(dir.path, release.manifest.asset));
    try {
      final request = http.Request('GET', release.assetUri)
        ..followRedirects = false;
      request.headers['User-Agent'] = 'PocketGigaScan-OTA';
      request.headers['Accept'] = 'application/octet-stream';
      var response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      var uri = release.assetUri;
      for (
        var redirects = 0;
        response.statusCode >= 300 &&
            response.statusCode < 400 &&
            redirects < 5;
        redirects++
      ) {
        final location = response.headers['location'];
        await response.stream
            .timeout(const Duration(seconds: 10))
            .drain<void>();
        if (location == null) {
          throw const HttpException('Invalid download redirect');
        }
        uri = uri.resolve(location);
        if (!_allowedDestination(uri)) {
          throw const FormatException('Untrusted redirect destination');
        }
        final redirected = http.Request('GET', uri)..followRedirects = false;
        redirected.headers['User-Agent'] = 'PocketGigaScan-OTA';
        redirected.headers['Accept'] = 'application/octet-stream';
        response = await _client
            .send(redirected)
            .timeout(const Duration(seconds: 30));
      }
      if (response.statusCode != 200) {
        await response.stream
            .timeout(const Duration(seconds: 10))
            .drain<void>();
        throw HttpException('GitHub returned HTTP ${response.statusCode}');
      }
      final announced = int.tryParse(response.headers['content-length'] ?? '');
      if (announced != null && announced != release.manifest.sizeBytes) {
        await response.stream
            .timeout(const Duration(seconds: 10))
            .drain<void>();
        throw const FormatException('Downloaded asset size mismatch');
      }
      final outputHandle = await temp.open(mode: FileMode.write);
      final digests = <Digest>[];
      final input = sha256.startChunkedConversion(_DigestResultSink(digests));
      var count = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 60),
        )) {
          count += chunk.length;
          if (count > release.manifest.sizeBytes || count > maxDownloadBytes) {
            throw const FormatException(
              'Downloaded asset exceeds manifest size',
            );
          }
          input.add(chunk);
          await outputHandle.writeFrom(chunk);
        }
        await outputHandle.flush();
      } finally {
        input.close();
        await outputHandle.close();
      }
      if (count != release.manifest.sizeBytes ||
          digests.single.toString() != release.manifest.sha256) {
        throw const FormatException(
          'Downloaded asset failed size or SHA-256 verification',
        );
      }
      return await temp.rename(output.path);
    } catch (_) {
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<String> installedVersion() async {
    final info = await PackageInfo.fromPlatform();
    final build = int.tryParse(info.buildNumber);
    return build == null ? info.version : '${info.version}+$build';
  }

  void close() => _client.close();
}

class _DigestResultSink implements Sink<Digest> {
  _DigestResultSink(this.values);
  final List<Digest> values;
  @override
  void add(Digest value) => values.add(value);
  @override
  void close() {}
}
