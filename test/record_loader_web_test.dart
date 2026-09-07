// Unit-level contract of the web record loader.
//
// This file used to carry `@TestOn('browser')`, which excluded it from every run
// the project performs (`flutter test` is the VM platform, and there is no
// browser job), so it silently never ran. The annotation was also unnecessary:
// record_loader_web.dart has no `dart:js_interop` / `package:web` import, and its
// `_*.dart` siblings resolve to their io variants on the VM.
//
// The first two tests inject every dependency and touch no filesystem; the third
// drives the real `_snapshotRecordDirectories` / `_isSafeRecordId` against a real
// tree. The on-disk counterparts of the gate behaviours live in
// record_recovery_gate_web_policy_test.dart, which builds the *real* platform gate
// instead of a callback.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_id_safety.dart';
import 'package:umacapture/src/core/fs/record_loader_web.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/records.dart';
import 'support/web_like_fs_backend.dart';
import 'support/long_read_declarations.dart';

void main() {
  late DirectoryPath storage;
  late DirectoryPath active;

  setUp(() {
    storage = DirectoryPath(['storage']);
    active = storage / 'chara_detail' / 'active';
  });

  test('single loader gates recovery before decode and derives storage root', () async {
    final directory = active / 'one';
    var decoded = false;
    final result = await loadRecord(
      directory,
      mutationLock: _lock,
      recoverRecordUnlocked: (actualStorage, id) async {
        expect(actualStorage.path, storage.path);
        expect(id, 'one');
      },
      loadAction: (_) async {
        decoded = true;
        return const RecordQuarantined(null);
      },
    );
    expect(decoded, isTrue);
    expect(result, isA<RecordQuarantined>());
  });

  test('recovery failure prevents decode: fatal for one record, contained for a scan', () async {
    final one = active / 'one';
    final two = active / 'two';
    var decoded = false;
    Future<void> blocked(DirectoryPath _, String _) => Future.error(StateError('recovery blocked'));
    await expectLater(
      loadRecord(
        one,
        mutationLock: _lock,
        recoverRecordUnlocked: blocked,
        loadAction: (_) async {
          decoded = true;
          return const RecordQuarantined(null);
        },
      ),
      throwsA(isA<StateError>()),
    );
    // The scan skips what it cannot recover instead of failing the whole store:
    // every cause is per-record, so one bad record must not hide every record.
    final (:results, :unavailable) = await loadRecordsUnder(
      active,
      declaration: undeclaredInTest,
      mutationLock: _lock,
      recoverRecordUnlocked: (_, id) async {
        if (id == 'one') await blocked(active, id);
      },
      snapshotDirectories: (_) async => [one, two],
      loadAction: (directory) async {
        decoded = true;
        // Not redundant: the scan must not swallow a TestFailure raised here.
        expect(directory.name, 'two');
        // A quarantine that *succeeded*, and the destination is what says so.
        // `RecordQuarantined(null)` would be a second unavailable record here --
        // a decode that failed and could not be moved aside is exactly what the
        // scan now counts -- so it would stop this test measuring the refusal it
        // is about.
        return RecordQuarantined(active.parent / 'quarantine' / directory.name);
      },
    );
    expect(results, hasLength(1));
    expect(decoded, isTrue);
    // Only the refused record. The one whose load returned is not unavailable,
    // whatever the load decided about it.
    expect(unavailable.keys, ['one']);
  });

  // The web half of "a decode failure whose quarantine move failed with it is
  // unavailable". The desktop half is driven end to end through the storages in
  // record_scan_unavailable_test.dart; this is not the same measurement. That one
  // exercises `_scanRecordsUnder`, which fans the decodes out across isolates and
  // pairs each result back to its directory *by position*; this scan decides per
  // record inside its own `gate.runForRecord`, with nothing to pair, and is the
  // only one of the two that can also be asked about a quarantine that succeeded.
  //
  // Both halves are here on purpose: `destination == null` is what separates them,
  // and an implementation that reported every quarantine -- or none -- would still
  // satisfy either assertion on its own.
  test('a quarantine the scan could not move is unavailable; one that moved is not', () async {
    final moved = active / 'moved';
    final stranded = active / 'stranded';
    final (:results, :unavailable) = await loadRecordsUnder(
      active,
      declaration: undeclaredInTest,
      mutationLock: _lock,
      recoverRecordUnlocked: (_, _) async {},
      snapshotDirectories: (_) async => [moved, stranded],
      loadAction: (directory) async => directory.name == 'moved'
          ? RecordQuarantined(storage / 'chara_detail' / 'quarantine' / directory.name)
          : const RecordQuarantined(null),
    );

    // Neither is a refusal: the scan opened both, and both stay in `results`.
    // Dropping the stranded one here instead would hide it from the very count
    // that is supposed to name it.
    expect(results, hasLength(2));
    // Only the record still standing in `active/`. The moved one is out of the
    // scanned tree and will not be seen again, so counting it would put a record
    // on the incomplete-store banner that is not missing from anything.
    expect(unavailable.keys, ['stranded']);
    // The cause, not merely the id: this is what the log and the crash report
    // are handed, and `unavailable`'s other values are the errors that refused a
    // record.
    expect(unavailable['stranded'], isA<RecordQuarantineFailed>());
  });

  group('the real store snapshot', () {
    late Directory tempRoot;
    late DirectoryPath activeRoot;
    late FsBackend originalBackend;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('umacapture_record_loader_web');
      activeRoot = DirectoryPath(tempRoot.path) / 'storage' / 'chara_detail' / 'active';
      originalBackend = fsBackend;
      // The scan is web-only production code, so it runs against
      // `WebLikeFsBackend`: a reflex `listSync`/`existsSync` here fails on the VM
      // too. That pins OPFS's *synchronous* prohibition and nothing else -- see
      // `support/web_like_fs_backend.dart` for what this backend does not model.
      fsBackend = WebLikeFsBackend(originalBackend);
    });

    tearDown(() {
      fsBackend = originalBackend;
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    Future<List<String>> scan() async {
      final loaded = <String>[];
      await loadRecordsUnder(
        activeRoot,
        declaration: undeclaredInTest,
        mutationLock: _lock,
        recoverRecordUnlocked: (_, _) async {},
        loadAction: (directory) async {
          loaded.add(directory.name);
          return RecordLoaded(makeRecord(id: directory.name, card: 1));
        },
      );
      return loaded;
    }

    test('a missing active root yields nothing instead of throwing', () async {
      expect(await scan(), isEmpty);
    });

    // G5: an unusable name is a reason to file the directory away, not a reason
    // to leave it in `active/` for every later scan to refuse again. The part
    // that needs a real tree is the *destination*: `quarantine/ + name` is joined
    // into a path string, and both `WebVfs._split` and this host read a backslash
    // in that string as a separator.
    test('a name that is not a usable record id is quarantined into a single segment', () async {
      // `a\b` cannot be created as one directory here -- Windows splits it,
      // exactly as the browser would -- so the source is made as the two levels
      // the string really denotes and handed to the scan as one PathEntity
      // segment. The `List<String>` constructor is the only way to build that:
      // `/` parses its argument through the platform context, which would split
      // it back apart before the loader ever saw it.
      final unusable = DirectoryPath([...activeRoot.segments, r'a\b']);
      await unusable.create(recursive: true);
      await unusable.filePath('record.json').writeAsString('{"broken": true}');

      final (:results, :unavailable) = await loadRecordsUnder(
        activeRoot,
        declaration: undeclaredInTest,
        mutationLock: _lock,
        recoverRecordUnlocked: (_, _) async {},
        snapshotDirectories: (_) async => [unusable],
        loadAction: (_) async => fail('an unusable name must never be handed to the decoder'),
      );

      expect(results, isEmpty);
      // Not unavailable: the directory left `active/`, so it is no longer
      // missing from a listing that will be taken again. Counting it here would
      // put a record on the incomplete-store banner that nothing is waiting on.
      expect(unavailable, isEmpty);
      expect(await unusable.exists(), isFalse);

      final quarantine = activeRoot.parent / 'quarantine';
      final children = await quarantine.list().toList();
      // The whole finding in one assertion: one child, directly under
      // `quarantine/`. Using the name as it stands files it at
      // `quarantine/a/b` instead -- one level further down, where the only
      // reader that folder has does not look.
      expect(children.map((e) => e.name), ['a_b']);
      expect(await (quarantine / 'a_b').filePath('record.json').readAsString(), '{"broken": true}');
    });

    test('a name whose quarantine move fails is still counted as unavailable', () async {
      // The other half of the same decision. `copyTreeInto` refuses a source
      // that is not a directory, which is the one quarantine failure this host
      // produces without a fake backend; the outcome under test is not how it
      // failed but that the entry is still standing in `active/`, and therefore
      // still owed to the user as a count.
      await activeRoot.create(recursive: true);
      await activeRoot.filePath('has space').writeAsString('not a tree');
      final stranded = activeRoot / 'has space';

      final (:results, :unavailable) = await loadRecordsUnder(
        activeRoot,
        declaration: undeclaredInTest,
        mutationLock: _lock,
        recoverRecordUnlocked: (_, _) async {},
        snapshotDirectories: (_) async => [stranded],
        loadAction: (_) async => fail('an unusable name must never be handed to the decoder'),
      );

      expect(results, isEmpty);
      expect(unavailable.keys, ['has space']);
      // The name is the cause. `RecordQuarantineFailed` says a decode failed,
      // and nothing was decoded here, so it would be a false account of it.
      expect(unavailable['has space'], isA<UnsafeRecordId>());
      expect(await activeRoot.filePath('has space').exists(), isTrue);
    });

    test('lists safe record ids in sorted order, skipping files and unsafe names', () async {
      // Sorted output, not creation order.
      for (final id in ['b-record', 'a-record', 'C.record_2']) {
        await (activeRoot / id).create(recursive: true);
      }
      // _isSafeRecordId rejects anything outside [A-Za-z0-9._-]. These are all
      // legal Windows/OPFS directory names, so only the sanitiser can exclude
      // them -- which is the point: an id reaches the loader as a path segment.
      for (final id in ['has space', 'plus+sign', 'ünïcode', 'semi;colon']) {
        await (activeRoot / id).create(recursive: true);
      }
      // A stray file at the root (e.g. a labels.json left by an odd import) must
      // not be handed to the decoder, which would report it as a corrupt record.
      await activeRoot.filePath('labels.json').writeAsString('{}');

      expect(await scan(), ['C.record_2', 'a-record', 'b-record']);
    });
  });
}

final _lock = RecordMutationLock((_, _, action) => action());
