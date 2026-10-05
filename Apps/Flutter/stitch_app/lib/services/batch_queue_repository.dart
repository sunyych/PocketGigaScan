import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

import '../models/batch_queue.dart';
import 'legacy_support_directory.dart';

class BatchQueueRepository {
  BatchQueueRepository({this._rootDirectory});
  final Directory? _rootDirectory;
  Future<void> _writeTail = Future.value();

  Future<Directory> root() async {
    final base =
        _rootDirectory ??
        await legacyCompatibleSupportDirectory(
          platformSupportRoot: await getApplicationSupportDirectory(),
          dataFolder: 'batches',
        );
    await base.create(recursive: true);
    return base;
  }

  Future<void> save(BatchQueue queue) async {
    final previous = _writeTail;
    final next = previous.then((_) => _write(queue));
    _writeTail = next.catchError((Object _) {});
    await next;
  }

  Future<void> _write(BatchQueue queue) async {
    final directory = Directory(p.join((await root()).path, queue.id));
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, 'batch.json'));
    final suffix = sha256
        .convert(
          '${DateTime.now().microsecondsSinceEpoch}:${queue.id}'.codeUnits,
        )
        .toString()
        .substring(0, 12);
    final temporary = File('${file.path}.tmp-$suffix');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(queue.toJson())}\n',
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<List<BatchQueue>> loadAll() async {
    final base = await root();
    final queues = <BatchQueue>[];
    await for (final entity in base.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'batch.json'));
      if (!await file.exists()) continue;
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is! Map<String, Object?> || json['schemaVersion'] != 1) {
          continue;
        }
        final loaded = BatchQueue.fromJson(json);
        if (loaded.id != p.basename(entity.path) || !_validPaths(loaded)) {
          continue;
        }
        queues.add(loaded);
      } on Object {
        // Preserve unreadable records for diagnosis.
      }
    }
    queues.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return queues;
  }

  bool _validPaths(BatchQueue queue) {
    if (queue.parentDirectory.trim().isEmpty) return false;
    final expectedOutput = p.normalize(
      p.join(
        p.dirname(p.normalize(queue.parentDirectory)),
        '${p.basename(p.normalize(queue.parentDirectory))}_stitched',
      ),
    );
    if (p.normalize(queue.outputDirectory) != expectedOutput) return false;
    for (final item in queue.items) {
      if (item.id.isEmpty || item.name.isEmpty) return false;
      if (item.sourceDirectory.isEmpty ||
          p.dirname(p.normalize(item.sourceDirectory)) !=
              p.normalize(queue.parentDirectory)) {
        return false;
      }
      if (item.taskId != null &&
          !RegExp(r'^[0-9]+-[a-f0-9]+$').hasMatch(item.taskId!)) {
        return false;
      }
    }
    return true;
  }
}
