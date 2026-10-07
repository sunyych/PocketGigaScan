import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/dwarf_download.dart';
import 'package:stitch_app/services/dwarf_device_client.dart';
import 'package:stitch_app/services/dwarf_download_service.dart';

const _jpeg = <int>[
  0xff,
  0xd8,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0x01,
  0x11,
  0x00,
  0xff,
  0xd9,
];

class _RawServer {
  _RawServer(this.socket);
  final ServerSocket socket;
  int get port => socket.port;
  static Future<_RawServer> start(
    Future<void> Function(Socket socket, String headers) handle,
  ) async {
    final server = _RawServer(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    server.socket.listen((client) {
      final bytes = <int>[];
      late StreamSubscription<List<int>> subscription;
      subscription = client.listen((chunk) {
        bytes.addAll(chunk);
        final text = latin1.decode(bytes, allowInvalid: true);
        if (text.contains('\r\n\r\n')) {
          unawaited(subscription.cancel());
          unawaited(
            handle(client, text.substring(0, text.indexOf('\r\n\r\n'))),
          );
        }
      }, onError: (_) => client.destroy());
    });
    return server;
  }

  Future<void> close() => socket.close();
}

Future<void> _rawResponse(
  Socket socket,
  List<int> body,
  int contentLength, {
  int status = 200,
  String etag = '"v1"',
  String? contentRange,
}) async {
  final reason = status == 206
      ? 'Partial Content'
      : status == 416
      ? 'Range Not Satisfiable'
      : 'OK';
  final headers = StringBuffer(
    'HTTP/1.1 $status $reason\r\nContent-Length: $contentLength\r\nETag: $etag\r\nConnection: close\r\n',
  );
  if (contentRange != null) headers.write('Content-Range: $contentRange\r\n');
  headers.write('\r\n');
  socket.add(latin1.encode(headers.toString()));
  socket.add(body);
  await socket.flush();
  socket.destroy();
}

void main() {
  late HttpServer server;
  late Directory temp;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    temp = await Directory.systemTemp.createTemp('dwarf-download-test-');
  });
  tearDown(() async {
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  test(
    'lists panorama originals from the selected directory index only',
    () async {
      expect(() => DwarfDeviceClient('8.8.8.8'), throwsArgumentError);
      server.listen((request) async {
        if (request.method == 'POST') {
          final route = request.uri.path;
          Object data;
          if (route == '/deviceInfo') {
            data = {'deviceName': 'DWARF3 test', 'sdCardAvailable': true};
          } else if (route == '/album/list/mediaCounts') {
            data = [
              {'mediaType': 5, 'count': 1},
            ];
          } else {
            data = [
              {
                'fileName': 'DWARF_PANORAMA_01',
                'filePath': '/DWARF3/Panoramas/Thumbnail/DWARF_PANORAMA_01.jpg',
                'fileSize': 0,
                'mediaType': 5,
              },
            ];
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'code': 0, 'data': data}));
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '<a href="0_0.jpg">0_0.jpg</a>'
            '<a href="preview.jpg">preview.jpg</a>'
            '<a href="DWARF_PANORAMA_01.jpg">DWARF_PANORAMA_01.jpg</a>'
            '<a href="../DWARF_PANORAMA_02/1_0.jpg">1_0.jpg</a>'
            '<a href="Thumbnail/preview.jpg">preview</a>',
          );
        }
        await request.response.close();
      });
      final client = DwarfDeviceClient(
        '127.0.0.1',
        apiPort: server.port,
        mediaPort: server.port,
      );
      addTearDown(() => client.close(force: true));

      expect((await client.probe()).deviceName, 'DWARF3 test');
      final panoramas = await client.listPanoramas();
      expect(panoramas, hasLength(1));
      final originals = await client.listOriginals(panoramas.single);
      expect(originals.map((source) => source.name), ['0_0.jpg']);
      expect(
        originals.single.url,
        contains('/DWARF3/Panoramas/DWARF_PANORAMA_01/0_0.jpg'),
      );
    },
  );

  test(
    'downloads JPEGs with exact source names and durable manifest identity',
    () async {
      server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.contentLength = _jpeg.length;
        request.response.add(_jpeg);
        await request.response.close();
      });
      final url =
          'http://127.0.0.1:${server.port}/DWARF3/Panoramas/P01/0_0.jpg';
      final source = DwarfOriginal(
        id: url,
        name: '0_0.jpg',
        url: url,
        size: _jpeg.length,
      );
      final service = DwarfDownloadService(
        rootDirectory: p.join(temp.path, 'downloads'),
      );
      addTearDown(() => service.close(force: true));
      final result = await service.downloadBatch(
        batchId: 'DWARF3|P01',
        originals: [source],
        metadata: {'host': '192.168.88.1', 'panoramaId': 'P01'},
      );

      expect(result.isComplete, isTrue, reason: result.error);
      expect(p.basename(result.files.single.path), '0_0.jpg');
      expect(result.files.single.sha256, sha256.convert(_jpeg).toString());
      final restored = await service.loadBatch('DWARF3|P01');
      expect(restored?.metadata['panoramaId'], 'P01');
      expect((await service.listBatches()).map((batch) => batch.id), [
        'DWARF3|P01',
      ]);
    },
  );

  test(
    'rejects non JPEG responses and does not produce a completed batch',
    () async {
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('not an image');
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/bad.jpg';
      final service = DwarfDownloadService(
        rootDirectory: p.join(temp.path, 'downloads'),
        maxRetries: 0,
      );
      addTearDown(() => service.close(force: true));
      final result = await service.downloadBatch(
        batchId: 'bad',
        originals: [DwarfOriginal(id: url, name: 'bad.jpg', url: url)],
      );
      expect(result.state, DwarfDownloadState.failed);
      expect(result.isComplete, isFalse);
      expect(await File(result.files.single.path).exists(), isFalse);
    },
  );

  test(
    'restarts cleanly when a server ignores Range and returns 200',
    () async {
      var interrupt = true;
      var sawRange = false;
      final raw = await _RawServer.start((socket, headers) async {
        final offset =
            int.tryParse(
              RegExp(
                    r'^Range: bytes=(\d+)-',
                    caseSensitive: false,
                    multiLine: true,
                  ).firstMatch(headers)?.group(1) ??
                  '',
            ) ??
            0;
        sawRange |= offset > 0;
        if (interrupt) {
          interrupt = false;
          await _rawResponse(socket, _jpeg.sublist(0, 8), _jpeg.length);
        } else {
          // Deliberately ignore Range. HTTP 200 must replace the partial file.
          await _rawResponse(socket, _jpeg, _jpeg.length);
        }
      });
      addTearDown(raw.close);
      final url = 'http://127.0.0.1:${raw.port}/image.jpg';
      final source = DwarfOriginal(id: url, name: 'image.jpg', url: url);
      final service = DwarfDownloadService(
        rootDirectory: p.join(temp.path, 'downloads'),
        maxRetries: 0,
      );
      addTearDown(() => service.close(force: true));
      final firstResult = await service.downloadBatch(
        batchId: 'range-200',
        originals: [source],
      );
      expect(firstResult.isComplete, isFalse);
      expect(firstResult.files.single.original.etag, '"v1"');
      expect(firstResult.files.single.bytes, 8);
      final resumed = await service.resumeBatch('range-200');
      expect(sawRange, isTrue);
      expect(resumed.isComplete, isTrue, reason: resumed.error);
      expect(await File(resumed.files.single.path).readAsBytes(), _jpeg);
    },
  );

  test('refuses a changed source validator during resume', () async {
    var interrupt = true;
    final raw = await _RawServer.start((socket, headers) async {
      if (interrupt) {
        interrupt = false;
        await _rawResponse(socket, _jpeg.sublist(0, 8), _jpeg.length);
      } else {
        final range = RegExp(
          r'^Range: bytes=(\d+)-',
          caseSensitive: false,
          multiLine: true,
        ).firstMatch(headers);
        final offset = range == null ? 0 : int.parse(range.group(1)!);
        await _rawResponse(
          socket,
          _jpeg.sublist(offset),
          _jpeg.length - offset,
          status: 206,
          etag: '"v2"',
          contentRange: 'bytes $offset-${_jpeg.length - 1}/${_jpeg.length}',
        );
      }
    });
    addTearDown(raw.close);
    final url = 'http://127.0.0.1:${raw.port}/image.jpg';
    final service = DwarfDownloadService(
      rootDirectory: p.join(temp.path, 'downloads'),
      maxRetries: 0,
    );
    addTearDown(() => service.close(force: true));
    await service.downloadBatch(
      batchId: 'changed-source',
      originals: [DwarfOriginal(id: url, name: 'image.jpg', url: url)],
    );
    final resumed = await service.resumeBatch('changed-source');
    expect(resumed.state, DwarfDownloadState.failed);
    expect(resumed.error, contains('source changed'));
  });

  test(
    'enumerates named panorama folders from the camera root when album API is empty',
    () async {
      server.listen((request) async {
        if (request.method == 'POST') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'code': 0, 'data': []}));
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '<a href="DWARF_PANORAMA_A/">DWARF_PANORAMA_A/</a>'
            '<a href="DWARF_PANORAMA_B/">DWARF_PANORAMA_B/</a>'
            '<a href="Thumbnail/">Thumbnail/</a>'
            '<a href="loose.jpg">loose.jpg</a>',
          );
        }
        await request.response.close();
      });
      final client = DwarfDeviceClient(
        '127.0.0.1',
        apiPort: server.port,
        mediaPort: server.port,
      );
      addTearDown(() => client.close(force: true));
      final panoramas = await client.listPanoramas();
      expect(panoramas.map((item) => item.title), [
        'DWARF_PANORAMA_A',
        'DWARF_PANORAMA_B',
      ]);
      expect(panoramas.first.filePath, '/DWARF3/Panoramas/DWARF_PANORAMA_A');
    },
  );

  test('rejects malformed 206 ranges then restarts from byte zero', () async {
    var interrupted = false;
    var malformedRangeSent = false;
    final raw = await _RawServer.start((socket, headers) async {
      final header = RegExp(
        r'^Range: bytes=(\d+)-',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(headers);
      final offset = header == null ? 0 : int.parse(header.group(1)!);
      if (header == null && !interrupted) {
        interrupted = true;
        await _rawResponse(
          socket,
          _jpeg.sublist(0, 8),
          _jpeg.length,
          etag: '"stable"',
        );
        return;
      }
      if (header != null && !malformedRangeSent) {
        malformedRangeSent = true;
        await _rawResponse(
          socket,
          _jpeg.sublist(offset),
          _jpeg.length - offset,
          status: 206,
          etag: '"stable"',
          contentRange:
              'bytes ${offset + 1}-${_jpeg.length - 1}/${_jpeg.length}',
        );
        return;
      }
      await _rawResponse(socket, _jpeg, _jpeg.length, etag: '"stable"');
    });
    addTearDown(raw.close);
    final url = 'http://127.0.0.1:${raw.port}/range.jpg';
    final service = DwarfDownloadService(
      rootDirectory: p.join(temp.path, 'downloads'),
      maxRetries: 0,
    );
    addTearDown(() => service.close(force: true));
    await service.downloadBatch(
      batchId: 'bad-range',
      originals: [DwarfOriginal(id: url, name: 'range.jpg', url: url)],
    );
    final result = await service.resumeBatch('bad-range');
    expect(malformedRangeSent, isTrue);
    expect(result.isComplete, isTrue, reason: result.error);
  });

  test(
    'keeps resumable bytes on cancellation and safely resumes them',
    () async {
      final raw = await _RawServer.start((socket, headers) async {
        final range = RegExp(
          r'^Range: bytes=(\d+)-',
          caseSensitive: false,
          multiLine: true,
        ).firstMatch(headers);
        final offset = range == null ? 0 : int.parse(range.group(1)!);
        if (offset == _jpeg.length) {
          await _rawResponse(
            socket,
            const [],
            0,
            status: 416,
            contentRange: 'bytes */${_jpeg.length}',
            etag: '"stable"',
          );
          return;
        }
        await _rawResponse(
          socket,
          _jpeg.sublist(offset),
          _jpeg.length - offset,
          status: offset > 0 ? 206 : 200,
          etag: '"stable"',
          contentRange: offset > 0
              ? 'bytes $offset-${_jpeg.length - 1}/${_jpeg.length}'
              : null,
        );
      });
      addTearDown(raw.close);
      final url = 'http://127.0.0.1:${raw.port}/image.jpg';
      final service = DwarfDownloadService(
        rootDirectory: p.join(temp.path, 'downloads'),
        maxRetries: 0,
      );
      addTearDown(() => service.close(force: true));
      final paused = await service.downloadBatch(
        batchId: 'cancel-resume',
        originals: [DwarfOriginal(id: url, name: 'image.jpg', url: url)],
        onProgress: (_) {
          unawaited(service.cancelBatch('cancel-resume'));
        },
      );
      expect(paused.state, DwarfDownloadState.cancelled);
      expect(await File('${paused.files.single.path}.part').exists(), isTrue);
      final resumed = await service.resumeBatch('cancel-resume');
      expect(resumed.isComplete, isTrue, reason: resumed.error);
    },
  );

  test(
    'recovers backup manifests and rejects paths outside the batch directory',
    () async {
      server.listen((request) async {
        request.response.contentLength = _jpeg.length;
        request.response.add(_jpeg);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/image.jpg';
      final service = DwarfDownloadService(
        rootDirectory: p.join(temp.path, 'downloads'),
      );
      addTearDown(() => service.close(force: true));
      final batch = await service.downloadBatch(
        batchId: 'manifest-check',
        originals: [DwarfOriginal(id: url, name: 'image.jpg', url: url)],
      );
      final manifest = File(
        p.join(
          p.dirname(batch.directory),
          p.basename(batch.directory),
          'manifest.json',
        ),
      );
      await manifest.rename('${manifest.path}.bak');
      expect((await service.loadBatch('manifest-check'))?.isComplete, isTrue);
      final backup = File('${manifest.path}.bak');
      final json =
          jsonDecode(await backup.readAsString()) as Map<String, Object?>;
      final files = (json['files']! as List).cast<Map<String, Object?>>();
      files.single['path'] = p.join(p.dirname(batch.directory), 'sibling.jpg');
      await backup.writeAsString(jsonEncode(json));
      await expectLater(
        service.loadBatch('manifest-check'),
        throwsFormatException,
      );
    },
  );

  test('does not treat empty or unknown-schema manifests as complete', () {
    const empty = DwarfDownloadBatch(
      id: 'empty',
      directory: '/tmp/empty',
      state: DwarfDownloadState.completed,
      files: [],
    );
    expect(empty.isComplete, isFalse);
    expect(
      () => DwarfDownloadBatch.fromJson({'schema': 99, 'files': []}),
      throwsFormatException,
    );
  });

  test('rejects duplicate and path-bearing original names', () async {
    final service = DwarfDownloadService(
      rootDirectory: p.join(temp.path, 'downloads'),
    );
    addTearDown(() => service.close(force: true));
    const source = DwarfOriginal(
      id: 'a',
      name: 'same.jpg',
      url: 'http://127.0.0.1/a',
    );
    await expectLater(
      service.downloadBatch(batchId: 'duplicate', originals: [source, source]),
      throwsArgumentError,
    );
    await expectLater(
      service.downloadBatch(
        batchId: 'unsafe',
        originals: [
          const DwarfOriginal(
            id: 'b',
            name: '../escape.jpg',
            url: 'http://127.0.0.1/b',
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('prevents concurrent writers for the same batch id', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      request.response.contentLength = _jpeg.length;
      request.response.add(_jpeg);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/race.jpg';
    final service = DwarfDownloadService(
      rootDirectory: p.join(temp.path, 'downloads'),
    );
    addTearDown(() => service.close(force: true));
    final source = DwarfOriginal(id: url, name: 'race.jpg', url: url);
    final first = service.downloadBatch(
      batchId: 'same-batch',
      originals: [source],
    );
    await entered.future;
    await expectLater(
      service.downloadBatch(batchId: 'same-batch', originals: [source]),
      throwsStateError,
    );
    release.complete();
    expect((await first).isComplete, isTrue);
  });
}
