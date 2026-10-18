import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stitch_app/models/dwarf_download.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';
import 'package:stitch_app/services/dwarf_download_service.dart';
import 'package:stitch_app/services/native_job_api.dart';
import 'package:stitch_app/services/task_repository.dart';

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

class _NoopJobApi implements JobApi {
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Map<String, Object?>> capabilities() async => const {};
  @override
  Future<Map<String, Object?>> cancel(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> configureResources({
    required int totalCpuWorkers,
    required int totalMemoryBudgetMiB,
    required int maxConcurrentJobs,
  }) async => const {};
  @override
  Future<Map<String, Object?>> export(String jobId, String destination) async =>
      const {};
  @override
  Future<Map<String, Object?>> pause(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> resume(String jobId) async => const {};
  @override
  Future<Map<String, Object?>> start(
    Map<String, Object?> request,
    String outputDirectory, {
    required int memoryBudgetMiB,
    required int workers,
  }) async => const {};
  @override
  Future<Map<String, Object?>> status(String jobId) async => const {};
}

void main() {
  late Directory temporary;
  late HttpServer server;
  late DwarfDownloadService downloader;
  late BatchQueueRepository queues;
  late TaskRepository tasks;
  late BatchQueueController controller;
  late DwarfDownloadBatch completeBatch;
  late File manifestFile;
  late String validManifest;

  BatchQueueController newController() => BatchQueueController(
    api: _NoopJobApi(),
    queueRepository: queues,
    taskRepository: tasks,
  );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('dwarf-queue-admission-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'jpeg');
      request.response.contentLength = _jpeg.length;
      request.response.add(_jpeg);
      await request.response.close();
    });
    final downloadRoot = p.join(temporary.path, 'downloads');
    downloader = DwarfDownloadService(rootDirectory: downloadRoot);
    final url = 'http://127.0.0.1:${server.port}/Panorama_01/0_0.jpg';
    completeBatch = await downloader.downloadBatch(
      batchId: 'host-device-panorama-01',
      originals: [
        DwarfOriginal(id: url, name: '0_0.jpg', url: url, size: _jpeg.length),
      ],
      metadata: const {
        'host': '192.168.88.1',
        'deviceName': 'DWARF3',
        'title': 'Panorama 01',
        'panoramaId': '/DWARF3/Panoramas/Panorama_01',
      },
    );
    manifestFile = File(p.join(completeBatch.directory, 'manifest.json'));
    validManifest = await manifestFile.readAsString();
    queues = BatchQueueRepository(
      rootDirectory: Directory(p.join(temporary.path, 'queues')),
    );
    tasks = TaskRepository(
      rootDirectory: Directory(p.join(temporary.path, 'tasks')),
    );
    controller = newController();
  });

  tearDown(() async {
    controller.dispose();
    await controller.drain();
    downloader.close(force: true);
    await server.close(force: true);
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'queues only a verified completed panorama and keeps its title',
    () async {
      expect(completeBatch.isComplete, isTrue);

      await controller.addCompletedPanoramas([completeBatch]);

      expect(controller.queues, hasLength(1));
      expect(controller.queues.single.items, hasLength(1));
      expect(controller.queues.single.items.single.name, 'Panorama 01');
      expect(
        controller.queues.single.items.single.sourceDirectory,
        completeBatch.directory,
      );
      expect(await queues.loadAll(), hasLength(1));
    },
  );

  test(
    'rejects paused or tampered manifests before creating queue work',
    () async {
      final incompleteJson = (jsonDecode(validManifest) as Map)
          .cast<String, Object?>();
      incompleteJson['state'] = DwarfDownloadState.paused.name;
      await manifestFile.writeAsString(jsonEncode(incompleteJson), flush: true);
      final incomplete = (await downloader.loadBatch(completeBatch.id))!;
      expect(incomplete.isComplete, isFalse);
      await expectLater(
        controller.addCompletedPanoramas([incomplete]),
        throwsA(isA<StateError>()),
      );
      expect(controller.queues, isEmpty);

      final corruptManifest = (jsonDecode(validManifest) as Map)
          .cast<String, Object?>();
      corruptManifest['files'] = [
        ...((corruptManifest['files']! as List).cast<Map>()),
      ];
      final savedFile = (corruptManifest['files']! as List).single as Map;
      savedFile['sha256'] = '0' * 64;
      await manifestFile.writeAsString(
        jsonEncode(corruptManifest),
        flush: true,
      );
      final corruptBatch = (await downloader.loadBatch(completeBatch.id))!;
      await expectLater(
        controller.addCompletedPanoramas([corruptBatch]),
        throwsA(isA<StateError>()),
      );
      expect(controller.queues, isEmpty);

      await manifestFile.writeAsString(validManifest, flush: true);
      await File(
        completeBatch.files.single.path,
      ).writeAsBytes(List<int>.from(_jpeg)..[10] = 0x7f, flush: true);
      await expectLater(
        controller.addCompletedPanoramas([completeBatch]),
        throwsA(isA<StateError>()),
      );
      expect(controller.queues, isEmpty);
    },
  );

  test('deduplicates a panorama after controller restart', () async {
    await controller.addCompletedPanoramas([completeBatch]);
    final queueId = controller.queues.single.id;
    controller.dispose();
    await controller.drain();
    controller = newController();
    await controller.initialize();

    await controller.addCompletedPanoramas([completeBatch]);

    expect(controller.queues, hasLength(1));
    expect(controller.queues.single.id, queueId);
    expect(controller.queues.single.items, hasLength(1));
  });
}
