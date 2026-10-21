import 'dart:async';

import 'package:umacapture/src/core/fs/fs_backend_io.dart';

/// Suspends the write of one file until [release] is called, and behaves as the real filesystem
/// everywhere else. A record.json is replaced by renaming a staged file over it, so the rename onto
/// [heldPath] is the moment its contents change, and the one held.
class HeldWriteFsBackend extends IoFsBackend {
  HeldWriteFsBackend(this.heldPath);

  final String heldPath;
  final Completer<void> _gate = Completer<void>();

  /// Whether the held write has been reached and is waiting.
  bool held = false;

  void release() => _gate.complete();

  @override
  Future<void> rename(String source, String destination) async {
    if (destination == heldPath) {
      held = true;
      await _gate.future;
    }
    return super.rename(source, destination);
  }
}
