class SerialTaskWriteQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> enqueue(Future<void> Function() write) {
    final pending = _tail.then((_) => write());
    _tail = pending.catchError((Object _) {});
    return pending;
  }
}
