import 'package:stitch_app/models/batch_queue.dart';
import 'package:stitch_app/services/batch_queue_controller.dart';
import 'package:stitch_app/services/task_repository.dart';

/// Keeps single-task widget fixtures deterministic without restoring local
/// queue files or starting the controller's periodic worker.
class EmptyBatchQueueController extends BatchQueueController {
  EmptyBatchQueueController({
    required super.api,
    required TaskRepository taskRepository,
    this.initialQueues = const <BatchQueue>[],
  }) : super(taskRepository: taskRepository);

  final List<BatchQueue> initialQueues;

  @override
  List<BatchQueue> get queues => initialQueues;

  @override
  Future<void> initialize() async {}
}
