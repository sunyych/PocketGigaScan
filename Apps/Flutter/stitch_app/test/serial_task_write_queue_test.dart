import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/performance_options.dart';
import 'package:stitch_app/services/serial_task_write_queue.dart';

class _GatedTaskRepository {
  final firstWriteGate = Completer<void>();
  final firstWriteStarted = Completer<void>();
  final savedOptions = <PerformanceOptions>[];

  Future<void> save(PerformanceOptions options) async {
    if (savedOptions.isEmpty) {
      firstWriteStarted.complete();
      await firstWriteGate.future;
    }
    savedOptions.add(options);
  }
}

void main() {
  test(
    'queued checkbox and task saves cannot overwrite the newest settings',
    () async {
      final queue = SerialTaskWriteQueue();
      final repository = _GatedTaskRepository();
      const firstChange = PerformanceOptions(parallelMatching: false);
      const manualTaskSave = PerformanceOptions(parallelMatching: false);
      const lastChange = PerformanceOptions(parallelMatching: true);

      final first = queue.enqueue(() => repository.save(firstChange));
      await repository.firstWriteStarted.future;
      final manual = queue.enqueue(() => repository.save(manualTaskSave));
      final latest = queue.enqueue(() => repository.save(lastChange));
      expect(repository.savedOptions, isEmpty);

      repository.firstWriteGate.complete();
      await Future.wait([first, manual, latest]);
      expect(repository.savedOptions, [
        firstChange,
        manualTaskSave,
        lastChange,
      ]);
    },
  );
}
