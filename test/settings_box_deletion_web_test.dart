// The stage-0 measurement the settings-group delete had to wait on: the web
// counterpart of settings_box_deletion_windows_test.dart. What actually happens
// when something tries to remove a settings box's backing storage while
// `StorageBox.ensureOpened` still holds a connection to it, on the platform
// where "a box" is not a file at all but an IndexedDB database
// (`hive_ce-2.19.3`'s JS backend -- pub-cache
// hive_ce-2.19.3/lib/src/backend/js/native/backend_manager.dart:16-56 -- names
// the database after the box, e.g. box `settings` lives in IndexedDB database
// `settings`, object store `box`).
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/settings_box_deletion_web_test.dart
//
// It must run in a real browser and under `dart test`, for the same two
// reasons as record_mutation_lock_web_test.dart / storage_persistence_web_test.dart:
// `dart:js_interop` semantics only exist there, and the flutter runner would
// compile the whole framework first (observed to sit at "loading" for 40+ min
// locally -- see the comment on the `browser-tests` job in
// .github/workflows/ci.yml). CI runs this in that `Browser tests` job; a file
// not named on its command line is run by nothing.
//
// This suite deliberately does not import `storage_box.dart` (it pulls in
// `package:hive_ce_flutter`, whose `HiveFlutterExtension.initFlutter` in turn
// reaches `package:flutter`, which `dart test` cannot compile for the browser --
// the same reason opfs_delete_failure_web_test.dart drives OPFS directly instead
// of going through `WebVfs`). `package:hive_ce` (the non-Flutter base package
// storage_box.dart's `Hive` global comes from) has no Flutter dependency and is
// usable here directly; `Hive.init(path)` ignores `path` on the web backend, so
// the same `Hive.openBox`/`Hive.deleteBoxFromDisk` calls `StorageBox` makes are
// exercised for real, against real IndexedDB, in this process.
//
// Findings pinned here -- this suite is the writeup:
//  * `Hive.deleteBoxFromDisk(name)` on a box that is still open succeeds
//    without hanging or throwing -- unlike Windows. `StorageBackendJs.deleteFromDisk`
//    (storage_backend_vm.dart's web sibling, storage_backend_js.dart:222-246)
//    calls `_db.close()` before `indexedDB.deleteDatabase(...)`, exactly
//    mirroring the VM backend's close-then-delete `_closeInternal()`. So the
//    official Hive API is safe to call on an open settings box on *both*
//    platforms; neither needs a prior explicit `Hive.close()`.
//  * The pathological case -- deleting the underlying IndexedDB database
//    directly while a connection to it is open, bypassing Hive's own
//    close-then-delete -- does not throw and does not silently succeed either.
//    Per the IndexedDB spec, `IDBFactory.deleteDatabase()` against a database
//    with an open connection fires a `blocked` event and the delete request
//    then sits pending until every open connection closes. This is the web
//    analogue of the Windows sharing violation, but the failure shape is the
//    opposite: Windows fails fast with `ERROR_SHARING_VIOLATION`; web does not
//    fail at all, it stalls indefinitely with no error surfaced anywhere until
//    something closes the connection.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:hive_ce/hive.dart';
// `package:test` resolves transitively through `flutter_test`, so no
// dev_dependency entry is added -- see the sibling browser suites for the same
// note.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// The suite's own wedge detector for the raw IndexedDB calls below, longer
/// than any bound `Hive.deleteBoxFromDisk` itself might apply -- see
/// storage_persistence_web_test.dart's `_guard` for why this has to be an
/// independent, larger number rather than reused as the thing under test.
const _guard = Duration(seconds: 10);

/// Waits for [request]'s `success` or `error` event and resolves to the
/// request's `result`, or rethrows the DOM error. `IDBRequest` (and its
/// `IDBOpenDBRequest` subtype, covering `open`/`deleteDatabase`) is bare event
/// wiring with no `Future`-returning method on it in `package:web`; `hive_ce`
/// has the identical helper as a private extension
/// (backend/js/native/utils.dart's `IDBRequestExtension.asFuture`), so this is
/// not a new idea, just re-declared because that one is not exported.
Future<T?> _settled<T extends JSAny?>(web.IDBRequest request) {
  final completer = Completer<T?>();
  request.onsuccess = ((web.Event e) {
    if (!completer.isCompleted) completer.complete(request.result as T?);
  }).toJS;
  request.onerror = ((web.Event e) {
    if (!completer.isCompleted) {
      completer.completeError(request.error ?? StateError('IDBRequest error, no DOMException'));
    }
  }).toJS;
  return completer.future;
}

