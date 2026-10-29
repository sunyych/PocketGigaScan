import '../models/stitch_task.dart';
import '../models/batch_queue.dart';

/// File-cleanup checkbox defaults and overrides for local task deletion.
class TaskDeletionSelection {
  const TaskDeletionSelection({
    this.deleteFailedFiles = true,
    this.deleteOtherFiles = false,
  });

  factory TaskDeletionSelection.forTasks(Iterable<StitchPhase> phases) {
    final values = phases.toList();
    return TaskDeletionSelection(
      deleteFailedFiles: values.contains(StitchPhase.failed),
      deleteOtherFiles: false,
    );
  }

  factory TaskDeletionSelection.forQueueItem(BatchItemState state) =>
      TaskDeletionSelection(
        deleteFailedFiles: state == BatchItemState.failed,
        deleteOtherFiles: false,
      );

  final bool deleteFailedFiles;
  final bool deleteOtherFiles;

  bool deletesFilesFor(StitchPhase phase) =>
      phase == StitchPhase.failed ? deleteFailedFiles : deleteOtherFiles;

  TaskDeletionSelection copyWith({
    bool? deleteFailedFiles,
    bool? deleteOtherFiles,
  }) => TaskDeletionSelection(
    deleteFailedFiles: deleteFailedFiles ?? this.deleteFailedFiles,
    deleteOtherFiles: deleteOtherFiles ?? this.deleteOtherFiles,
  );
}
