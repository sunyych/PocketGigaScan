import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/dwarf_device_client.dart';
import 'package:stitch_app/services/dwarf_download_service.dart';
import 'package:stitch_app/services/mobile_runtime_service.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';

// Generated 16x16 JPEG, with a valid large APP segment inserted to exercise
// interruption at a nontrivial offset. No camera originals are embedded.
List<int> _jpeg() {
  final raster = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAQABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwCCiiivdPFP/9k=',
  );
  return [
    0xff,
    0xd8,
    0xff,
    0xe2,
    0x80,
    0x02,
    ...List<int>.filled(32768, 0x31),
    ...raster.skip(2),
  ];
}

class _FixtureQueues extends BatchQueueRepository {
  _FixtureQueues(this.directory);
  final Directory directory;
  @override
  Future<Directory> root() async {
    await directory.create(recursive: true);
    return directory;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const cameraHost = String.fromEnvironment('DWARF_TEST_HOST');
  if (cameraHost.isNotEmpty) {
    testWidgets('real STA camera identity and panorama enumeration', (_) async {
      final camera = DwarfDeviceClient(cameraHost);
      try {
        final info = await camera.probe();
        expect(info.deviceName.toLowerCase(), contains('dwarf'));
        expect(info.deviceId, isNotEmpty);
        expect(info.sdCardAvailable, isTrue);
        final panoramas = await camera.listPanoramas();
        // Never log raw device responses, serials, credentials or photo names.
        debugPrint(
          'Real DWARF identity verified; panorama packages: ${panoramas.length}',
        );
        if (panoramas.isNotEmpty) {
          final originals = await camera.listOriginals(panoramas.first);
          expect(originals, isNotEmpty);
          debugPrint('First package enumerated originals: ${originals.length}');
        }
      } finally {
        camera.close(force: true);
      }
    });
  }

  testWidgets(
    'phone downloads, reloads and resumes originals before durable queue admission',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final root = Directory(
        p.join(
          support.path,
          'dwarf-device-fixture-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await root.create(recursive: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = _jpeg();
      var interrupt = true;
      var rangeRequests = 0;
      final requestErrors = <Object>[];
      server.listen((request) async {
        try {
          final path = request.uri.path;
          if (request.method == 'POST') {
            final body = jsonDecode(await utf8.decoder.bind(request).join());
            Object data;
            if (path == '/deviceInfo') {
              data = {
                'deviceName': 'DWARF3_fixture',
                'deviceId': 'DWARF3',
                'sdCardAvailable': true,
              };
            } else if (path == '/album/list/mediaCounts') {
              data = [
                {'mediaType': 5, 'count': 1},
              ];
            } else {
              expect(body['pageIndex'], 0);
              data = [
                {
                  'fileName': 'DWARF_PANORAMA_fixture',
                  'filePath': '/DWARF3/Panoramas/DWARF_PANORAMA_fixture/',
                  'fileSize': 0,
                  'mediaType': 5,
                },
              ];
            }
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'code': 0, 'data': data}));
            await request.response.close();
            return;
          }
          if (path.endsWith('/')) {
            request.response.headers.contentType = ContentType.html;
            request.response.write(
              '<html>${['0_0', '0_1', '1_0', '1_1'].map((n) => '<a href="$n.jpg">$n.jpg</a>').join()}</html>',
            );
            await request.response.close();
            return;
          }
          request.response.headers.set(HttpHeaders.etagHeader, '"fixture-v1"');
          request.response.headers.contentType = ContentType('image', 'jpeg');
          final range = request.headers.value(HttpHeaders.rangeHeader);
          final offset = range == null
              ? 0
              : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          if (offset > 0) {
            rangeRequests++;
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $offset-${bytes.length - 1}/${bytes.length}',
            );
          }
          request.response.contentLength = bytes.length - offset;
          if (interrupt) {
            interrupt = false;
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nETag: "fixture-v1"\r\nContent-Length: ${bytes.length}\r\nConnection: close\r\n\r\n',
              ),
            );
            socket.add(bytes.sublist(offset, offset + 8192));
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 50));
            socket.destroy();
            return;
          }
          request.response.add(bytes.sublist(offset));
          await request.response.close();
        } on Object catch (error) {
          requestErrors.add(error);
        }
      });
      final device = DwarfDeviceClient(
        '127.0.0.1',
        apiPort: server.port,
        mediaPort: server.port,
      );
      var downloader = DwarfDownloadService(
        rootDirectory: p.join(root.path, 'downloads'),
        maxRetries: 0,
      );
      final runtime = MobileRuntimeService();
      final tasks = TaskRepository(
        rootDirectory: Directory(p.join(root.path, 'tasks')),
      );
      final queues = _FixtureQueues(Directory(p.join(root.path, 'queues')));
      final api = NativeJobApi();
      final controller = BatchQueueController(
        api: api,
        taskRepository: tasks,
        queueRepository: queues,
      );
      try {
        expect((await device.probe()).deviceName, 'DWARF3_fixture');
        final panoramas = await device.listPanoramas();
        expect(panoramas, hasLength(1));
        final originals = await device.listOriginals(panoramas.single);
        expect(originals.map((f) => f.name), [
          '0_0.jpg',
          '0_1.jpg',
          '1_0.jpg',
          '1_1.jpg',
        ]);
        final failed = await downloader.downloadBatch(
          batchId: 'phone-fixture',
          originals: originals,
        );
        expect(failed.isComplete, isFalse);
        expect(controller.queues, isEmpty);
        downloader.close(force: true);
        downloader = DwarfDownloadService(
          rootDirectory: p.join(root.path, 'downloads'),
          maxRetries: 0,
        );
        expect(await downloader.listBatches(), hasLength(1));
        final complete = await downloader.resumeBatch('phone-fixture');
        expect(complete.isComplete, isTrue, reason: complete.error);
        expect(rangeRequests, greaterThan(0));
        for (final photo in complete.files) {
          expect(
            sha256.convert(await File(photo.path).readAsBytes()),
            sha256.convert(bytes),
          );
        }
        await controller.addCompletedPanoramas([complete]);
        expect(controller.queues, hasLength(1));
        expect(controller.queues.single.items, hasLength(1));
        final task = (await tasks.loadAll()).single;
        expect(
          task.photos.map((p) => p.originalName),
          originals.map((o) => o.name),
        );
        expect(task.grid.rows, 2);
        expect(task.grid.columns, 2);
        await controller.addCompletedPanoramas([complete]);
        expect(controller.queues, hasLength(1));
        expect((await queues.loadAll()).single.items, hasLength(1));
        expect(api.isAvailable, isTrue, reason: api.unavailableReason);
        expect((await runtime.readResourceBudget()).cpuCount, greaterThan(0));
        expect(requestErrors, isEmpty);
      } finally {
        controller.dispose();
        await controller.drain();
        await runtime.dispose();
        device.close(force: true);
        downloader.close(force: true);
        await server.close(force: true);
        // Only this test's uniquely owned private fixture directory is removed.
        await root.delete(recursive: true);
      }
    },
  );
}
