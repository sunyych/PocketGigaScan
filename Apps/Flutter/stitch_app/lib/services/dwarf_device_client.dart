import 'dart:convert';
import 'dart:io';

import '../models/dwarf_download.dart';

/// Minimal implementation of the DWARF 3 HTTP album API.
/// The camera REST API listens on 8082 and serves SD-card files on port 80.
class DwarfDeviceClient {
  DwarfDeviceClient(
    String host, {
    this.apiPort = 8082,
    this.mediaPort = 80,
    HttpClient? httpClient,
  }) : host = _cleanHost(host),
       _http = httpClient ?? HttpClient();
  final String host;
  final int apiPort, mediaPort;
  final HttpClient _http;
  static String _cleanHost(String value) {
    final uri = Uri.parse(value.contains('://') ? value : 'http://$value');
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.query.isNotEmpty) {
      throw ArgumentError.value(
        value,
        'host',
        'Expected a DWARF host name or IP address',
      );
    }
    if (!isLocalNetworkHost(uri.host)) {
      throw ArgumentError.value(
        value,
        'host',
        'DWARF connections are limited to local network addresses',
      );
    }
    return uri.host;
  }

  static bool isLocalNetworkHost(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      final name = host.toLowerCase();
      return name == 'localhost' ||
          name.endsWith('.local') ||
          name.endsWith('.lan');
    }
    if (address.type == InternetAddressType.IPv4) {
      final b = address.rawAddress;
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 169 && b[1] == 254) ||
          b[0] == 127;
    }
    final bytes = address.rawAddress;
    return address.isLoopback ||
        (bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
  }

  Future<DwarfDeviceInfo> probe() async {
    final data = await _post('/deviceInfo');
    if (data is! Map) {
      throw const FormatException('DWARF deviceInfo response is not an object');
    }
    final info = DwarfDeviceInfo.fromJson(data.cast<String, Object?>());
    if (!info.deviceName.toLowerCase().contains('dwarf') &&
        !(info.deviceId ?? '').toLowerCase().contains('dwarf')) {
      throw const FormatException(
        'The connected device did not identify itself as a DWARF telescope',
      );
    }
    if (info.sdCardAvailable == false) {
      throw const FormatException('The DWARF SD card is unavailable');
    }
    return info;
  }

  Future<List<DwarfPanorama>> listPanoramas({int pageSize = 50}) async {
    if (pageSize < 1 || pageSize > 200) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
    Object? counts;
    Object? apiFailure;
    try {
      counts = await _post('/album/list/mediaCounts');
    } on Object catch (error) {
      apiFailure = error;
    }
    if (counts == null) {
      final scanned = await _scanPanoramaDirectories();
      if (scanned.isNotEmpty) return scanned;
      if (apiFailure != null) throw apiFailure;
      throw const FormatException('DWARF camera returned no album counts');
    }
    if (counts is! List) {
      throw const FormatException('DWARF mediaCounts response is not a list');
    }
    final found = <String, DwarfPanorama>{};
    for (final count in counts) {
      if (count is! Map) continue;
      final type = count['mediaType'];
      final total = count['count'];
      if (type is! int || total is! int || total <= 0) continue;
      for (var page = 0; page * pageSize < total; page++) {
        final response = await _post('/album/list/mediaInfos', {
          'mediaType': type,
          'pageIndex': page,
          'pageSize': pageSize,
        });
        if (response is! List) {
          throw const FormatException(
            'DWARF mediaInfos response is not a list',
          );
        }
        for (final item in response) {
          if (item is! Map) continue;
          final row = item.cast<String, Object?>();
          final path = row['filePath'];
          final name = row['fileName'];
          if (path is! String || name is! String) {
            continue;
          }
          final packagePath = _packagePath(path, name);
          if (packagePath == null) continue;
          final seconds = row['modificationTime'];
          final stamp = seconds is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  seconds.toInt() * 1000,
                  isUtc: true,
                )
              : null;
          final thumb = row['thumbnailPath'];
          final id = packagePath;
          found[id] = DwarfPanorama(
            id: id,
            title: packagePath.split('/').where((part) => part.isNotEmpty).last,
            filePath: packagePath,
            fileSize: row['fileSize'] is num
                ? (row['fileSize'] as num).toInt()
                : 0,
            mediaType: row['mediaType'] is num
                ? (row['mediaType'] as num).toInt()
                : type,
            capturedAt: stamp,
            thumbnailUrl: thumb is String && thumb.isNotEmpty
                ? _fileUrl(thumb)
                : null,
          );
        }
      }
    }
    if (found.isEmpty) {
      final scanned = await _scanPanoramaDirectories();
      if (scanned.isNotEmpty) return scanned;
    }
    final result = found.values.toList()
      ..sort(
        (a, b) => (b.capturedAt ?? DateTime(0)).compareTo(
          a.capturedAt ?? DateTime(0),
        ),
      );
    return List.unmodifiable(result);
  }

  String? _packagePath(String path, String name) {
    final parts = _devicePath(
      path,
    ).split('/').where((part) => part.isNotEmpty).toList();
    final index = parts.indexWhere((part) => part.toLowerCase() == 'panoramas');
    if (index < 0) return null;
    final title = name.replaceFirst(
      RegExp(r'\.(jpg|jpeg)$', caseSensitive: false),
      '',
    );
    final candidates = <String>[];
    if (title.toUpperCase().startsWith('DWARF_PANORAMA_')) {
      candidates.add(title);
    }
    if (index + 1 < parts.length &&
        parts[index + 1].toLowerCase() == 'thumbnail' &&
        index + 2 < parts.length) {
      final thumbName = parts[index + 2].replaceFirst(
        RegExp(r'\.(jpg|jpeg)$', caseSensitive: false),
        '',
      );
      if (thumbName.toUpperCase().startsWith('DWARF_PANORAMA_')) {
        candidates.add(thumbName);
      }
    } else if (index + 1 < parts.length &&
        parts[index + 1].toUpperCase().startsWith('DWARF_PANORAMA_')) {
      candidates.add(parts[index + 1]);
    }
    if (candidates.isEmpty) return null;
    return '/${[...parts.take(index + 1), candidates.first].join('/')}';
  }

  Future<List<DwarfPanorama>> _scanPanoramaDirectories() async {
    const root = '/DWARF3/Panoramas/';
    final uri = Uri(scheme: 'http', host: host, port: mediaPort, path: root);
    final request = await _http
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      await response.listen(null).cancel();
      return const [];
    }
    final contentType = response.headers.contentType?.mimeType;
    if (contentType != null &&
        contentType != 'text/html' &&
        contentType != 'application/xhtml+xml') {
      await response.listen(null).cancel();
      return const [];
    }
    final html = await _readResponse(response, maxBytes: 2 * 1024 * 1024);
    final links = RegExp(
      r'''<a\b[^>]*href\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a\s*>''',
      caseSensitive: false,
      dotAll: true,
    );
    final panoramas = <DwarfPanorama>[];
    for (final match in links.allMatches(html)) {
      final href = _decodeHtml(match.group(2)!).trim();
      if (!href.endsWith('/')) continue;
      final target = uri.resolve(href);
      if (target.host != host ||
          target.port != mediaPort ||
          target.scheme != uri.scheme ||
          target.userInfo.isNotEmpty ||
          target.query.isNotEmpty) {
        continue;
      }
      final path = Uri.decodeFull(target.path);
      if (!path.startsWith(root) || path == root) continue;
      final name = path.substring(root.length).split('/').first;
      if (!name.toUpperCase().startsWith('DWARF_PANORAMA_')) continue;
      final packagePath = '$root$name';
      panoramas.add(
        DwarfPanorama(
          id: packagePath,
          title: name,
          filePath: packagePath,
          fileSize: 0,
          mediaType: -1,
        ),
      );
    }
    panoramas.sort((a, b) => a.title.compareTo(b.title));
    return List.unmodifiable(panoramas);
  }

  /// Reads the camera's HTTP directory index for the selected package. This
  /// intentionally refuses thumbnail paths and never promotes the album row
  /// itself to an original image.
  Future<List<DwarfOriginal>> listOriginals(DwarfPanorama panorama) async {
    final directory =
        _packagePath(panorama.filePath, panorama.title) ??
        (panorama.id.startsWith('/DWARF3/Panoramas/DWARF_PANORAMA_')
            ? panorama.id
            : null);
    if (directory == null ||
        !_isPanoramaDirectory(directory) ||
        directory.toLowerCase() == '/dwarf3/panoramas' ||
        directory.toLowerCase().contains('/thumbnail/')) {
      throw const FormatException(
        'Selected item does not identify a DWARF panorama package',
      );
    }
    final collected = <String, DwarfOriginal>{};
    await _listDirectory(
      directory,
      directory,
      collected,
      visited: <String>{},
      depth: 0,
    );
    final result = collected.values.toList()
      ..sort((a, b) => _naturalCompare(a.name, b.name));
    if (result.isEmpty) {
      throw const FormatException(
        'No original JPEGs were found in the DWARF panorama directory listing',
      );
    }
    return List.unmodifiable(result);
  }

  Future<void> _listDirectory(
    String root,
    String path,
    Map<String, DwarfOriginal> found, {
    required Set<String> visited,
    required int depth,
  }) async {
    if (depth > 4 || visited.length > 128) {
      throw const FormatException(
        'Panorama directory tree is larger than the supported scan bounds',
      );
    }
    if (!visited.add(path)) return;
    // Passing decoded path lets Uri perform the one required escaping pass.
    final uri = Uri(
      scheme: 'http',
      host: host,
      port: mediaPort,
      path: path.endsWith('/') ? path : '$path/',
    );
    final request = await _http
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    final response = await request.close().timeout(const Duration(seconds: 45));
    final body = await _readResponse(response, maxBytes: 2 * 1024 * 1024);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'DWARF directory listing returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final contentType = response.headers.contentType?.mimeType;
    if (contentType != null &&
        contentType != 'text/html' &&
        contentType != 'application/xhtml+xml') {
      throw FormatException(
        'DWARF path is not a directory listing ($contentType)',
      );
    }
    final links = RegExp(
      r'''<a\b[^>]*href\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a\s*>''',
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in links.allMatches(body)) {
      final href = _decodeHtml(match.group(2)!).trim();
      if (href.isEmpty ||
          href.startsWith('?') ||
          href.startsWith('#') ||
          href == '../' ||
          href == './') {
        continue;
      }
      final target = uri.resolve(href);
      if (target.host != host || target.port != mediaPort) continue;
      final targetPath = Uri.decodeFull(target.path);
      if (target.scheme != uri.scheme ||
          target.userInfo.isNotEmpty ||
          target.query.isNotEmpty ||
          !_isPanoramaDirectory(targetPath) ||
          !(targetPath == root ||
              targetPath.startsWith(root.endsWith('/') ? root : '$root/')) ||
          targetPath == path) {
        continue;
      }
      final name = targetPath.split('/').where((s) => s.isNotEmpty).last;
      final nameWithoutExtension = name.replaceFirst(
        RegExp(r'\.(jpg|jpeg)$', caseSensitive: false),
        '',
      );
      final packageName = root.split('/').where((s) => s.isNotEmpty).last;
      if (targetPath
              .split('/')
              .any((segment) => segment.toLowerCase() == 'thumbnail') ||
          nameWithoutExtension == packageName ||
          const {
            'preview',
            'thumbnail',
            'stitched',
            'panorama',
          }.contains(nameWithoutExtension.toLowerCase())) {
        continue;
      }
      if (name.toLowerCase().endsWith('.jpg') ||
          name.toLowerCase().endsWith('.jpeg')) {
        final url = target.toString();
        found[url] = DwarfOriginal(id: url, name: name, url: url, size: null);
      } else if (href.endsWith('/') ||
          match.group(3)!.toLowerCase().contains('directory')) {
        if (depth == 4) {
          throw const FormatException(
            'Panorama directory nesting exceeds supported bounds',
          );
        }
        await _listDirectory(
          root,
          targetPath,
          found,
          visited: visited,
          depth: depth + 1,
        );
      }
    }
  }

  bool _isPanoramaDirectory(String path) =>
      path.replaceAll('\\', '/').toLowerCase().contains('/panoramas/');
  String _devicePath(String path) {
    final decoded = Uri.decodeFull(path.replaceAll('\\', '/'));
    if (!decoded.startsWith('/') || decoded.split('/').contains('..')) {
      throw const FormatException('Invalid DWARF media path');
    }
    return decoded;
  }

  String _fileUrl(String path) {
    final clean = _devicePath(path);
    return Uri(
      scheme: 'http',
      host: host,
      port: mediaPort,
      path: clean,
    ).toString();
  }

  String _decodeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&#x2F;', '/')
      .replaceAll('&#47;', '/')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  int _naturalCompare(String a, String b) {
    final aa = RegExp(
      r'(\d+|\D+)',
    ).allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
    final bb = RegExp(
      r'(\d+|\D+)',
    ).allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
    for (var i = 0; i < aa.length && i < bb.length; i++) {
      final x = int.tryParse(aa[i]), y = int.tryParse(bb[i]);
      final c = x != null && y != null
          ? x.compareTo(y)
          : aa[i].compareTo(bb[i]);
      if (c != 0) return c;
    }
    return aa.length.compareTo(bb.length);
  }

  Future<Object?> _post(
    String path, [
    Map<String, Object?> body = const {},
  ]) async {
    final uri = Uri(scheme: 'http', host: host, port: apiPort, path: path);
    final request = await _http
        .postUrl(uri)
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await _readResponse(response, maxBytes: 1024 * 1024);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'DWARF API returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('DWARF API response has no envelope');
    }
    final code = decoded['code'];
    if (code is num && code != 0) {
      throw HttpException(
        'DWARF API error $code: ${decoded['message'] ?? decoded['msg'] ?? ''}',
        uri: uri,
      );
    }
    return decoded['data'];
  }

  void close({bool force = false}) => _http.close(force: force);

  Future<String> _readResponse(
    HttpClientResponse response, {
    required int maxBytes,
  }) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('DWARF response exceeded the allowed size');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }
}
