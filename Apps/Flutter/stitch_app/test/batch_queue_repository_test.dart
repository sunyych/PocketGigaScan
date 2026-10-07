import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/models/stitch_quality.dart';
import 'package:stitch_app/services/batch_queue_repository.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('batch-queue-test-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'persists ordered states, pause intent, progress, elapsed time and ETA',
    () async {
      final parent = Directory(
        '${temporary.path}${Platform.pathSeparator}parent',
      )..createSync();
      final first = Directory('${parent.path}${Platform.pathSeparator}first')
        ..createSync();
      final second = Directory('${parent.path}${Platform.pathSeparator}second')
        ..createSync();
      final queue = BatchQueue(
        id: '100-abcdef12',
        createdAt: DateTime.utc(2026),
        parentDirectory: parent.path,
        outputDirectory:
            '${temporary.path}${Platform.pathSeparator}parent_stitched',
        exportDestination: 'content://provider/tree/export',
        performanceOptions: const PerformanceOptions(fastRegistration: true),
        refineGridNeighbors: false,
        seamBlendMode: SeamBlendMode.feather,
        localTextureWarp: false,
        items: [
          BatchQueueItem(
            id: '101-abcdef12',
            name: 'first',
            sourceDirectory: first.path,
            state: BatchItemState.running,
            taskId: '101-abcdef12',
            pauseRequested: true,
            progress: 0.34,
            etaSeconds: 50,
            elapsedSeconds: 17,
            lastTickAt: DateTime.utc(2026, 1, 1),
            progressSamples: [ProgressSample(DateTime.utc(2026, 1, 1), 0.1)],
          ),
          BatchQueueItem(
            id: '102-abcdef12',
            name: 'second',
            sourceDirectory: second.path,
            state: BatchItemState.cancelled,
            message: 'user cancelled',
          ),
        ],
      );
      await BatchQueueRepository(
        rootDirectory: Directory(
          '${temporary.path}${Platform.pathSeparator}store',
        ),
      ).save(queue);
      final loaded = await BatchQueueRepository(
        rootDirectory: Directory(
          '${temporary.path}${Platform.pathSeparator}store',
        ),
      ).loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.single.items.map((item) => item.state), [
        BatchItemState.running,
        BatchItemState.cancelled,
      ]);
      expect(loaded.single.items.first.pauseRequested, isTrue);
      expect(loaded.single.items.first.progress, 0.34);
      expect(loaded.single.items.first.etaSeconds, 50);
      expect(loaded.single.items.first.elapsedSeconds, 17);
      expect(loaded.single.items.first.progressSamples, hasLength(1));
      expect(loaded.single.exportDestination, 'content://provider/tree/export');
      expect(loaded.single.performanceOptions.fastRegistration, isTrue);
      expect(loaded.single.refineGridNeighbors, isFalse);
      expect(loaded.single.seamBlendMode, SeamBlendMode.feather);
      expect(loaded.single.localTextureWarp, isFalse);
    },
  );

  test('rejects tampered queue paths outside its parent', () async {
    final parent = Directory('${temporary.path}${Platform.pathSeparator}parent')
      ..createSync();
    final child = Directory('${parent.path}${Platform.pathSeparator}child')
      ..createSync();
    final repository = BatchQueueRepository(
      rootDirectory: Directory(
        '${temporary.path}${Platform.pathSeparator}store',
      ),
    );
    await repository.save(
      BatchQueue(
        id: '200-abcdef12',
        createdAt: DateTime.utc(2026),
        parentDirectory: parent.path,
        outputDirectory:
            '${temporary.path}${Platform.pathSeparator}parent_stitched',
        items: [
          BatchQueueItem(
            id: '201-abcdef12',
            name: 'child',
            sourceDirectory: child.path,
            state: BatchItemState.pending,
          ),
        ],
      ),
    );
    final record = File(
      '${temporary.path}${Platform.pathSeparator}store${Platform.pathSeparator}200-abcdef12${Platform.pathSeparator}batch.json',
    );
    final json =
        jsonDecode(await record.readAsString()) as Map<String, Object?>;
    final items = json['items']! as List<Object?>;
    final item = items.single! as Map<String, Object?>;
    item['sourceDirectory'] = temporary.path;
    await record.writeAsString(jsonEncode(json));
    expect(await repository.loadAll(), isEmpty);
  });
}
