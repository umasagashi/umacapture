// Who owns a teardown of the wasm worker's event loop, and therefore who owns the harvest it
// produces (`TeardownRegistry` / `PendingTeardown` in `lib/src/core/wasm_worker_ops.dart`).
// Run: .fvm/flutter_sdk/bin/flutter test test/wasm_worker_teardown_slots_test.dart
//
// THE DEFECT THIS PINS. `WasmWorkerClient` held "the teardown in flight" in a single field, so two
// teardowns that can legitimately overlap fought over it. A video import arms its harvest completer
// at `startVideoImport` — minutes before the ending it is armed for — while a stop posted by the
// user, or by a controller rebuild tearing a session down, can still be waiting for its own
// `stopped`. That window is not narrow: the stop's own bound is 60 s and the drain that follows it
// is another 30 s, and the import picker's guard reads a capture flag the teardown has already
// cleared, so it opens.
//
// Two ways in, both ending in the same silent loss:
//
//   * ARMING (A2-02). `startVideoImport` replaced the field and emptied the harvest buffer. The
//     earlier stop was left with no one to settle it, and the records it had already buffered were
//     overwritten with an empty list. Those bytes are the only copy — the worker deletes each
//     harvested record directory from its MEMFS the moment it has posted it — and the overwrite
//     bypassed the stranded-harvest rescue, so there was no log line, no Sentry event and no toast.
//   * RELEASING (A2-03). `_releaseVideoImportSlots` completed whatever the field pointed at. A
//     refused import's cleanup therefore answered somebody else's stop with an empty harvest and
//     disarmed it, reaching the same loss from the other side. Fixing only the arming would have
//     left this one open, which is why the two are asserted separately below.
//
// `wasm_worker_client.dart` cannot be compiled by the VM suite (it imports `dart:js_interop`), so
// what is testable is the rule. The message plumbing that calls it — `case 'harvest'`,
// `case 'stopped'`, `_postStop`, `_releaseVideoImportSlots` — is not reachable from here and is
// noted as such rather than claimed.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

WorkerRecordFile _file(String path) => (path: path, bytes: Uint8List.fromList(path.codeUnits));

List<String> _paths(Iterable<WorkerRecordFile> files) => files.map((file) => file.path).toList();

const String _liveRecord = 'chara_detail/active/rec-live/record.json';
const String _importRecord = 'chara_detail/active/rec-import/record.json';

