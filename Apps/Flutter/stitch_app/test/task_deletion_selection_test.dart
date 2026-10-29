import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/models/stitch_task.dart';
import 'package:stitch_app/services/task_deletion_selection.dart';

void main() {
  test(
    'successful tasks keep files by default and allow an explicit override',
    () {
      final selection = TaskDeletionSelection.forTasks([StitchPhase.completed]);

      expect(selection.deleteOtherFiles, isFalse);
      expect(selection.deletesFilesFor(StitchPhase.completed), isFalse);
      expect(
        selection
            .copyWith(deleteOtherFiles: true)
            .deletesFilesFor(StitchPhase.completed),
        isTrue,
      );
    },
  );

  test('failed tasks remove files by default and allow retaining them', () {
    final selection = TaskDeletionSelection.forTasks([StitchPhase.failed]);

    expect(selection.deleteFailedFiles, isTrue);
    expect(selection.deletesFilesFor(StitchPhase.failed), isTrue);
    expect(
      selection
          .copyWith(deleteFailedFiles: false)
          .deletesFilesFor(StitchPhase.failed),
      isFalse,
    );
  });

  test('mixed selection keeps separate failed and other-task choices', () {
    final selection = TaskDeletionSelection.forTasks([
      StitchPhase.completed,
      StitchPhase.failed,
    ]);

    expect(selection.deleteFailedFiles, isTrue);
    expect(selection.deleteOtherFiles, isFalse);
    expect(selection.deletesFilesFor(StitchPhase.failed), isTrue);
    expect(selection.deletesFilesFor(StitchPhase.completed), isFalse);
  });

  test('queue removal defaults use queue failure state', () {
    expect(
      TaskDeletionSelection.forQueueItem(
        BatchItemState.failed,
      ).deleteFailedFiles,
      isTrue,
    );
    expect(
      TaskDeletionSelection.forQueueItem(
        BatchItemState.completed,
      ).deleteFailedFiles,
      isFalse,
    );
  });
}