/// Opens a fresh IndexedDB database of [name] with a single `box` object
/// store, mirroring what `BackendManager.open` (backend_manager.dart:16-56)
/// does for a non-collection Hive box.
Future<web.IDBDatabase> _openRawDatabase(String name) {
  final request = web.window.indexedDB.open(name, 1);
  request.onupgradeneeded = ((web.IDBVersionChangeEvent e) {
    final db = (e.target as web.IDBOpenDBRequest).result as web.IDBDatabase;
    if (!db.objectStoreNames.contains('box')) {
      db.createObjectStore('box');
    }
  }).toJS;
  return _settled<web.IDBDatabase>(request).then((db) => db!);
}

void main() {
  test('positive control: closing the box first lets deleteBoxFromDisk complete promptly', () async {
    final name = 'u13_control_${DateTime.now().microsecondsSinceEpoch}';
    Hive.init(null);
    final box = await Hive.openBox(name);
    await box.put('k', 1);
    await box.close();

    await Hive.deleteBoxFromDisk(name).timeout(_guard);

    // Reopening must come back empty: proof the delete was real, not a facade
    // in front of a database Hive quietly recreated underneath it.
    final reopened = await Hive.openBox(name);
    expect(reopened.isEmpty, isTrue);
    await reopened.close();
    await Hive.deleteBoxFromDisk(name).timeout(_guard);
  });

  test(
    'Hive.deleteBoxFromDisk on a still-open box completes promptly -- unlike Windows, no error and no hang',
    () async {
      final name = 'u13_open_${DateTime.now().microsecondsSinceEpoch}';
      Hive.init(null);
      final box = await Hive.openBox(name);
      await box.put('k', 1);
      // No box.close() / Hive.close() here on purpose: the box is exactly as
      // open as it is during a live app session.

      final stopwatch = Stopwatch()..start();
      await Hive.deleteBoxFromDisk(name).timeout(_guard);
      stopwatch.stop();
      // ignore: avoid_print
      print('[deleteBoxFromDisk(open box)] completed in ${stopwatch.elapsedMilliseconds} ms');

      final reopened = await Hive.openBox(name);
      expect(
        reopened.isEmpty,
        isTrue,
        reason: 'the delete must have been real, not a no-op the still-open box papered over',
      );
      await reopened.close();
      await Hive.deleteBoxFromDisk(name).timeout(_guard);
    },
  );

  test('deleting the underlying IndexedDB database directly, bypassing Hive, while a connection is open, '
      'blocks instead of failing -- the opposite failure shape from the Windows sharing violation', () async {
    final name = 'u13_raw_${DateTime.now().microsecondsSinceEpoch}';
    final db = await _openRawDatabase(name);
    // Hold `db` open -- do not close it. This is the raw analogue of the VM
    // test's "the box is still open" setup, except reached by driving
    // IndexedDB directly instead of through Hive's own (closes-first)
    // deleteFromDisk, the same way opfs_delete_failure_web_test.dart drives
    // OPFS directly instead of through WebVfs.

    final deleteRequest = web.window.indexedDB.deleteDatabase(name);
    var blockedFired = false;
    deleteRequest.onblocked = ((web.Event e) => blockedFired = true).toJS;

    final outcome = await _settled<JSAny?>(
      deleteRequest,
    ).then<String>((_) => 'success').timeout(const Duration(seconds: 3), onTimeout: () => 'no-answer-within-3s');
    // ignore: avoid_print
    print('[deleteDatabase(open connection), 3s bound] outcome=$outcome blockedFired=$blockedFired');

    // The measured fact: the delete neither completes nor errors while the
    // connection stays open. If a future browser change makes this complete
    // anyway, that is worth knowing -- this line turning red is that signal,
    // not a bug in the harness.
    expect(
      outcome,
      'no-answer-within-3s',
      reason: 'IndexedDB deleteDatabase against an open connection was expected to stall, not settle',
    );
    expect(
      blockedFired,
      isTrue,
      reason: 'the spec-mandated `blocked` event must fire even while the delete itself never settles',
    );

    // Closing the connection is what the app would do through Hive's own
    // deleteFromDisk automatically; done here by hand to observe that the
    // stalled request unblocks once nothing holds the database open, so the
    // delete this test issued is not silently lost -- and to leave IndexedDB
    // clean for whatever runs after this test.
    db.close();
    final finished = await _settled<JSAny?>(deleteRequest).timeout(_guard);
    expect(finished, isNull, reason: 'IDBFactory.deleteDatabase resolves its result to undefined/null on success');
  });
}