void main() {
  group('TeardownRegistry', () {
    test('a video import armed mid-stop leaves the stop armed and its harvest untouched', () {
      final registry = TeardownRegistry();
      // A live session's stop is posted and the worker ships its harvest.
      final liveStop = registry.arm(awaitsImportTeardown: false);
      registry.addHarvest([_file(_liveRecord)]);

      // The user, told the capture had stopped, starts a video import before `stopped` arrives.
      final import = registry.arm(awaitsImportTeardown: true);

      // THE ASSERTION THE SINGLE SLOT FAILED: arming adds, it does not replace.
      expect(registry.pending, [liveStop, import]);
      expect(liveStop.completer.isCompleted, isFalse, reason: 'the stop still has a `stopped` coming');
      expect(_paths(liveStop.harvested), [_liveRecord], reason: 'the only copy of the session tail');
      expect(import.harvested, isEmpty);

      // And the worker's `stopped` is still that stop's: it is the oldest one that has not had one.
      expect(registry.claimStopped(), same(liveStop));
      expect(_paths(registry.takeHarvest(liveStop, <String>{})), [_liveRecord]);
    });

    test('the import\'s own harvest goes to the import\'s slot, not to the stop it followed', () {
      final registry = TeardownRegistry();
      final liveStop = registry.arm(awaitsImportTeardown: false);
      registry.addHarvest([_file(_liveRecord)]);
      final import = registry.arm(awaitsImportTeardown: true);

      // The live stop's `stopped` arrives; the next `harvest` belongs to the import's ending.
      expect(registry.claimStopped(), same(liveStop));
      registry.addHarvest([_file(_importRecord)]);

      expect(_paths(import.harvested), [_importRecord]);
      expect(_paths(liveStop.harvested), [_liveRecord], reason: 'a claimed stop takes no further files');
      // The drain that follows a `stopped` runs for up to 30 s before the completer settles, so the
      // slot is still pending here; the *next* `stopped` must go to the import all the same.
      expect(registry.claimStopped(), same(import));
    });

    test('releasing a refused import releases only its own slot', () {
      final registry = TeardownRegistry();
      final liveStop = registry.arm(awaitsImportTeardown: false);
      registry.addHarvest([_file(_liveRecord)]);
      final import = registry.arm(awaitsImportTeardown: true);

      // The worker refuses the start, so the import gives back every slot it took.
      import.completer.complete(registry.takeHarvest(import, <String>{}));
      registry.release(import);

      // THE ASSERTION THE SHARED SLOT FAILED: the stop is still armed, and still holds its records.
      expect(registry.pending, [liveStop]);
      expect(liveStop.completer.isCompleted, isFalse);
      expect(_paths(liveStop.harvested), [_liveRecord]);
      expect(registry.claimStopped(), same(liveStop), reason: 'the `stopped` still has an owner');
    });

    test('an answered teardown stops being the slot a later stop would coalesce onto', () {
      final registry = TeardownRegistry();
      final first = registry.arm(awaitsImportTeardown: false);
      expect(registry.latest, same(first));

      first.completer.complete(const []);

      expect(registry.latest, isNull);
      expect(registry.isEmpty, isTrue);
      expect(resolveStopArming(stopArmed: registry.latest != null, awaitsImportTeardown: false), StopArming.post);
    });

    test('a harvest that belongs to no teardown is kept for the rescue, not dropped', () {
      final registry = TeardownRegistry();
      // The stop's bound expired and it was answered; the worker ships its harvest afterwards.
      final expired = registry.arm(awaitsImportTeardown: false);
      expired.completer.complete(const []);
      registry.addHarvest([_file(_liveRecord)]);

      expect(registry.claimStopped(), isNull, reason: 'the message belongs to nobody');
      expect(_paths(registry.takeUnowned()), [_liveRecord]);
      expect(registry.takeUnowned(), isEmpty, reason: 'taken once, so a later stop cannot see it');
    });

    test('a slot answered with files still buffered strands them rather than losing them', () {
      final registry = TeardownRegistry();
      final slot = registry.arm(awaitsImportTeardown: true);
      registry.addHarvest([_file(_importRecord)]);

      // Answered from somewhere other than the harvest path (a worker that went away).
      slot.completer.complete(const []);

      expect(registry.isEmpty, isTrue);
      expect(_paths(registry.takeUnowned()), [_importRecord]);
    });

    test('releaseAll strands every buffer and leaves nothing armed for a worker that is gone', () {
      final registry = TeardownRegistry();
      final stop = registry.arm(awaitsImportTeardown: false);
      registry.addHarvest([_file(_liveRecord)]);
      expect(stop.harvested, isNotEmpty);

      registry.releaseAll();

      expect(registry.pending, isEmpty);
      expect(registry.awaitsImportTeardown, isFalse);
      expect(_paths(registry.takeUnowned()), [_liveRecord]);
    });

    test('awaitsImportTeardown answers for the pending set, not for the newest arming', () {
      final registry = TeardownRegistry();
      final import = registry.arm(awaitsImportTeardown: true);
      // A stop posted while the import runs adopts that slot rather than arming a second one, but a
      // stop for an unrelated session does arm one, and the import is still expecting its teardown.
      registry.arm(awaitsImportTeardown: false);

      expect(registry.awaitsImportTeardown, isTrue);

      import.completer.complete(const []);

      expect(registry.awaitsImportTeardown, isFalse);
    });

    test('hasOtherPending is what keeps one teardown from clearing state another still needs', () {
      final registry = TeardownRegistry();
      final stop = registry.arm(awaitsImportTeardown: false);
      expect(registry.hasOtherPending(stop), isFalse);

      final import = registry.arm(awaitsImportTeardown: true);
      expect(registry.hasOtherPending(stop), isTrue);
      expect(registry.hasOtherPending(import), isTrue);

      import.completer.complete(const []);
      expect(registry.hasOtherPending(stop), isFalse);
    });

    test('takeHarvest drops the records the incremental path already committed', () {
      final registry = TeardownRegistry();
      final slot = registry.arm(awaitsImportTeardown: false);
      registry.addHarvest([_file(_liveRecord), _file(_importRecord)]);

      final taken = registry.takeHarvest(slot, <String>{'rec-live'});

      expect(_paths(taken), [_importRecord]);
      expect(slot.harvested, isEmpty, reason: 'a taken buffer is the caller\'s to keep');
    });
  });
}
