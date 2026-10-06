import 'dart:async';
import 'dart:collection';

class TaskPool {
  TaskPool(this.concurrency) : assert(concurrency > 0);

  final int concurrency;

  final Queue<Completer<void>> _waiting = Queue();
  final Queue<Completer<void>> _priorityWaiting = Queue();
  int _active = 0;

  int get activeCount => _active;

  int get pendingCount => _waiting.length + _priorityWaiting.length;

  int get idleSlots => pendingCount == 0 ? concurrency - _active : 0;

  Future<T> run<T>(Future<T> Function() task, {bool priority = false}) async {
    if (_active >= concurrency || pendingCount > 0) {
      final waiter = Completer<void>();
      if (priority) {
        _priorityWaiting.add(waiter);
      } else {
        _waiting.add(waiter);
      }
      await waiter.future;
    } else {
      _active++;
    }
    try {
      return await task();
    } finally {
      if (_priorityWaiting.isNotEmpty) {
        _priorityWaiting.removeFirst().complete();
      } else if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}
