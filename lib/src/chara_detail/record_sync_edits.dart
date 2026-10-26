// The user's edits of what sync carries ([SyncLocalEdits]): what asks for a round five seconds after the last of them
// (`recordSyncTriggersProvider`).
//
// An edit is an operation of the user's that changes the list a round sends — a capture or a video import, a
// re-recognition, an archive, a delete from the record table or from the storage management, a merge, a dismissed
// pair, a zip import, an inheritance resolution the user starts from the settings, a rating, a memo, a column's title
// or its removal — and each says so where the user makes it.
// What a round of sync takes in is not one: a round writes through the same stores and controllers, but through
// entries of its own (its place, a controller's `takeSynced`), and says nothing, so what it puts in place asks for no
// round of its own.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The user's edits of what sync carries on this device, counted: each operation of the user's that changes the list
/// a round sends says so once it has ([edited]).
class SyncLocalEdits extends Notifier<int> {
  @override
  int build() => 0;

  /// The user changed what sync carries.
  void edited() => state++;
}

final syncLocalEditsProvider = NotifierProvider<SyncLocalEdits, int>(SyncLocalEdits.new);
