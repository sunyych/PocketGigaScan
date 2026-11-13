import 'package:flutter_test/flutter_test.dart';
import 'package:stitch_app/models/batch_queue.dart';

void main() {
  test('round-trips recovery and removable-media identity fields', () {
    final stableSince = DateTime.utc(2026, 11, 1, 12);
    final item = BatchQueueItem(
      id: 'item-1',
      name: 'panorama',
      sourceDirectory: '/Volumes/DWARF/Panorama',
      state: BatchItemState.completed,
      taskId: 'task-1',
      durableInputDirectory: '/tasks/task-1/input',
      publishFailed: true,
      message: 'destination unavailable',
      usbSourceIdentity: 'volume-17/panorama-3',
      usbSourceSignature: 'sha256:stable',
      usbStableSince: stableSince,
    );

    final restored = BatchQueueItem.fromJson(item.toJson());

    expect(restored.state, BatchItemState.completed);
    expect(restored.taskId, 'task-1');
    expect(restored.durableInputDirectory, '/tasks/task-1/input');
    expect(restored.publishFailed, isTrue);
    expect(restored.message, 'destination unavailable');
    expect(restored.usbSourceIdentity, 'volume-17/panorama-3');
    expect(restored.usbSourceSignature, 'sha256:stable');
    expect(restored.usbStableSince, stableSince);
  });

  test('retry copy can clear stale publication and staging state', () {
    const item = BatchQueueItem(
      id: 'item-2',
      name: 'panorama',
      sourceDirectory: '/source/panorama',
      state: BatchItemState.failed,
      taskId: 'task-2',
      durableInputDirectory: '/tasks/task-2/input',
      publishFailed: true,
      message: 'publish failed',
    );

    final retry = item.copyWith(
      state: BatchItemState.ready,
      clearDurableInputDirectory: true,
      clearPublishFailed: true,
      clearMessage: true,
    );

    expect(retry.state, BatchItemState.ready);
    expect(retry.taskId, 'task-2');
    expect(retry.durableInputDirectory, isNull);
    expect(retry.publishFailed, isFalse);
    expect(retry.message, isNull);
    expect(
      item.publishFailed,
      isTrue,
      reason: 'copyWith leaves persisted source immutable',
    );
  });
}
