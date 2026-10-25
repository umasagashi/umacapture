// The device's side of sync: what the reader makes of a real data directory, the list it is carried in and read back
// from, the records a round reads again after each entry that changes them, rounds between two devices, and the
// server's endpoints over HTTP as the app reads their answers.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_sync_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/addon/trigger_catalog.dart' show appExitRequestsProvider;
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/image_converter.dart';
import 'package:umacapture/src/chara_detail/record_archive_state.dart';
import 'package:umacapture/src/chara_detail/record_notes.dart';
import 'package:umacapture/src/chara_detail/record_quarantine_ledger.dart';
import 'package:umacapture/src/chara_detail/record_share_session.dart';
import 'package:umacapture/src/chara_detail/record_sync.dart';
import 'package:umacapture/src/chara_detail/record_sync_list.dart';
import 'package:umacapture/src/chara_detail/record_sync_merge.dart';
import 'package:umacapture/src/chara_detail/record_sync_round.dart';
import 'package:umacapture/src/chara_detail/record_sync_server.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/rating.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/chara_detail/value_write_time.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/fs_backend_io.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_report.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/chara_detail/column_spec_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart' show ImageSizeContainer;
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/enhancement_merge_scratch.dart';
import 'support/factor_classifier.dart';
import 'support/held_write_fs_backend.dart';
import 'support/hive.dart';
import 'support/localization.dart';
import 'support/long_read_declarations.dart';
import 'support/record_binding_seed.dart' show expectedBinding;
import 'support/record_sync_harness.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';
import 'support/settling.dart';
import 'support/storage_delete_claim.dart';
import 'support/sync_http_face.dart';
import 'support/web_like_fs_backend.dart';

String _hex(int fill) => fill.toRadixString(16).padLeft(2, '0') * 32;

final _binding = RecordBinding(
  skillPng: _hex(1),
  skillJpeg: _hex(2),
  factorPng: _hex(3),
  factorJpeg: _hex(4),
  campaignPng: _hex(5),
  campaignJpeg: _hex(6),
);

/// Every value of [list], one line each, in a fixed order: two lists are the same list exactly when these are equal.
List<String> _describe(SyncList list) => [
  for (final id in list.rows.keys.toList()..sort()) 'row ${list.rows[id]!.record} ${list.rows[id]!.bodyName}',
  for (final cell in list.cells.keys.toList()..sort((a, b) => '$a'.compareTo('$b'))) 'cell $cell ${list.cells[cell]}',
  for (final column in list.titles.keys.toList()..sort()) 'title $column ${list.titles[column]}',
  for (final pair in list.dismissed.toList()..sort((a, b) => '$a'.compareTo('$b'))) 'dismissed $pair',
];

Uint8List _zipOf(Map<String, CharaDetailRecord> records) {
  final archive = Archive();
  for (final MapEntry(key: id, value: record) in records.entries) {
    final json = record.toRecordJsonBytes();
    archive.addFile(ArchiveFile('$id/record.json', json.length, json));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

CharaDetailRecord _bound(String id) {
  final map = recordFromFixture(id, '2026-02-01T00:00:00').toMap();
  (map['metadata'] as Map<String, dynamic>)['binding'] = _binding.toMap();
  return CharaDetailRecordMapper.fromMap(map);
}

/// A request whose answer did not arrive: a connection that dropped.
class _Dropped implements Exception {
  const _Dropped();
}

/// [server], counting every request a round makes of it; [beforeGeneration], where given, is awaited before the first.
class _CountedServer implements SyncServer {
  _CountedServer(this.server, {this.beforeGeneration});

  final SyncServer server;
  final Future<void> Function()? beforeGeneration;
  var calls = 0;

  @override
  Future<({int generation, String? root})> readGeneration() async {
    calls++;
    await beforeGeneration?.call();
    return server.readGeneration();
  }

  @override
  Future<String> root(String name) {
    calls++;
    return server.root(name);
  }

  @override
  Future<String> part(String name) {
    calls++;
    return server.part(name);
  }

  @override
  Future<List<({String name, String body})>> bodies(List<String> names) {
    calls++;
    return server.bodies(names);
  }

  @override
  Future<void> putBodies(List<({String name, String body})> bodies) {
    calls++;
    return server.putBodies(bodies);
  }

  @override
  Future<void> putPart(String name, String text) {
    calls++;
    return server.putPart(name, text);
  }

  @override
  Future<int> replaceRoot(int generation, String name, String text) {
    calls++;
    return server.replaceRoot(generation, name, text);
  }

  @override
  Future<String> imageForm() {
    calls++;
    return server.imageForm();
  }

  @override
  Future<void> putImageForm(String form) {
    calls++;
    return server.putImageForm(form);
  }

  @override
  Future<Set<String>> held(List<String> names) {
    calls++;
    return server.held(names);
  }

  @override
  Future<void> putImage(String name, Uint8List bytes, {required bool jpeg}) {
    calls++;
    return server.putImage(name, bytes, jpeg: jpeg);
  }

  @override
  Future<Uint8List?> image(String name) {
    calls++;
    return server.image(name);
  }
}

void main() {
  setUpAll(initializeMappers);
  // A round gives a title it takes in to the column presets, which the app keeps in a StorageBox.
  useStorageBoxForTest();

  late SyncTestDevice a;

  setUp(() => a = SyncTestDevice('a'));
  tearDown(() => a.dispose());

  /// Device [a] holding one of everything the list carries, each value at a time of its own.
  void seedEverything() {
    a.seedRecord(
      'R1',
      binding: _binding,
      bodyWrittenAt: 1767225600123,
      parent1: 'P1',
      relationBonus: 42,
      normalWrittenAt: 1767225600200,
      absorbed: {'R9'},
    );
    a.seedRecord(
      'R2',
      store: 'archive',
      binding: RecordBinding(skillPng: _hex(7)),
      bodyWrittenAt: 1767225600300,
      archived: (state: RecordArchiveState.jpeg, writtenAt: 1767225600400),
    );
    a.seedRecord('R3');
    a.seedColumn(
      'rating',
      'r1',
      title: 'Score',
      titleWrittenAt: 1767225600500,
      data: {'R1': 4.5},
      writtenAt: {'R1': 1767225600600, 'R2': 1767225600700},
    );
    a.seedColumn('memo', 'm1', title: 'Note', data: {'R2': 'hello "there"'}, writtenAt: {'R2': 1767225600800});
    a.seedColumn('rating', 'gone', title: 'Old', titleWrittenAt: 1767225600900, titleCleared: true);
    a.seedDismissed([('R2', 'R1')]);
  }

  group('the list', () {
    test('a device read into the list comes back from its parts as it was, every time as written', () async {
      seedEverything();
      final read = await a.read();
      final parts = syncListParts(read.list);
      final back = syncListOfParts(parts.values);

      expect(_describe(back), _describe(read.list));
      expect(read.unreadable, isEmpty);
      expect(parts.keys.toSet(), {
        '${syncRecordPartOf('R1')}',
        '${syncRecordPartOf('R2')}',
        '${syncRecordPartOf('R3')}',
        'columns',
        'dismissed',
      });
      final r1 = back.rows['R1']!.record;
      expect((r1.body.time, r1.stage.value, r1.stage.time), (1767225600123, null, 1767225600200));
      expect(r1.body.binding, _binding);
      expect(r1.body.parents, {'parent1': 'P1'});
      expect(r1.absorbed, {'R9'});
      final r2 = back.rows['R2']!.record;
      expect(
        (r2.body.time, r2.stage.value, r2.stage.time),
        (1767225600300, ArchiveImageOption.resizedJpeg, 1767225600400),
      );
      final r3 = back.rows['R3']!.record;
      expect((r3.body.time, r3.stage.time, r3.body.binding), (0, 0, null), reason: 'a value from before times is 0');
      expect(back.cells, {
        ('rating/r1', 'R1'): const SyncValue<String?>('4.5', 1767225600600),
        ('rating/r1', 'R2'): const SyncValue<String?>(null, 1767225600700),
        ('memo/m1', 'R2'): SyncValue<String?>(jsonEncode('hello "there"'), 1767225600800),
      });
      expect(back.titles, {
        'rating/r1': const SyncValue<String?>('Score', 1767225600500),
        'memo/m1': const SyncValue<String?>('Note', 0),
        'rating/gone': const SyncValue<String?>(null, 1767225600900),
      });
      expect(back.dismissed, {('R1', 'R2')});
      expect(back.side.dismissed, {syncPairOf('R1', 'R2')});
    });

    test('a record falls in the part the protocol states', () {
      // sha256(utf8(id)).readUInt16BE(0) % 128, worked out apart from the app.
      const expected = {'record-1': 70, 'R1': 17, 'R2': 83, 'record-2': 88, 'record-3': 92, 'ﾚｺｰﾄﾞ-ü': 4};
      expect({for (final id in expected.keys) id: syncRecordPartOf(id)}, expected);
      expect(syncRecordPartOf('x' * 128), 90);
    });

    test('a body object is record.json without the time it was written and the relation bonus', () async {
      seedEverything();
      final read = await a.read();
      final body = jsonDecode(a.bodyOf('R1')) as Map<String, Object?>;
      final metadata = body['metadata'] as Map<String, Object?>;

      expect(metadata.containsKey('body_written_at'), isFalse);
      expect(metadata.containsKey('relation_bonus'), isFalse);
      expect(metadata['binding'], _binding.toMap());
      expect((metadata['record_id'] as Map)['parent1'], 'P1');
      expect(read.list.rows['R1']!.bodyName, syncObjectName(utf8.encode(a.bodyOf('R1'))));
    });

    test('the server takes what the reader makes, and another device reads the same list back', () async {
      seedEverything();
      // The server takes a body only with its binding; a record without one is put once its binding is placed.
      Directory((a.charaDetail / 'active' / 'R3').path).deleteSync(recursive: true);
      final server = FakeSyncServer();

      await putDeviceList(a, server);

      expect(server.generation, 1);
      final onServer = syncListOfParts(server.currentParts());
      expect(_describe(onServer), _describe((await a.read()).list));
      for (final row in onServer.rows.values) {
        expect(server.body(row.bodyName), isNotNull, reason: '${row.record.id} names a body the server holds');
      }
    });
  });

  group('what changed', () {
    // Each entry that changes what the list holds, driven as the app drives it, and the round after it: the records
    // the stores say changed since the last read are read again, and those alone. Rows are the entries, in the order
    // they run below; "read again" is the set [syncRecordsChangedSince] answers.
    //
    // | entry                              | read again          |
    // |------------------------------------|---------------------|
    // | capture (`addFromFile`)            | the captured record |
    // | rating a cell                      | none: columns are read whole every round |
    // | a column title                     | none: likewise      |
    // | archive                            | the archived record |
    // | merge                              | the survivor and the retired record |
    // | dismiss a pair                     | none: the pairs are read whole every round |
    // | zip import                         | the imported record |
    // | delete from the list               | the deleted record  |
    // | zip export of a record without a binding | the exported record: the export placed its binding |
    // | delete in the storage view         | the deleted record  |
    test('after each entry a round reads the records it changed and no other, and finds every change', () async {
      // The deletes evict record images, which reads the painting binding.
      TestWidgetsFlutterBinding.ensureInitialized();
      final info = a.info;
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'R1', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'R2', card: 2));
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('newer'));
      writeRecord(
        info.charaDetailActiveDir,
        _pairRecord('d1', stars: 1, whiteCount: 5, capturedDate: '2026-01-01T00:00:00+0900'),
      );
      writeRecord(
        info.charaDetailActiveDir,
        _pairRecord('d2', stars: 3, whiteCount: 6, capturedDate: '2026-02-01T00:00:00+0900'),
      );
      a.seedColumn('rating', 'r1', title: 'Score', data: {'R1': 1.0}, writtenAt: {'R1': 1767225600600});
      final container = await loadedMergeContainer(
        info: info,
        overrides: [pathLayoutLoader.overrideWith((ref) async => info)],
      );
      final ref = container.read(containerRefProvider);
      final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      EnhancementCandidate pair(String older, String newer) {
        final candidates = candidatesIn(container);
        return candidates.singleWhere(
          (c) => c.olderId == older && c.newerId == newer,
          orElse: () => fail('${[for (final c in candidates) '${c.olderId}/${c.newerId}']}'),
        );
      }

      var last = await a.read();
      expect(syncRecordsChangedSince(last, syncHeldRecordsOf(ref)!), isEmpty, reason: 'the stores hold what is read');

      /// A round over [last], and that it found everything: what it reads is what reading every unit reads, and the
      /// stores now hold what it read.
      Future<Set<String>> round() async {
        final changed = syncRecordsChangedSince(last, syncHeldRecordsOf(ref)!);
        final next = await a.read(previous: last, records: changed);
        expect(_describe(next.list), _describe((await a.read()).list));
        expect(next.unreadable, isEmpty);
        expect(syncRecordsChangedSince(next, syncHeldRecordsOf(ref)!), isEmpty, reason: 'the stores hold what it read');
        last = next;
        return changed;
      }

      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'C1', card: 3));
      active.addFromFile('C1', effects: arrivalEffects(container));
      expect(await round(), {'C1'});

      await container.read(charaDetailRecordRatingProvider('r1').future);
      expect(saveRating(ref, storageKey: 'r1', recordId: 'R1', rating: 4, notify: false), isTrue);
      final rating = container.read(charaDetailRecordRatingProvider('r1').notifier);
      expect(await rating.flush(), isTrue);
      expect(await round(), isEmpty);
      expect(last.list.cells[('rating/r1', 'R1')]?.value, '4.0');

      expect(rating.updateTitle('Grade'), isTrue);
      rating.save();
      expect(await rating.flush(), isTrue);
      expect(await round(), isEmpty);
      expect(last.list.titles['rating/r1']?.value, 'Grade');

      await container
          .read(charaArchiveControllerProvider.notifier)
          .archive(['R2'], ArchiveImageOption.none, effects: archiveEffects(container));
      expect(await round(), {'R2'});
      expect(last.list.rows['R2']?.record.stage.value, ArchiveImageOption.none);

      final merged = await container
          .read(enhancementMergeProvider)
          .merge(pair('older', 'newer'), choices: const EnhancementMergeChoices(), effects: mergeEffects(container));
      expect(merged.outcome, EnhancementMergeOutcome.merged);
      expect(await round(), {'older', 'newer'});
      expect(last.list.rows['older']?.record.absorbed, {'newer'});
      expect(last.list.rows.containsKey('newer'), isFalse);

      expect(
        await container.read(enhancementDismissalStoreProvider).dismiss(pair('d1', 'd2')),
        EnhancementDismissOutcome.dismissed,
      );
      expect(await round(), isEmpty);
      expect(last.list.dismissed, {('d1', 'd2')});

      final imported = await RecordZipService.import(_zipOf({'Z1': _bound('Z1')}), info.storageDir);
      applyRecordsPublished(ref, info, writtenIds: imported.recordIds, effects: recordImportEffects(ref));
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
      expect(await round(), {'Z1'});

      final deleted = await container.read(charaDetailRecordStorageLoaderProvider.notifier).deleteAllAsync({
        'C1',
      }, effects: recordDeleteEffects(container));
      expect(deleted.isSuccess, isTrue);
      expect(await round(), {'C1'});
      expect(last.list.rows.containsKey('C1'), isFalse);

      expect(last.list.rows['R1']?.record.body.binding, isNull);
      await RecordZipService.export([info.charaDetailActiveDir / 'R1'], ref: ref, declaration: undeclaredInTest);
      expect(await round(), {'R1'});
      expect(last.list.rows['R1']?.record.body.binding, isNotNull);

      await runStorageDelete(
        ref,
        effects: storageDeleteEffects(container),
        group: storageGroupOf(StorageGroupId.activeRecords),
        request: StorageDeletePathsRequest([info.charaDetailActiveDir / 'Z1']),
        silent: true,
      );
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      expect(await round(), {'Z1'});
      expect(last.list.rows.keys.toSet(), {'R1', 'R2', 'older', 'd1', 'd2'});
    });

    test('a record a store could not open is not read as removed', () async {
      a.seedRecord('R1');
      final read = await a.read();

      final held = SyncHeldRecords(const {}, unavailable: {'R1'});

      expect(syncRecordsChangedSince(read, held), isEmpty);
      expect(syncRecordsChangedSince(read, const SyncHeldRecords({})), {'R1'}, reason: 'positive control: gone');
    });
  });

  group('a round', () {
    // Two devices and the server, each round driven as the app runs it ([SyncTestDevice.round]); every change is made
    // through the entry the app makes it with. Rows of `SPEC-R` §2 a round reaches are named after their rule and
    // number.
    late SyncTestDevice b;
    late FakeSyncServer server;

    setUp(() {
      b = SyncTestDevice('b');
      server = FakeSyncServer();
    });
    tearDown(() => b.dispose());

    SyncList onServer() => syncListOfParts(server.currentParts());
    Future<SyncList> listOf(SyncTestDevice device) async => (await device.read()).list;

    /// [device] holding three records, a rating with its title, and a dismissed pair, each at a time of its own.
    void seed(SyncTestDevice device) {
      device.seedRecord('R1', binding: _binding, bodyWrittenAt: 1767225600100, normalWrittenAt: 1767225600150);
      device.seedRecord('R2', binding: _binding, bodyWrittenAt: 1767225600200);
      device.seedRecord('R3', binding: _binding, bodyWrittenAt: 1767225600250);
      device.seedColumn(
        'rating',
        'r1',
        title: 'Score',
        titleWrittenAt: 1767225600300,
        data: {'R1': 4.0},
        writtenAt: {'R1': 1767225600400},
      );
      device.seedColumn('memo', 'm1', title: 'Note');
      device.seedDismissed([('R1', 'R3')]);
    }

    Future<void> deleteRecords(SyncTestDevice device, Set<String> ids) async {
      final container = await device.open();
      final deleted = await container
          .read(charaDetailRecordStorageLoaderProvider.notifier)
          .deleteAllAsync(ids, effects: recordDeleteEffects(container));
      expect(deleted.isSuccess, isTrue);
    }

    Future<void> retitle(SyncTestDevice device, String title) async {
      final container = await device.open();
      await container.read(charaDetailRecordRatingProvider('r1').future);
      final rating = container.read(charaDetailRecordRatingProvider('r1').notifier);
      expect(rating.updateTitle(title), isTrue);
      rating.save();
      expect(await rating.flush(), isTrue);
    }

    Future<void> rate(SyncTestDevice device, String id, double value) async {
      final container = await device.open();
      final ref = container.read(containerRefProvider);
      await container.read(charaDetailRecordRatingProvider('r1').future);
      expect(saveRating(ref, storageKey: 'r1', recordId: id, rating: value, notify: false), isTrue);
      expect(await container.read(charaDetailRecordRatingProvider('r1').notifier).flush(), isTrue);
    }

    for (final webLike in [false, true]) {
      test('what one device sends the other takes in, and the base it keeps outlives a restart'
          '${webLike ? ' (a backend that cannot rename a file over another)' : ''}', () async {
        if (webLike) {
          final original = fsBackend;
          fsBackend = WebLikeFsBackend(original);
          addTearDown(() => fsBackend = original);
        }
        seed(a);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(_describe(onServer()), _describe(await listOf(a)));
        final first = await b.round(server);
        expect((first.end, first.added), (SyncRoundEnd.done, 3), reason: 'a first round tells what it took in');
        expect(_describe(await listOf(b)), _describe(await listOf(a)));
        expect(File(syncBaseFile(a.info).path).existsSync(), isTrue);
        expect(File(syncSentFile(a.info).path).existsSync(), isFalse);

        // The app restarts: what the round knew of the last list is on disk or nowhere. The user deletes R1.
        a.close();
        await deleteRecords(a, {'R1'});
        final removal = await a.round(server);
        expect((removal.end, removal.added), (SyncRoundEnd.done, 0));
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expect(onServer().rows.keys.toSet(), {'R2', 'R3'});
        expect((await listOf(b)).rows.keys.toSet(), {'R2', 'R3'});
        expect((await listOf(a)).rows.keys.toSet(), {'R2', 'R3'});
      });
    }

    test(
      'rule 2, check 1: a record one device deletes goes from both, with what the other did to it meanwhile',
      () async {
        seed(a);
        await a.round(server);
        await b.round(server);
        await deleteRecords(a, {'R2'});
        final container = await b.open();
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive(['R2'], ArchiveImageOption.none, effects: archiveEffects(container));
        expect(saveMemo(container.read(containerRefProvider), storageKey: 'm1', recordId: 'R2', memo: 'later'), isTrue);
        expect(await container.read(charaDetailRecordMemoProvider('m1').notifier).flush(), isTrue);

        await a.round(server);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        await a.round(server);

        for (final list in [onServer(), await listOf(a), await listOf(b)]) {
          expect(list.rows.keys.toSet(), {'R1', 'R3'});
          expect(list.cells.keys.where((cell) => cell.$2 == 'R2'), isEmpty);
        }
      },
    );

    test('a record the list deletes takes its dismissed pairs and its values with it', () async {
      seed(a);
      await deleteRecords(a, {'R1'});

      final list = await listOf(a);
      expect(list.rows.keys.toSet(), {'R2', 'R3'});
      expect(list.dismissed, isEmpty, reason: 'the pair R1+R3 was of the record deleted');
      expect(list.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty);
    });

    test('rule 5, check 2: a value is carried with the time it was written, and one written after it wins', () async {
      seed(a);
      await a.round(server);
      await b.round(server);
      final clock = valueWriteClock;
      addTearDown(() => valueWriteClock = clock);
      // A's clock runs ahead: it writes 5 at a time B's clock has not reached.
      valueWriteClock = () => 1767225609000;
      await rate(a, 'R1', 5);
      await a.round(server);
      await b.round(server);
      expect((await listOf(b)).cells[('rating/r1', 'R1')], const SyncValue<String?>('5.0', 1767225609000));
      // B writes 2 by its own clock, behind the value it replaces: just after it.
      valueWriteClock = () => 1767225605000;
      await rate(b, 'R1', 2);
      await b.round(server);
      await a.round(server);
      for (final list in [onServer(), await listOf(a), await listOf(b)]) {
        expect(list.cells[('rating/r1', 'R1')], const SyncValue<String?>('2.0', 1767225609001));
      }
    });

    test('a record made normal on the other device comes with its state and time in one note', () async {
      a.seedRecord('R2', binding: _binding, bodyWrittenAt: 1767225600200, normalWrittenAt: 1767225600900);
      b.seedRecord(
        'R2',
        store: 'archive',
        binding: _binding,
        bodyWrittenAt: 1767225600200,
        archived: (state: RecordArchiveState.jpeg, writtenAt: 1767225600500),
      );
      await a.round(server);
      expect((await b.round(server)).end, SyncRoundEnd.done);

      final moved = b.charaDetail / 'active' / 'R2';
      expect(Directory((b.charaDetail / 'archive' / 'R2').path).existsSync(), isFalse);
      expect(
        jsonDecode(File(moved.filePath(recordArchiveNoteName).path).readAsStringSync()),
        {
          'normal_written_at': 1767225600900,
          'archived': {'state': 'jpeg', 'written_at': 1767225600500},
        },
        reason: 'the time the list carries, not the time it arrived',
      );
      final row = (await listOf(b)).rows['R2']!.record;
      expect((row.stage.value, row.stage.time), (null, 1767225600900));
    });

    test(
      'a replacement whose answer was lost is read again: what the server holds as sent is the base, and nothing is told',
      () async {
        seed(a);
        server.loseAnswer = true;
        expect((await a.round(server)).end, SyncRoundEnd.answerLost);
        expect(File(syncSentFile(a.info).path).existsSync(), isTrue);
        expect(onServer().rows.keys.toSet(), {'R1', 'R2', 'R3'}, reason: 'the server made it');

        // Before the next round the user deletes R2, and takes the dismissed pair out in the storage view.
        await deleteRecords(a, {'R2'});
        final container = await a.open();
        await runStorageDelete(
          container.read(containerRefProvider),
          effects: storageDeleteEffects(container),
          group: storageGroupOf(StorageGroupId.metadata),
          request: StorageDeletePathsRequest([a.info.charaDetailEnhancementDismissedFile]),
          silent: true,
        );

        final outcome = await a.round(server);
        expect(outcome.end, SyncRoundEnd.done);
        expect((outcome.restored, outcome.splitOff, outcome.added), (0, 0, 0));
        expect(File(syncSentFile(a.info).path).existsSync(), isFalse);
        for (final list in [onServer(), await listOf(a)]) {
          expect(list.rows.keys.toSet(), {'R1', 'R3'}, reason: 'R2 was the base, so its absence is a removal');
          expect(list.dismissed, isEmpty, reason: 'the pair was the base, so its absence is the user taking it out');
          expect(list.titles['rating/r1'], const SyncValue<String?>('Score', 1767225600300));
        }
      },
    );

    test('a replacement refused as stale is made once more in the same round, from the generation on', () async {
      seed(a);
      await a.round(server);
      await b.round(server);
      // B merges R2 into R1, which A deletes: A's first attempt puts R1 back, and the second finds it in place.
      await b.merge('R1', 'R2', keep: 'R2');
      await b.round(server);
      await deleteRecords(a, {'R1'});
      await rate(b, 'R1', 5);
      await retitle(a, 'Grade');
      // B's round lands while A's replacement is on its way.
      server.beforeReplace = () async {
        server.beforeReplace = null;
        expect((await b.round(server)).end, SyncRoundEnd.done);
      };

      final outcome = await a.round(server);
      expect(
        (outcome.end, outcome.replacements, outcome.restored),
        (SyncRoundEnd.done, 2, 1),
        reason: 'the round told of R1 it put back, though the attempt that did so was refused',
      );
      for (final list in [onServer(), await listOf(a)]) {
        expect(list.titles['rating/r1']?.value, 'Grade');
        expect(list.cells[('rating/r1', 'R1')]?.value, '5.0');
        expect(list.rows.keys.toSet(), {'R1', 'R3'});
      }
      expect(SyncKeptList.decode(File(syncBaseFile(a.info).path).readAsBytesSync()).generation, server.generation);
    });

    test('refused as stale twice, the round stops: the device and its base stay as they were', () async {
      seed(a);
      await a.round(server);
      await retitle(a, 'Grade');
      final base = File(syncBaseFile(a.info).path).readAsBytesSync();
      final before = _describe(await listOf(a));
      server.refuseAsStale = 2;

      final outcome = await a.round(server);
      expect((outcome.end, outcome.replacements), (SyncRoundEnd.refused, 2));
      expect(File(syncBaseFile(a.info).path).readAsBytesSync(), base);
      expect(_describe(await listOf(a)), before);
      expect(File(syncSentFile(a.info).path).existsSync(), isFalse);
      expect(onServer().titles['rating/r1']?.value, 'Score');

      expect((await a.round(server)).end, SyncRoundEnd.done, reason: 'positive control: the next round sends it');
      expect(onServer().titles['rating/r1']?.value, 'Grade');
    });

    test('a record a merge on this device has not finished is left as the server lists it', () async {
      a.seedRecord('R1', binding: _binding, bodyWrittenAt: 1767225600100);
      a.seedRecord('R2', binding: _binding, bodyWrittenAt: 1767225600200);
      await a.round(server);
      // A merge of R2 into R1 stopped after it published R1: R1 absorbed R2, and R2 is still a record.
      final r1 = a.charaDetail / 'active' / 'R1';
      File(r1.filePath(mergedIdsFileName).path).writeAsBytesSync(mergedIdsBytes(['R2']));
      final mark = File(r1.filePath(mergesInProgressFileName).path)
        ..writeAsBytesSync(
          mergesInProgressBytes({
            'R2': (
              route: EnhancementMergeRoute.values.first,
              identical: false,
              contentFromOlder: true,
              enhancedIsOlder: false,
            ),
          }),
        );
      a.close();

      expect((await a.round(server)).end, SyncRoundEnd.done);
      expect(onServer().rows['R1']!.record.absorbed, isEmpty);
      expect(File(r1.filePath(mergedIdsFileName).path).existsSync(), isTrue, reason: 'nothing written over it');

      // Once the merge is done, its result goes.
      mark.deleteSync();
      a.close();
      expect((await a.round(server)).end, SyncRoundEnd.done);
      expect(onServer().rows['R1']!.record.absorbed, {'R2'});
    });

    group('[R6-3], [N15-02]: a merge stopped before it retired the record it merges away', () {
      /// R1 to R3 on A, R1 and R2 with a memo each, sent and taken in by B; then a merge of R2 into R1 that published
      /// R1 — absorbing R2, with the mark — and moved R2's memo onto R1, and stopped before it retired R2.
      Future<void> stopMerge() async {
        for (final id in ['R1', 'R2', 'R3']) {
          a.seedRecord(id, binding: _binding, bodyWrittenAt: 1767225600100);
        }
        a.seedColumn(
          'memo',
          'm1',
          title: 'Note',
          data: {'R1': 'm1', 'R2': 'm2'},
          writtenAt: {'R1': 1767225600200, 'R2': 1767225600300},
        );
        await a.round(server);
        await b.round(server);
        final r1 = a.charaDetail / 'active' / 'R1';
        File(r1.filePath(mergedIdsFileName).path).writeAsBytesSync(mergedIdsBytes(['R2']));
        File(r1.filePath(mergesInProgressFileName).path).writeAsBytesSync(
          mergesInProgressBytes({
            'R2': (
              route: EnhancementMergeRoute.values.first,
              identical: false,
              contentFromOlder: true,
              enhancedIsOlder: false,
            ),
          }),
        );
        a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'm2'}, writtenAt: {'R1': 1767225600900});
        a.close();
      }

      test(
        'the record it retires waits with its end: the memo the merge moved off it stays on the server and the other '
        'device',
        () async {
          await stopMerge();

          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect((await b.round(server)).end, SyncRoundEnd.done);
          for (final list in [onServer(), await listOf(b)]) {
            expect(list.rows['R1']!.record.absorbed, isEmpty);
            expect(list.rows.keys.toSet(), {'R1', 'R2', 'R3'});
            expect(list.cells[('memo/m1', 'R2')]?.value, jsonEncode('m2'));
            expect(list.cells[('memo/m1', 'R1')]?.value, jsonEncode('m1'));
          }
        },
      );

      test('[R7-3]: a record deleted from the list beside it goes', () async {
        await stopMerge();
        await deleteRecords(a, {'R3'});

        final outcome = await a.round(server);
        expect((outcome.end, outcome.withheld), (SyncRoundEnd.done, 0));
        expect((await b.round(server)).end, SyncRoundEnd.done);
        for (final list in [onServer(), await listOf(b)]) {
          expect(list.rows.keys.toSet(), {'R1', 'R2'});
        }
      });
    });

    test('a record is read under its lock: a write half done is waited for, and read whole', () async {
      a.seedRecord('R1', binding: _binding, bodyWrittenAt: 1767225600100, normalWrittenAt: 1767225600150);
      final dir = a.charaDetail / 'active' / 'R1';
      // The lock the writer and the reader share, telling which records' locks are asked for while the writer holds.
      final locks = InProcessNamedLocks();
      final askedWhileHeld = <String>[];
      var holding = false;
      final gate = createPlatformRecordRecoveryGate(
        mutationLock: RecordMutationLock((name, mode, action) {
          if (holding && mode == RecordMutationLockMode.exclusive) askedWhileHeld.add(name);
          return locks.run(name, mode, action);
        }),
      );
      final halfWritten = Completer<void>();
      final finish = Completer<void>();
      final writer = gate.runForRecord(a.info.storageDir, 'R1', () async {
        holding = true;
        final map = jsonDecode(File(dir.filePath('record.json').path).readAsStringSync()) as Map<String, dynamic>;
        (map['metadata'] as Map<String, dynamic>)['body_written_at'] = 1767225600700;
        File(dir.filePath('record.json').path).writeAsStringSync(jsonEncode(map));
        halfWritten.complete();
        await finish.future;
        File(
          dir.filePath(recordArchiveNoteName).path,
        ).writeAsStringSync(jsonEncode({'normal_written_at': 1767225600800}));
      }, declaration: const LongReadDeclaration.none(reason: 'a test writer'));
      await halfWritten.future;

      var read = false;
      final reading = a.read(gate: gate).whenComplete(() => read = true);
      // The reader either asks for the record's lock, or reads without it and is done.
      await waitUntil(() => askedWhileHeld.isNotEmpty || read, describe: 'the reader to ask for R1 or to finish');
      expect(read, isFalse, reason: 'the read waits for the writer');
      finish.complete();
      await writer;
      final row = (await reading).list.rows['R1']!.record;
      expect((row.body.time, row.stage.time), (1767225600700, 1767225600800));
    });

    // The checks below make their changes at hours of a day, as `SPEC-R` §2 tells them; a value is written at the
    // hour the clock is set to. The day is one after the test runs: an archive is written in the archive executor's
    // isolate, which the test's clock does not reach, so at the real time — before every hour here, as each check that
    // archives has it.
    int hour(int h, [int m = 0]) => 1893456000000 + (h * 60 + m) * 60000;
    void clockAt(int time) {
      final clock = valueWriteClock;
      addTearDown(() => valueWriteClock = clock);
      valueWriteClock = () => time;
    }

    /// Of each record, the binding it was seeded with: the body a record shows is told by it.
    RecordBinding own(String id) => RecordBinding(skillPng: syncObjectName(utf8.encode(id)));

    /// What [record] absorbed, and the binding of the body it shows.
    (String, RecordBinding?) made(SyncRecord record) =>
        ((record.absorbed.toList()..sort()).join('+'), record.body.binding);

    /// [ids] on [device], each a body of its own written before any check's hour. Of two records the older is the
    /// smaller id, but where [captured] gives one a later day.
    void seedUmas(SyncTestDevice device, List<String> ids, {Map<String, int> captured = const {}}) {
      for (final (i, id) in ids.indexed) {
        device.seedRecord(
          id,
          binding: own(id),
          bodyWrittenAt: 1767225600100 + i,
          fans: 1000 + i,
          capturedDate: '2026-01-0${captured[id] ?? 1}T00:00:00',
        );
      }
    }

    /// The rectangle the geometry file of the [i]-th image of capture [n] holds, as the native pipeline writes one: a
    /// rectangle of its own, away from the origin.
    Map<String, Object?> intersectionOfShot(int n, int i) => {
      'top_left': {
        'x': 3 * n + i,
        'y': 5 * n + 7 * i,
        'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
      },
      'bottom_right': {
        'x': 3 * n + i + 8,
        'y': 5 * n + 7 * i + 12,
        'anchor': {'h': 'ScreenStart', 'v': 'ScreenEnd'},
      },
    };

    /// The geometry file of a rect [intersection], laid out as the app writes one (an indent of four spaces), so that a
    /// file the app writes of the same rect holds the same bytes.
    Uint8List geometryFile(Map<String, Object?> intersection) =>
        utf8.encode(const JsonEncoder.withIndent('    ').convert({'intersection': intersection}));

    /// The images of capture [n] as a record directory holds them: three real PNGs of pixels no other capture has, the
    /// geometry of each, and the icon cut from the factor image.
    final shots = <int, Map<String, Uint8List>>{};
    Map<String, Uint8List> shot(int n) => shots[n] ??= {
      for (final (i, image) in ['skill', 'factor', 'campaign'].indexed) ...{
        '$image.png': img.encodePng(
          img.Image(width: 8, height: 12)..clear(img.ColorRgb8(30 * n, 60 + 40 * i, 250 - 30 * n)),
        ),
        '$image.json': geometryFile(intersectionOfShot(n, i)),
      },
      'trainee.jpg': img.encodeJpg(img.Image(width: 4, height: 4)..clear(img.ColorRgb8(20 * n, 20 * n, 20 * n))),
    };
    RecordBinding bindingOfShot(int n) => expectedBinding({
      for (final image in ['skill', 'factor', 'campaign']) image: shot(n)['$image.png']!,
    });

    /// `metadata.geometry` of a record read from capture [n] whose directory holds its PNGs: each PNG's rectangle, and
    /// the same rectangle for its reduced JPEG — a PNG as narrow as these is not reduced, and so neither is its rect.
    Map<String, Object?> geometryOfShot(int n) => {
      for (final (i, image) in ['skill', 'factor', 'campaign'].indexed) ...{
        '${image}_png': intersectionOfShot(n, i),
        '${image}_jpeg': intersectionOfShot(n, i),
      },
    };

    /// `metadata.icon` of a record read from capture [n]: the SHA-256 of the icon cut from it.
    String iconOfShot(int n) => sha256.convert(shot(n)['trainee.jpg']!).toString();

    /// The record [id] on [device], its body read from capture [n] and its directory holding that capture's images.
    void seedShot(SyncTestDevice device, String id, int n) {
      final dir = device.seedRecord(
        id,
        binding: bindingOfShot(n),
        geometry: geometryOfShot(n),
        icon: iconOfShot(n),
        bodyWrittenAt: 1767225600100 + n,
        fans: 1000 + n,
      );
      for (final MapEntry(key: name, value: bytes) in shot(n).entries) {
        File(dir.filePath(name).path).writeAsBytesSync(bytes);
      }
    }

    /// The images, their geometry and the icon in the directory of the record [id] on [device]; none where it holds
    /// no record [id].
    Map<String, Uint8List> imagesOf(SyncTestDevice device, String id) {
      final dir = Directory((device.charaDetail / 'active' / id).path);
      if (!dir.existsSync()) return const {};
      return {
        for (final file in dir.listSync().whereType<File>())
          if (RegExp(r'^((skill|factor|campaign)\.(png|jpg|json)|trainee\.jpg)$').hasMatch(file.uri.pathSegments.last))
            file.uri.pathSegments.last: file.readAsBytesSync(),
      };
    }

    bool holds(SyncTestDevice device, String id) => Directory((device.charaDetail / 'active' / id).path).existsSync();

    /// The rect of each image of the record [id] in [device]'s store [store] as the preview reads it
    /// ([ImageSizeContainer]), as `[left, top, right, bottom]`.
    Future<List<List<int>>> previewRectsOf(SyncTestDevice device, String id, {String store = 'active'}) async {
      final size = (await ImageSizeContainer.load(device.charaDetail / store / id))!;
      return [
        for (final info in [size.skill, size.factor, size.campaign])
          [
            info.intersection.topLeft.x,
            info.intersection.topLeft.y,
            info.intersection.bottomRight.x,
            info.intersection.bottomRight.y,
          ],
      ];
    }

    /// The rects of capture [n]'s images ([intersectionOfShot]), as [previewRectsOf] reads them.
    List<List<int>> rectsOfShot(int n) => [
      for (final i in [0, 1, 2]) [3 * n + i, 5 * n + 7 * i, 3 * n + i + 8, 5 * n + 7 * i + 12],
    ];

    /// Removes the geometry files of the record [id] on [device], leaving its images: a directory that holds no
    /// geometry of the images its body carries one of.
    void dropGeometryFiles(SyncTestDevice device, String id) {
      for (final image in ['skill', 'factor', 'campaign']) {
        File((device.charaDetail / 'active' / id).filePath('$image.json').path).deleteSync();
      }
    }

    Future<void> writeMemo(SyncTestDevice device, String id, String memo) async {
      final container = await device.open();
      await container.read(charaDetailRecordMemoProvider('m1').future);
      expect(saveMemo(container.read(containerRefProvider), storageKey: 'm1', recordId: id, memo: memo), isTrue);
      expect(await container.read(charaDetailRecordMemoProvider('m1').notifier).flush(), isTrue);
    }

    /// The three lists — the server's and each device's — after the rounds, which a check expects to be one.
    Future<List<SyncList>> allLists() async => [onServer(), await listOf(a), await listOf(b)];

    test('rule 1, check 1: a zip of the same record over a record the other device deleted does not keep it, though '
        'its body is another', () async {
      seedUmas(a, ['R1', 'R2']);
      await a.round(server);
      await b.round(server);
      // The zip holds R1 with what it is made of — nothing absorbed — and a body the devices do not hold.
      final c = SyncTestDevice('c');
      addTearDown(c.dispose);
      c.seedRecord('R1', binding: own('R1'), fans: 4242);
      final zip = await c.exportZip('R1');
      await deleteRecords(b, {'R1'});
      expect((await b.round(server)).end, SyncRoundEnd.done);

      clockAt(hour(9));
      await a.importZip(zip);
      expect((await listOf(a)).rows['R1']!.record.body.time, hour(9), reason: 'the import wrote the body');
      final outcome = await a.round(server);
      expect((outcome.end, outcome.restored, outcome.added), (SyncRoundEnd.done, 0, 0));
      await b.round(server);
      for (final list in await allLists()) {
        expect(list.rows.keys.toSet(), {'R2'});
      }
    });

    test('rule 1, check 2 but its images: a record taken again from a zip is the same record, its state written later '
        'stands, and the memo the retake lost is lost on both', () async {
      seedUmas(a, ['R1']);
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'kept'}, writtenAt: {'R1': 1767225600500});
      await a.round(server);
      await b.round(server);
      final zip = await a.exportZip('R1');
      clockAt(hour(9));
      final container = await b.open();
      await container
          .read(charaArchiveControllerProvider.notifier)
          .archive(['R1'], ArchiveImageOption.none, effects: archiveEffects(container));
      clockAt(hour(10));
      await deleteRecords(a, {'R1'});
      await a.importZip(zip);

      await b.round(server);
      final outcome = await a.round(server);
      expect((outcome.end, outcome.restored, outcome.added), (SyncRoundEnd.done, 0, 0));
      await b.round(server);
      for (final list in await allLists()) {
        expect(list.rows.keys.toSet(), {'R1'});
        final r1 = list.rows['R1']!.record;
        expect((r1.stage.value, r1.stage.time), (null, hour(10)), reason: 'the retake wrote after the archive');
        expect(list.cells[('memo/m1', 'R1')], isNull, reason: 'A lost the memo with the record it deleted');
      }
      expect(Directory((b.charaDetail / 'active' / 'R1').path).existsSync(), isTrue);
    });

    test('rule 2, checks 2 and 3: a re-recognition reaches the other device, and of two the later stands, whatever '
        'module read it', () async {
      seedUmas(a, ['R1', 'R2']);
      await a.round(server);
      await b.round(server);
      clockAt(hour(9));
      await a.recognizeAgain('R1', (result) {
        result['fans'] = 7;
        (result['metadata'] as Map)['recognizer_version'] = '2030-01-01T00:00:00+0900';
      });
      clockAt(hour(10));
      await b.recognizeAgain('R1', (result) {
        result['fans'] = 8;
        (result['metadata'] as Map)['recognizer_version'] = '2026-01-01T00:00:00+0900';
      });
      final older = (await listOf(b)).rows['R1']!.record.body;
      expect(older.content, isNot((await listOf(a)).rows['R1']!.record.body.content));

      await a.round(server);
      await b.round(server);
      await a.round(server);
      for (final list in await allLists()) {
        final body = list.rows['R1']!.record.body;
        expect((body.content, body.time, body.binding), (older.content, hour(10), own('R1')));
      }
    });

    test(
      'rule 1, check 3: a record deleted and imported again is the one the base holds, the other device\'s merge reaches '
      'it, and the body written later stands',
      () async {
        seedUmas(a, ['R1', 'R3']);
        await a.round(server);
        await b.round(server);
        final zip = await b.exportZip('R1');
        clockAt(hour(10));
        await deleteRecords(b, {'R1'});
        await b.importZip(zip);
        clockAt(hour(9));
        await a.merge('R1', 'R3', keep: 'R3');

        await a.round(server);
        final outcome = await b.round(server);
        expect((outcome.end, outcome.restored, outcome.splitOff), (SyncRoundEnd.done, 0, 0));
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1'}, reason: 'not split: the import made R1 what the base holds');
          final r1 = list.rows['R1']!.record;
          expect(r1.absorbed, {'R3'});
          expect((r1.body.binding, r1.body.time), (own('R1'), hour(10)), reason: 'the import wrote after the merge');
        }
      },
    );

    test('rule 3, check 1 (S7): a record two devices merge apart is split, each body going with its record', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      await a.round(server);
      await b.round(server);
      clockAt(hour(9));
      await a.merge('R1', 'R2', keep: 'R2');
      await b.merge('R1', 'R3', keep: 'R3');
      // What B's R1 holds beside the files a round writes goes with it to the id it is split off to.
      final bR1 = b.charaDetail / 'active' / 'R1';
      File(bR1.filePath('skill.png').path).writeAsStringSync('the skills R3 was read from');
      final bR1Body = (await listOf(b)).rows['R1']!.record.body;

      expect((await a.round(server)).splitOff, 0);
      final split = await b.round(server);
      expect((split.end, split.splitOff, split.restored, split.added), (SyncRoundEnd.done, 1, 0, 0));
      expect((await a.round(server)).splitOff, 0, reason: 'the device that split it alone tells it');

      final ids = onServer().rows.keys.toSet();
      expect(ids, hasLength(2));
      expect(ids, contains('R1'));
      final splitId = ids.singleWhere((id) => id != 'R1');
      for (final list in await allLists()) {
        expect(list.rows.keys.toSet(), ids);
        final (r1, d) = (list.rows['R1']!.record, list.rows[splitId]!.record);
        expect(made(r1), ('R2', own('R2')), reason: 'the server\'s record keeps the id');
        expect(made(d), ('R3', own('R3')), reason: 'B\'s record goes on under its own id');
        expect(d.body.content, bR1Body.content);
      }
      for (final device in [a, b]) {
        expect((await device.round(server)).replacements, 0, reason: 'the two devices and the server agree');
      }
      final carried = b.charaDetail / 'active' / splitId;
      expect(File(carried.filePath('skill.png').path).readAsStringSync(), 'the skills R3 was read from');
      expect(
        syncObjectName(utf8.encode(b.bodyOf('R1'))),
        onServer().rows['R1']!.bodyName,
        reason: 'the id B\'s record is split off holds the server\'s body',
      );
    });

    test(
      'rule 3, check 1: the relation bonus of a record split off goes with it, and the id it leaves holds none',
      () async {
        seedUmas(a, ['R1', 'R2', 'R3']);
        await a.round(server);
        await b.round(server);
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R2');
        await b.merge('R1', 'R3', keep: 'R3');
        // B's resolver derived a bonus of its R1, which only B holds.
        int? bonusOn(String id) {
          final json = jsonDecode(
            File((b.charaDetail / 'active' / id).filePath('record.json').path).readAsStringSync(),
          );
          return ((json as Map<String, dynamic>)['metadata'] as Map<String, dynamic>)['relation_bonus'] as int?;
        }

        final bR1 = File((b.charaDetail / 'active' / 'R1').filePath('record.json').path);
        final map = jsonDecode(bR1.readAsStringSync()) as Map<String, dynamic>;
        (map['metadata'] as Map<String, dynamic>)['relation_bonus'] = 7;
        bR1.writeAsStringSync(jsonEncode(map));
        b.close();

        await a.round(server);
        expect((await b.round(server)).splitOff, 1);
        final splitId = onServer().rows.keys.singleWhere((id) => id != 'R1');
        expect((bonusOn('R1'), bonusOn(splitId)), (null, 7));
      },
    );

    test(
      'rule 3, check 1: a record split off that holds no relation bonus leaves the one the id it lands on holds',
      () async {
        seedUmas(a, ['R1', 'R2']);
        await a.round(server);
        await b.round(server);
        clockAt(hour(9));
        // B meets the server with no base and splits its merge off R1; both devices then hold R1, R2 and the record
        // split off, made of R2.
        await b.merge('R1', 'R2', keep: 'R2');
        File(syncBaseFile(b.info).path).deleteSync();
        expect((await b.round(server)).splitOff, 1);
        await a.round(server);
        final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        File recordOf(String id) => File((a.charaDetail / 'active' / id).filePath('record.json').path);
        int? bonusOn(String id) =>
            ((jsonDecode(recordOf(id).readAsStringSync()) as Map<String, dynamic>)['metadata']
                    as Map<String, dynamic>)['relation_bonus']
                as int?;
        // A's resolver derived a bonus of the record split off, which only A holds.
        final map = jsonDecode(recordOf(splitId).readAsStringSync()) as Map<String, dynamic>;
        (map['metadata'] as Map<String, dynamic>)['relation_bonus'] = 7;
        recordOf(splitId).writeAsStringSync(jsonEncode(map));
        a.close();

        // B merges R1 with R3 and the record split off with R4; A's merge makes its R1 of what the record split off is
        // made of. A's round splits its R1 off onto the record split off, which B changed: B's content stands there.
        b.close();
        seedUmas(b, ['R3', 'R4']);
        await b.merge('R1', 'R3', keep: 'R3');
        await b.merge(splitId, 'R4', keep: 'R4');
        await a.merge('R1', 'R2', keep: 'R1');
        await b.round(server);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(onServer().rows.keys.toSet(), {'R1', splitId});
        expect((bonusOn('R1'), bonusOn(splitId)), (null, 7));
      },
    );

    test(
      'rule 3, check 1: a record split off carries its relation bonus onto an id that splits its own record off in the '
      'same round',
      () async {
        final splitId = recordSyncSplitId('R1', {'R3'});
        void seedOn(SyncTestDevice device, String id, Set<String> absorbed, int fans, {int? bonus}) =>
            device.seedRecord(
              id,
              binding: _binding,
              absorbed: absorbed,
              fans: fans,
              bodyWrittenAt: 1767225600100 + fans,
              relationBonus: bonus,
            );
        seedOn(a, 'R1', {'R2'}, 2);
        seedOn(a, splitId, {'R3', 'R4'}, 4);
        await a.round(server);
        await b.round(server);
        a.close();
        b.close();
        // Since that base, A's R1 is made of R3 and holds the bonus its resolver derived, and its record at the split
        // id took R5 in; B's R1 took R6 in, and its record at the split id holds R3 alone.
        seedOn(a, 'R1', {'R3'}, 1003, bonus: 7);
        seedOn(a, splitId, {'R3', 'R4', 'R5'}, 1005);
        seedOn(b, 'R1', {'R2', 'R6'}, 1006);
        seedOn(b, splitId, {'R3'}, 1003);
        await b.round(server);
        final outcome = await a.round(server);
        expect(outcome.end, SyncRoundEnd.done);
        int? bonusOn(String id) =>
            ((jsonDecode(File((a.charaDetail / 'active' / id).filePath('record.json').path).readAsStringSync())
                        as Map<String, dynamic>)['metadata']
                    as Map<String, dynamic>)['relation_bonus']
                as int?;
        expect((bonusOn('R1'), bonusOn(splitId)), (null, 7));
      },
    );

    // A's round splits its R1 off onto the split id, whose record A splits off in turn: A's R1 becomes the record at
    // the split id, and A's record of the split id the record past it. They are two records of A's, as the user holds
    // them, though one lands on the other's id.
    group('a chain of splits keeps the device\'s two records two', () {
      final splitId = recordSyncSplitId('R1', {'R3'});
      final pastIt = recordSyncSplitId(splitId, {'R3', 'R4', 'R5'});
      void seedOn(SyncTestDevice device, String id, Set<String> absorbed, int fans) =>
          device.seedRecord(id, binding: _binding, absorbed: absorbed, fans: fans, bodyWrittenAt: 1767225600100 + fans);
      // The base holds R1 made of R2, the split id made of R3 and R4, and R3 on its own beside [more]; since, A's R1
      // took R3 in and its record of the split id R5, and B's R1 took R6 in and its record of the split id holds R3
      // alone. Both devices then delete R3.
      Future<void> chainOf(List<(String, String)> dismissed, {void Function(SyncTestDevice a)? more}) async {
        seedOn(a, 'R1', {'R2'}, 2);
        seedOn(a, splitId, {'R3', 'R4'}, 4);
        seedOn(a, 'R3', {}, 3);
        more?.call(a);
        a.seedDismissed(dismissed);
        await a.round(server);
        await b.round(server);
        a.close();
        b.close();
        seedOn(a, 'R1', {'R3'}, 1003);
        seedOn(a, splitId, {'R3', 'R4', 'R5'}, 1005);
        seedOn(b, 'R1', {'R2', 'R6'}, 1006);
        seedOn(b, splitId, {'R3'}, 1003);
        await deleteRecords(a, {'R3'});
        await deleteRecords(b, {'R3'});
      }

      test('a pair of the base both devices took out, deleting one of its records, stays out', () async {
        await chainOf([(splitId, 'R3')]);
        await b.round(server);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', splitId, pastIt});
          expect(list.dismissed, isEmpty, reason: 'R3 went on both devices, and its pair with it');
        }
      });

      test(
        'a pair the other device dismissed stays, where the device lists the base\'s pair as its two records give it',
        () async {
          await chainOf([('R1', 'R3')], more: (a) => seedOn(a, 'Z', {'R3'}, 9));
          await a.dismiss('R1', splitId);
          await b.dismiss(splitId, 'Z');
          await b.round(server);
          expect((await a.round(server)).end, SyncRoundEnd.done);
          await b.round(server);
          await a.round(server);
          for (final list in await allLists()) {
            expect(list.rows.keys.toSet(), {'R1', splitId, pastIt, 'Z'});
            expect(list.dismissed, {(splitId, pastIt), (splitId, 'Z')});
          }
        },
      );

      // A lists R1+R4, which its R1 and its record of the split id give as the split id and the record past it, which
      // absorbed R4: a reading of the base's R1+R3 through two records of A's that are not the base pair's holders.
      test('a pair the other device dismissed stays, where the device lists the base\'s pair through another of its '
          'records', () async {
        seedOn(a, 'R1', {'R2'}, 2);
        seedOn(a, splitId, {'R3', 'R4'}, 4);
        seedOn(a, 'R3', {}, 3);
        seedOn(a, 'R4', {}, 8);
        seedOn(a, 'Z', {'R3'}, 9);
        a.seedDismissed([('R1', 'R3')]);
        // The split id, R3, R4 and Z are one operation: more slots than the server's default takes in one.
        server.partsLimit = 8;
        expect((await a.round(server)).end, SyncRoundEnd.done);
        await b.round(server);
        a.close();
        b.close();
        seedOn(a, 'R1', {'R3'}, 1003);
        seedOn(a, splitId, {'R3', 'R4', 'R5'}, 1005);
        seedOn(b, 'R1', {'R2', 'R6'}, 1006);
        seedOn(b, splitId, {'R3'}, 1003);
        await deleteRecords(a, {'R3'});
        await deleteRecords(b, {'R3', 'R4'});
        await a.dismiss('R1', 'R4');
        await b.dismiss(splitId, 'Z');
        await b.round(server);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', splitId, pastIt, 'Z'});
          expect(list.dismissed, {(splitId, pastIt), (splitId, 'Z')});
        }
      });
    });

    // R1 and the split id of A both land on the id past the split id, so A's R1+(split id) reads as one record and no
    // pair: A says nothing of it, and the pair B dismissed of a record Z that absorbed the split id stays.
    test(
      'a pair the device lists of two of its records that land on one id says nothing of the other device\'s pair',
      () async {
        final splitId = recordSyncSplitId('R1', {'R3'});
        final pastIt = recordSyncSplitId(splitId, {'R3'});
        void seedOn(SyncTestDevice device, String id, Set<String> absorbed, int fans) => device.seedRecord(
          id,
          binding: _binding,
          absorbed: absorbed,
          fans: fans,
          bodyWrittenAt: 1767225600100 + fans,
        );
        seedOn(a, 'R1', {'R2', 'R6'}, 2);
        seedOn(a, splitId, {'R3', 'R4'}, 4);
        seedOn(a, pastIt, {'R3'}, 5);
        seedOn(a, 'Z', {splitId, 'R3', 'R4'}, 9);
        a.seedDismissed([('R1', splitId)]);
        await a.round(server);
        await b.round(server);
        a.close();
        b.close();
        seedOn(a, 'R1', {'R3'}, 1003);
        seedOn(a, splitId, {'R3'}, 1004);
        seedOn(b, 'R1', {'R2', 'R6', 'R8'}, 1008);
        seedOn(b, splitId, {'R3', 'R4', 'R7'}, 1007);
        await b.deleteDismissedFile();
        await b.dismiss(pastIt, 'Z');
        await b.round(server);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.dismissed, isEmpty, reason: 'A took $pastIt+Z out');
        }
      },
    );

    test(
      'rule 3, check 2 but its images: two merges of one pair agree, and the archive state written later stands',
      () async {
        seedUmas(a, ['X', 'Y']);
        await a.round(server);
        await b.round(server);
        final zip = await a.exportZip('Y');
        clockAt(hour(9));
        final container = await a.open();
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive(['Y'], ArchiveImageOption.none, effects: archiveEffects(container));
        clockAt(hour(9, 10));
        await deleteRecords(b, {'Y'});
        await b.importZip(zip);
        clockAt(hour(9, 20));
        await a.merge('X', 'Y', keep: 'Y');
        clockAt(hour(9, 30));
        await b.merge('X', 'Y', keep: 'Y');

        final outcomes = [await a.round(server), await b.round(server), await a.round(server)];
        for (final outcome in outcomes) {
          expect((outcome.end, outcome.restored, outcome.splitOff, outcome.added), (SyncRoundEnd.done, 0, 0, 0));
        }
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'X'});
          final x = list.rows['X']!.record;
          expect(made(x), ('Y', own('Y')));
          expect((x.stage.value, x.stage.time), (ArchiveImageOption.none, hour(9, 20)), reason: 'only A wrote a state');
        }
        expect(Directory((b.charaDetail / 'archive' / 'X').path).existsSync(), isTrue);
        expect(Directory((b.charaDetail / 'active' / 'X').path).existsSync(), isFalse);
      },
    );

    test(
      'rule 4, check 3: the memo written last stands on a merged record, and a pair dismissed on it stays',
      () async {
        seedUmas(a, ['R1', 'R2', 'R5']);
        a.seedColumn('memo', 'm1', title: 'Note');
        await a.round(server);
        await b.round(server);
        clockAt(hour(9));
        await a.merge(
          'R1',
          'R2',
          keep: 'R2',
          choices: const EnhancementMergeChoices(memo: {'m1': 'a'}),
        );
        clockAt(hour(10));
        await writeMemo(b, 'R1', 'b');
        await b.dismiss('R1', 'R5');

        await a.round(server);
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R5'});
          expect(made(list.rows['R1']!.record), ('R2', own('R2')));
          expect(list.cells[('memo/m1', 'R1')], SyncValue<String?>(jsonEncode('b'), hour(10)));
          expect(list.dismissed, {('R1', 'R5')});
        }
      },
    );

    test('rule 4, check 4: a pair of a record the other device merged is read as the pair of the record that absorbed '
        'it, not of the record split off', () async {
      seedUmas(a, ['X', 'Y', 'W', 'Z'], captured: {'Y': 2, 'W': 2, 'Z': 2});
      await a.round(server);
      await b.round(server);
      await a.merge('X', 'W', keep: 'W');
      await a.dismiss('Y', 'Z');
      await b.merge('X', 'Y', keep: 'Y');

      expect((await b.round(server)).splitOff, 0);
      final split = await a.round(server);
      expect((split.end, split.splitOff), (SyncRoundEnd.done, 1));
      await b.round(server);
      final ids = onServer().rows.keys.toSet();
      final d = ids.singleWhere((id) => !{'X', 'Z'}.contains(id));
      for (final list in await allLists()) {
        expect(list.rows.keys.toSet(), {'X', 'Z', d});
        expect((made(list.rows['X']!.record), made(list.rows[d]!.record)), (('Y', own('Y')), ('W', own('W'))));
        expect(list.dismissed, {('X', 'Z')}, reason: 'Y+Z is read as X+Z, the X the server holds; D+Z is not one');
      }
    });

    test(
      'rule 4, check 5: a pair of a record kept in the result is not read as the pair of a record absorbing it',
      () async {
        seedUmas(a, ['X', 'Y', 'W', 'Z'], captured: {'Y': 2, 'W': 3, 'Z': 4});
        await a.round(server);
        await b.round(server);
        await a.merge('X', 'Y', keep: 'Y');
        await a.round(server);
        await b.merge('Y', 'W', keep: 'W');
        await b.dismiss('Y', 'Z');

        final kept = await b.round(server);
        expect(
          (kept.end, kept.restored, kept.splitOff),
          (SyncRoundEnd.done, 1, 0),
          reason: 'B tells the merge it undid',
        );
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'X', 'Y', 'Z'});
          expect((made(list.rows['X']!.record).$1, made(list.rows['Y']!.record).$1), ('Y', 'W'));
          expect(list.dismissed, {('Y', 'Z')});
        }
      },
    );

    test('rule 4, check 8: a device that deleted the pairs\' file reaches the pair the other device moved by a merge, '
        'past the record it splits off', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      a.seedDismissed([('R2', 'R3')]);
      await a.round(server);
      await b.round(server);
      await b.merge('R1', 'R2', keep: 'R1');
      expect((await listOf(b)).dismissed, {('R1', 'R3')}, reason: 'the merge moves B\'s pair onto R1');
      // A captures R4 while it is closed: a record the base does not hold.
      a.close();
      a.seedRecord('R4', binding: own('R4'), bodyWrittenAt: 1767225600200, fans: 2000);
      await a.merge('R1', 'R4', keep: 'R1');
      await a.deleteDismissedFile();

      await b.round(server);
      final split = await a.round(server);
      expect((split.end, split.splitOff), (SyncRoundEnd.done, 1));
      await b.round(server);
      final d = onServer().rows.keys.singleWhere((id) => !{'R1', 'R3'}.contains(id));
      for (final list in await allLists()) {
        expect(list.rows.keys.toSet(), {'R1', 'R3', d});
        expect((made(list.rows['R1']!.record).$1, made(list.rows[d]!.record).$1), ('R2', 'R4'));
        expect(list.dismissed, isEmpty, reason: 'A said R2+R3 is not, and R2 is R1 in the result');
      }
    });

    test(
      'rule 4, check 9: a merge moving a pair onto one survivor says nothing of the pair\'s other readings',
      () async {
        seedUmas(a, ['R1', 'R2', 'R3', 'R5', 'R4'], captured: {'R4': 2});
        await a.round(server);
        await b.round(server);
        final zip = await b.exportZip('R4');
        await b.merge('R3', 'R4', keep: 'R3');
        await b.importZip(zip);
        await b.dismiss('R1', 'R4');
        await b.round(server);
        await a.round(server);
        expect((await listOf(a)).dismissed, {('R1', 'R4')});
        expect(made((await listOf(a)).rows['R3']!.record).$1, 'R4', reason: 'A holds R4 and R3 that absorbed it');

        await a.merge('R5', 'R4', keep: 'R5');
        await b.merge('R2', 'R4', keep: 'R2');
        expect((await listOf(a)).dismissed, {('R1', 'R5')});
        expect((await listOf(b)).dismissed, {('R1', 'R2')});
        await a.round(server);
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R2', 'R3', 'R5'});
          expect(list.dismissed, {('R1', 'R2'), ('R1', 'R3'), ('R1', 'R5')});
        }
      },
    );

    test('rule 4, check 10: a pair a device takes out goes in every reading, the one through a record it never held '
        'too', () async {
      seedUmas(a, ['R1', 'R2', 'R3', 'R4']);
      a.seedDismissed([('R2', 'R3')]);
      await a.round(server);
      await b.round(server);
      await b.merge('R1', 'R2', keep: 'R1');
      await a.merge('R1', 'R3', keep: 'R1');
      await a.merge('R2', 'R4', keep: 'R2');
      expect((await listOf(a)).dismissed, {('R1', 'R2')});

      await a.round(server);
      final split = await b.round(server);
      expect((split.end, split.splitOff, split.restored), (SyncRoundEnd.done, 1, 1));
      final d = onServer().rows.keys.singleWhere((id) => !{'R1', 'R2'}.contains(id));
      // A has not taken in the round that split D off: D is a record it never held, and its base is its own round's.
      expect((await listOf(a)).rows.keys.toSet(), {'R1', 'R2'});
      for (final list in [onServer(), await listOf(b)]) {
        expect(list.rows.keys.toSet(), {'R1', 'R2', d});
        expect(
          [
            for (final id in ['R1', 'R2', d]) made(list.rows[id]!.record).$1,
          ],
          ['R3', 'R4', 'R2'],
        );
        expect(list.dismissed, {('R1', 'R2'), syncDismissedPair(d, 'R1')});
      }

      await a.deleteDismissedFile();
      await a.round(server);
      await b.round(server);
      for (final list in await allLists()) {
        expect(list.dismissed, isEmpty, reason: 'A took out R1+R2, and D+R1 is a reading of it too');
      }
    });

    test('rule 5, check 1: a memo opened and closed with OK is not written', () async {
      seedUmas(a, ['R1']);
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'old'}, writtenAt: {'R1': 1767225600500});
      await a.round(server);
      await b.round(server);
      clockAt(hour(9));
      await writeMemo(b, 'R1', 'X');
      clockAt(hour(10));
      await writeMemo(a, 'R1', 'old');

      await b.round(server);
      await a.round(server);
      await b.round(server);
      for (final list in await allLists()) {
        expect(list.cells[('memo/m1', 'R1')], SyncValue<String?>(jsonEncode('X'), hour(9)));
      }
    });

    /// The memos of the storage `m1` on [device]'s disk.
    Map<String, String> memosOnDisk(SyncTestDevice device) {
      final file = File(device.info.charaDetailMemoDir.filePath('m1.json').path);
      return file.existsSync() ? MemoDataMapper.fromJson(file.readAsStringSync()).data : const {};
    }

    // [N15-21]・[N15-24]: a round puts what it took in through the chain every edit of a storage writes through, and
    // a value only where the device still holds it as the round read it; a record likewise ([G218]).
    test('[N15-24]: a memo saved while a round is writing another memo of the same storage stays, and so does the one '
        'the round wrote', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      await writeMemo(b, 'R1', 'from b');
      await b.round(server);

      a.close();
      final entered = Completer<void>();
      final go = Completer<void>();
      a.beforeMetadataWrite = (path) async {
        if (entered.isCompleted || path.name != 'm1.json') return;
        entered.complete();
        await go.future;
      };
      final container = await a.open();
      await container.read(charaDetailRecordMemoProvider('m1').future);
      final round = a.round(server);
      await Future.any([entered.future, round]);
      expect(
        entered.isCompleted,
        isTrue,
        reason: 'the round writes the storage through the chain an edit writes through',
      );
      expect(saveMemo(container.read(containerRefProvider), storageKey: 'm1', recordId: 'R2', memo: 'mine'), isTrue);
      go.complete();
      expect((await round).end, SyncRoundEnd.done);
      expect(await container.read(charaDetailRecordMemoProvider('m1').notifier).flush(), isTrue);
      expect(memosOnDisk(a), {'R1': 'from b', 'R2': 'mine'});

      await a.round(server);
      await b.round(server);
      for (final list in await allLists()) {
        expect(list.cells[('memo/m1', 'R1')]?.value, jsonEncode('from b'));
        expect(list.cells[('memo/m1', 'R2')]?.value, jsonEncode('mine'));
      }
    });

    test('[N15-21]: a memo whose save is still on its way when a round reads the device is not written over by the '
        'round, and the next round sends it', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      await writeMemo(b, 'R1', 'from b');
      // A body A has to ask the server for, so that A's round stops there once it has read the device.
      await b.recognizeAgain('R3', (result) => result['fans'] = 8);
      await b.round(server);

      a.close();
      final go = Completer<void>();
      var held = false;
      a.beforeMetadataWrite = (path) async {
        if (held || path.name != 'm1.json') return;
        held = true;
        await go.future;
      };
      final container = await a.open();
      await container.read(charaDetailRecordMemoProvider('m1').future);
      expect(saveMemo(container.read(containerRefProvider), storageKey: 'm1', recordId: 'R2', memo: 'mine'), isTrue);
      await waitUntil(() => held, describe: 'the save to reach its write');
      server.beforeBodies = (names) async {
        // The round has read the device, the save still on its way; it lands before anything is put in place.
        go.complete();
        expect(await container.read(charaDetailRecordMemoProvider('m1').notifier).flush(), isTrue);
        return const {};
      };
      expect((await a.round(server)).end, SyncRoundEnd.done);
      expect(go.isCompleted, isTrue);
      expect(memosOnDisk(a), {'R1': 'from b', 'R2': 'mine'});

      server.beforeBodies = null;
      await a.round(server);
      await b.round(server);
      expect((await listOf(b)).cells[('memo/m1', 'R2')]?.value, jsonEncode('mine'));
      expect(memosOnDisk(b), {'R1': 'from b', 'R2': 'mine'});
    });

    test('[N15-21]: a storage whose last save failed is not written by a round, which leaves it to the next; the memo '
        'the failed save held goes once it lands', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      await writeMemo(b, 'R1', 'from b');
      await b.round(server);

      a.close();
      var failing = true;
      a.beforeMetadataWrite = (path) async {
        if (failing && path.name == 'm1.json') throw const FileSystemException('a write that does not land');
      };
      final container = await a.open();
      await container.read(charaDetailRecordMemoProvider('m1').future);
      final memo = container.read(charaDetailRecordMemoProvider('m1').notifier);
      expect(saveMemo(container.read(containerRefProvider), storageKey: 'm1', recordId: 'R2', memo: 'mine'), isTrue);
      expect(await memo.flush(), isFalse);

      expect((await a.round(server)).end, SyncRoundEnd.failed);
      expect(memosOnDisk(a), isEmpty, reason: 'nothing is put in the storage while its last save has not landed');
      expect(container.read(charaDetailRecordMemoProvider('m1')).requireValue.data, {'R2': 'mine'});

      failing = false;
      memo.retryWrite();
      expect(await memo.flush(), isTrue);
      expect((await a.round(server)).end, SyncRoundEnd.done);
      await b.round(server);
      expect(memosOnDisk(a), {'R1': 'from b', 'R2': 'mine'});
      expect(memosOnDisk(b), {'R1': 'from b', 'R2': 'mine'});
    });

    test('[G218]: a record this device re-recognizes after a round read it, and before the round puts the other '
        "device's body in its place, keeps what it read; the next round merges it, the later standing", () async {
      seedUmas(a, ['R1']);
      await a.round(server);
      await b.round(server);
      clockAt(hour(9));
      await b.recognizeAgain('R1', (result) => result['fans'] = 8);
      await b.round(server);

      // A's round has read A and asks the server for B's body; A re-recognizes R1 meanwhile, later than B did.
      server.beforeBodies = (names) async {
        server.beforeBodies = null;
        clockAt(hour(10));
        await a.recognizeAgain('R1', (result) => result['fans'] = 9);
        return const {};
      };
      expect((await a.round(server)).end, SyncRoundEnd.changedMeanwhile, reason: 'the round leaves R1 to the next');
      final mine = (await listOf(a)).rows['R1']!.record.body;
      expect(mine.time, hour(10));

      await a.round(server);
      await b.round(server);
      for (final list in await allLists()) {
        expect((list.rows['R1']!.record.body.content, list.rows['R1']!.record.body.time), (mine.content, hour(10)));
      }
    });

    test('[G218]: a record the other device removed, which this device merges into after a round read it and before '
        'the round removes it, stays; the next round keeps it, the merge with it (S4)', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      await a.round(server);
      await b.round(server);
      await deleteRecords(b, {'R1'});
      // B's re-recognition of R3 is what sends A's round to the server for a body, where it is held.
      clockAt(hour(9));
      await b.recognizeAgain('R3', (result) => result['fans'] = 8);
      await b.round(server);

      final entered = Completer<void>();
      final go = Completer<void>();
      server.beforeBodies = (names) async {
        server.beforeBodies = null;
        entered.complete();
        await go.future;
        return const {};
      };
      final round = a.round(server);
      await entered.future;
      clockAt(hour(10));
      await a.merge('R1', 'R2', keep: 'R2');
      go.complete();
      expect((await round).end, SyncRoundEnd.changedMeanwhile, reason: 'the round leaves R1 to the next');
      expect((await listOf(a)).rows['R1']?.record.absorbed, {'R2'}, reason: 'the round removed nothing of the merge');

      await a.round(server);
      await b.round(server);
      for (final list in await allLists()) {
        expect(list.rows.keys.toSet(), {'R1', 'R3'});
        expect(list.rows['R1']!.record.absorbed, {'R2'});
      }
    });

    test('a pair this device dismisses after a round read it, and before the round puts the pairs in place, stays: '
        "the round lands only its own change of the pairs (3c ⑧)", () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      await a.round(server);
      await b.round(server);
      await b.dismiss('R1', 'R2');
      // B's re-recognition of R3 is what sends A's round to the server for a body, where A dismisses a pair.
      await b.recognizeAgain('R3', (result) => result['fans'] = 8);
      await b.round(server);

      server.beforeBodies = (names) async {
        server.beforeBodies = null;
        await a.dismiss('R2', 'R3');
        return const {};
      };
      expect((await a.round(server)).end, SyncRoundEnd.done);
      expect((await listOf(a)).dismissed, {('R1', 'R2'), ('R2', 'R3')}, reason: 'the dismissal made meanwhile stays');

      await a.round(server);
      await b.round(server);
      for (final list in await allLists()) {
        expect(list.dismissed, {('R1', 'R2'), ('R2', 'R3')});
      }
    });

    for (final unread in ['R1', 'R2']) {
      test('a record this device cannot read when a round asks for it is left to the next round, neither written nor '
          'removed, and the round ends (3c2 ⑦): $unread', () async {
        seedUmas(a, ['R1', 'R2', 'R3']);
        await a.round(server);
        await b.round(server);
        // R1 is one the round puts B's body in place of, R2 one it removes; B's body of R3 is what sends A's round to
        // the server.
        await b.recognizeAgain('R1', (result) => result['fans'] = 8);
        await deleteRecords(b, {'R2'});
        await b.recognizeAgain('R3', (result) => result['fans'] = 9);
        await b.round(server);

        final file = File((a.charaDetail / 'active' / unread).filePath('record.json').path);
        server.beforeBodies = (names) async {
          server.beforeBodies = null;
          file.writeAsStringSync('{not a record');
          return const {};
        };
        expect((await a.round(server)).end, SyncRoundEnd.failed, reason: 'the round leaves $unread to the next');
        expect(file.readAsStringSync(), '{not a record', reason: 'nothing is written over the record, nor removed');
      });
    }

    test('[R7-3]: a record this device merged into another and has not sent stays on the server and the other device, '
        'where the round cannot read the record it went into', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R2': 'kept'}, writtenAt: {'R2': hour(8)});
      a.seedDismissed([('R1', 'R2')]);
      await a.round(server);
      await b.round(server);
      final before = _describe(onServer());
      clockAt(hour(9));
      await a.merge('R1', 'R2', keep: 'R2');
      File((a.charaDetail / 'active' / 'R1').filePath(mergedIdsFileName).path).writeAsStringSync('["R2", cut short');

      final outcome = await a.round(server);
      expect(outcome.end, SyncRoundEnd.done);
      expect((await b.round(server)).end, SyncRoundEnd.done);
      expect(_describe(onServer()), before);
      expect(_describe(await listOf(b)), before);
      expect(outcome.withheld, 1, reason: 'R2, which R1 may hold');
    });

    // [R7-4]: what the server has no room for waits until it has some — a merge's end with the record it absorbed —,
    // and what needs no room goes in the same round. The decision is the shared round's: one backend.
    group('room ([R7-4])', () {
      Future<void> recognizeAgain(SyncTestDevice device, String id) =>
          device.recognizeAgain(id, (result) => result['fans'] = 7);

      test('check 2: a merge whose end the server has no room for waits with the record it absorbed, the other device '
          'sees both as they were, and both go once there is room and the user syncs now', () async {
        await a.setSyncOn(true);
        seedUmas(a, ['R1', 'R2', 'R3']);
        await a.round(server);
        await b.round(server);
        final before = _describe(onServer());
        server.noRoom = 'account_limit';
        clockAt(hour(9));
        // The merge's end shows a body the server does not hold: recognised again once merged, as the merge refuses a
        // record recognised again before it.
        await a.merge('R1', 'R2', keep: 'R2');
        await recognizeAgain(a, 'R1');
        final merged = (await listOf(a)).rows['R1']!.record;

        final waited = await a.round(server);
        expect((waited.end, waited.waitingForRoom), (SyncRoundEnd.done, 2), reason: 'R1, and R2 its merge absorbed');
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expect(_describe(onServer()), before);
        expect(_describe(await listOf(b)), before, reason: 'B sees R1 and R2 as they were before the merge');
        expect((await listOf(a)).rows['R1']?.record.absorbed, {'R2'}, reason: 'A holds its merge');

        server.noRoom = null;
        final stopped = await a.round(server);
        expect((stopped.end, stopped.waitingForRoom), (SyncRoundEnd.done, 2), reason: 'A is stopped for room');
        final sent = await a.syncNow(server);
        expect((sent.end, sent.waitingForRoom), (SyncRoundEnd.done, 0));
        await b.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R3'});
          expect(list.rows['R1']!.record.absorbed, {'R2'});
          expect(list.rows['R1']!.record.body.content, merged.body.content);
        }
      });

      test(
        'what needs no room goes in the round a body waits for room: the delete and the archive of other records',
        () async {
          await a.setSyncOn(true);
          seedUmas(a, ['R1', 'R2', 'R3']);
          await a.round(server);
          await b.round(server);
          final r2 = onServer().rows['R2']!.bodyName;
          server.noRoom = 'account_limit';
          clockAt(hour(9));
          await recognizeAgain(a, 'R2');
          await deleteRecords(a, {'R1'});
          final container = await a.open();
          await container
              .read(charaArchiveControllerProvider.notifier)
              .archive(['R3'], ArchiveImageOption.none, effects: archiveEffects(container));

          final waited = await a.round(server);
          expect((waited.end, waited.waitingForRoom), (SyncRoundEnd.done, 1), reason: 'R2');
          await b.round(server);
          for (final list in [onServer(), await listOf(b)]) {
            expect(list.rows.keys.toSet(), {'R2', 'R3'}, reason: 'the delete of R1 went');
            expect(list.rows['R3']!.record.stage.value, ArchiveImageOption.none, reason: 'the archive of R3 went');
            expect(list.rows['R2']!.bodyName, r2, reason: 'R2 waits');
          }

          server.noRoom = null;
          await a.syncNow(server);
          await b.round(server);
          final recognized = (await listOf(a)).rows['R2']!.bodyName;
          expect(recognized, isNot(r2));
          for (final list in await allLists()) {
            expect(list.rows['R2']!.bodyName, recognized);
          }
        },
      );

      test('[N1-15]: a body the server refused for the day waits, the delete of another record goes that day, and a '
          'round of the next day sends the body with nothing on the device changed', () async {
        seedUmas(a, ['R1', 'R2', 'R3']);
        await a.round(server);
        await b.round(server);
        final r2 = onServer().rows['R2']!.bodyName;
        clockAt(hour(9));
        server.limitTheDay(0);
        await recognizeAgain(a, 'R2');
        await deleteRecords(a, {'R1'});

        final waited = await a.round(server);
        expect((waited.end, waited.waitingForTheDay, waited.waitingForRoom), (SyncRoundEnd.done, 1, 0));
        expect(onServer().rows.keys.toSet(), {'R2', 'R3'}, reason: 'the delete of R1 went');
        expect(onServer().rows['R2']!.bodyName, r2, reason: 'R2 waits for the day');

        clockAt(hour(24 + 9));
        expect((await a.round(server)).end, SyncRoundEnd.done);
        final recognized = (await listOf(a)).rows['R2']!.bodyName;
        expect(recognized, isNot(r2));
        expect(onServer().rows['R2']!.bodyName, recognized);
      });

      test(
        'a memo of a record that waits for room waits with it, and a memo of another record goes ([N1-17] (C1))',
        () async {
          await a.setSyncOn(true);
          seedUmas(a, ['R1', 'R2']);
          a.seedColumn('memo', 'm1', title: 'Note');
          await a.round(server);
          await b.round(server);
          server.noRoom = 'account_limit';
          clockAt(hour(9));
          await recognizeAgain(a, 'R2');
          await writeMemo(a, 'R2', 'waits');
          await writeMemo(a, 'R1', 'goes');

          final waited = await a.round(server);
          expect((waited.end, waited.waitingForRoom), (SyncRoundEnd.done, 1), reason: 'R2');
          await b.round(server);
          for (final list in [onServer(), await listOf(b)]) {
            expect(list.cells[('memo/m1', 'R1')]?.value, jsonEncode('goes'));
            expect(list.cells[('memo/m1', 'R2')], isNull, reason: 'the memo waits with R2');
          }

          server.noRoom = null;
          await a.syncNow(server);
          await b.round(server);
          for (final list in await allLists()) {
            expect(list.cells[('memo/m1', 'R2')]?.value, jsonEncode('waits'));
          }
        },
      );
    });

    test("E-9: an inheritance resolution that read a record before the round puts the other device's body in its "
        'place, and writes it after, leaves the new body and the memo standing', () async {
      seedUmas(a, ['R1']);
      a.seedRecord('P', binding: own('P'), bodyWrittenAt: 1767225600200, parentOfTheOthers: true);
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'mine'}, writtenAt: {'R1': 1767225600400});
      expect((await a.round(server)).end, SyncRoundEnd.done);
      expect((await b.round(server)).end, SyncRoundEnd.done);
      clockAt(hour(9));
      await b.recognizeAgain('R1', (result) => result['fans'] = 8);
      expect((await b.round(server)).end, SyncRoundEnd.done);
      final theirs = (await listOf(b)).rows['R1']!.record.body;
      expect(theirs.time, hour(9));

      final container = await a.open();
      final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      expect(active.getBy(id: 'R1')!.metadata.recordId.parent1, isNull, reason: 'R1 is not linked yet');

      // A's round has read A and asks the server for B's body, where it is held; the resolution reads R1 meanwhile and
      // is held at its write of it.
      final entered = Completer<void>();
      final go = Completer<void>();
      server.beforeBodies = (names) async {
        server.beforeBodies = null;
        entered.complete();
        await go.future;
        return const {};
      };
      final round = a.round(server);
      await entered.future;
      final writes = HeldWriteFsBackend((a.charaDetail / 'active' / 'R1').filePath('record.json').path);
      final previous = fsBackend;
      fsBackend = writes;
      addTearDown(() => fsBackend = previous);
      final resolution = active.resolveAllInheritance(effects: inheritanceResolutionEffects(container));
      await waitUntil(() => writes.held, describe: "the resolution's write of R1 to be reached");
      // The round goes on to put B's body in place, which nothing signals it has reached: it is given a window in which
      // it must not finish, for the resolution has not written R1 yet.
      var finished = false;
      unawaited(round.whenComplete(() => finished = true));
      go.complete();
      await Future.any([round, Future<void>.delayed(const Duration(milliseconds: 200))]);
      expect(finished, isFalse, reason: 'the round waits for the record the resolution holds');
      writes.release();
      await resolution;
      expect(active.getBy(id: 'R1')!.metadata.recordId.parent1, 'P', reason: 'the resolution linked R1');
      expect(
        (await round).end,
        SyncRoundEnd.changedMeanwhile,
        reason: 'the round leaves R1, which the resolution changed',
      );

      await a.round(server);
      await b.round(server);
      for (final list in await allLists()) {
        final body = list.rows['R1']!.record.body;
        expect((body.content, body.time), (theirs.content, hour(9)), reason: "B's body stands");
      }
      expect(memosOnDisk(a), {'R1': 'mine'});
      expect(memosOnDisk(b), {'R1': 'mine'});
    });

    testWidgets('[N15-23]: a title the other device gave a rating storage, taken in while the column\'s settings are '
        'open, is the one a confirm keeps; no older title comes back', (tester) async {
      final presets = Hive.box(storageBoxNameOf(StorageBoxKey.columnSpec));
      // The settings render the app's own strings, which the field and its rows are laid out for.
      loadAppTranslations();
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await presets.clear();
        seed(a);
        await a.round(server);
        await b.round(server);
      });
      addTearDown(() => tester.runAsync(presets.clear));
      final container = (await tester.runAsync(() async {
        final container = await b.open();
        await container.read(charaDetailRecordRatingProvider('r1').future);
        await container.read(charaDetailRecordRatingStorageDataLoader.future);
        return container;
      }))!;
      final column = RatingColumnSpec(
        id: 'column',
        title: 'Score',
        parser: EvaluationValueParser(),
        predicate: IsInRangeRatingPredicate(),
        storageKey: 'r1',
      );
      container.read(currentColumnSpecsLoaderProvider.notifier).add(column);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: ColumnSpecDialog(spec: column)),
          ),
        ),
      );
      expect(find.widgetWithText(TextField, 'Score'), findsOneWidget);

      // A renames the storage; B takes it in with the settings open.
      await tester.runAsync(() async {
        await retitle(a, 'Points');
        await a.round(server);
        expect((await b.round(server)).end, SyncRoundEnd.done);
      });
      await tester.pump();
      expect(container.read(currentColumnSpecsLoaderProvider.notifier).getById('column')?.title, 'Points');
      expect(
        find.widgetWithText(TextField, 'Points'),
        findsOneWidget,
        reason: 'the field follows a title not typed in',
      );

      await tester.tap(find.byIcon(Symbols.check_circle_rounded));
      await tester.pump();
      expect(container.read(currentColumnSpecsLoaderProvider.notifier).getById('column')?.title, 'Points');
      await tester.runAsync(() async {
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.titles['rating/r1']?.value, 'Points');
        }
      });
    });

    testWidgets('[N15-23]: a storage the other device deleted, taken in while the settings of its column are open, '
        'keeps no title after a confirm that left the field as shown (3c ②′)', (tester) async {
      final presets = Hive.box(storageBoxNameOf(StorageBoxKey.columnSpec));
      loadAppTranslations();
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await presets.clear();
        seed(a);
        await a.round(server);
        await b.round(server);
      });
      addTearDown(() => tester.runAsync(presets.clear));
      final container = (await tester.runAsync(() async {
        final container = await b.open();
        await container.read(charaDetailRecordRatingProvider('r1').future);
        await container.read(charaDetailRecordRatingStorageDataLoader.future);
        return container;
      }))!;
      final column = RatingColumnSpec(
        id: 'column',
        title: 'Score',
        parser: EvaluationValueParser(),
        predicate: IsInRangeRatingPredicate(),
        storageKey: 'r1',
      );
      container.read(currentColumnSpecsLoaderProvider.notifier).add(column);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: ColumnSpecDialog(spec: column)),
          ),
        ),
      );

      // A deletes the storage in the storage view; B takes it in with the settings open. A title deleted gives the
      // columns no title to follow.
      await tester.runAsync(() async {
        a.close();
        expect((await a.deleteMetadata()).isComplete, isTrue);
        await a.round(server);
        expect((await b.round(server)).end, SyncRoundEnd.done);
      });
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Score'), findsOneWidget, reason: 'the field has nothing to follow');

      await tester.tap(find.byIcon(Symbols.check_circle_rounded));
      await tester.pump();
      await tester.runAsync(() async {
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.titles['rating/r1']?.value, isNull, reason: 'the title shown is not written over the delete');
        }
      });
    });

    test('rule 6 (R2-6 (a)): ratings and memos deleted in the storage view are none from the time of the delete, on '
        'both devices, over what the other device wrote before it and not over what it wrote after', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn(
        'rating',
        'r1',
        title: 'Score',
        titleWrittenAt: hour(8),
        data: {'R1': 4.0, 'R2': 1.0},
        writtenAt: {'R1': hour(8), 'R2': hour(8)},
      );
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'old'}, writtenAt: {'R1': hour(8)});
      await a.round(server);
      await b.round(server);
      // B writes before A's delete, and A has not taken it in when it deletes.
      clockAt(hour(9));
      await rate(b, 'R1', 5);
      await retitle(b, 'Points');
      await writeMemo(b, 'R1', 'X');
      await b.round(server);
      clockAt(hour(10));
      a.close();
      final report = await a.deleteMetadata();
      expect(
        Directory(a.info.charaDetailSyncDir.path).existsSync(),
        isFalse,
        reason: 'the group delete takes the base',
      );
      expect(
        report.cleared.map((subject) => subject.path),
        containsAll([
          a.info.charaDetailRatingDir.filePath('r1.json').path,
          a.info.charaDetailMemoDir.filePath('m1.json').path,
        ]),
        reason: 'their values went, and the files stay',
      );
      expect(report.isComplete, isTrue);
      // B writes after it.
      clockAt(hour(11));
      await rate(b, 'R2', 3);

      await a.round(server);
      await b.round(server);
      await a.round(server);
      for (final list in await allLists()) {
        expect(list.cells[('rating/r1', 'R1')], SyncValue<String?>(null, hour(10)));
        expect(list.cells[('memo/m1', 'R1')], SyncValue<String?>(null, hour(10)));
        expect(list.titles['rating/r1'], SyncValue<String?>(null, hour(10)));
        expect(list.titles['memo/m1'], SyncValue<String?>(null, hour(10)));
        expect(list.cells[('rating/r1', 'R2')], SyncValue<String?>('3.0', hour(11)));
      }
      for (final (name, device) in [('a', a), ('b', b)]) {
        final rating = RatingDataMapper.fromJson(
          File(device.info.charaDetailRatingDir.filePath('r1.json').path).readAsStringSync(),
        );
        expect(rating.titleCleared, isTrue, reason: name);
        expect(rating.data, {'R2': 3.0}, reason: name);
      }
    });

    group('the quarantine shelf', () {
      // A record whose record.json cannot be read is moved onto the quarantine shelf by its store's scan; sync reads
      // the move as no delete ([R7-3], [N15-20], [N15-26]), and the storage view's deletes as [N15-22] tells them.

      /// R1 and R2 on [a], with a memo of R1 and the pair R1+R2 dismissed, sent and taken in by [b].
      Future<void> seedSynced() async {
        seedUmas(a, ['R1', 'R2']);
        a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'kept'}, writtenAt: {'R1': hour(8)});
        a.seedDismissed([('R1', 'R2')]);
        await a.round(server);
        await b.round(server);
      }

      Future<List<String>> shelved(SyncTestDevice device) async => [
        for (final record in (await readQuarantineLedger(device.shelf)).kept) record.id,
      ];

      test('§2.7 check 1: a record whose record.json cannot be read goes onto the quarantine shelf, and stays on the '
          'other device and the server with its memo and its pair', () async {
        await seedSynced();
        final before = _describe(onServer());
        await a.breakRecord('R1');
        expect(await shelved(a), ['R1']);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expect(_describe(onServer()), before);
        expect(_describe(await listOf(b)), before);
        expect(await shelved(a), ['R1']);
      });

      test(
        '[N15-20]: a record on the quarantine shelf is kept as the server holds it after the app starts again',
        () async {
          await seedSynced();
          final before = _describe(onServer());
          await a.breakRecord('R1');
          await a.round(server);
          a.close();
          await a.open();

          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(_describe(onServer()), before);
          expect(_describe(await listOf(b)), before);
        },
      );

      test('[N15-20]: a quarantine shelf whose list of deleted records cannot be read is read as one that holds a '
          'record: what the device holds no record of stays on the server', () async {
        await seedSynced();
        final before = _describe(onServer());
        await a.breakRecord('R1');
        File(a.shelf.filePath(quarantineUserDeletedName).path).writeAsStringSync('["R9", cut short');

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(_describe(onServer()), before);
      });

      test(
        '[N15-26]: a record this device merged into another and has not sent stays on the server and the other '
        'device, where the record it went into goes onto the quarantine shelf; that one stays as the server holds it',
        () async {
          await seedSynced();
          final before = _describe(onServer());
          clockAt(hour(9));
          await a.merge('R1', 'R2', keep: 'R2');
          await a.breakRecord('R1');

          final outcome = await a.round(server);
          expect(outcome.end, SyncRoundEnd.done);
          expect(outcome.withheld, 1, reason: 'R2, which the shelf may hold'); // withheld
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(_describe(onServer()), before);
          expect(_describe(await listOf(b)), before);
        },
      );

      test('[N15-26]: a record put back from the quarantine shelf is merged by the next round as one that never went '
          'there: what the other device did to it meanwhile reaches this device', () async {
        await seedSynced();
        final bytes = await a.breakRecord('R1');
        await a.round(server);
        clockAt(hour(9));
        final container = await b.open();
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive(['R1'], ArchiveImageOption.none, effects: archiveEffects(container));
        await b.round(server);
        await a.repairQuarantined('R1', bytes);
        expect(await shelved(a), isEmpty);

        expect((await a.round(server)).splitOff, 0);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        final lists = await allLists();
        expect({for (final list in lists) _describe(list).join('\n')}, hasLength(1));
        expect(lists.first.rows.keys.toSet(), {'R1', 'R2'});
        expect(lists.first.rows['R1']!.record.stage.value, ArchiveImageOption.none);
      });

      test('[N15-26]: a record the other device deleted while it was on the quarantine shelf goes from this device '
          'once put back', () async {
        await seedSynced();
        final bytes = await a.breakRecord('R1');
        await a.round(server);
        await deleteRecords(b, {'R1'});
        await b.round(server);
        await a.repairQuarantined('R1', bytes);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R2'});
          expect(list.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty);
          expect(list.dismissed, isEmpty);
        }
      });

      test('[N15-26]: a record the other device deleted while it was on the quarantine shelf goes from this device '
          'once put back, where this device ran a round after the delete reached the server', () async {
        await seedSynced();
        final bytes = await a.breakRecord('R1');
        await a.round(server);
        await deleteRecords(b, {'R1'});
        await b.round(server);
        expect((await a.round(server)).end, SyncRoundEnd.done, reason: 'R1 still on the shelf');
        await a.repairQuarantined('R1', bytes);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R2'});
          expect(list.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty);
          expect(list.dismissed, isEmpty);
        }
      });

      test(
        '[N15-22] (d), [R4-1]: a record deleted from the quarantine shelf in the storage view takes its memo and its '
        'pair with it from this device',
        () async {
          await seedSynced();
          await a.breakRecord('R1');
          await a.deleteInStorageView(StorageGroupId.quarantine, StorageDeletePathsRequest([a.shelf / 'R1']));

          expect(await shelved(a), isEmpty);
          final local = await listOf(a);
          expect(local.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty);
          expect(local.dismissed, isEmpty);
        },
      );

      test('[N15-22] (d): a record deleted from the quarantine shelf in the storage view is deleted on the other '
          'device by the next round, while another stays on the shelf', () async {
        seedUmas(a, ['R1', 'R2', 'R3']);
        a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'kept', 'R3': 'too'}, writtenAt: {'R1': hour(8)});
        a.seedDismissed([('R1', 'R2')]);
        await a.round(server);
        await b.round(server);
        await a.breakRecord('R1');
        await a.breakRecord('R3');
        await a.round(server);
        await b.round(server);
        expect((await listOf(b)).rows.keys.toSet(), {'R1', 'R2', 'R3'}, reason: 'kept while on the shelf');

        final report = await a.deleteInStorageView(
          StorageGroupId.quarantine,
          StorageDeletePathsRequest([a.shelf / 'R1']),
        );
        expect(report.isComplete, isTrue);
        expect(await shelved(a), ['R3']);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        for (final list in [onServer(), await listOf(b)]) {
          expect(list.rows.keys.toSet(), {'R2', 'R3'});
          expect(list.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty);
          expect(list.cells[('memo/m1', 'R3')]?.value, isNotNull, reason: 'R3 stays on the shelf');
          expect(list.dismissed, isEmpty);
        }
      });

      test('[N15-22] (d): a record deleted from the quarantine shelf whose id a store holds again, taken from a zip, '
          'keeps the memo of the record the store holds', () async {
        await seedSynced();
        final zip = await a.exportZip('R1');
        await a.breakRecord('R1');
        await a.importZip(zip);
        await a.deleteInStorageView(StorageGroupId.quarantine, StorageDeletePathsRequest([a.shelf / 'R1']));

        expect((await listOf(a)).cells[('memo/m1', 'R1')]?.value, isNotNull);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(onServer().rows.keys.toSet(), {'R1', 'R2'});
      });

      test('[N15-22] (b): a record whose record.json alone is deleted in the storage view goes onto the quarantine '
          'shelf, and is not sent as a delete', () async {
        await seedSynced();
        final before = _describe(onServer());
        final report = await a.deleteInStorageView(
          StorageGroupId.activeRecords,
          StorageDeletePathsRequest([(a.charaDetail / 'active' / 'R1').filePath('record.json')]),
        );
        expect(report.isComplete, isTrue);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(await shelved(a), ['R1']);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expect(_describe(onServer()), before);
        expect(_describe(await listOf(b)), before);
      });

      List<String> onShelf(SyncTestDevice device) => [
        for (final entry in Directory(device.shelf.path).listSync())
          if (entry is Directory) entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
      ]..sort();

      test('[R7-3]: a record on the quarantine shelf whose note alone is deleted from outside the app, on a shelf that '
          'holds nothing else, stays on the other device and the server', () async {
        await seedSynced();
        final before = _describe(onServer());
        await a.breakRecord('R1');
        // The storage view refuses this delete, so the note goes from outside the app, while it is closed.
        a.close();
        File((a.shelf / 'R1').filePath(quarantineOriginName).path).deleteSync();
        await a.open();
        expect(onShelf(a), ['R1']);
        expect(await shelved(a), isEmpty);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expect(_describe(onServer()), before);
        expect(_describe(await listOf(b)), before);
      });

      for (final webLike in [false, true]) {
        final on = webLike ? ' (a backend that cannot rename a file over another)' : '';
        void useBackend(FsBackend Function(FsBackend original) backend) {
          final original = fsBackend;
          fsBackend = backend(original);
          addTearDown(() => fsBackend = original);
        }

        // The order of a delete is the storage view's, whatever the backend: one backend.
        if (!webLike) {
          test('[D-65]: a delete of the whole quarantine shelf deletes each record\'s note with its directory, and the '
              'record it names goes with its memo and its pair', () async {
            await seedSynced();
            await a.breakRecord('R1');
            final report = await a.deleteInStorageView(StorageGroupId.quarantine, StorageDeletePathsRequest([a.shelf]));
            expect(report.isComplete, isTrue);
            expect(Directory((a.shelf / 'R1').path).existsSync(), isFalse);
            final local = await listOf(a);
            expect(local.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty, reason: 'its memo goes with it');
            expect(local.dismissed, isEmpty, reason: 'and its pair');
          });
        }

        test('[D-65]: the note of a record on the quarantine shelf is not deleted alone in the storage view, and the '
            'record it names still goes with its memo and its pair when its directory is deleted$on', () async {
          if (webLike) useBackend(WebLikeFsBackend.new);
          await seedSynced();
          await a.breakRecord('R1');
          final note = (a.shelf / 'R1').filePath(quarantineOriginName);

          final report = await a.deleteInStorageView(StorageGroupId.quarantine, StorageDeletePathsRequest([note]));
          expect(report.deleted, isEmpty);
          expect(report.retained.map((r) => (r.subject, r.reason)), [
            (StorageDeletePathSubject(note.path), StorageDeleteRetentionReason.identifiesShelfRecord),
          ]);
          expect(File(note.path).existsSync(), isTrue);
          expect(await shelved(a), ['R1']);
          final kept = await listOf(a);
          expect(kept.cells[('memo/m1', 'R1')]?.value, isNotNull);
          expect(kept.dismissed, {('R1', 'R2')});

          expect(
            (await a.deleteInStorageView(
              StorageGroupId.quarantine,
              StorageDeletePathsRequest([a.shelf / 'R1']),
            )).isComplete,
            isTrue,
          );
          expect(onShelf(a), isEmpty);
          final local = await listOf(a);
          expect(local.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty);
          expect(local.dismissed, isEmpty);
        });

        test('[D-65]: a directory on the quarantine shelf whose delete another file stops keeps its note, and is '
            'deleted as its record once the file is let go$on', () async {
          await seedSynced();
          await a.breakRecord('R1');
          final held = (a.shelf / 'R1').filePath('record.json').path;
          var holding = true;
          bool refuse(String path) => holding && path == held;
          useBackend(
            (original) => webLike ? ObstructedFsBackend(original, refuse: refuse) : _RefusingIoFsBackend(refuse),
          );

          final report = await a.deleteInStorageView(
            StorageGroupId.quarantine,
            StorageDeletePathsRequest([a.shelf / 'R1']),
          );
          expect(report.failed.map((f) => f.subject), [StorageDeletePathSubject(held)]);
          expect(File((a.shelf / 'R1').filePath(quarantineOriginName).path).existsSync(), isTrue);
          expect(await shelved(a), ['R1']);
          expect((await listOf(a)).dismissed, {('R1', 'R2')});

          holding = false;
          await a.deleteInStorageView(StorageGroupId.quarantine, StorageDeletePathsRequest([a.shelf / 'R1']));
          expect(onShelf(a), isEmpty);
          final local = await listOf(a);
          expect(local.cells.keys.where((cell) => cell.$2 == 'R1'), isEmpty);
          expect(local.dismissed, isEmpty);
        });
      }

      test(
        '[R7-3]: a record whose write the recovery gives up on goes onto the quarantine shelf with no note, and on a '
        'shelf that holds nothing else stays on the other device and the server',
        () async {
          await seedSynced();
          final before = _describe(onServer());
          a.close();
          // A web write of R1 cut short after it parked the version it replaces: the slot holds that version and a
          // fragment of the new one under a torn manifest, and no store holds R1.
          final slot =
              a.charaDetail /
              WebRecordWriteTransaction.transactionRootName /
              'v1' /
              base64Url.encode(utf8.encode('publish-active-record:R1')).replaceAll('=', '');
          await slot.create(recursive: true);
          await slot.filePath('manifest.json').writeAsString('{"version":2,"owner":"umacapture.web-r');
          Directory((a.charaDetail / 'active' / 'R1').path).renameSync((slot / 'superseded').path);
          await (slot / 'desired').filePath('record.json').writeAsString('{"metadata": {"record_id": {"self": "R1"}}}');

          await recoverWebRecordWriteTransactionsUnlocked(a.charaDetail);
          expect(onShelf(a), ['R1', 'R1_1']);
          expect(await shelved(a), isEmpty);

          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(_describe(onServer()), before);
          expect(_describe(await listOf(b)), before);
        },
      );

      test('[N15-26]: a record the other device merged into one on the quarantine shelf stays on this device with its '
          'images, and the record of the merge takes them once the one on the shelf is deleted', () async {
        for (final device in [a, b]) {
          for (final (i, id) in ['R1', 'R2', 'R3'].indexed) {
            seedShot(device, id, i + 1);
          }
        }
        await a.round(server);
        await b.round(server);
        await a.deleteInStorageView(
          StorageGroupId.activeRecords,
          StorageDeletePathsRequest([(a.charaDetail / 'active' / 'R1').filePath('record.json')]),
        );
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(await shelved(a), ['R1']);
        await b.merge('R1', 'R3', keep: 'R3');
        await b.round(server);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R3'), shot(3), reason: 'R3 went into R1, which A cannot read');

        await a.deleteInStorageView(StorageGroupId.quarantine, StorageDeletePathsRequest([a.shelf / 'R1']));
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R1'), shot(3), reason: 'R1 shows the body read from capture 3');
        expect(holds(a, 'R3'), isFalse);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R2'});
          expect(list.rows['R1']!.record.body.binding, bindingOfShot(3));
        }
      });

      // The record on the shelf is no record's id on the server: it reaches the server's R1 only as an id R1 absorbed.
      test('[N15-26]: a record the other device merged on the quarantine shelf into one of another id leaves this '
          'device\'s record of that id with its images', () async {
        for (final device in [a, b]) {
          for (final (i, id) in ['R1', 'R2', 'R3'].indexed) {
            seedShot(device, id, i + 1);
          }
        }
        await a.round(server);
        await b.round(server);
        await a.deleteInStorageView(
          StorageGroupId.activeRecords,
          StorageDeletePathsRequest([(a.charaDetail / 'active' / 'R3').filePath('record.json')]),
        );
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(await shelved(a), ['R3']);
        await b.merge('R1', 'R3', keep: 'R3');
        await b.round(server);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R1'), shot(1), reason: 'R1 absorbed R3, which A cannot read');
        expect(onServer().rows.keys.toSet(), {'R1', 'R2'});
      });

      test('[N15-26] (D-80): a record the device holds and reads, which absorbed one on its quarantine shelf on the '
          'other device, is no removal the shelf withholds', () async {
        for (final device in [a, b]) {
          for (final (i, id) in ['R1', 'R2', 'R3'].indexed) {
            seedShot(device, id, i + 1);
          }
        }
        await a.round(server);
        await b.round(server);
        await a.deleteInStorageView(
          StorageGroupId.activeRecords,
          StorageDeletePathsRequest([(a.charaDetail / 'active' / 'R3').filePath('record.json')]),
        );
        expect((await a.round(server)).end, SyncRoundEnd.done);
        await b.merge('R1', 'R3', keep: 'R3');
        await b.round(server);

        for (final round in [await a.round(server), await a.round(server)]) {
          expect((round.end, round.withheld), (SyncRoundEnd.done, 0), reason: 'A holds R1, and deleted none');
        }
        expect((await listOf(a)).rows.keys.toSet(), {'R1', 'R2'});
      });
    });

    test(
      'a replacement whose answer was lost, of a record the server holds neither as sent nor as the base, is kept and '
      'told',
      () async {
        seedUmas(a, ['R1', 'R2']);
        await a.round(server);
        await b.round(server);
        a.close();
        a.seedRecord('R4', binding: own('R4'), bodyWrittenAt: 1767225600200, fans: 2000);
        server.loseAnswer = true;
        expect((await a.round(server)).end, SyncRoundEnd.answerLost);
        // B takes R4 in and deletes it before A hears whether its replacement was made.
        await b.round(server);
        await deleteRecords(b, {'R4'});
        await b.round(server);
        expect(onServer().rows.keys.toSet(), {'R1', 'R2'});

        final outcome = await a.round(server);
        expect((outcome.end, outcome.restored, outcome.splitOff, outcome.added), (SyncRoundEnd.done, 0, 0, 1));
        await b.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R2', 'R4'}, reason: 'of R4 the base holds nothing: it is kept');
        }
      },
    );

    test('[R7-5]: a round that reads the base again after a lost answer and then stops at a memo over the limit leaves '
        'what it could not confirm to the round that runs, which tells it as added up, once', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      a.close();
      a.seedRecord('R4', binding: own('R4'), bodyWrittenAt: 1767225600200, fans: 2000);
      server.loseAnswer = true;
      expect((await a.round(server)).end, SyncRoundEnd.answerLost);
      // B takes R4 in and deletes it before A hears whether its replacement was made.
      await b.round(server);
      await deleteRecords(b, {'R4'});
      await b.round(server);

      await writeMemo(a, 'R1', 'x' * (syncMemoLimit + 1));
      expect((await a.round(server)).end, SyncRoundEnd.heldByLongMemos);
      await writeMemo(a, 'R1', 'cut');
      final ran = await a.round(server);
      expect((ran.end, ran.added), (SyncRoundEnd.done, 1), reason: 'of R4 the base holds nothing: it is added up');
      expect(onServer().rows.keys.toSet(), {'R1', 'R2', 'R4'});
      expect((await a.round(server)).added, 0);
    });

    // A round the app stops part way ([N15-03]): every write before the stop is on the disk and none after it, and the
    // round after a restart reads what the stop left as the whole round would have left it.
    for (final webLike in [false, true]) {
      final backend = webLike ? ' (a backend that cannot rename a file over another)' : '';
      void onBackend() {
        if (!webLike) return;
        final original = fsBackend;
        fsBackend = WebLikeFsBackend(original);
        addTearDown(() => fsBackend = original);
      }

      test('records merged on the other device go in as one: stopped between the record that absorbed and the one it '
          'absorbed, a pair the device took out stays out$backend', () async {
        onBackend();
        seedUmas(a, ['R1', 'R2', 'R3'], captured: {'R1': 2});
        a.seedDismissed([('R1', 'R3')]);
        await a.round(server);
        await b.round(server);
        await b.deleteDismissedFile();
        await a.merge('R2', 'R1', keep: 'R2');
        await a.round(server);

        final active = b.charaDetail / 'active';
        await stoppedRound(
          b,
          server,
          SyncStopFsBackend(fsBackend, markOf: SyncStopFsBackend.recordsOf({'R1', 'R2'}), stopAt: 2),
          whileHeld: () async {
            final absorbed = File((active / 'R2').filePath(mergedIdsFileName).path).existsSync();
            final gone = !Directory((active / 'R1').path).existsSync();
            expect(absorbed != gone, isTrue, reason: 'one of the two writes is in, and the other not');
          },
        );
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R2', 'R3'});
          expect(made(list.rows['R2']!.record).$1, 'R1');
          expect(list.dismissed, isEmpty, reason: 'B took R1+R3 out, and R1 is R2 in the result');
        }
      });

      test('a pair moved onto a merged record is in place before the record: stopped once the record is, the pair '
          'stays$backend', () async {
        onBackend();
        seedUmas(a, ['R1', 'R2', 'R3']);
        a.seedDismissed([('R2', 'R3')]);
        await a.round(server);
        await b.round(server);
        await deleteRecords(b, {'R2'});
        // A captures R4 and R5 while it is closed, and merges R2 into R1.
        a.close();
        a.seedRecord('R4', binding: own('R4'), bodyWrittenAt: 1767225600200, fans: 2000);
        a.seedRecord('R5', binding: own('R5'), bodyWrittenAt: 1767225600201, fans: 2001);
        await a.merge('R1', 'R2', keep: 'R1');
        await a.round(server);

        await stoppedRound(
          b,
          server,
          SyncStopFsBackend(fsBackend, markOf: SyncStopFsBackend.recordsOf({'R1', 'R4', 'R5'}), stopAt: 2),
        );
        expect(
          File((b.charaDetail / 'active' / 'R1').filePath(mergedIdsFileName).path).existsSync(),
          isTrue,
          reason: 'the round stopped once R1 absorbed R2',
        );
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R3', 'R4', 'R5'});
          expect(made(list.rows['R1']!.record).$1, 'R2');
          expect(list.dismissed, {('R1', 'R3')}, reason: 'R2+R3 is R1+R3, and B said nothing of it');
        }
      });

      test('a pair of two records a round takes in is not read as taken out when the round stops between '
          'them$backend', () async {
        onBackend();
        seedUmas(a, ['R1']);
        await a.round(server);
        await b.round(server);
        a.close();
        a.seedRecord('R4', binding: own('R4'), bodyWrittenAt: 1767225600200, fans: 2000);
        a.seedRecord('R5', binding: own('R5'), bodyWrittenAt: 1767225600201, fans: 2001);
        await a.dismiss('R4', 'R5');
        await a.round(server);

        await stoppedRound(
          b,
          server,
          SyncStopFsBackend(fsBackend, markOf: SyncStopFsBackend.recordsOf({'R4', 'R5'}), stopAt: 2),
        );
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R4', 'R5'});
          expect(list.dismissed, {('R4', 'R5')});
        }
      });

      test(
        'a pair of a record a round splits off goes in after the record: stopped before it, and the record not split '
        'off by the next round, the pair the device took out stays$backend',
        () async {
          onBackend();
          seedUmas(a, ['R1', 'R2', 'R3', 'R4']);
          await a.round(server);
          await b.round(server);
          clockAt(hour(9));
          await a.merge('R1', 'R2', keep: 'R2');
          await b.merge('R1', 'R3', keep: 'R3');
          await b.dismiss('R1', 'R4');
          await a.round(server);

          final active = b.charaDetail / 'active';
          Set<String> held() => {
            for (final e in Directory(active.path).listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
          };
          final before = held();
          // The first write into any record directory: the round places the record split off before any other.
          await stoppedRound(
            b,
            server,
            SyncStopFsBackend(
              fsBackend,
              markOf: (path) =>
                  RegExp(r'[/\\]chara_detail[/\\](?:active|archive)[/\\]').hasMatch(path) ? 'record' : null,
            ),
            whileHeld: () async => expect(held(), before, reason: 'no record is placed yet'),
          );
          // Before B's next round A deletes its R1: B's R1 now stands against a record removed, and is not split off.
          await deleteRecords(a, {'R1'});
          await a.round(server);
          final next = await b.round(server);
          expect((next.end, next.splitOff), (SyncRoundEnd.done, 0));
          await a.round(server);
          for (final list in await allLists()) {
            expect(list.rows.keys.toSet(), {'R1', 'R4'});
            expect(made(list.rows['R1']!.record).$1, 'R3');
            expect(list.dismissed, {('R1', 'R4')}, reason: 'B took R1+R4 out, and nothing split B\'s R1 off');
          }
        },
      );

      test('a pair the base holds of a record split off stays: stopped once the record split off is in place, the next '
          'round, which splits the device\'s record off to it again, reads the two as one record$backend', () async {
        onBackend();
        seedUmas(a, ['R1', 'R2', 'R3']);
        a.seedDismissed([('R1', 'R2')]);
        await a.round(server);
        await b.round(server);
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R1');
        await a.merge('R1', 'R3', keep: 'R1');
        await b.merge('R1', 'R2', keep: 'R1');
        await b.round(server);

        final active = a.charaDetail / 'active';
        bool splitPlaced() => Directory(active.path).listSync().any(
          (e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty).startsWith('R1$recordSyncSplitSeparator'),
        );
        // The first write that follows the writes into the record split off: the round places that record first.
        var placing = false;
        String? markOf(String path) {
          final id = RegExp(r'[/\\]chara_detail[/\\](?:active|archive)[/\\]([^/\\]+)').firstMatch(path)?.group(1);
          if (id != null && id.startsWith('R1$recordSyncSplitSeparator')) {
            placing = true;
            return null;
          }
          return placing ? path : null;
        }

        await stoppedRound(
          a,
          server,
          SyncStopFsBackend(fsBackend, markOf: markOf),
          whileHeld: () async => expect(splitPlaced(), isTrue, reason: 'the record split off is in place'),
        );
        await a.round(server);
        await b.round(server);
        await a.round(server);
        final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', splitId});
          expect(made(list.rows[splitId]!.record).$1, 'R2+R3');
          expect(
            list.dismissed,
            {('R1', splitId)},
            reason: 'R1+R2 of the base is R1 and the record split off, which absorbed R2: no user took it out',
          );
        }
      });

      test('S7: a record split off takes its memo and pairs in the step that puts the server\'s record in the id it is '
          'split off: refused at a later record, the next round, which no longer splits it off, leaves them '
          'there$backend', () async {
        seedUmas(a, ['R1', 'R2', 'R3', 'R9', 'R95']);
        a.seedColumn('memo', 'm1', title: 'Note');
        await a.round(server);
        await b.round(server);
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R2');
        await b.merge('R1', 'R3', keep: 'R3');
        await writeMemo(b, 'R1', 'M');
        await b.dismiss('R1', 'R9');
        // A re-recognition is the desktop app's, made before the backend of this test's rounds is put in.
        await a.recognizeAgain('R9', (result) => result['fans'] = 8);
        onBackend();
        await a.round(server);

        // B's round has read B and asks the server for the bodies; B merges into R9 meanwhile, so the round puts in
        // place the records split off and of R1, and stops at R9.
        server.beforeBodies = (names) async {
          server.beforeBodies = null;
          clockAt(hour(10));
          await b.merge('R9', 'R95', keep: 'R9');
          return const {};
        };
        expect((await b.round(server)).end, SyncRoundEnd.changedMeanwhile, reason: 'the round leaves R9 to the next');
        final splitId = (await listOf(b)).rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        expect(made((await listOf(b)).rows['R1']!.record).$1, 'R2', reason: 'the server\'s R1 is in place');

        expect((await b.round(server)).splitOff, 0, reason: 'B\'s R1 is the server\'s now: nothing is split off');
        await a.round(server);
        await b.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', splitId, 'R9'});
          expect(made(list.rows[splitId]!.record).$1, 'R3');
          expect(list.cells[('memo/m1', splitId)], SyncValue<String?>(jsonEncode('M'), hour(9)));
          expect(list.cells[('memo/m1', 'R1')], isNull, reason: 'B wrote M on its record, which is split off');
          expect(list.dismissed, {(splitId, 'R9')});
        }
      });

      // G259: the round is stopped at each write that puts in place the record split off of R1, the server's record of
      // R1, and the memo and the dismissed pairs of the two — at the write of the kind named last that follows writes
      // of each kind before it, in order: a write into the record split off (`split`) or into R1, of the memo storage,
      // of the dismissed pairs, or `any` write at all. Reopened, it goes on to the end the round not stopped comes to.
      // Stopped before the server's record of R1 is in place, the pairs may hold one more: R1 then holds the base's
      // pairs, and the next round reads R1+R4, which B took out, as the record split off's again.
      for (final (stop, after, pairsWhole) in [
        ('not stopped', null, true),
        ('stopped once the record split off is in place, before its memo', ['split', 'memo'], true),
        (
          'stopped once the memo of the record split off is in place, before its pairs',
          ['split', 'memo', 'pairs'],
          true,
        ),
        (
          'stopped before the server\'s record of R1 goes in place, the pairs keeping the ones dismissed',
          ['split', 'memo', 'pairs', 'any'],
          false,
        ),
        ('stopped by a write of the memo failing once the server\'s record of R1 is in place', ['R1', 'memo'], true),
        ('stopped once the memo of R1 is in place, before its pairs', ['R1', 'memo', 'pairs'], true),
        ('stopped once every step of R1 is in place', ['R1', 'memo', 'pairs', 'any'], true),
      ]) {
        test('G259: a record split off takes the memo and pairs the device wrote on it, and the id it is split off the '
            'server\'s, $stop$backend', () async {
          onBackend();
          // The memo storage written in the app's isolate, where the backend of the test reaches it.
          b.beforeMetadataWrite = (_) async {};
          seedUmas(a, ['R1', 'R2', 'R3', 'R4', 'R5']);
          a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'Base'}, writtenAt: {'R1': hour(8)});
          a.seedDismissed([('R1', 'R4')]);
          await a.round(server);
          await b.round(server);
          clockAt(hour(9));
          await a.merge('R1', 'R2', keep: 'R2');
          await writeMemo(a, 'R1', 'A');
          await a.dismiss('R1', 'R5');
          await a.round(server);
          // B writes after A: of the two memos of R1, B's would stand, were the two one record.
          clockAt(hour(10));
          await b.merge('R1', 'R3', keep: 'R3');
          await writeMemo(b, 'R1', 'M');
          await b.deleteDismissedFile();
          await b.dismiss('R1', 'R5');

          if (after != null) {
            var reached = 0;
            String? markOf(String path) {
              final id = RegExp(r'[/\\]chara_detail[/\\](?:active|archive)[/\\]([^/\\]+)').firstMatch(path)?.group(1);
              final kind = id != null
                  ? (id.startsWith('R1$recordSyncSplitSeparator') ? 'split' : id)
                  : RegExp(r'[/\\]memo[/\\]m1\.json$').hasMatch(path)
                  ? 'memo'
                  : RegExp(r'enhancement_dismissed\.json$').hasMatch(path)
                  ? 'pairs'
                  : SyncStopFsBackend.baseOf(path);
              if (reached == after.length) return null;
              if (after[reached] == 'any' || after[reached] == kind) reached++;
              return reached == after.length ? path : null;
            }

            await stoppedRound(b, server, SyncStopFsBackend(fsBackend, markOf: markOf));
          }
          await b.round(server);
          await a.round(server);
          await b.round(server);
          final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
          for (final list in await allLists()) {
            expect(list.rows.keys.toSet(), {'R1', splitId, 'R4', 'R5'});
            expect(made(list.rows[splitId]!.record).$1, 'R3');
            expect(
              {
                for (final MapEntry(:key, :value) in list.cells.entries)
                  if (key.$1 == 'memo/m1') key.$2: value,
              },
              {
                'R1': SyncValue<String?>(jsonEncode('A'), hour(9)),
                splitId: SyncValue<String?>(jsonEncode('M'), hour(10)),
              },
              reason: 'B wrote M on its record, which is split off; A wrote A on its R1',
            );
            if (pairsWhole) {
              expect(list.dismissed, {('R1', 'R4'), ('R1', 'R5'), (splitId, 'R5')});
            } else {
              expect(list.dismissed, contains(('R1', 'R4')), reason: 'the pair A dismissed on its R1 stays');
            }
          }
        });
      }

      test('E-10: stopped between the records it put in place and the base, the device holds them whole, and the next '
          'round goes on from there$backend', () async {
        onBackend();
        seedUmas(a, ['R1', 'R2', 'R3']);
        a.seedColumn('rating', 'r1', title: 'Score', data: {'R1': 1.0}, writtenAt: {'R1': hour(8)});
        a.seedColumn('memo', 'm1', title: 'Note');
        a.seedDismissed([('R1', 'R3')]);
        await a.round(server);
        await b.round(server);
        clockAt(hour(9));
        await rate(a, 'R1', 5);
        await writeMemo(a, 'R1', 'X');
        await deleteRecords(a, {'R2'});
        await a.deleteDismissedFile();
        await a.round(server);
        final base = File(syncBaseFile(b.info).path).readAsBytesSync();

        // Of the records and the base, the round is stopped at whichever it writes second.
        await stoppedRound(
          b,
          server,
          SyncStopFsBackend(
            fsBackend,
            markOf: (path) => SyncStopFsBackend.baseOf(path) ?? SyncStopFsBackend.recordsOf({'R1', 'R2'})(path),
            stopAt: 2,
          ),
        );
        expect(File(syncBaseFile(b.info).path).readAsBytesSync(), base, reason: 'the base is where the round found it');
        final held = await b.read();
        expect(held.unreadable, isEmpty);
        expect(held.list.rows.keys.toSet(), {'R1', 'R3'});
        expect(held.list.cells[('rating/r1', 'R1')], SyncValue<String?>('5.0', hour(9)));
        expect(held.list.cells[('memo/m1', 'R1')], SyncValue<String?>(jsonEncode('X'), hour(9)));

        expect((await b.round(server)).end, SyncRoundEnd.done);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R3'}, reason: 'R2 deleted on A stays deleted');
          expect(list.cells[('rating/r1', 'R1')], SyncValue<String?>('5.0', hour(9)));
          expect(list.cells[('memo/m1', 'R1')], SyncValue<String?>(jsonEncode('X'), hour(9)));
          expect(list.dismissed, isEmpty, reason: 'A took R1+R3 out');
        }
      });
    }

    // [R4-8] 5: a record a round puts a body on that is not the one the device held keeps the images of its own the
    // body's binding names, lets go of the others, and takes an image it then holds none of from any record of the
    // device whose binding names it — all in the one publication. Images are compared byte for byte.
    for (final webLike in [false, true]) {
      final backend = webLike ? ' (a backend that cannot rename a file over another)' : '';
      void onBackend() {
        if (!webLike) return;
        final original = fsBackend;
        fsBackend = WebLikeFsBackend(original);
        addTearDown(() => fsBackend = original);
      }

      /// Both devices holding the records [ids], the i-th of them read from capture i + 1, and agreeing on them.
      Future<void> seedShots(List<String> ids) async {
        for (final device in [a, b]) {
          for (final (i, id) in ids.indexed) {
            seedShot(device, id, i + 1);
          }
        }
        await a.round(server);
        await b.round(server);
      }

      test('T2b-3b §4.4: a record that took the body of the one it absorbed on the other device takes that one\'s '
          'images, lets go of its own, and the one absorbed goes; a record that kept its own body keeps its '
          'images$backend', () async {
        onBackend();
        await seedShots(['R1', 'R2', 'R3', 'R4']);
        await b.merge('R1', 'R2', keep: 'R2');
        await b.merge('R3', 'R4', keep: 'R3');
        await b.round(server);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R1'), shot(2), reason: 'R1 shows the body read from capture 2');
        expect(imagesOf(a, 'R3'), shot(3), reason: 'R3 kept its own body');
        expect((holds(a, 'R2'), holds(a, 'R4')), (false, false));
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1', 'R3'});
          expect(list.rows['R1']!.record.body.binding, bindingOfShot(2));
        }
        expect(imagesOf(b, 'R1'), shot(2), reason: 'as the merge on B left it');
      });

      test('check 6: a body read again from the record\'s own images keeps them; one read from images no directory on '
          'the device holds leaves the record none of its images, and none of the old ones$backend', () async {
        await seedShots(['R1', 'R2']);
        final read = (await listOf(a)).rows['R1']!.record.body.content;
        // A re-recognition is the desktop app's, made before the backend of this test's rounds is put in.
        await b.recognizeAgain('R1', (result) => result['fans'] = 7);
        onBackend();
        // B captures R3, and merges it into R2 keeping R3's body: capture 3 is on B alone.
        b.close();
        seedShot(b, 'R3', 3);
        await b.merge('R2', 'R3', keep: 'R3');
        // Both capture R4; A's is a record without a binding, its body read earlier and otherwise.
        seedShot(b, 'R4', 4);
        await b.round(server);
        a.close();
        final legacy = a.seedRecord('R4', bodyWrittenAt: 1767225600000, fans: 999);
        for (final MapEntry(key: name, value: bytes) in shot(4).entries) {
          File(legacy.filePath(name).path).writeAsBytesSync(bytes);
        }

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R4'), shot(4), reason: 'the binding worked out of the images A holds is the body\'s');
        expect((await listOf(a)).rows['R4']!.record.body.binding, bindingOfShot(4));
        final list = await listOf(a);
        expect(list.rows['R1']!.record.body.content, isNot(read), reason: 'A took the body B read again');
        expect(imagesOf(a, 'R1'), shot(1), reason: 'the body read again binds the images R1 holds');
        expect(list.rows['R2']!.record.body.binding, bindingOfShot(3));
        expect(imagesOf(a, 'R2'), isEmpty, reason: 'capture 3 is on B alone, and capture 2 is not R2\'s body\'s');
        expect(holds(a, 'R2'), isTrue);
      });

      test('G250: a record read again into the body of one the devices share, which is merged into it keeping the '
          'body of the capture read again, writes the body at the merge, and the capture it kept reaches the other '
          'device$backend', () async {
        await seedShots(['R1']);
        // R1 is read again on A, and the devices agree on what it now shows.
        await a.recognizeAgain('R1', (result) => result['fans'] = 7);
        await a.round(server);
        await b.round(server);
        // A captures the uma again; read otherwise, it got past the duplicate rule, and no round has bound it yet.
        a.close();
        final again = a.seedRecord('R2', fans: 999, capturedDate: '2026-01-02T00:00:00');
        for (final MapEntry(key: name, value: bytes) in shot(2).entries) {
          File(again.filePath(name).path).writeAsBytesSync(bytes);
        }
        await a.recognizeAgain('R2', (result) => result['fans'] = 7);
        // The list shows what the re-recognition wrote once the batch is published; a restart reads it from the disk.
        a.close();
        onBackend();
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R2');

        final merged = (await listOf(a)).rows['R1']!.record.body;
        expect(
          (merged.time, merged.binding),
          (hour(9), bindingOfShot(2)),
          reason: 'the body of capture 2 is new to R1',
        );
        await a.round(server);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        for (final list in await allLists()) {
          expect(list.rows.keys.toSet(), {'R1'});
          expect(list.rows['R1']!.record.body.binding, bindingOfShot(2));
        }
        expect(imagesOf(a, 'R1'), shot(2), reason: 'the capture A kept');
        expect(imagesOf(b, 'R1'), isEmpty, reason: 'capture 2 is on A alone, and B lets go of capture 1');
      });

      test('S7: a record split off carries its images; the id it is split off takes the images of the server\'s body '
          'from the record that body absorbed, on both devices$backend', () async {
        onBackend();
        await seedShots(['R1', 'R2', 'R3']);
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R2');
        await b.merge('R1', 'R3', keep: 'R3');
        await a.round(server);
        expect((await b.round(server)).splitOff, 1);
        await a.round(server);

        final splitId = onServer().rows.keys.singleWhere((id) => id != 'R1');
        for (final (name, device) in [('A', a), ('B', b)]) {
          expect(imagesOf(device, 'R1'), shot(2), reason: '$name: R1 shows the body read from capture 2');
          expect(imagesOf(device, splitId), shot(3), reason: '$name: the record split off shows capture 3');
          expect((holds(device, 'R2'), holds(device, 'R3')), (false, false), reason: name);
        }
      });

      // R4-8 5 names no unit: a record takes an image from any record the device holds. Two devices that keep R1's
      // body in merges of their own both bind R1's capture, and the record split off reaches A, whose R1 holds it.
      Future<String> splitOffWithR1sBody(int capture) async {
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R1');
        await b.merge('R1', 'R3', keep: 'R1');
        await a.round(server);
        expect((await b.round(server)).splitOff, 1);
        final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        expect(onServer().rows[splitId]!.record.body.binding, bindingOfShot(capture));
        return splitId;
      }

      // L386: a merge that keeps the body of the same content under another icon names it, and is a write of the
      // body as a re-recognition that cuts the icon again is — else an older write of the icon by another device
      // stands over it by time, the device cannot put the bytes it holds under that name, and a new device gets none.
      test('T-R5d: a merge that keeps the same content under another icon writes the body, and a new device takes '
          'that icon over another device\'s earlier write of the icon$backend', () async {
        await seedShots(['R1', 'R2', 'R3']);
        final splitId = await splitOffWithR1sBody(1);
        await a.round(server);
        Future<Uint8List> cutAgain(SyncTestDevice device, String id, int red, int at) async {
          final icon = img.encodeJpg(img.Image(width: 4, height: 4)..clear(img.ColorRgb8(red, 10, 10)));
          final directory = device.charaDetail / 'active' / id;
          File(directory.filePath('trainee.jpg').path).writeAsBytesSync(icon);
          final stored = (jsonDecode(File(directory.filePath('record.json').path).readAsStringSync()) as Map)
              .cast<String, dynamic>();
          clockAt(at);
          await device.recognizeAgain(
            id,
            (result) => result
              ..clear()
              ..addAll(stored),
          );
          return icon;
        }

        final icon = await cutAgain(a, splitId, 200, hour(10));
        final before = (await listOf(a)).rows;
        expect(before['R1']!.record.body.sameAs(before[splitId]!.record.body), isTrue, reason: 'the same content');
        await cutAgain(b, 'R1', 100, hour(10) + 1000);
        await b.round(server);
        expect(server.images, isEmpty, reason: 'under none B put no icon');
        a.close();
        await a.deleteDismissedFile();
        clockAt(hour(11));
        await a.merge('R1', splitId, keep: splitId);
        final merged = (await listOf(a)).rows['R1']!.record.body;
        expect((merged.icon, merged.time), (syncObjectName(icon), hour(11)), reason: 'the merge wrote the body');
        onBackend();
        server.form = 'png';
        await a.round(server);
        final c = SyncTestDevice('t-r5d-c');
        addTearDown(c.dispose);
        await c.round(server);
        expect(imagesOf(c, 'R1')['trainee.jpg'], icon, reason: 'C takes the icon the merge kept');
      });

      test('a record taken in takes the images its body names from a record of the device it is not joined with, '
          'which keeps them$backend', () async {
        onBackend();
        await seedShots(['R1', 'R2', 'R3']);
        final splitId = await splitOffWithR1sBody(1);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, splitId), shot(1), reason: 'A\'s R1 holds capture 1');
        expect(imagesOf(a, 'R1'), shot(1));
        expect(holds(a, 'R3'), isFalse);
      });

      // D-ICON-3a (iii), (iv), S-11: the geometry of a form a record takes from another record of the device is written
      // from the record's body, and not left to what the record it is taken from holds.
      if (webLike) {
        test(
          'D-ICON-3a (iii), (iv): a record taken in that takes the images its body names from a record of the device '
          'holding none of their geometry holds the geometry its body carries$backend',
          () async {
            onBackend();
            await seedShots(['R1', 'R2', 'R3']);
            final splitId = await splitOffWithR1sBody(1);
            dropGeometryFiles(a, 'R1');

            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(imagesOf(a, splitId), shot(1), reason: 'A\'s R1\'s images, and the geometry of capture 1');
            expect(await previewRectsOf(a, splitId), rectsOfShot(1));
          },
        );
      }

      test('a record taken in takes the images its body names from a record the device has archived, not joined with '
          'it$backend', () async {
        await seedShots(['R1', 'R2', 'R3']);
        final splitId = await splitOffWithR1sBody(1);
        // The archive is the desktop app's, made before the backend of this test's rounds is put in.
        final container = await a.open();
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive(['R1'], ArchiveImageOption.resizedJpeg, effects: archiveEffects(container));
        onBackend();
        final archived = Directory((a.charaDetail / 'archive' / 'R1').path);
        final source = {
          for (final file in archived.listSync().whereType<File>())
            if (RegExp(r'^(skill|factor|campaign)\.(jpg|json)$').hasMatch(file.uri.pathSegments.last))
              file.uri.pathSegments.last: file.readAsBytesSync(),
        };
        expect(source.keys.toSet(), containsAll(['skill.jpg', 'factor.jpg', 'campaign.jpg']));

        expect((await a.round(server)).end, SyncRoundEnd.done);
        final taken = imagesOf(a, splitId);
        expect({for (final name in source.keys) name: taken[name]}, source, reason: 'as A\'s archive holds capture 1');
        expect(archived.existsSync(), isTrue);
      });

      test('a record the round removes goes once every record is placed: one taken in later takes the images its body '
          'names from it$backend', () async {
        onBackend();
        await seedShots(['R0', 'R1', 'R2', 'R3']);
        final splitId = await splitOffWithR1sBody(2);
        // B merges its R1 into R0: A's R1 is a record the round removes, and the one record of A holding capture 2.
        await b.merge('R0', 'R1', keep: 'R0');
        await b.round(server);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, splitId), shot(2));
        expect(imagesOf(a, 'R0'), shot(1));
        expect((holds(a, 'R1'), holds(a, 'R3')), (false, false));
      });

      // A record placed in a round lets go of the images of its own its new body does not name, in its own
      // publication: one whose images another record of the round takes is placed after that record.
      test('a record of the device another record of the round takes its images from is placed after it: a third '
          'device holding the capture of a record split off in the record of the id it is split off$backend', () async {
        onBackend();
        await seedShots(['R1', 'R2', 'R3']);
        final c = SyncTestDevice('c');
        addTearDown(c.dispose);
        for (final (i, id) in ['R1', 'R2', 'R3'].indexed) {
          seedShot(c, id, i + 1);
        }
        await c.round(server);
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R2');
        await b.merge('R1', 'R3', keep: 'R1');
        await a.round(server);
        expect((await b.round(server)).splitOff, 1);
        final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        expect(onServer().rows[splitId]!.record.body.binding, bindingOfShot(1));
        expect(onServer().rows['R1']!.record.body.binding, bindingOfShot(2));
        expect(imagesOf(c, 'R1'), shot(1), reason: 'C\'s R1, the one record of C holding capture 1');

        expect((await c.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(c, 'R1'), shot(2));
        expect(imagesOf(c, splitId), shot(1), reason: 'C held capture 1 when the round began');
      });

      for (final bindingChunk in [syncBindingChunk, 1]) {
        if (webLike) continue;
        test('F1: a third device whose first round works the bindings out $bindingChunk at a time takes the images of '
            'a record split off from its record from before the binding, though that one is bound in a later part, '
            'and holds them when opened again', () async {
          await seedShots(['R10', 'R11', 'R12']);
          final c = SyncTestDevice('c');
          addTearDown(c.dispose);
          for (final (i, id) in ['R10', 'R11', 'R12'].indexed) {
            final dir = c.seedRecord(id, bodyWrittenAt: 1767225600101 + i, fans: 1001 + i);
            for (final MapEntry(key: name, value: bytes) in shot(i + 1).entries) {
              File(dir.filePath(name).path).writeAsBytesSync(bytes);
            }
          }
          clockAt(hour(9));
          await a.merge('R10', 'R11', keep: 'R11');
          await b.merge('R10', 'R12', keep: 'R10');
          await a.round(server);
          expect((await b.round(server)).splitOff, 1);
          final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R10$recordSyncSplitSeparator'));
          expect(onServer().rows[splitId]!.record.body.binding, bindingOfShot(1));

          expect((await c.round(server, bindingChunk: bindingChunk)).end, SyncRoundEnd.done);
          expect(imagesOf(c, splitId), shot(1), reason: 'C\'s R10, bound only after the record split off, holds it');
          expect(imagesOf(c, 'R10'), shot(2));
          c.close();
          expect((await c.round(server)).end, SyncRoundEnd.done);
          expect(imagesOf(c, splitId), shot(1));
          expect(imagesOf(c, 'R10'), shot(2));
        });
      }

      // A and B both keep R1's body in merges of their own, and A takes the record split off only after B has merged
      // R2 into R1 keeping R2's body: in that round A's R1, the one record of A holding capture 1, takes capture 2.
      Future<String> splitOffThenR1TakesR2sBody() async {
        await seedShots(['R1', 'R2', 'R3', 'R4']);
        clockAt(hour(9));
        await a.merge('R1', 'R3', keep: 'R1');
        await b.merge('R1', 'R4', keep: 'R1');
        await a.round(server);
        expect((await b.round(server)).splitOff, 1);
        final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        expect(onServer().rows[splitId]!.record.body.binding, bindingOfShot(1));
        await b.merge('R1', 'R2', keep: 'R2');
        await b.round(server);
        expect(onServer().rows['R1']!.record.body.binding, bindingOfShot(2));
        expect(imagesOf(a, 'R1'), shot(1), reason: 'A\'s R1, the one record of A holding capture 1');
        return splitId;
      }

      test('a record of the device another record of the round takes its images from is placed after it: two devices, '
          'the record split off reaching the device in the round its R1 takes another body$backend', () async {
        onBackend();
        final splitId = await splitOffThenR1TakesR2sBody();

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R1'), shot(2));
        expect(imagesOf(a, splitId), shot(1), reason: 'A held capture 1 when the round began');
      });

      test(
        'a record of the device another record of the round takes its images from: stopped after the record that '
        'takes them is placed and before it is, the next round places it, and neither loses an image$backend',
        () async {
          onBackend();
          final splitId = await splitOffThenR1TakesR2sBody();

          await stoppedRound(
            a,
            server,
            SyncStopFsBackend(fsBackend, markOf: SyncStopFsBackend.recordsOf({'R1'})),
            whileHeld: () async {
              expect(imagesOf(a, splitId), shot(1), reason: 'the record split off is placed first, with capture 1');
              expect(imagesOf(a, 'R1'), shot(1), reason: 'R1 is as it was');
            },
          );
          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect(imagesOf(a, 'R1'), shot(2));
          expect(imagesOf(a, splitId), shot(1));
          expect(holds(a, 'R2'), isFalse);
        },
      );

      test('control: the record split off reaching the device in a round of its own, before its R1 takes another '
          'body$backend', () async {
        onBackend();
        await seedShots(['R1', 'R2', 'R3', 'R4']);
        clockAt(hour(9));
        await a.merge('R1', 'R3', keep: 'R1');
        await b.merge('R1', 'R4', keep: 'R1');
        await a.round(server);
        expect((await b.round(server)).splitOff, 1);
        final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        expect((await a.round(server)).end, SyncRoundEnd.done);
        await b.merge('R1', 'R2', keep: 'R2');
        await b.round(server);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R1'), shot(2));
        expect(imagesOf(a, splitId), shot(1));
      });

      test(
        'a record of the device another record of the round takes its images from is placed after it: the record '
        'of the id another is split off archived on the other device, its PNGs shaped away as it is placed$backend',
        () async {
          await seedShots(['R1', 'R2', 'R3']);
          clockAt(hour(9));
          await a.merge('R1', 'R2', keep: 'R1');
          await b.merge('R1', 'R3', keep: 'R1');
          await a.round(server);
          expect((await b.round(server)).splitOff, 1);
          final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
          // The archive is the desktop app's, made before the backend of this test's rounds is put in.
          final container = await b.open();
          await container
              .read(charaArchiveControllerProvider.notifier)
              .archive(['R1'], ArchiveImageOption.resizedJpeg, effects: archiveEffects(container));
          onBackend();
          await b.round(server);
          expect(imagesOf(a, 'R1'), shot(1), reason: 'A\'s R1, the one record of A holding capture 1');

          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect(Directory((a.charaDetail / 'archive' / 'R1').path).existsSync(), isTrue);
          expect(imagesOf(a, splitId), shot(1), reason: 'A held capture 1 as PNGs when the round began');
        },
      );

      // B gives R1 the body of R10 while A merges R1 and, apart, gives R10 the body of R11: R1's body as B left it
      // goes to a record split off whose images are those of R10, which survives with another body. C holds R10,
      // archived, as the one record of C holding capture 3, and the split-off record's id sorts after R10's.
      test('a record of the device another record of the round takes its images from is placed after it: the record it '
          'takes them from archived on the device, and given another body in the same round$backend', () async {
        await seedShots(['R1', 'R2', 'R10', 'R11']);
        final c = SyncTestDevice('c');
        addTearDown(c.dispose);
        for (final (i, id) in ['R1', 'R2', 'R10', 'R11'].indexed) {
          seedShot(c, id, i + 1);
        }
        // The archive is the desktop app's, made before the backend of this test's rounds is put in.
        final container = await c.open();
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive(['R10'], ArchiveImageOption.resizedJpeg, effects: archiveEffects(container));
        onBackend();
        await c.round(server);
        clockAt(hour(9));
        await a.merge('R1', 'R2', keep: 'R1');
        await a.merge('R10', 'R11', keep: 'R11');
        await b.merge('R1', 'R10', keep: 'R10');
        await a.round(server);
        expect((await b.round(server)).splitOff, 1);
        final splitId = onServer().rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));
        expect(onServer().rows[splitId]!.record.body.binding, bindingOfShot(3));
        expect(onServer().rows['R10']!.record.body.binding, bindingOfShot(4));
        expect(splitId.compareTo('R10'), greaterThan(0));
        final archived = Directory((c.charaDetail / 'archive' / 'R10').path);
        final source = {
          for (final file in archived.listSync().whereType<File>())
            if (RegExp(r'^(skill|factor|campaign)\.(jpg|json)$').hasMatch(file.uri.pathSegments.last))
              file.uri.pathSegments.last: file.readAsBytesSync(),
        };
        expect(source.keys.toSet(), containsAll(['skill.jpg', 'factor.jpg', 'campaign.jpg']));

        expect((await c.round(server)).end, SyncRoundEnd.done);
        final taken = imagesOf(c, splitId);
        expect({for (final name in source.keys) name: taken[name]}, source, reason: 'as C\'s archive held capture 3');
      });

      test('a record that took the body of one the device has archived takes that one\'s images from the archive, and '
          'keeps them once the one absorbed goes$backend', () async {
        await seedShots(['R1', 'R2']);
        // The archive is the desktop app's, made before the backend of this test's rounds is put in.
        final container = await a.open();
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive(['R2'], ArchiveImageOption.resizedJpeg, effects: archiveEffects(container));
        onBackend();
        await a.round(server);
        final archived = Directory((a.charaDetail / 'archive' / 'R2').path);
        final source = {
          for (final file in archived.listSync().whereType<File>())
            if (RegExp(
              r'^((skill|factor|campaign)\.(png|jpg|json)|trainee\.jpg)$',
            ).hasMatch(file.uri.pathSegments.last))
              file.uri.pathSegments.last: file.readAsBytesSync(),
        };
        expect(source.keys.toSet(), containsAll(['skill.jpg', 'factor.jpg', 'campaign.jpg']));
        await b.merge('R1', 'R2', keep: 'R2');
        await b.round(server);

        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await listOf(a)).rows['R1']!.record.body.binding, bindingOfShot(2));
        expect(imagesOf(a, 'R1'), source, reason: 'R1 shows the body read from capture 2, as A\'s archive holds it');
        expect((holds(a, 'R2'), archived.existsSync()), (false, false), reason: 'the one absorbed is gone');
      });

      // [N15-03]: the source of an image a record takes is removed after the record is placed, so a stop anywhere
      // leaves it, and the round after a restart places the images.
      test('a record that takes the images of the one it absorbed: stopped after it is placed and before the one '
          'absorbed is deleted, it holds them, and the next round deletes that one$backend', () async {
        onBackend();
        await seedShots(['R1', 'R2']);
        await b.merge('R1', 'R2', keep: 'R2');
        await b.round(server);

        await stoppedRound(
          a,
          server,
          SyncStopFsBackend(fsBackend, markOf: SyncStopFsBackend.recordsOf({'R2'})),
          whileHeld: () async {
            expect(imagesOf(a, 'R1'), shot(2), reason: 'R1 is placed with the images of capture 2');
            expect(imagesOf(a, 'R2'), shot(2), reason: 'R2 is not deleted yet');
          },
        );
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R1'), shot(2));
        expect(holds(a, 'R2'), isFalse);
      });

      test('a record that takes the images of the one it absorbed: stopped part way through its publication, it is as '
          'it was, and the next round places it with them$backend', () async {
        onBackend();
        await seedShots(['R1', 'R2']);
        await b.merge('R1', 'R2', keep: 'R2');
        await b.round(server);

        // The first file the round writes into a record's tree in staging: R1's, the one record it places.
        await stoppedRound(
          a,
          server,
          SyncStopFsBackend(
            fsBackend,
            markOf: (path) => RegExp(r'[/\\]desired[/\\]').hasMatch(path) ? 'publication' : null,
          ),
          whileHeld: () async {
            expect(imagesOf(a, 'R1'), shot(1), reason: 'R1 is as it was until its publication commits');
            expect(imagesOf(a, 'R2'), shot(2));
          },
        );
        expect(imagesOf(a, 'R1'), shot(1));
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(imagesOf(a, 'R1'), shot(2));
        expect(holds(a, 'R2'), isFalse);
      });

      // [R4-8] 5, [R2-4], S-09, S-11: once the device and the server hold one list, a round puts on the server the
      // images of the bodies it lists that the server holds no form of, and takes from it those it wants and does not
      // hold. The server's image form is none until a test sets it.
      group('the images on the server', () {
        /// The PNGs of capture [n], by file name.
        Map<String, Uint8List> pngsOf(int n) => {
          for (final MapEntry(:key, :value) in shot(n).entries)
            if (key.endsWith('.png')) key: value,
        };

        /// The names the server holds the PNGs of capture [n] by.
        Set<String> pngNames(int n) => {for (final bytes in pngsOf(n).values) syncObjectName(bytes)};

        /// The PNGs of capture [n] with the geometry file of each, by file name: what a device that takes the PNGs holds
        /// of them, for a device that places a form of an image writes its geometry with it (S-11).
        Map<String, Uint8List> takenPngsOf(int n) => {
          for (final MapEntry(:key, :value) in shot(n).entries)
            if (key.endsWith('.png') || key.endsWith('.json')) key: value,
        };

        /// What a device that takes the PNGs of capture [n] and its icon holds of them ([takenPngsOf]), the icon the
        /// capturing device holds included (L373, S-11: the icon is an image).
        Map<String, Uint8List> takenOf(int n) => {...takenPngsOf(n), 'trainee.jpg': shot(n)['trainee.jpg']!};

        /// The image files of the record [id] in [device]'s store [store]; none where it holds no record [id] there.
        Map<String, Uint8List> filesIn(SyncTestDevice device, String id, {String store = 'active'}) {
          final dir = Directory((device.charaDetail / store / id).path);
          if (!dir.existsSync()) return const {};
          return {
            for (final file in dir.listSync().whereType<File>())
              if (RegExp(
                r'^((skill|factor|campaign)\.(png|jpg|json)|trainee\.jpg)$',
              ).hasMatch(file.uri.pathSegments.last))
                file.uri.pathSegments.last: file.readAsBytesSync(),
          };
        }

        Future<void> archive(SyncTestDevice device, String id, ArchiveImageOption option) async {
          final container = await device.open();
          await container
              .read(charaArchiveControllerProvider.notifier)
              .archive([id], option, effects: archiveEffects(container));
        }

        test('[R2-4]: an archive without images that reaches a device lets go of the images it held and had not sent, '
            'and no round sends them$backend', () async {
          await seedShots(['R1']);
          expect(server.images, isEmpty, reason: 'nothing is sent under the form none');
          // The archive is the desktop app's, made before the backend of this test's rounds is put in.
          await archive(a, 'R1', ArchiveImageOption.none);
          onBackend();
          await a.round(server);
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(filesIn(b, 'R1', store: 'archive'), isEmpty, reason: 'B lets go of every image it held');

          server.form = 'png';
          await b.round(server);
          await a.round(server);
          expect(server.images, isEmpty, reason: 'neither device holds an image of R1 to send');
        });

        test('[R2-4]: a record back in its normal state takes the images of its body the server holds, where it holds '
            'none of them$backend', () async {
          server.form = 'png';
          await seedShots(['R1']);
          expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)});
          final zip = await a.exportZip('R1');
          await archive(b, 'R1', ArchiveImageOption.none);
          onBackend();
          await b.round(server);
          await a.round(server);
          expect(filesIn(a, 'R1', store: 'archive'), isEmpty, reason: 'A took B\'s archive without images in');
          // A takes R1 back from its zip, normal and with its images.
          await a.importZip(zip);
          await a.round(server);

          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(
            filesIn(b, 'R1'),
            takenOf(1),
            reason: 'B takes the PNGs of R1\'s body, with their geometry, and its icon; the server holds nothing else',
          );
        });

        test('S-11: a normal record that holds the reduced JPEGs alone takes the PNGs of its body the server '
            'holds$backend', () async {
          server.form = 'png';
          seedShot(a, 'R1', 1);
          // B holds R1 from before the binding, the same body, its directory holding capture 1's reduced JPEGs alone.
          final legacy = b.seedRecord('R1', bodyWrittenAt: 1767225600101, fans: 1001);
          for (final MapEntry(key: name, value: png) in pngsOf(1).entries) {
            File(legacy.filePath(name.replaceAll('.png', '.jpg')).path).writeAsBytesSync(archiveJpegOf(png)!);
          }
          onBackend();
          await a.round(server);

          expect((await b.round(server)).end, SyncRoundEnd.done);
          final held = filesIn(b, 'R1');
          expect({for (final name in pngsOf(1).keys) name: held[name]}, pngsOf(1), reason: 'B takes the PNGs');
          expect((await listOf(b)).rows['R1']!.record.body.binding, bindingOfShot(1));
        });

        test('[R4-9] (ii): a record from before the binding that takes a body bound to the images it holds works the '
            'binding out of them, and keeps them$backend', () async {
          seedShot(a, 'R1', 1);
          // B holds R1 from before the binding, its directory holding capture 1.
          final legacy = b.seedRecord('R1', bodyWrittenAt: 1767225600101, fans: 1001);
          for (final MapEntry(key: name, value: bytes) in shot(1).entries) {
            File(legacy.filePath(name).path).writeAsBytesSync(bytes);
          }
          // A reads R1 again: another body, bound to the same images.
          await a.recognizeAgain('R1', (result) => result['fans'] = 7);
          onBackend();
          await a.round(server);

          expect((await b.round(server)).end, SyncRoundEnd.done);
          final list = await listOf(b);
          expect(list.rows['R1']!.record.body.content, (await listOf(a)).rows['R1']!.record.body.content);
          expect(imagesOf(b, 'R1'), shot(1), reason: 'the images B holds are those the body is bound to');
        });

        test(
          'C3: a body that reached a device before its images takes them in the next round, which finds the list and '
          'the generation as it left them$backend',
          () async {
            onBackend();
            seedShot(a, 'R1', 1);
            await a.round(server);
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(filesIn(b, 'R1'), isEmpty, reason: 'under the form none A sent no image');

            server.form = 'png';
            final generation = server.generation;
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)}, reason: 'A put them');
            expect(server.generation, generation, reason: 'A replaced no root');
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(server.generation, generation);
            // D-ICON-3b (i): B takes the icon too, the bytes A's capture holds.
            expect(filesIn(b, 'R1'), takenOf(1), reason: 'B took them, its records as they were');
            // D-ICON-3a (i), (iv): the preview of B reads each image's rect as A's capture wrote it.
            expect(await previewRectsOf(b, 'R1'), rectsOfShot(1));
          },
        );

        // D-ICON-3a (ii), (iv), S-11: a device that takes the reduced JPEGs of a body writes the geometry of each in
        // the JPEG's coordinates, the rect A's own archive writes as it reduces the PNG — a capture wide enough to be
        // reduced, its rects away from the origin, where the rescaling rounds both ways.
        if (!webLike) {
          test('D-ICON-3a (ii), (iv): a new device that takes the reduced JPEGs of a record from before the binding '
              'holds the geometry of each in the JPEG\'s coordinates, as the capturing device\'s archive writes it, '
              'and its preview reads it', () async {
            server.form = 'jpeg';
            final legacy = a.seedRecord('R1', bodyWrittenAt: 1767225600101, fans: 1001);
            for (final (i, image) in ['skill', 'factor', 'campaign'].indexed) {
              File(legacy.filePath('$image.png').path).writeAsBytesSync(
                img.encodePng(img.Image(width: 900, height: 10)..clear(img.ColorRgb8(40, 80 + 40 * i, 200))),
              );
              File(legacy.filePath('$image.json').path).writeAsBytesSync(
                geometryFile({
                  'top_left': {
                    'x': 13 + i,
                    'y': 27 + 7 * i,
                    'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
                  },
                  'bottom_right': {
                    'x': 913 + i,
                    'y': 37 + 7 * i,
                    'anchor': {'h': 'ScreenStart', 'v': 'ScreenEnd'},
                  },
                }),
              );
            }
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect((await b.round(server)).end, SyncRoundEnd.done);

            final held = filesIn(b, 'R1');
            expect(held.keys.toSet(), {
              for (final image in ['skill', 'factor', 'campaign']) ...['$image.jpg', '$image.json'],
            }, reason: 'B takes the reduced JPEGs, the server holding no PNG');
            // The PNG is 900 wide and its JPEG 720 by 8: each coordinate times 0.8, rounded, and the corner opposite
            // the top left 720 by 8 from it.
            final rects = [(10, 22), (11, 27), (12, 33)];
            for (final (i, image) in ['skill', 'factor', 'campaign'].indexed) {
              final (x, y) = rects[i];
              expect(jsonDecode(utf8.decode(held['$image.json']!)), {
                'intersection': {
                  'top_left': {
                    'x': x,
                    'y': y,
                    'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
                  },
                  'bottom_right': {
                    'x': x + 720,
                    'y': y + 8,
                    'anchor': {'h': 'ScreenStart', 'v': 'ScreenEnd'},
                  },
                },
              }, reason: '$image on B');
            }
            expect(await previewRectsOf(b, 'R1'), [
              for (final (x, y) in rects) [x, y, x + 720, y + 8],
            ]);

            // A archives R1 with resized images: the geometry its archive writes is the one B holds.
            final container = await a.open();
            await container
                .read(charaArchiveControllerProvider.notifier)
                .archive(['R1'], ArchiveImageOption.resizedJpeg, effects: archiveEffects(container));
            final archived = filesIn(a, 'R1', store: 'archive');
            for (final image in ['skill', 'factor', 'campaign']) {
              expect(
                jsonDecode(utf8.decode(held['$image.json']!)),
                jsonDecode(utf8.decode(archived['$image.json']!)),
                reason: '$image as A\'s archive writes it',
              );
            }
          });

          test('D-ICON-3a (i), (iv): a device that takes the PNGs of a capture wide enough to be reduced holds the '
              'geometry of each in the PNG\'s coordinates, not the reduced JPEG\'s', () async {
            server.form = 'png';
            final legacy = a.seedRecord('R1', bodyWrittenAt: 1767225600101, fans: 1001);
            final written = <String, Uint8List>{};
            for (final (i, image) in ['skill', 'factor', 'campaign'].indexed) {
              File(legacy.filePath('$image.png').path).writeAsBytesSync(
                img.encodePng(img.Image(width: 900, height: 10)..clear(img.ColorRgb8(40, 80 + 40 * i, 200))),
              );
              written['$image.json'] = geometryFile({
                'top_left': {
                  'x': 13 + i,
                  'y': 27 + 7 * i,
                  'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
                },
                'bottom_right': {
                  'x': 913 + i,
                  'y': 37 + 7 * i,
                  'anchor': {'h': 'ScreenStart', 'v': 'ScreenEnd'},
                },
              });
              File(legacy.filePath('$image.json').path).writeAsBytesSync(written['$image.json']!);
            }
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect((await b.round(server)).end, SyncRoundEnd.done);

            final held = filesIn(b, 'R1');
            for (final image in ['skill', 'factor', 'campaign']) {
              expect(held.containsKey('$image.png'), isTrue, reason: 'B takes the PNG of $image');
              expect(
                jsonDecode(utf8.decode(held['$image.json']!)),
                jsonDecode(utf8.decode(written['$image.json']!)),
                reason: '$image on B, as A\'s capture wrote it',
              );
            }
          });
        }

        test('C3: an image whose put a dropped connection cut short is put in the next round, which finds the list and '
            'the generation as it left them, and reaches the other device$backend', () async {
          onBackend();
          server.form = 'png';
          seedShot(a, 'R1', 1);
          var drops = 1;
          server.beforeImagePut = (_) async {
            if (drops-- > 0) throw const _Dropped();
          };
          expect((await a.round(server)).end, SyncRoundEnd.done, reason: 'the list is the server\'s');
          expect(server.images, isEmpty, reason: 'the first put dropped, and the round put no more');
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(filesIn(b, 'R1'), isEmpty);

          final generation = server.generation;
          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)}, reason: 'A put them');
          expect(server.generation, generation, reason: 'A replaced no root');
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(filesIn(b, 'R1'), takenOf(1));
        });

        // T2b-8: the app's server over HTTP ([HttpSyncServer]) means to a round what the fake means. The same rounds,
        // the same expectations, against the fake and through the Worker's HTTP face over it ([SyncHttpFace]).
        if (!webLike) {
          for (final overHttp in [false, true]) {
            test(
              'T2b-8 (C1): every endpoint a round calls, a replacement refused as stale and for its slots, an image put '
              'whose connection drops, a body held back, and a body refused for room and for the day, mean the same '
              '${overHttp ? 'over HTTP' : 'from the fake'}',
              () async {
                final faces = <SyncHttpFace>[];
                if (overHttp) {
                  for (final device in [a, b]) {
                    final face = SyncHttpFace(server);
                    faces.add(face);
                    device.syncHttp = face;
                  }
                }
                Future<SyncServer> to(SyncTestDevice device) async => overHttp ? device.overHttp() : server;
                seedShot(a, 'R1', 1);
                seedShot(a, 'R2', 2);
                expect(syncRecordPartOf('R1'), isNot(syncRecordPartOf('R2')), reason: 'two slots of the root');
                await a.setImageForm(await to(a), 'png');
                expect(server.form, 'png');

                server.refuseAsStale = 1;
                server.partsLimit = 1;
                var drops = 1;
                server.beforeImagePut = (_) async {
                  if (drops-- > 0) throw const _Dropped();
                };
                final first = await a.round(await to(a));
                expect(first.end, SyncRoundEnd.done);
                expect(server.refuseAsStale, 0, reason: 'refused as stale once');
                expect(server.slotsChanged, [1, 1], reason: 'then refused for its slots, and made one slot at a time');
                expect(first.imagesUndone?.stops, {
                  SyncImagesStop.lost,
                }, reason: 'an image put whose connection dropped');
                expect((await a.round(await to(a))).imagesUndone, isNull);
                expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1), ...pngNames(2), iconOfShot(2)});

                server.beforeBodies = (names) async {
                  server.beforeBodies = null;
                  return names.toSet();
                };
                expect(
                  (await b.round(await to(b))).end,
                  SyncRoundEnd.bodiesMissing,
                  reason: 'the server held them back',
                );
                expect((await b.round(await to(b))).end, SyncRoundEnd.done);
                expect(filesIn(b, 'R1'), takenOf(1));
                expect(filesIn(b, 'R2'), takenOf(2));

                a.close();
                seedShot(a, 'R3', 3);
                server.noRoom = 'database_full';
                final room = await a.round(await to(a));
                expect((room.end, room.waitingForRoom, server.refusedForRoom), (SyncRoundEnd.done, 1, 1));
                server.noRoom = null;
                server.limitTheDay(0);
                await a.setSyncOn(true);
                final day = await a.syncNow(await to(a));
                expect((day.end, day.waitingForTheDay, server.refusedForTheDay), (SyncRoundEnd.done, 1, 1));
                expect(server.storedBodies.length, 2, reason: 'R3\'s body waits');

                for (final face in faces) {
                  expect(face.malformed, isEmpty, reason: 'every request as the protocol states it');
                }
                if (overHttp) {
                  expect(
                    {for (final face in faces) ...face.asked},
                    {
                      for (final path in ['generation', 'roots/<name>', 'parts/<name>', 'settings', 'images/<name>'])
                        'GET /api/sync/$path',
                      for (final path in ['bodies/get', 'bodies', 'parts', 'root', 'held']) 'POST /api/sync/$path',
                      for (final path in ['settings', 'images/<name>']) 'PUT /api/sync/$path',
                    },
                    reason: 'every endpoint a round calls, and the image form the user sets',
                  );
                }
              },
            );

            // T3a1, D2-5: what the device tells its user stopped sync — the account's room, or the service's stop —
            // is the round's to say, through the same refusals over HTTP as from the fake.
            test(
              'T3a1 (C1 i, ii): a round tells a refusal for the account\'s room apart from one for the service\'s, a '
              'round the mark holds back tells the room that raised it, and sync switched off is the service\'s stop '
              '${overHttp ? 'over HTTP' : 'from the fake'}',
              () async {
                if (overHttp) a.syncHttp = SyncHttpFace(server);
                Future<SyncServer> to() async => overHttp ? a.overHttp() : server;
                seedUmas(a, ['R1']);
                await a.setSyncOn(true);

                server.noRoom = 'account_limit';
                final account = await a.syncNow(await to());
                expect(
                  (account.end, account.waitingForRoom, account.serverStop),
                  (SyncRoundEnd.done, 1, SyncServerStop.accountRoom),
                );
                final held = await a.roundAsAsked(await to());
                expect(
                  (held?.waitingForRoom, held?.serverStop, server.refusedForRoom),
                  (1, SyncServerStop.accountRoom, 1),
                  reason: 'the mark the refusal raised asks for no room, and says whose room it was',
                );

                server.noRoom = 'storage_full';
                final service = await a.syncNow(await to());
                expect(
                  (service.end, service.waitingForRoom, service.serverStop),
                  (SyncRoundEnd.done, 1, SyncServerStop.service),
                );

                server
                  ..noRoom = null
                  ..paused = true;
                final paused = await a.syncNow(await to());
                expect((paused.end, paused.serverStop), (SyncRoundEnd.failed, SyncServerStop.service));

                server.paused = false;
                final sent = await a.syncNow(await to());
                expect((sent.end, sent.waitingForRoom, sent.serverStop), (SyncRoundEnd.done, 0, null));
                expect(onServer().rows.keys.toSet(), {'R1'});
              },
            );

            // T3a2 (L-6, V2; S-10): the screen that turns sync on shows, before any round, what the first would send and
            // take in, and the memos that would hold it back. And (N8) whose daily limit stopped a round.
            test(
              'T3a2 (C1 iii, iv): before sync is on, the device reads what a round would send and take in, by the '
              'round\'s merge, and its long memos, with no round run and nothing kept or changed; a round stopped for '
              'the day tells the account\'s limit apart from the service\'s ${overHttp ? 'over HTTP' : 'from the fake'}',
              () async {
                if (overHttp) a.syncHttp = SyncHttpFace(server);
                Future<SyncServer> to() async => overHttp ? a.overHttp() : server;
                Future<RecordSync> sync() async => (await a.open()).read(recordSyncProvider.notifier);
                seedUmas(b, ['R2', 'R3']);
                await b.round(server);
                seedUmas(a, ['R2']);
                a.seedRecord('R1', binding: own('R1'), bodyWrittenAt: 1767225600150, fans: 1500);
                a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'あ' * (syncMemoLimit + 1)});
                final (generation, device) = (server.generation, _describe(await listOf(a)));

                expect(
                  await (await sync()).countsBeforeOn(await to()),
                  (toSend: 1, toReceive: 1),
                  reason: 'R1, which the device alone holds, and R3, which the server alone lists; R2 is on both',
                );
                expect(await (await sync()).longMemos(), 1);
                expect(server.generation, generation, reason: 'no round ran');
                expect(File(syncBaseFile(a.info).path).existsSync(), isFalse, reason: 'no list was kept');
                expect(_describe(await listOf(a)), device, reason: 'nothing of the device changed');

                a.close();
                a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'short'});
                await a.setSyncOn(true);
                expect((await a.syncNow(await to())).end, SyncRoundEnd.done);
                await deleteRecords(a, {'R2'});
                b.close();
                seedUmas(b, ['R4']);
                await b.round(server);
                expect(onServer().rows.keys.toSet(), {'R1', 'R2', 'R3', 'R4'});
                expect(
                  await (await sync()).countsBeforeOn(await to()),
                  (toSend: 0, toReceive: 1),
                  reason: 'R4; R2, which the device removed since its base, is not taken in again',
                );

                for (final scope in ['account', 'service']) {
                  a.close();
                  a.seedRecord('S-$scope', binding: own('S-$scope'), bodyWrittenAt: 1767225600200, fans: 2000);
                  server.limitTheDay(0, scope: scope);
                  final day = await a.syncNow(await to());
                  expect(
                    (day.waitingForTheDay > 0, day.serverStop),
                    (true, scope == 'account' ? SyncServerStop.accountDay : SyncServerStop.serviceDay),
                  );
                }
              },
            );
          }
        }

        // D-ICON-3b, L374, [R4-8] 6: the name a body gives its icon is where a device that holds no icon takes one
        // from; a device that keeps one of its own with the factor image keeps it. Which icon goes and comes is the
        // shared round's decision; both backends take it through the C3 cases above.
        if (!webLike) {
          test('D-ICON-3b (iii): a device that keeps an icon of its own with the factor image keeps it once the body it '
              'holds arrives naming another, its images not bound again: it puts none of its own under that name and '
              'takes none, and the other device puts the one named', () async {
            seedShot(a, 'R1', 1);
            // B holds R1 from before the binding, the same body, its directory holding capture 1 and an icon of its own,
            // cut from the same factor image into other bytes.
            final legacy = b.seedRecord('R1', bodyWrittenAt: 1767225600101, fans: 1001);
            for (final MapEntry(key: name, value: bytes) in shot(1).entries) {
              File(legacy.filePath(name).path).writeAsBytesSync(bytes);
            }
            final own = img.encodeJpg(img.Image(width: 4, height: 4)..clear(img.ColorRgb8(200, 10, 10)));
            File(legacy.filePath('trainee.jpg').path).writeAsBytesSync(own);
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect((await listOf(b)).rows['R1']!.record.body.icon, iconOfShot(1), reason: 'the body names A\'s icon');

            server.form = 'png';
            final first = await b.round(server);
            expect(first.imagesUndone, isNull, reason: 'B put nothing the server refused');
            expect(server.images.keys.toSet(), pngNames(1), reason: 'B put the PNGs, and no icon');
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)}, reason: 'A put its icon');
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(filesIn(b, 'R1'), {...takenPngsOf(1), 'trainee.jpg': own}, reason: 'B keeps its own icon');
          });

          test('D-ICON-3b (ii): no icon goes out while the account\'s form is none, nor of a record archived without '
              'images whose directory still holds one; under png the icon of a normal record does', () async {
            seedShot(a, 'R1', 1);
            seedShot(a, 'R2', 2);
            final asked = <String>[];
            server.beforeImagePut = (name) async => asked.add(name);
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(asked, isEmpty, reason: 'under the form none');
            await archive(a, 'R2', ArchiveImageOption.none);
            // R2's directory holding its icon still, as an archive without images of an older app left it.
            File(
              (a.charaDetail / 'archive' / 'R2').filePath('trainee.jpg').path,
            ).writeAsBytesSync(shot(2)['trainee.jpg']!);

            server.form = 'png';
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(asked.toSet(), {...pngNames(1), iconOfShot(1)}, reason: 'R1 alone, its icon with it');
          });

          test('D-ICON-3b (iv): an icon whose put a dropped connection cut short is put in the next round from the '
              'work left, and reaches the other device', () async {
            server.form = 'png';
            seedShot(a, 'R1', 1);
            var drops = 1;
            server.beforeImagePut = (name) async {
              if (name == iconOfShot(1) && drops-- > 0) throw const _Dropped();
            };
            final first = await a.round(server);
            expect(first.end, SyncRoundEnd.done);
            expect(first.imagesUndone?.records, 1, reason: 'R1\'s icon is left undone');
            expect(server.images.keys.toSet(), pngNames(1));
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(filesIn(b, 'R1'), takenPngsOf(1));

            expect((await a.round(server)).imagesUndone, isNull);
            expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)}, reason: 'A put the icon');
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(filesIn(b, 'R1'), takenOf(1));
          });

          test('D-ICON-3b (v): a re-recognition that cuts the icon again into other bytes names it, and the other '
              'device, which holds no icon of the record, takes the new one', () async {
            seedShot(a, 'R1', 1);
            await a.round(server);
            await b.round(server);
            final icon = img.encodeJpg(img.Image(width: 4, height: 4)..clear(img.ColorRgb8(200, 10, 10)));
            File((a.charaDetail / 'active' / 'R1').filePath('trainee.jpg').path).writeAsBytesSync(icon);
            clockAt(hour(10));
            await a.recognizeAgain('R1', (result) => result['fans'] = 7);

            server.form = 'png';
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images.keys.toSet(), {...pngNames(1), syncObjectName(icon)}, reason: 'the icon cut again');
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(filesIn(b, 'R1'), {...takenPngsOf(1), 'trainee.jpg': icon});
          });

          test(
            'T-R5b: a re-recognition that reads the same content writes no body while it cuts the same icon, and '
            'writes one naming the icon when it cuts it into other bytes, which the other device then takes',
            () async {
              seedShot(a, 'R1', 1);
              await a.round(server);
              await b.round(server);
              final jsonFile = File((a.charaDetail / 'active' / 'R1').filePath('record.json').path);
              void readTheStored(Map<String, dynamic> result) => result
                ..clear()
                ..addAll((jsonDecode(jsonFile.readAsStringSync()) as Map).cast<String, dynamic>());
              final before = jsonFile.readAsBytesSync();
              clockAt(hour(9));
              await a.recognizeAgain('R1', readTheStored);
              expect(jsonFile.readAsBytesSync(), before, reason: 'the same content and the same icon write nothing');

              final icon = img.encodeJpg(img.Image(width: 4, height: 4)..clear(img.ColorRgb8(200, 10, 10)));
              File((a.charaDetail / 'active' / 'R1').filePath('trainee.jpg').path).writeAsBytesSync(icon);
              clockAt(hour(10));
              await a.recognizeAgain('R1', readTheStored);
              final metadata = (jsonDecode(jsonFile.readAsStringSync()) as Map)['metadata'] as Map;
              expect(metadata['icon'], syncObjectName(icon), reason: 'the body names the icon cut again');

              server.form = 'png';
              expect((await a.round(server)).end, SyncRoundEnd.done);
              expect((await b.round(server)).end, SyncRoundEnd.done);
              expect(filesIn(b, 'R1'), {...takenPngsOf(1), 'trainee.jpg': icon});
            },
          );
        }

        test(
          'a device whose rounds kept nothing of images, as one that ran them before rounds did, keeps its base: the '
          'next round reads it as its base, works the images of every record, and loses none$backend',
          () async {
            onBackend();
            seedShot(a, 'R1', 1);
            await a.round(server);
            await b.round(server);
            server.form = 'png';
            await a.round(server);
            // B as a round left it before rounds kept anything of images: its base and nothing beside it.
            final images = File(syncImagesFile(b.info).path);
            expect(images.existsSync(), isTrue, reason: 'B\'s round kept what it left of R1\'s images');
            images.deleteSync();
            expect(
              (jsonDecode(File(syncBaseFile(b.info).path).readAsStringSync()) as Map).keys.toSet(),
              {'format', 'account', 'generation', 'parts'},
              reason: 'the base says nothing of images',
            );
            final (rootsRead, heldAsked) = (server.rootsRead, server.heldAsked.length);

            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(
              server.rootsRead,
              rootsRead,
              reason: 'the base read, at the generation of the list: none read again',
            );
            expect(server.heldAsked.length, greaterThan(heldAsked), reason: 'B asked which images the server holds');
            expect(filesIn(b, 'R1'), takenOf(1));
            expect(images.existsSync(), isTrue, reason: 'and kept what it left of them');
          },
        );

        /// The names the server holds the reduced JPEGs of capture [n] by: those an archive with resized images makes of
        /// its PNGs ([archiveJpegOf]).
        Set<String> jpegNames(int n) => {for (final png in pngsOf(n).values) syncObjectName(archiveJpegOf(png)!)};

        /// The archive state of the row of [id] in the server's current root; null where it lists none.
        String? stateOnServer(String id) {
          for (final text in server.currentParts()) {
            for (final row in ((jsonDecode(text) as Map<String, Object?>)['records'] as List<Object?>? ?? const [])) {
              row as Map<String, Object?>;
              if (row['id'] == id) return (row['archive'] as Map<String, Object?>)['state'] as String;
            }
          }
          return null;
        }

        // S-09, S-11: a record archived with resized images owes the server its reduced JPEGs until they land, though
        // the server holds its PNGs; a replacement refused under none is owed again in the next round. The decision is
        // the shared round's: one backend.
        if (!webLike) {
          test('S-09: a device that took the PNGs of a record another device archived with resized images, the form '
              'png, has not put the reduced JPEGs until they land, and puts them', () async {
            server.form = 'png';
            seedShot(a, 'R1', 1);
            await a.round(server);
            await archive(a, 'R1', ArchiveImageOption.resizedJpeg);
            server.beforeImagePut = (_) async => throw const SyncRefusal(507, 'account_limit');
            expect((await a.round(server)).imagesUndone?.records, 1);
            server.beforeImagePut = null;
            expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)});
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(
              filesIn(b, 'R1', store: 'archive').keys,
              containsAll(['skill.jpg', 'factor.jpg', 'campaign.jpg']),
              reason: 'B made the reduced JPEGs of the PNGs it took',
            );
            final generation = server.generation;
            for (var i = 0; i < 3; i++) {
              await b.round(server);
            }
            b.close();
            await b.round(server);
            expect(server.generation, generation);
            expect(server.images.keys.toSet(), {
              ...pngNames(1),
              iconOfShot(1),
              ...jpegNames(1),
            }, reason: 'B holds the reduced JPEGs the server lacks, and puts them');
          });

          test(
            'S-09: a replacement the server refused while the form is none is put again once the user syncs now',
            () async {
              await a.setSyncOn(true);
              server.form = 'png';
              seedShot(a, 'R1', 1);
              await a.round(server);
              await archive(a, 'R1', ArchiveImageOption.resizedJpeg);
              server.form = 'none';
              server.beforeImagePut = (_) async => throw const SyncRefusal(507, 'account_limit');
              expect((await a.round(server)).imagesUndone?.records, 1);
              server.beforeImagePut = null;
              expect((await a.syncNow(server)).end, SyncRoundEnd.done);
              expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1), ...jpegNames(1)});
            },
          );
        }

        // S-09: what a round puts follows the account's form, as the round read it and as this device sets it from
        // then on; a refused put ends the puts of the round. The decision is the shared round's: one backend.
        if (!webLike) {
          test('S-09 (i): while the account\'s form is none a round asks to put no image', () async {
            seedShot(a, 'R1', 1);
            seedShot(a, 'R2', 2);
            final asked = <String>[];
            server.beforeImagePut = (name) async => asked.add(name);
            final outcome = await a.round(server);

            expect(outcome.end, SyncRoundEnd.done);
            expect(asked, isEmpty);
            expect(server.images, isEmpty);
            expect(
              outcome.imagesUndone,
              isNull,
              reason: 'what the form none spares the device from putting is not undone',
            );
          });

          test('S-09 (ii): a round follows the form this device sets part way through it, from then on: set to none '
              'once an image landed, the round asks to put no other', () async {
            server.form = 'png';
            seedShot(a, 'R1', 1);
            seedShot(a, 'R2', 2);
            final asked = <String>[];
            server.beforeImagePut = (name) async => asked.add(name);
            server.afterImagePut = (_) async {
              server.afterImagePut = null;
              await a.setImageForm(server, 'none');
            };
            final outcome = await a.round(server);

            expect(outcome.end, SyncRoundEnd.done);
            expect(asked, hasLength(1), reason: 'the put that landed before the form was set to none, and no other');
            expect(server.images.keys, asked);
            expect(outcome.imagesUndone, isNull);
          });

          test('S-09 (ii): a device the server refuses an image puts none of the rest of the round\'s images: the form '
              'another device set to none part way through the round', () async {
            server.form = 'png';
            seedShot(a, 'R1', 1);
            seedShot(a, 'R2', 2);
            final asked = <String>[];
            server.beforeImagePut = (name) async => asked.add(name);
            server.afterImagePut = (_) async {
              server.afterImagePut = null;
              // The other device's `PUT /api/sync/settings`.
              server.form = 'none';
            };
            final outcome = await a.round(server);

            expect(outcome.end, SyncRoundEnd.done);
            expect(asked, hasLength(2), reason: 'one landed, the next was refused, and no other was asked');
            expect(server.images, hasLength(1));
            expect(outcome.imagesUndone?.records, 2, reason: 'R1 refused part way, R2 not put');
            expect(outcome.imagesUndone?.stops, {SyncImagesStop.refused});
          });

          test('S-09 (iii): set back from none, a round puts the images the server holds none of, of the records '
              'captured meanwhile too, in the form set then', () async {
            seedShot(a, 'R1', 1);
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images, isEmpty);
            a.close();
            seedShot(a, 'R2', 2);
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images, isEmpty);

            await a.setImageForm(server, 'jpeg');
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images.keys.toSet(), {
              ...jpegNames(1),
              ...jpegNames(2),
              iconOfShot(1),
              iconOfShot(2),
            }, reason: 'the reduced JPEGs alone, and the icons as they are');
          });

          test(
            'S-11, L241 (B) (v): under png a device puts no PNG beside the reduced JPEG another device put first; it '
            'keeps its PNGs',
            () async {
              server.form = 'jpeg';
              seedShot(b, 'R1', 1);
              expect((await b.round(server)).end, SyncRoundEnd.done);
              expect(server.images.keys.toSet(), {...jpegNames(1), iconOfShot(1)});

              server.form = 'png';
              seedShot(a, 'R1', 1);
              expect((await a.round(server)).end, SyncRoundEnd.done);
              expect(server.images.keys.toSet(), {
                ...jpegNames(1),
                iconOfShot(1),
              }, reason: 'the server keeps the form put first');
              expect(filesIn(a, 'R1'), shot(1), reason: 'A holds the most original form it has');
            },
          );

          test('[R7-1] (vi): a round whose image puts the server has no room for ends telling the images it left '
              'undone, the device stops for room, and the user syncing now with room puts them', () async {
            await a.setSyncOn(true);
            server.form = 'png';
            seedShot(a, 'R1', 1);
            server.beforeImagePut = (_) async => throw const SyncRefusal(507, 'account_limit', 'bytes');
            final outcome = await a.round(server);

            expect(outcome.end, SyncRoundEnd.done, reason: 'the list is the server\'s');
            expect(outcome.imagesUndone?.records, 1);
            expect(outcome.imagesUndone?.stops, {SyncImagesStop.room});
            server.beforeImagePut = null;
            final asked = <String>[];
            server.beforeImagePut = (name) async => asked.add(name);
            final stopped = await a.round(server);
            expect(asked, isEmpty, reason: 'a round of a device stopped for room asks to put no image ([N1-15])');
            expect(stopped.imagesUndone?.stops, {SyncImagesStop.room});
            final next = await a.syncNow(server);
            expect(next.imagesUndone, isNull);
            expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)});
          });

          test(
            '[N1-15], [R7-1]: an image put the server refused for the day is put by a round of the next day, nothing '
            'on the device changed and the list where it was',
            () async {
              server.form = 'png';
              clockAt(hour(9));
              server.limitTheDay(1);
              seedShot(a, 'R1', 1);
              final refused = await a.round(server);
              expect(refused.end, SyncRoundEnd.done, reason: 'the body went, and the list');
              expect(refused.imagesUndone?.records, 1);
              expect(refused.imagesUndone?.stops, {SyncImagesStop.dailyLimit});
              expect(server.images, isEmpty);
              final generation = server.generation;
              expect((await a.round(server)).imagesUndone?.records, 1, reason: 'the same day refuses them still');

              clockAt(hour(24 + 9));
              final next = await a.round(server);
              expect(next.imagesUndone, isNull);
              expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)});
              expect(server.generation, generation, reason: 'no round replaced the root');
            },
          );

          test('[R7-1] (vi): a round whose image put a dropped connection cut short ends telling the images it left '
              'undone', () async {
            server.form = 'png';
            seedShot(a, 'R1', 1);
            seedShot(a, 'R2', 2);
            server.beforeImagePut = (_) async => throw const _Dropped();
            final outcome = await a.round(server);

            expect(outcome.end, SyncRoundEnd.done);
            expect(outcome.imagesUndone?.records, 2);
            expect(outcome.imagesUndone?.stops, {SyncImagesStop.lost});
          });
        }

        test(
          'S-11, S-09 (iv): an archive with resized images replaces the PNGs the server holds with its reduced '
          'JPEGs, put after the list that archives it, under the form none too, which puts no other image$backend',
          () async {
            server.form = 'png';
            seedShot(a, 'R1', 1);
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)});
            await a.setImageForm(server, 'none');
            a.close();
            seedShot(a, 'R2', 2);
            await archive(a, 'R1', ArchiveImageOption.resizedJpeg);
            onBackend();
            final states = <String?>[];
            server.beforeImagePut = (_) async => states.add(stateOnServer('R1'));
            final outcome = await a.round(server);

            expect(outcome.end, SyncRoundEnd.done);
            expect(outcome.imagesUndone, isNull);
            expect(server.images.keys.toSet(), {
              ...pngNames(1),
              ...jpegNames(1),
              iconOfShot(1),
            }, reason: 'R2\'s images stay on A');
            expect(states, ['jpeg', 'jpeg', 'jpeg'], reason: 'each JPEG put once the server listed R1 archived');
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(
              filesIn(b, 'R1', store: 'archive').keys.where((name) => name.endsWith('.jpg') && name != 'trainee.jpg'),
              hasLength(3),
              reason: 'B takes the reduced JPEGs',
            );
          },
        );

        // S-11, S-09, L285: a device that took the PNGs of a record archived with resized images, and reduced them, owes
        // the server the replacement as the device that archived it does — under the form none too, and whatever
        // became of that device.
        test('S-11, S-09: a device that took the PNGs of a record archived with resized images puts its reduced JPEGs '
            'in their place under the form none, the device that archived it having had no room to and gone '
            'offline$backend', () async {
          server.form = 'png';
          seedShot(a, 'R1', 1);
          expect((await a.round(server)).end, SyncRoundEnd.done);
          await archive(a, 'R1', ArchiveImageOption.resizedJpeg);
          server.form = 'none';
          server.beforeImagePut = (_) async => throw const SyncRefusal(507, 'account_limit');
          expect((await a.round(server)).imagesUndone?.records, 1, reason: 'A had no room for the replacement');
          server.beforeImagePut = null;
          expect(server.images.keys.toSet(), {...pngNames(1), iconOfShot(1)});
          onBackend();

          // A is offline from here on: B alone runs rounds.
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(
            filesIn(b, 'R1', store: 'archive').keys.where((name) => name.endsWith('.jpg') && name != 'trainee.jpg'),
            hasLength(3),
            reason: 'B took the PNGs and reduced them',
          );
          final generation = server.generation;
          expect((await b.round(server)).imagesUndone, isNull);
          expect(server.images.keys.toSet(), {
            ...pngNames(1),
            ...jpegNames(1),
            iconOfShot(1),
          }, reason: 'B put the reduced JPEGs in the PNGs\' place');
          expect(server.generation, generation, reason: 'B replaced no root');
        });

        // S-09, S-11: under the form none, the one image a device puts is the replacement, owed only where the server
        // holds a PNG; a record archived with resized images of which the server holds no form owes it nothing.
        test(
          'S-09, S-11: under the form none, a round asks the server nothing of a record archived with resized images '
          'of which it holds no form, once one round saw it archived$backend',
          () async {
            seedShot(a, 'R1', 1);
            expect((await a.round(server)).end, SyncRoundEnd.done);
            await archive(a, 'R1', ArchiveImageOption.resizedJpeg);
            onBackend();
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.images, isEmpty, reason: 'nothing is sent under the form none');
            server.heldAsked.clear();

            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect(server.heldAsked, isEmpty, reason: 'A asked the server which images it holds of no record');
          },
        );

        // S-11, D-65: a device takes again an image it holds no longer, whatever removed it; the storage view removes
        // an image file of a record and leaves its row as it was.
        Future<File> removeSkillImage(SyncTestDevice device) async {
          final image = (device.charaDetail / 'active' / 'R1').filePath('skill.png');
          final report = await device.deleteInStorageView(
            StorageGroupId.activeRecords,
            StorageDeletePathsRequest([image]),
          );
          expect(report.isComplete, isTrue);
          expect(File(image.path).existsSync(), isFalse);
          return File(image.path);
        }

        test('S-11, D-65: an image the storage view removed is taken again from the server in the next round, which '
            'replaces no root$backend', () async {
          server.form = 'png';
          seedShot(a, 'R1', 1);
          expect((await a.round(server)).end, SyncRoundEnd.done);
          onBackend();
          final image = await removeSkillImage(a);
          final generation = server.generation;

          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect(image.existsSync(), isTrue, reason: 'A took skill.png again');
          expect(image.readAsBytesSync(), shot(1)['skill.png']);
          expect(filesIn(a, 'R1'), shot(1));
          expect(server.generation, generation, reason: 'A replaced no root');
        });

        if (!webLike) {
          test(
            'S-11, D-65: an image the storage view removed is taken again in the first round after a restart',
            () async {
              server.form = 'png';
              seedShot(a, 'R1', 1);
              expect((await a.round(server)).end, SyncRoundEnd.done);
              final image = await removeSkillImage(a);
              a.close();

              expect((await a.round(server)).end, SyncRoundEnd.done);
              expect(image.existsSync(), isTrue, reason: 'A took skill.png again');
              expect(image.readAsBytesSync(), shot(1)['skill.png']);
            },
          );
        }

        // S-11, L373: a record a device holds has the geometry of the images it holds, whatever removed it; the body
        // carries it, so nothing is taken for it.
        test('S-11, L373: the geometry of an image the storage view removed is written again from the body in the next '
            'round, which replaces no root$backend', () async {
          server.form = 'png';
          seedShot(a, 'R1', 1);
          expect((await a.round(server)).end, SyncRoundEnd.done);
          onBackend();
          final geometry = (a.charaDetail / 'active' / 'R1').filePath('skill.json');
          final report = await a.deleteInStorageView(
            StorageGroupId.activeRecords,
            StorageDeletePathsRequest([geometry]),
          );
          expect(report.isComplete, isTrue);
          expect(File(geometry.path).existsSync(), isFalse);
          final generation = server.generation;

          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect(File(geometry.path).existsSync(), isTrue, reason: 'A wrote skill.json again');
          expect(filesIn(a, 'R1'), shot(1));
          expect(server.generation, generation, reason: 'A replaced no root');
        });

        // L382, S-11: a zip that carries the images places its `trainee.jpg`, and the body names that icon — as a
        // device that cut the icon of the same factor image into other bytes exports the record of the same body. The
        // decision is the import's ([syncImport]), whatever the backend writes it, so one backend runs it.
        if (!webLike) {
          test('L382, S-11: a zip of the same body with an icon of other bytes, imported over the record, names the '
              'icon it places at the time of the import, and the other device takes that icon', () async {
            seedShot(a, 'R1', 1);
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect((await b.round(server)).end, SyncRoundEnd.done);
            final icon = img.encodeJpg(img.Image(width: 4, height: 4)..clear(img.ColorRgb8(200, 10, 10)));
            final zip = ZipDecoder().decodeBytes(await a.exportZip('R1'));
            const iconEntry = 'chara_detail/active/R1/trainee.jpg';
            const bodyEntry = 'chara_detail/active/R1/record.json';
            expect(zip.files.map((file) => file.name), containsAll([iconEntry, bodyEntry]));
            final out = Archive();
            for (final file in zip.files) {
              final bytes = switch (file.name) {
                iconEntry => icon,
                bodyEntry => () {
                  final map = jsonDecode(utf8.decode(file.content)) as Map<String, dynamic>;
                  (map['metadata'] as Map)['icon'] = syncObjectName(icon);
                  return utf8.encode(jsonEncode(map));
                }(),
                _ => file.content,
              };
              out.addFile(ArchiveFile(file.name, bytes.length, bytes));
            }
            clockAt(hour(10));

            await a.importZip(Uint8List.fromList(ZipEncoder().encode(out)));
            final metadata =
                (jsonDecode(File((a.charaDetail / 'active' / 'R1').filePath('record.json').path).readAsStringSync())
                        as Map)['metadata']
                    as Map;
            expect(filesIn(a, 'R1')['trainee.jpg'], icon, reason: 'A placed the zip\'s icon');
            expect([metadata['icon'], metadata['body_written_at']], [syncObjectName(icon), hour(10)]);
            server.form = 'png';
            expect((await a.round(server)).end, SyncRoundEnd.done);
            expect((await b.round(server)).end, SyncRoundEnd.done);
            expect(filesIn(b, 'R1'), {...takenPngsOf(1), 'trainee.jpg': icon});
          });
        }
      });
    }

    // D-ICON: the geometry of a record's images and the name of its icon are carried in its body (`metadata.geometry`,
    // `metadata.icon`), worked out with the binding and kept by every operation that composes a body. Read here from
    // the JSON a device and the server hold.
    group('the geometry of the images and the name of the icon', () {
      /// The `metadata` of the `record.json` the record [id] holds on [device], in [store].
      Map<String, Object?> metadataOn(SyncTestDevice device, String id, {String store = 'active'}) =>
          (jsonDecode(File((device.charaDetail / store / id).filePath('record.json').path).readAsStringSync())
                  as Map)['metadata']
              as Map<String, Object?>;

      /// What [metadata] carries of the images: the geometry, the icon's name and the binding.
      List<Object?> carried(Map<String, Object?> metadata) => [
        metadata['geometry'],
        metadata['icon'],
        metadata['binding'],
      ];

      /// What a record read from capture [n] carries of its images ([carried]).
      List<Object?> ofShot(int n) => [geometryOfShot(n), iconOfShot(n), bindingOfShot(n).toMap()];

      /// The `metadata` of every body of the record [id] the server holds.
      List<Map<String, Object?>> bodiesOnServer(String id) => [
        for (final body in server.storedBodies.values)
          if ((jsonDecode(body) as Map)['metadata'] case final Map<String, Object?> m
              when (m['record_id'] as Map)['self'] == id)
            m,
      ];

      /// The record [id] on [device] from before the binding, its body read from capture [n] and its directory holding
      /// that capture's images but those [without] names.
      void seedLegacyShot(SyncTestDevice device, String id, int n, {Set<String> without = const {}}) {
        final dir = device.seedRecord(id, bodyWrittenAt: 1767225600100 + n, fans: 1000 + n);
        for (final MapEntry(key: name, value: bytes) in shot(n).entries) {
          if (!without.contains(name)) File(dir.filePath(name).path).writeAsBytesSync(bytes);
        }
      }

      /// A zip of the format from before the binding: the record [id] read from capture [n], its `record.json`
      /// carrying no binding, with that capture's images where [images].
      Uint8List legacyZip(String id, int n, {required bool images}) {
        final map = recordFromFixture(id, '2026-01-01T00:00:00').toMap()..['fans'] = 1000 + n;
        final archive = Archive();
        void add(String name, List<int> bytes) => archive.addFile(ArchiveFile('$id/$name', bytes.length, bytes));
        add('record.json', CharaDetailRecordMapper.fromMap(map).toRecordJsonBytes());
        if (images) shot(n).forEach(add);
        return Uint8List.fromList(ZipEncoder().encode(archive));
      }

      /// The names of the image files the record [id] holds on [device] in [store].
      Set<String> imageFilesOn(SyncTestDevice device, String id, String store) => {
        for (final file in Directory((device.charaDetail / store / id).path).listSync().whereType<File>())
          if (RegExp(r'^((skill|factor|campaign)\.(png|jpg|json)|trainee\.jpg)$').hasMatch(file.uri.pathSegments.last))
            file.uri.pathSegments.last,
      };

      Future<void> archiveOn(SyncTestDevice device, String id, ArchiveImageOption option) async {
        final container = await device.open();
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive([id], option, effects: archiveEffects(container));
      }

      test('(i), (iv): a record from before the binding goes out with the geometry of its images and the name of its '
          'icon in every body that carries its binding — worked out with the binding in one write, by the round and '
          'by an archive that lets go of its PNGs first —, and the other device holds them', () async {
        seedLegacyShot(a, 'R1', 1);
        seedLegacyShot(a, 'R2', 2);
        await archiveOn(a, 'R2', ArchiveImageOption.resizedJpeg);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);

        for (final (id, n, store) in [('R1', 1, 'active'), ('R2', 2, 'archive')]) {
          expect(bodiesOnServer(id), isNotEmpty);
          for (final body in bodiesOnServer(id)) {
            expect(carried(body), ofShot(n), reason: 'a body of $id the server holds');
          }
          expect(carried(metadataOn(a, id, store: store)), ofShot(n), reason: '$id on A');
          expect(carried(metadataOn(b, id, store: store)), ofShot(n), reason: '$id on B');
        }
      });

      test(
        '(i), (iv): a device that imports a zip of reduced JPEGs from before the binding, and another that holds the '
        'same body with its PNGs, each take the geometry the other knows',
        () async {
          final map = recordFromFixture('R1', '2026-01-01T00:00:00').toMap()..['fans'] = 1001;
          final zip = Archive();
          void add(String name, List<int> bytes) => zip.addFile(ArchiveFile('R1/$name', bytes.length, bytes));
          add('record.json', CharaDetailRecordMapper.fromMap(map).toRecordJsonBytes());
          for (final image in ['skill', 'factor', 'campaign']) {
            add('$image.jpg', archiveJpegOf(shot(1)['$image.png']!)!);
            add('$image.json', shot(1)['$image.json']!);
          }
          add('trainee.jpg', shot(1)['trainee.jpg']!);
          seedLegacyShot(b, 'R1', 1);
          await a.importZip(Uint8List.fromList(ZipEncoder().encode(zip)));
          final geometry = metadataOn(a, 'R1')['geometry'] as Map;
          expect(geometry.containsKey('factor_png'), isFalse, reason: 'A holds no PNG to know its field by');
          expect(geometry.containsKey('factor_jpeg'), isTrue);

          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(carried(metadataOn(b, 'R1')), ofShot(1), reason: 'B keeps the PNG fields A does not know');
        },
      );

      test('(ii), (iv): a re-recognition names the icon the recognizer left and keeps the geometry, at the time it '
          'writes the body, and the other device takes both with the body', () async {
        seedShot(a, 'R1', 1);
        seedShot(b, 'R1', 1);
        await a.round(server);
        await b.round(server);
        // The recognizer cuts the icon again from the same factor image, into other bytes.
        final icon = img.encodeJpg(img.Image(width: 4, height: 4)..clear(img.ColorRgb8(200, 10, 10)));
        File((a.charaDetail / 'active' / 'R1').filePath('trainee.jpg').path).writeAsBytesSync(icon);
        clockAt(hour(10));
        await a.recognizeAgain('R1', (result) => result['fans'] = 7);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);

        for (final (name, device) in [('A', a), ('B', b)]) {
          final m = metadataOn(device, 'R1');
          expect(
            [m['geometry'], m['icon'], m['body_written_at'], m['binding']],
            [geometryOfShot(1), sha256.convert(icon).toString(), hour(10), bindingOfShot(1).toMap()],
            reason: 'R1 on $name',
          );
        }
      });

      test(
        '(iii), (iv): a merge keeps the geometry and the icon of the content it keeps, worked out with the binding '
        'where that side carried none, and the merge of the lists keeps what either device knows of one body',
        () async {
          seedShot(a, 'R1', 1);
          // B holds R1 from before the binding, the same body, its skill image and that image's geometry deleted.
          seedLegacyShot(b, 'R1', 1, without: {'skill.png', 'skill.json'});
          await a.round(server);
          expect((await b.round(server)).end, SyncRoundEnd.done);
          expect(carried(metadataOn(b, 'R1')), ofShot(1), reason: 'B knows what A does of the body both hold');
          expect(metadataOn(b, 'R1')['body_written_at'], 1767225600101);

          a.close();
          seedLegacyShot(a, 'R2', 2);
          clockAt(hour(9));
          await a.merge('R1', 'R2', keep: 'R2');
          expect((await a.round(server)).end, SyncRoundEnd.done);
          expect((await b.round(server)).end, SyncRoundEnd.done);
          for (final (name, device) in [('A', a), ('B', b)]) {
            final m = metadataOn(device, 'R1');
            expect([...carried(m), m['body_written_at']], [...ofShot(2), hour(9)], reason: 'R1 on $name');
          }
        },
      );

      test('D-ICON-3a (iii), (iv): a device that imports a zip whose images come without their geometry holds the '
          'geometry the zip\'s body carries, and its preview reads it', () async {
        seedShot(a, 'R1', 1);
        dropGeometryFiles(a, 'R1');
        final zip = await a.exportZip('R1');

        await b.importZip(zip);
        expect(imagesOf(b, 'R1'), shot(1), reason: 'the zip\'s images, and the geometry of capture 1');
        expect(await previewRectsOf(b, 'R1'), rectsOfShot(1));
      });

      test('(iii), (iv): a zip import keeps the geometry and the icon — those of the body the device holds, and those '
          'worked out of the images of a zip from before the binding —, through a restart, an archive without images '
          'and the record taken back from the zip', () async {
        seedShot(a, 'R1', 1);
        clockAt(hour(9));
        // R1: a zip of the same body without images, over the record A holds; R3: one with images, of none it holds.
        await a.importZip(legacyZip('R1', 1, images: false));
        await a.importZip(legacyZip('R3', 3, images: true));
        a.close();
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        void expectCarried(String when, {String r3Store = 'active'}) {
          for (final (name, device) in [('A', a), ('B', b)]) {
            final (r1, r3) = (metadataOn(device, 'R1'), metadataOn(device, 'R3', store: r3Store));
            expect([...carried(r1), r1['body_written_at']], [...ofShot(1), 1767225600101], reason: 'R1 on $name $when');
            expect([...carried(r3), r3['body_written_at']], [...ofShot(3), hour(9)], reason: 'R3 on $name $when');
          }
        }

        expectCarried('after the import');
        await archiveOn(a, 'R3', ArchiveImageOption.none);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expect(imageFilesOn(b, 'R3', 'archive'), isEmpty, reason: 'B let go of the images of R3');
        expectCarried('with R3 archived without images', r3Store: 'archive');
        await a.importZip(legacyZip('R3', 3, images: true));
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await b.round(server)).end, SyncRoundEnd.done);
        expectCarried('with R3 taken back from the zip');
      });
    });

    test('[R7-2]: while the server holds back a body the result shows, no record is put in place', () async {
      final ids = [for (var i = 1; i <= 12; i++) 'R${'$i'.padLeft(2, '0')}'];
      seedUmas(a, ids);
      await a.round(server);
      // The first ten bodies come; the server holds back the request for the rest, and then says it holds one not.
      final asked = Completer<List<String>>();
      final answer = Completer<Set<String>>();
      server.beforeBodies = (names) async {
        if (names.length == 10) return const {};
        asked.complete(names);
        return answer.future;
      };
      final round = b.round(server);
      final rest = await asked.future;
      final active = Directory((b.charaDetail / 'active').path);
      bool holdsNone() => !active.existsSync() || active.listSync().isEmpty;
      expect(holdsNone(), isTrue, reason: 'ten bodies are at hand, and no record is put in place');
      answer.complete({rest.first});
      expect((await round).end, SyncRoundEnd.bodiesMissing);
      expect(holdsNone(), isTrue);
      expect(File(syncBaseFile(b.info).path).existsSync(), isFalse);

      server.beforeBodies = null;
      expect((await b.round(server)).end, SyncRoundEnd.done);
      expect(_describe(await listOf(b)), _describe(await listOf(a)));
    });

    // S-10: a memo longer than a round sends — one from before the app limited what a user types, which the app neither
    // removes nor cuts — holds every round of its device back until its user cuts it. A memo of that length is written
    // here through the memo's save, which takes any length; in the app one arrives with a record taken back from a zip.
    test('S-10: a memo over the limit holds the round back and tells how many there are, the device and the server as '
        'they were; cut to the limit, the round runs', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      // Memos from before the limit, which carry no time they were written at.
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'x' * (syncMemoLimit + 1), 'R2': 'y' * 300});
      await deleteRecords(a, {'R3'});
      final (serverBefore, deviceBefore) = (_describe(onServer()), _describe(await listOf(a)));

      final held = await a.round(server);
      expect((held.end, held.longMemos, held.replacements), (SyncRoundEnd.heldByLongMemos, 2, 0));
      expect(_describe(onServer()), serverBefore);
      expect(_describe(await listOf(a)), deviceBefore);

      await writeMemo(a, 'R1', 'cut');
      final cut = await a.round(server);
      expect((cut.end, cut.longMemos), (SyncRoundEnd.heldByLongMemos, 1));
      await writeMemo(a, 'R2', 'y' * syncMemoLimit);
      final ran = await a.round(server);
      expect((ran.end, ran.longMemos), (SyncRoundEnd.done, 0));
      expect(onServer().rows.keys.toSet(), {'R1', 'R2'});
      expect(onServer().cells[('memo/m1', 'R2')]?.value, jsonEncode('y' * syncMemoLimit));
    });

    test('S-10: the gate counts the memos of the list the round merges and sends: one written while the round works '
        'out a binding, before it reads the device, holds it back', () async {
      seedUmas(a, ['R1']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      a.close();
      // R2 carries no binding: the round works it out, and writes R2, before it reads the device.
      a.seedRecord('R2');
      final writes = HeldWriteFsBackend((a.charaDetail / 'active' / 'R2').filePath('record.json').path);
      final previous = fsBackend;
      fsBackend = writes;
      addTearDown(() => fsBackend = previous);
      final round = a.round(server);
      await waitUntil(() => writes.held, describe: "the round's write of R2's binding to be reached");
      await writeMemo(a, 'R1', 'x' * (syncMemoLimit + 1));
      writes.release();

      final held = await round;
      expect((held.end, held.longMemos), (SyncRoundEnd.heldByLongMemos, 1));
      expect(onServer().rows.keys.toSet(), {'R1'});
      expect(onServer().cells[('memo/m1', 'R1')], isNull);
    });

    test('S-10: a memo over the limit written after the round read the device goes with no round, and holds the next '
        'back', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R1': 'short'}, writtenAt: {'R1': 1767225600500});
      await a.round(server);
      await b.round(server);
      await deleteRecords(a, {'R2'});
      // A's round read A and asks the server to take its list; A's user writes a memo over the limit meanwhile.
      server.beforeReplace = () async {
        server.beforeReplace = null;
        await writeMemo(a, 'R1', 'x' * (syncMemoLimit + 1));
      };
      expect((await a.round(server)).end, SyncRoundEnd.done);
      expect(onServer().rows.keys.toSet(), {'R1'}, reason: 'the round sent what it read');

      final next = await a.round(server);
      expect((next.end, next.longMemos), (SyncRoundEnd.heldByLongMemos, 1));
      expect((await b.round(server)).end, SyncRoundEnd.done);
      for (final list in [onServer(), await listOf(b)]) {
        expect(list.cells[('memo/m1', 'R1')]?.value, jsonEncode('short'));
      }
    });

    test(
      'S-10: a memo over the limit a column holds of a record the device does not hold holds no round back',
      () async {
        seedUmas(a, ['R1']);
        // A memo from before the limit, left in the column's file by a record deleted before the upgrade.
        a.seedColumn('memo', 'm1', title: 'Note', data: {'R0': 'x' * (syncMemoLimit + 1)});
        expect((await listOf(a)).cells[('memo/m1', 'R0')]?.value, jsonEncode('x' * (syncMemoLimit + 1)));

        final ran = await a.round(server);
        expect((ran.end, ran.longMemos), (SyncRoundEnd.done, 0));
        expect(onServer().rows.keys.toSet(), {'R1'});
      },
    );

    test('[R3-5]: a removal a round undoes is told by the device that ran the round, whichever device removed it, and '
        'by no other', () async {
      seedUmas(a, ['R1', 'R2']);
      await a.round(server);
      await b.round(server);
      // B deletes R1, and A, which has not received that, merges R2 into R1: A's round undoes B's delete (S4).
      await deleteRecords(b, {'R1'});
      expect((await b.round(server)).restored, 0);
      clockAt(hour(9));
      await a.merge('R1', 'R2', keep: 'R2');

      final undone = await a.round(server);
      expect((undone.end, undone.restored), (SyncRoundEnd.done, 1));
      final back = await b.round(server);
      expect((back.end, back.restored), (SyncRoundEnd.done, 0), reason: 'B, whose delete came undone, is told nothing');
      expect((await listOf(b)).rows.keys.toSet(), {'R1'});
    });

    test('[R3-5]: a device that lost the lists a round keeps meets the server as with no base, and tells as added up '
        'the records one side alone held that it kept; the other device tells none', () async {
      seedUmas(a, ['R1', 'R2']);
      await a.round(server);
      await b.round(server);
      await deleteRecords(b, {'R2'});
      await b.round(server);
      // A's base is gone; a round that ended with the server holding the device's list leaves no sent list.
      a.close();
      File(syncBaseFile(a.info).path).deleteSync();

      final met = await a.round(server);
      expect((met.end, met.added, met.restored), (SyncRoundEnd.done, 1, 0));
      final other = await b.round(server);
      expect((other.end, other.added), (SyncRoundEnd.done, 0));
      expect((await listOf(b)).rows.keys.toSet(), {'R1', 'R2'});
    });

    test('[R3-5] (G226): a round that puts nothing in place, the server answering a body other than the one it '
        'names, tells no removal undone; the round that puts it in place tells it', () async {
      seedUmas(a, ['R1', 'R2']);
      await a.round(server);
      await b.round(server);
      // A deletes R1, and B merges R2 into R1: A's round keeps B's R1, whose body it asks the server for (S4).
      await deleteRecords(a, {'R1'});
      clockAt(hour(9));
      await b.merge('R1', 'R2', keep: 'R2');
      await b.round(server);

      server.beforeBodies = (names) async {
        server.answeredWrong = {...names};
        return const {};
      };
      final missing = await a.round(server);
      expect((missing.end, missing.restored), (SyncRoundEnd.bodiesMissing, 0));
      server
        ..beforeBodies = null
        ..answeredWrong = {};
      final placed = await a.round(server);
      expect((placed.end, placed.restored), (SyncRoundEnd.done, 1));
      expect((await listOf(a)).rows.keys.toSet(), {'R1'});
    });

    test('[R3-5] (G243): a round that put back a record a removal took and then stopped at a record this device '
        'changed since it read it tells the removal undone; the round after it does not tell it again', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      await a.round(server);
      await b.round(server);
      // A deletes R1; B merges R2 into R1 and recognizes R3 again.
      await deleteRecords(a, {'R1'});
      clockAt(hour(9));
      await b.merge('R1', 'R2', keep: 'R2');
      await b.recognizeAgain('R3', (result) => result['fans'] = 8);
      await b.round(server);

      // A's round asks the server for B's R1 and R3; A recognizes R3 again meanwhile, later than B did. The round puts
      // R1 back, and leaves R3, which A changed since the round read it, to the next.
      server.beforeBodies = (names) async {
        server.beforeBodies = null;
        clockAt(hour(10));
        await a.recognizeAgain('R3', (result) => result['fans'] = 9);
        return const {};
      };
      final stopped = await a.round(server);
      expect((stopped.end, stopped.restored), (SyncRoundEnd.changedMeanwhile, 1));
      expect((await listOf(a)).rows.keys.toSet(), {'R1', 'R2', 'R3'});
      final next = await a.round(server);
      expect((next.end, next.restored), (SyncRoundEnd.done, 0), reason: 'the removal undone is told once');
    });

    test('[R3-5] (G243): a round that placed a record split off and then stopped at a write that failed tells the '
        'split; the round after it does not tell it again', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      clockAt(hour(9));
      await a.merge('R1', 'R2', keep: 'R2');
      await writeMemo(b, 'R1', 'mine');
      await b.merge('R1', 'R3', keep: 'R3');
      await a.round(server);

      // B's round places the record split off, and then moves B's memo of R1 onto it, which fails to write.
      b.close();
      b.beforeMetadataWrite = (path) async {
        if (path.name == 'm1.json') throw const FileSystemException('the memo storage could not be written');
      };
      final stopped = await b.round(server);
      expect((stopped.end, stopped.splitOff), (SyncRoundEnd.failed, 1));
      final splitId = (await listOf(b)).rows.keys.singleWhere((id) => id.startsWith('R1$recordSyncSplitSeparator'));

      b.close();
      b.beforeMetadataWrite = null;
      final next = await b.round(server);
      expect((next.end, next.splitOff), (SyncRoundEnd.done, 0), reason: 'the record split off is told once');
      expect(onServer().rows.keys.toSet(), {'R1', splitId});
    });

    test('[R3-5]: a first round that stops after it placed what it added up tells the records only the server held; a '
        'record of the device\'s it wrote again, which the next round meets again, that round tells, once', () async {
      // A's R1 names P as its parent; B's Q absorbed P, so the merge writes Q in R1's parent and sends R1 again.
      a.seedRecord('R1', binding: own('R1'), parent1: 'P', bodyWrittenAt: 1767225600100);
      a.seedRecord('RZ', binding: own('RZ'), bodyWrittenAt: 1767225600100);
      b.seedRecord('Q', binding: own('Q'), absorbed: {'P'}, bodyWrittenAt: 1767225600100);
      b.seedRecord('RZ', binding: own('RZ'), bodyWrittenAt: 1767225600200, fans: 8);
      await b.round(server);

      // A recognizes RZ again while its first round asks for the bodies: the round stops at RZ.
      server.beforeBodies = (_) async {
        server.beforeBodies = null;
        clockAt(hour(10));
        await a.recognizeAgain('RZ', (result) => result['fans'] = 9);
        return const {};
      };
      final stopped = await a.round(server);
      expect(stopped.end, SyncRoundEnd.changedMeanwhile);
      expect((await listOf(a)).rows['R1']?.record.body.parents['parent1'], 'Q');
      expect(stopped.added, 1, reason: 'Q, which only the server held');
      final next = await a.round(server);
      expect((next.end, next.added), (SyncRoundEnd.done, 1), reason: 'R1, which only A held');
    });

    // [R6-1], [R6-4] and R1: the switch of sync, through the entry the app asks for a round with ([RecordSync.round]).
    test('[R6-1] (R1): with sync off, a round asked for asks the server nothing and writes nothing of the device\'s; '
        'turned on, it runs, and the app keeps what it told', () async {
      seedUmas(a, ['R1']);
      final counted = _CountedServer(server);
      expect(await a.roundAsAsked(counted), isNull);
      expect(counted.calls, 0, reason: 'the server is asked nothing');
      expect(File(syncBaseFile(a.info).path).existsSync(), isFalse, reason: 'no list a round keeps is written');

      await a.setSyncOn(true);
      final ran = await a.roundAsAsked(counted);
      expect(ran?.end, SyncRoundEnd.done);
      expect(counted.calls, greaterThan(0));
      expect((await a.open()).read(recordSyncProvider).told, same(ran));
      expect(onServer().rows.keys.toSet(), {'R1'});
    });

    test(
      'R1: the records are listed as the app starts while a round asked for meanwhile waits on the server',
      () async {
        seedUmas(a, ['R1']);
        await a.setSyncOn(true);
        a.close();
        final asked = Completer<void>();
        final answer = Completer<void>();
        final counted = _CountedServer(
          server,
          beforeGeneration: () {
            asked.complete();
            return answer.future;
          },
        );
        final container = a.start();
        final round = container.read(recordSyncProvider.notifier).round(counted);
        await asked.future;
        final listed = await container.read(charaDetailRecordStorageLoaderProvider.future);
        expect([for (final r in listed) r.id], ['R1'], reason: 'the list does not wait on the round');
        answer.complete();
        expect((await round)?.end, SyncRoundEnd.done);
      },
    );

    test('a round asked for while one runs is one round after it, however many are asked for, and sends what the user '
        'did after the running round read the device: the two never run together', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      clockAt(hour(9));
      await b.recognizeAgain('R1', (r) => r['fans'] = 8);
      await b.round(server);
      await a.setSyncOn(true);
      var generations = 0;
      final counted = _CountedServer(
        server,
        beforeGeneration: () async {
          generations++;
        },
      );
      // A's round asks for B's body of R1 after it has read the device, and the answer is held there.
      final entered = Completer<void>();
      final answer = Completer<void>();
      server.beforeBodies = (_) async {
        server.beforeBodies = null;
        entered.complete();
        await answer.future;
        return const {};
      };
      final first = a.roundAsAsked(counted);
      await entered.future;
      clockAt(hour(10));
      await writeMemo(a, 'R2', 'late');
      final asked = [for (var i = 0; i < 3; i++) a.roundAsAsked(counted)];
      answer.complete();
      final one = await first;
      expect(one?.end, SyncRoundEnd.done);
      expect(
        onServer().cells[('memo/m1', 'R2')]?.value,
        isNot(jsonEncode('late')),
        reason: 'the running round read the device before the memo was saved',
      );

      final later = await Future.wait(asked);
      expect(
        onServer().cells[('memo/m1', 'R2')]?.value,
        jsonEncode('late'),
        reason: 'a request is answered once a round that read the memo has sent it',
      );
      expect(later.first?.end, SyncRoundEnd.done);
      expect(later.first, isNot(same(one)), reason: 'it is answered by the round after the one running');
      expect(later, everyElement(same(later.first)), reason: 'one round after the running one, for all three');
      expect(generations, 2);
      expect((await a.roundAsAsked(counted))?.end, SyncRoundEnd.done, reason: 'one asked for after it ends runs');
      expect(generations, 3, reason: 'no round was left queued behind the one that answered');
    });

    test('T2b-8 (C1 iii): a request over HTTP that never answers fails at its deadline as one whose answer did not '
        'arrive, and the round asked for behind its round runs', () async {
      seedUmas(a, ['R1']);
      final face = SyncHttpFace(server);
      final entered = Completer<void>();
      face.beforeAnswer = (request) async {
        if (request.uri.path != '/api/sync/generation' || entered.isCompleted) return;
        entered.complete();
        await Completer<void>().future;
      };
      // The deadline is a quarter of an hour in the app ([syncRequestTimeoutProvider]); what is asserted here is that
      // a request held past whatever deadline the server is given fails, not how long the deadline is.
      a
        ..syncHttp = face
        ..syncRequestTimeout = const Duration(milliseconds: 250);
      await a.setSyncOn(true);
      final http = await a.overHttp();
      final first = a.roundAsAsked(http);
      await entered.future;
      final behind = a.roundAsAsked(http);
      expect((await first)?.end, SyncRoundEnd.failed, reason: 'the generation never came');
      expect((await behind)?.end, SyncRoundEnd.done);
      expect(onServer().rows.keys.toSet(), {'R1'});
    });

    // T3a1: what the screen reads of the rounds — whether one runs, which keeps the user from syncing now meanwhile,
    // and when the device last synced (N8).
    test('T3a1 (C1 iii, iv): the device shows a round running from when it is asked for until the one asked for '
        'behind it ends, and its last sync moves with a round that synced alone', () async {
      final time = HeldSyncTime()..now = DateTime.utc(2030, 1, 1, 9);
      a.syncTime = time.time;
      seedUmas(a, ['R1']);
      await a.setSyncOn(true);
      final app = await a.open();
      RecordSyncState state() => app.read(recordSyncProvider);
      expect((state().running, state().lastSynced), (false, null), reason: 'no round has run');

      final entered = Completer<void>();
      final answer = Completer<void>();
      final held = _CountedServer(
        server,
        beforeGeneration: () async {
          if (entered.isCompleted) return;
          entered.complete();
          await answer.future;
        },
      );
      final first = a.roundAsAsked(held);
      await entered.future;
      expect(state().running, isTrue, reason: 'a round runs');
      final behind = a.roundAsAsked(held);
      time.now = DateTime.utc(2030, 1, 1, 10);
      answer.complete();
      expect((await first)?.end, SyncRoundEnd.done);
      expect(state().running, isTrue, reason: 'the round asked for behind it is still to run');
      expect((await behind)?.end, SyncRoundEnd.done);
      expect((state().running, state().lastSynced), (false, DateTime.utc(2030, 1, 1, 10)));

      server.paused = true;
      time.now = DateTime.utc(2030, 1, 1, 11);
      expect((await a.roundAsAsked(server))?.end, SyncRoundEnd.failed);
      expect(
        (state().running, state().lastSynced),
        (false, DateTime.utc(2030, 1, 1, 10)),
        reason: 'the round did not sync',
      );
      server.paused = false;
      expect((await a.roundAsAsked(server))?.end, SyncRoundEnd.done);
      expect(state().lastSynced, DateTime.utc(2030, 1, 1, 11));
    });

    // T2b-7a: the moments a round runs at (U5), each from the entry the app has for it: the app's start reads the
    // moments as the app does ([SyncTestDevice.startTriggers]), the user turns sync on, rates and syncs now, and the
    // platform says the app came back to the foreground. Each round goes over HTTP ([SyncHttpFace]), so a round asked
    // for with no session or deleting has no server. The clock and the timer are the test's ([HeldSyncTime]): what is
    // asserted is which moment asks, and that the quiet after an edit is five seconds — not how long a test waits.
    group('T2b-7a: the moments a round runs at', () {
      late SyncHttpFace face;
      late HeldSyncTime time;
      // The rounds the server was asked for: each asks the generation first.
      late int asked;

      setUp(() {
        TestWidgetsFlutterBinding.ensureInitialized();
        asked = 0;
        face = SyncHttpFace(server)
          ..beforeAnswer = (request) async {
            if (request.uri.path == '/api/sync/generation') asked++;
          };
        time = HeldSyncTime();
        a
          ..syncHttp = face
          ..syncTime = time.time;
      });

      /// What the next round [app] runs tells, once it has ended.
      Future<SyncRoundOutcome> told(ProviderContainer app) {
        final ended = Completer<SyncRoundOutcome>();
        final listening = app.listen(recordSyncProvider.select((s) => s.told), (_, told) {
          if (told != null && !ended.isCompleted) ended.complete(told);
        });
        return ended.future.whenComplete(listening.close);
      }

      /// The platform says the app went to the background and came back to the foreground.
      void cameToTheForeground() => TestWidgetsFlutterBinding.instance
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      test('T2b-7a (C1 i): the app\'s start runs a round, and what it takes in is no edit', () async {
        seedUmas(a, ['R1']);
        seedUmas(b, ['R2']);
        b.seedColumn('rating', 'r1', title: 'Score', data: {'R2': 5.0}, writtenAt: {'R2': 1767225600400});
        await b.round(server);
        await a.setSyncOn(true);
        final ran = told(await a.open());
        await a.startTriggers();
        expect((await ran).end, SyncRoundEnd.done);
        expect(asked, 1);
        expect(onServer().rows.keys.toSet(), {'R1', 'R2'});
        expect((await listOf(a)).cells[('rating/r1', 'R2')]?.value, '5.0');
        expect(time.timers, isEmpty, reason: 'the record and the rating the round put in place ask for no round');
      });

      test('T2b-7a (C1 i): turning sync on runs a round; the app\'s start with sync off ran none', () async {
        seedUmas(a, ['R1']);
        await a.startTriggers();
        final ran = told(await a.open());
        await a.setSyncOn(true);
        expect((await ran).end, SyncRoundEnd.done);
        expect(asked, 1);
        expect(onServer().rows.keys.toSet(), {'R1'});
      });

      test('T2b-7a (C1 i): the user syncing now runs a round', () async {
        seedUmas(a, ['R1']);
        await a.setSyncOn(true);
        expect((await (await a.open()).read(recordSyncProvider.notifier).syncNow())?.end, SyncRoundEnd.done);
        expect(asked, 1);
        expect(onServer().rows.keys.toSet(), {'R1'});
      });

      test('T2b-7a (C1 i): an edit runs a round five seconds after it', () async {
        seedUmas(a, ['R1']);
        await a.setSyncOn(true);
        final app = await a.open();
        var ran = told(app);
        await a.startTriggers();
        await ran;
        ran = told(app);
        await rate(a, 'R1', 3);
        expect(time.timers.single.duration, const Duration(seconds: 5));
        expect(asked, 1, reason: 'no round before the quiet ends');
        time.timers.single.fire();
        expect((await ran).end, SyncRoundEnd.done);
        expect(asked, 2);
        expect(onServer().cells[('rating/r1', 'R1')]?.value, '3.0');
      });

      test('T2b-7a (C1 iii): edits closer together than five seconds are sent by one round', () async {
        seedUmas(a, ['R1', 'R2']);
        await a.setSyncOn(true);
        final app = await a.open();
        var ran = told(app);
        await a.startTriggers();
        await ran;
        ran = told(app);
        await rate(a, 'R1', 3);
        await rate(a, 'R2', 4);
        expect([for (final timer in time.timers) timer.isActive], [false, true], reason: 'the second edit restarts it');
        time.timers.last.fire();
        expect((await ran).end, SyncRoundEnd.done);
        expect(asked, 2, reason: 'the start, and one round for both edits');
        expect(onServer().cells[('rating/r1', 'R1')]?.value, '3.0');
        expect(onServer().cells[('rating/r1', 'R2')]?.value, '4.0');
      });

      test('T2b-7a (C1 i): coming back to the foreground runs a round ten minutes or more after the last was asked '
          'for, and none sooner', () async {
        seedUmas(a, ['R1']);
        await a.setSyncOn(true);
        final app = await a.open();
        final sync = app.read(recordSyncProvider.notifier);
        var ran = told(app);
        final start = time.now;
        await a.startTriggers();
        await ran;
        time.now = start.add(const Duration(minutes: 9, seconds: 59));
        cameToTheForeground();
        // Rounds run one after another: one the foreground had started would run before this one, and be asked.
        expect((await sync.syncNow())?.end, SyncRoundEnd.done);
        expect(asked, 2, reason: 'the start and syncing now; not the foreground before ten minutes');
        time.now = time.now.add(const Duration(minutes: 10));
        ran = told(app);
        cameToTheForeground();
        expect((await ran).end, SyncRoundEnd.done);
        expect(asked, 3);
      });

      test('T2b-7a (C1 iv): after a round whose connection dropped once the server had replaced the list, the round '
          'the next moment runs ends as an uncut one: one list on the server and both devices', () async {
        seedUmas(a, ['R1', 'R2']);
        await a.setSyncOn(true);
        final app = await a.open();
        var ran = told(app);
        server.loseAnswer = true;
        await a.startTriggers();
        expect((await ran).end, SyncRoundEnd.answerLost);
        ran = told(app);
        await rate(a, 'R1', 3);
        time.timers.single.fire();
        expect((await ran).end, SyncRoundEnd.done);
        expect(File(syncSentFile(a.info).path).existsSync(), isFalse, reason: 'the base is the server\'s list again');
        await b.round(server);
        final lists = [onServer(), await listOf(a), await listOf(b)].map(_describe).toList();
        expect(lists[1], lists[0]);
        expect(lists[2], lists[0]);
        expect(onServer().cells[('rating/r1', 'R1')]?.value, '3.0');
      });

      test(
        'T2b-7a (C1 ii): logged out, sync on for the account it was turned on under, no moment runs a round',
        () async {
          a.auth = FakeShareAuth();
          seedUmas(a, ['R1']);
          await a.login(syncTestAccount);
          await a.setSyncOn(true);
          await a.logout();
          final sync = (await a.open()).read(recordSyncProvider.notifier);
          await a.startTriggers();
          await rate(a, 'R1', 3);
          time.timers.single.fire();
          time.now = time.now.add(syncForegroundInterval);
          cameToTheForeground();
          // Asked last, and run after any round asked before it.
          expect(await sync.syncNow(), isNull);
          expect(asked, 0);
        },
      );

      test('T2b-7a (C1 ii): with sync off, no moment runs a round', () async {
        seedUmas(a, ['R1']);
        final sync = (await a.open()).read(recordSyncProvider.notifier);
        await a.startTriggers();
        await rate(a, 'R1', 3);
        time.timers.single.fire();
        time.now = time.now.add(syncForegroundInterval);
        cameToTheForeground();
        expect(await sync.syncNow(), isNull);
        expect(asked, 0);
      });
    });

    test('[R6-4]: with sync off, the device keeps the lists its rounds keep and writes the times of what its user '
        'does; turned on again, that reaches the server and the other device as it would have with sync on', () async {
      seedUmas(a, ['R1', 'R2']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.setSyncOn(true);
      expect((await a.roundAsAsked(server))?.end, SyncRoundEnd.done);
      await b.round(server);
      // Read before the switch, so what turning sync off does to the base is what is compared.
      final base = File(syncBaseFile(a.info).path).readAsBytesSync();
      await a.setSyncOn(false);

      clockAt(hour(9));
      await writeMemo(a, 'R1', 'off');
      await deleteRecords(a, {'R2'});
      final counted = _CountedServer(server);
      expect(await a.roundAsAsked(counted), isNull);
      expect(counted.calls, 0);
      final kept = File(syncBaseFile(a.info).path);
      expect(kept.existsSync() ? kept.readAsBytesSync() : null, base, reason: 'the base is kept as it was');
      final memo = (await listOf(a)).cells[('memo/m1', 'R1')];
      expect((memo?.value, memo?.time), (jsonEncode('off'), hour(9)), reason: 'the memo is written with its time');

      await a.setSyncOn(true);
      expect((await a.roundAsAsked(server))?.end, SyncRoundEnd.done);
      expect((await b.round(server)).end, SyncRoundEnd.done);
      for (final list in [onServer(), await listOf(b)]) {
        expect(list.rows.keys.toSet(), {'R1'}, reason: 'the delete made with sync off reaches it');
        final memo = list.cells[('memo/m1', 'R1')];
        expect((memo?.value, memo?.time), (jsonEncode('off'), hour(9)));
      }
    });

    // R-LIB8: a merge left unfinished on a record whose row is as the base lists it ([N15-02]); a close that opens
    // while the first round prepares its place (G311, A106); a waiting record whose body the server holds already
    // (G371).
    test('an unfinished merge into a record whose row is as the base lists it holds back the memo it moves', () async {
      a.seedRecord('R1', binding: _binding, bodyWrittenAt: 1767225600100, absorbed: {'R2'});
      a.seedRecord('R2', binding: _binding, bodyWrittenAt: 1767225600100, capturedDate: '2026-01-02T00:00:00');
      a.seedColumn(
        'memo',
        'm1',
        title: 'Note',
        data: {'R1': 'm1', 'R2': 'm2'},
        writtenAt: {'R1': 1767225600200, 'R2': 1767225600300},
      );
      await a.round(server);
      await b.round(server);
      final before = (await a.read()).list.rows['R1']!.record;
      final c = await a.open();
      final candidate = candidatesIn(c).singleWhere((x) => x.olderId == 'R1' && x.newerId == 'R2');
      final originalBackend = fsBackend;
      final stop = SyncStopFsBackend(originalBackend, markOf: SyncStopFsBackend.recordsOf({'R2'}));
      fsBackend = stop;
      final merging = c
          .read(enhancementMergeProvider)
          .merge(
            candidate,
            keptContentId: 'R1',
            choices: const EnhancementMergeChoices(memo: {'m1': 'm2'}),
            effects: mergeEffects(c),
          );
      await stop.held;
      stop.stop();
      final result = await merging;
      fsBackend = originalBackend;
      expect(result.outcome, EnhancementMergeOutcome.failedDelete);
      final held = syncHeldRecordsOf(c.read(containerRefProvider))!.records['R1']!;
      expect(syncRecordsAgree(held, before), isTrue, reason: 'the merge leaves the row of R1 as the base lists it');
      expect((await a.read()).mergesInProgress.keys, contains('R1'));

      expect((await a.round(server)).end, SyncRoundEnd.done);
      await b.round(server);
      for (final list in [onServer(), await listOf(b)]) {
        expect(list.cells[('memo/m1', 'R2')]?.value, jsonEncode('m2'), reason: 'the memo of R2 waits for the merge');
        expect(list.cells[('memo/m1', 'R1')]?.value, jsonEncode('m1'));
      }
    });

    test('a close that opens while the first round prepares its place puts nothing in place', () async {
      seedUmas(b, ['R2']);
      await b.round(server);
      final c = await a.open();
      final ref = c.read(containerRefProvider);
      final run = runSyncRound(ref, server, account: syncTestAccount, effects: recordImportEffects(ref));
      final tasks = Completer<void>();
      final requests = c.read(appExitRequestsProvider.notifier);
      final exit = requests.request(onHeld: () => c.read(appExitRequestsProvider)!.hold(tasks.future));
      final outcome = await run;
      tasks.complete();
      await exit;
      expect(outcome.end, SyncRoundEnd.closing);
      expect((await listOf(a)).rows, isEmpty);
    });

    test('a waiting record whose body the server holds unlisted is not listed with its waiting memo', () async {
      seedUmas(a, ['R1']);
      await a.round(server);
      a.close();
      a.seedRecord('R2', binding: _binding, bodyWrittenAt: 1767225600200, fans: 2000);
      a.seedColumn('memo', 'm1', title: 'Note', data: {'R2': 'waits'}, writtenAt: {'R2': 1767225600300});
      server.noRoom = 'account_limit';
      expect((await a.round(server)).waitingForRoom, 1);
      server.noRoom = null;
      final body = a.bodyOf('R2');
      await server.putBodies([(name: syncObjectName(utf8.encode(body)), body: body)]);
      final outcome = await a.round(server);
      expect(outcome.end, SyncRoundEnd.done);
      expect(outcome.waitingForRoom, 1);
      expect(onServer().rows.keys, isNot(contains('R2')));
      expect(onServer().cells[('memo/m1', 'R2')], isNull);
    });

    // T2b-7b: what a round of the device keeps is of the account it ran as, and the switch of sync is turned on for one
    // (S-08, [N1-22]); a write the storage quota refuses (C2); and the close of the desktop app (G311, A106).
    group('the account, the storage quota and the close of the app', () {
      late FakeSyncServer other;

      setUp(() {
        other = FakeSyncServer();
        a.auth = FakeShareAuth();
      });

      test('[N1-22] (D-30): logged out and in to another account, the device meets it as an account it holds no base '
          'of — the base of the account before is not read, and its mark of being stopped for room is down', () async {
        await a.login(syncTestAccount);
        seedUmas(a, ['R1']);
        await a.setSyncOn(true);
        expect((await a.roundAsAsked(server))?.end, SyncRoundEnd.done);
        a.close();
        a.seedRecord('R2', binding: own('R2'), bodyWrittenAt: 1767225600200, fans: 2000);
        server.noRoom = 'account_limit';
        expect((await a.roundAsAsked(server))?.waitingForRoom, 1, reason: 'R2 waits for room, and the mark is up');

        await a.logout();
        await a.login('account-2');
        await a.setSyncOn(true);
        final met = await a.roundAsAsked(other);
        expect(
          (met?.end, met?.added, met?.waitingForRoom),
          (SyncRoundEnd.done, 2, 0),
          reason: 'R1 and R2, which only the device held, are kept as a round with no base keeps them, and R2 is put',
        );
        expect(syncListOfParts(other.currentParts()).rows.keys.toSet(), {'R1', 'R2'});
        expect((await listOf(a)).rows.keys.toSet(), {'R1', 'R2'});
      });

      test(
        'S-08 (G323): the switch of sync is on for the account it was turned on under: logged in to another, the '
        'device runs no round until the user turns sync on for it; logged in to that account again, it runs',
        () async {
          await a.login(syncTestAccount);
          seedUmas(a, ['R1']);
          await a.setSyncOn(true);
          expect((await a.roundAsAsked(server))?.end, SyncRoundEnd.done);

          await a.logout();
          await a.login('account-2');
          final counted = _CountedServer(other);
          expect(
            await a.roundAsAsked(counted),
            isNull,
            reason: 'no screen told the user of a first round of account-2',
          );
          expect(counted.calls, 0);

          await a.logout();
          await a.login(syncTestAccount);
          expect((await a.roundAsAsked(server))?.end, SyncRoundEnd.done, reason: 'sync was turned on for this account');
        },
      );

      // T3a2 (L-4, V4): the counts a round tells ([R3-5]) stay where the device shows them (S-08) through the rounds that
      // tell none, for the account they are of.
      test('T3a2 (C1 i): a round that tells no counts leaves the counts the one before told, which are shown for their '
          'account alone and go once sync is turned on for another', () async {
        seedUmas(b, ['R2']);
        await b.round(server);
        await a.login(syncTestAccount);
        seedUmas(a, ['R1']);
        await a.setSyncOn(true);
        final app = await a.open();
        RecordSyncState state() => app.read(recordSyncProvider);
        const counts = SyncToldCounts(account: syncTestAccount, restored: 0, splitOff: 0, added: 2);

        expect((await a.roundAsAsked(server))?.added, 2, reason: 'R1 and R2, which one side alone held');
        final none = await a.roundAsAsked(server);
        expect((none?.end, none?.added), (SyncRoundEnd.done, 0));
        expect(state().countsFor(syncTestAccount), counts, reason: 'a round that told none');

        await a.logout();
        await a.login('account-2');
        expect(state().countsFor('account-2'), isNull, reason: 'sync is not on for account-2');
        await a.logout();
        await a.login(syncTestAccount);
        expect(state().countsFor(syncTestAccount), counts, reason: 'the switch is on for this account still (V1)');

        await a.logout();
        await a.login('account-2');
        await a.setSyncOn(true);
        expect(state().counts, isNull, reason: 'sync is on for another account');
      });

      // T-S401: the owner of the session is [RecordShareSession]; a sync request's 401 and 409 account_deleting reach
      // it as a sharing request's do.
      ResponseBody refused(int status, String error) => ResponseBody.fromString(
        jsonEncode({'error': error}),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );

      test('T-S401 (i): a sync request answered 401 drops the session, and the device holds no sync server until '
          'the user logs in again', () async {
        a.syncHttp = _Canned(() => refused(401, 'session_required'));
        await a.login(syncTestAccount);
        await a.round(await a.overHttp());
        final app = await a.open();
        expect(app.read(recordShareSessionProvider), isNull);
        expect(app.read(syncServerProvider), isNull);
        expect(app.read(recordShareSessionDroppedProvider), isTrue, reason: 'T3a2 (C1 ii): the server dropped it');
      });

      test('T-S401 (ii): a sync request answered 409 account_deleting marks the session as deleting', () async {
        a.syncHttp = _Canned(() => refused(409, 'account_deleting'));
        await a.login(syncTestAccount);
        await a.round(await a.overHttp());
        final app = await a.open();
        expect(app.read(recordShareSessionProvider)?.deleting, isTrue);
        expect(app.read(syncServerProvider), isNull, reason: 'a deleting session syncs nothing');
      });

      test('T-S401 (iii): a 401 under the token of a session before logging in again leaves the new session', () async {
        final gate = Completer<void>();
        a.syncHttp = _Canned(() => refused(401, 'session_required'), gate: gate.future);
        await a.login(syncTestAccount);
        final pending = a.round(await a.overHttp());
        await a.logout();
        await a.login('account-2');
        gate.complete();
        await pending;
        expect((await a.open()).read(recordShareSessionProvider)?.token, 'token-account-2');
      });

      test('C2 (web): a write of the result that the storage quota refuses ends the round with the base where it was, '
          'and the next round puts the result in place', () async {
        final original = fsBackend;
        final web = WebLikeFsBackend(original);
        fsBackend = web;
        addTearDown(() => fsBackend = original);
        seedUmas(a, ['R1']);
        await a.round(server);
        seedUmas(b, ['R2']);
        await b.round(server);
        final baseFile = File(syncBaseFile(a.info).path);
        final before = baseFile.readAsBytesSync();

        final ofR2 = SyncStopFsBackend.recordsOf({'R2'});
        web.refuseWrite = (path) => ofR2(path) == null ? null : const QuotaExceededError();
        final refused = await a.round(server);
        expect(refused.end, SyncRoundEnd.failed);
        expect(baseFile.readAsBytesSync(), before, reason: 'the base does not move past what was not put in place');
        expect((await listOf(a)).rows.keys.toSet(), {'R1'});

        web.refuseWrite = null;
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect((await listOf(a)).rows.keys.toSet(), {'R1', 'R2'});
        expect(baseFile.readAsBytesSync(), isNot(before));
      });

      test('G311 (A106): the close of the desktop app waits until the round running has put its result in place and '
          'kept its base, and not for the list it sends after; once the app closes, no round puts a result in '
          'place', () async {
        seedUmas(a, ['R1']);
        a.seedColumn('memo', 'm1', title: 'Note');
        await a.round(server);
        seedUmas(b, ['R2']);
        await b.round(server);
        await writeMemo(a, 'R1', 'mine');
        final baseFile = File(syncBaseFile(a.info).path);
        final before = baseFile.readAsBytesSync();
        final generation = server.generation;

        // A's round is held at the first write of R2, which it puts in place, and then at the replacement it makes.
        final replacing = Completer<void>();
        final replace = Completer<void>();
        addTearDown(() => replace.isCompleted ? null : replace.complete());
        server.beforeReplace = () async {
          server.beforeReplace = null;
          replacing.complete();
          await replace.future;
        };
        final original = fsBackend;
        final hold = SyncStopFsBackend(original, markOf: SyncStopFsBackend.recordsOf({'R2'}));
        fsBackend = hold;
        addTearDown(() => fsBackend = original);
        final round = a.round(server);
        await hold.held;
        final exit = (await a.open()).read(appExitRequestsProvider.notifier).request();
        final atExit = exit.then((_) => (base: baseFile.readAsBytesSync(), generation: server.generation));
        hold.go();
        final first = await Future.any([
          atExit.then((_) => 'the close'),
          replacing.future.then((_) => 'the replacement'),
        ]);
        expect(first, 'the close', reason: 'the close does not wait for the list the round sends after its base');
        final (:base, generation: replaced) = await atExit;
        expect(base, isNot(before), reason: 'the close waited until the round kept its base');
        expect(replaced, generation);
        replace.complete();
        expect((await round).end, SyncRoundEnd.done);
        expect((await listOf(a)).rows.keys.toSet(), {'R1', 'R2'});

        await deleteRecords(b, {'R2'});
        await b.round(server);
        final kept = baseFile.readAsBytesSync();
        final closing = await a.round(server);
        expect(closing.end, SyncRoundEnd.closing);
        expect((await listOf(a)).rows.keys.toSet(), {'R1', 'R2'}, reason: 'the delete of B is not put in place');
        expect(baseFile.readAsBytesSync(), kept);
      });
    });

    test('S-13 (G249): after a round that puts a record in place, the resolution runs once and places the parent of a '
        'record whose slot it finds empty, moving no time', () async {
      a.seedRecord('P', binding: own('P'), bodyWrittenAt: 1767225600200, parentOfTheOthers: true);
      await a.round(server);
      seedUmas(b, ['R1']);

      expect((await b.round(server)).end, SyncRoundEnd.done);
      final container = await b.open();
      final r1 = container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: 'R1')!;
      expect(r1.metadata.recordId.parent1, 'P', reason: 'the resolution placed the parent the round put in place');
      expect((await listOf(b)).rows['R1']!.record.body.time, 1767225600100, reason: 'placing it moves no time');
      expect(onServer().rows['R1']!.record.body.parents, isEmpty, reason: 'a parent placed is not sent by itself');
    });

    test('[R7-3] (G314): a round that stops at a write tells the removals the quarantine shelf withholds from the '
        'server, as a round that runs does, and the app keeps them with what the round told', () async {
      seedUmas(a, ['R1', 'R2', 'R3']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.setSyncOn(true);
      await a.roundAsAsked(server);
      await b.round(server);
      await writeMemo(b, 'R3', 'theirs');
      await b.round(server);
      clockAt(hour(9));
      await a.merge('R1', 'R2', keep: 'R2');
      await a.breakRecord('R1');

      // A's round puts B's memo in place first, and that write fails.
      a.close();
      a.beforeMetadataWrite = (path) async {
        if (path.name == 'm1.json') throw const FileSystemException('the memo storage could not be written');
      };
      final stopped = await a.roundAsAsked(server);
      expect((stopped?.end, stopped?.withheld), (SyncRoundEnd.failed, 1), reason: 'R2, which the shelf may hold');
      expect((await a.open()).read(recordSyncProvider).told, same(stopped));
    });

    test('[R5-4]: of two of the device\'s records split off to one id, the memo written later stands, whichever '
        'record holds the cell first', () async {
      // X=A1, Y=B2, Z=C3, U=D4, W=E5, V=F6. A holds two records made of [B2] — A1 and the one split off it — and
      // both are split off to one id.
      final s1 = recordSyncSplitId('A1', {'B2'});
      final s2 = recordSyncSplitId(s1, {'B2'});
      seedUmas(a, ['A1', 'B2', 'C3', 'D4', 'E5', 'F6']);
      a.seedColumn('memo', 'm1', title: 'Note');
      await a.round(server);
      await b.round(server);
      await a.merge('A1', 'B2', keep: 'A1');
      final zx = await a.exportZip('A1');
      await b.merge('A1', 'C3', keep: 'A1');
      await b.round(server);
      expect((await a.round(server)).splitOff, 1);
      final zs = await a.exportZip(s1);
      await a.merge(s1, 'E5', keep: s1);
      await a.round(server);
      await b.round(server);
      await b.merge(s1, 'F6', keep: s1);
      await b.merge('A1', 'D4', keep: 'A1');
      await b.round(server);
      await a.importZip(zx);
      await a.importZip(zs);
      // A1's cell is written first, so it is first in the device's cells, and written again last.
      for (final (i, (id, memo)) in [('A1', 'first'), (s1, 'middle'), ('A1', 'last')].indexed) {
        clockAt(hour(9 + i));
        await writeMemo(a, id, memo);
      }
      final before = (await listOf(a)).rows.keys.toSet();
      expect((await a.round(server)).splitOff, 1, reason: 'one record is placed under a new id');
      expect((await listOf(a)).rows.keys.toSet().difference(before), {s2});
      await b.round(server);
      await a.round(server);
      for (final list in await allLists()) {
        expect(list.cells[('memo/m1', s2)], SyncValue<String?>(jsonEncode('last'), hour(11)));
      }
    });

    test(
      '[R4-1]: a record split off to an id whose record is gone does not bring back the memo written on it',
      () async {
        final s1 = recordSyncSplitId('A1', {'B2'});
        seedUmas(a, ['A1', 'B2', 'C3', 'D4', 'F6']);
        a.seedColumn('memo', 'm1', title: 'Note');
        await a.round(server);
        await b.round(server);
        await a.merge('A1', 'B2', keep: 'A1');
        final zx = await a.exportZip('A1');
        await b.merge('A1', 'C3', keep: 'A1');
        await b.round(server);
        expect((await a.round(server)).splitOff, 1);
        await b.round(server);
        await b.merge(s1, 'F6', keep: s1);
        clockAt(hour(9));
        await writeMemo(b, s1, 'of the record deleted');
        await b.round(server);
        await a.round(server);
        await b.merge('A1', 'D4', keep: 'A1');
        await b.round(server);
        // A deletes the record B wrote on, and takes in the zip of A1 as it was before the split.
        await deleteRecords(a, {s1});
        await a.importZip(zx);
        await a.round(server);
        await b.round(server);
        await a.round(server);
        for (final list in await allLists()) {
          expect(list.rows.keys, contains(s1));
          expect(list.cells[('memo/m1', s1)], isNull);
        }
      },
    );

    group('a list more than one replacement takes, and a first round in parts (G142, G134)', () {
      // The fake server takes as many slots of the root in one replacement as the Worker does
      // ([FakeSyncServer.partsLimit]), so a round sends a list that changes more in several, each an operation whole. A
      // device holding records from before the binding works their bindings out a part at a time, each record under its
      // own lock, and sends a part once it is worked out.

      /// The ids of [n] records from before the binding, `L0001`….
      List<String> legacyIds(int n) => [for (var i = 1; i <= n; i++) 'L${'$i'.padLeft(4, '0')}'];

      /// The record [id] of [legacyIds] from before the binding on [device], a body and a skill image of its own.
      void seedLegacyRecord(SyncTestDevice device, String id) {
        final i = int.parse(id.substring(1));
        final dir = device.seedRecord(id, bodyWrittenAt: 1767225600100 + i, fans: 1000 + i);
        File(dir.filePath('skill.png').path).writeAsBytesSync(utf8.encode('the skill image of $id'));
      }

      /// [n] records from before the binding on [device] ([seedLegacyRecord]), and a memo of the first.
      void seedLegacy(SyncTestDevice device, int n) {
        for (final id in legacyIds(n)) {
          seedLegacyRecord(device, id);
        }
        device.seedColumn('memo', 'm2', title: 'Kept', data: {'L0001': 'mine'}, writtenAt: {'L0001': 1767225600050});
      }

      /// A first round of a device holding [n] records from before the binding, against a server another device put
      /// its records on, the bindings worked out [bindingChunk] at a time: what the server, the two devices (the other
      /// after a round of its own) and the device's base end with, the lists the server held as each replacement was
      /// asked for, and what the round told. Where [stopAt] names a record, the app stops at the work on that record's
      /// binding and opens again with nothing changed meanwhile, and the next round goes on: it tells nothing, the
      /// stopped round having told nothing. Where [theOtherHolds] names one of the records, the other device holds it
      /// as well, as a zip took it there, and put it on the server with a memo of its own.
      Future<({List<String> end, List<Set<String>> asked, SyncRoundOutcome? told})> firstRound(
        int n, {
        required int bindingChunk,
        String? stopAt,
        String? theOtherHolds,
      }) async {
        final (x, y, there) = (SyncTestDevice('x'), SyncTestDevice('y'), FakeSyncServer());
        addTearDown(x.dispose);
        addTearDown(y.dispose);
        seed(y);
        if (theOtherHolds != null) {
          seedLegacyRecord(y, theOtherHolds);
          y.seedColumn(
            'memo',
            'm3',
            title: 'Theirs',
            data: {theOtherHolds: 'theirs'},
            writtenAt: {theOtherHolds: 1767225600060},
          );
        }
        expect((await y.round(there)).end, SyncRoundEnd.done);
        seedLegacy(x, n);
        final asked = <Set<String>>[];
        there.beforeReplace = () async =>
            asked.add({...syncListOfParts(there.currentParts()).rows.keys.where((id) => id.startsWith('L'))});
        SyncRoundOutcome? told;
        if (stopAt == null) {
          told = await x.round(there, bindingChunk: bindingChunk);
          expect(told.end, SyncRoundEnd.done);
        } else {
          final stop = SyncStopFsBackend(fsBackend, markOf: SyncStopFsBackend.recordsOf({stopAt}));
          await stoppedRound(x, there, stop, bindingChunk: bindingChunk);
          final listed = syncListOfParts(there.currentParts()).rows.keys.where((id) => id.startsWith('L')).length;
          expect(listed, inExclusiveRange(0, n), reason: 'the app stopped with a part sent and a part not');
          expect(SyncKeptList.decode(File(syncBaseFile(x.info).path).readAsBytesSync()).pending, isNotEmpty);
          expect((await x.round(there, bindingChunk: bindingChunk)).end, SyncRoundEnd.done);
        }
        there.beforeReplace = null;
        expect((await y.round(there)).end, SyncRoundEnd.done);
        final base = SyncKeptList.decode(File(syncBaseFile(x.info).path).readAsBytesSync());
        return (
          end: [
            'server',
            ..._describe(syncListOfParts(there.currentParts())),
            'device',
            ..._describe((await x.read()).list),
            'other',
            ..._describe((await y.read()).list),
            'base',
            ..._describe(base.list),
            'pending ${base.pending}',
          ],
          asked: asked,
          told: told,
        );
      }

      test('G134: a first round that works the bindings out in parts ends as one that works them all out first: the '
          'records, the base and what it tells', () async {
        final whole = await firstRound(20, bindingChunk: 20);
        final parts = await firstRound(20, bindingChunk: 4);
        // A part ends where a record part of the list ends: as each replacement was asked for, the server held every
        // record of the record parts it had reached, and none of a record part after them.
        final sent = parts.asked.where((ids) => ids.isNotEmpty && ids.length < 20).toList();
        expect(sent, isNotEmpty, reason: 'a part was sent before the next was worked out');
        for (final ids in sent) {
          final reached = ids.map(syncRecordPartOf).reduce(max);
          expect(ids, {...legacyIds(20).where((id) => syncRecordPartOf(id) <= reached)});
        }
        expect(parts.end, whole.end);
        expect(parts.end, contains('pending {}'));
        String told(SyncRoundOutcome? o) => '${o?.end} restored ${o?.restored} split ${o?.splitOff} added ${o?.added}';
        expect(told(parts.told), told(whole.told));
        expect(whole.told?.added, 23, reason: 'the twenty it sends and the three it takes in');
      });

      test('G134: a first round stopped part way, opened again with nothing changed, goes on with the next part and '
          'ends as one that was not stopped', () async {
        final whole = await firstRound(20, bindingChunk: 20);
        final stopped = await firstRound(20, bindingChunk: 4, stopAt: 'L0005');
        expect(stopped.end, whole.end);
      });

      test('G254: a record the other device put on the server with a memo, which the device holds from before the '
          'binding, keeps the memo through a first round stopped before it and opened again: the base had no word on '
          'it', () async {
        // The last of the twenty in record-part order, so the round stopped at L0005 has not reached it.
        final last = legacyIds(20).reduce((a, b) => syncRecordPartOf(a) >= syncRecordPartOf(b) ? a : b);
        final whole = await firstRound(20, bindingChunk: 20, theOtherHolds: last);
        expect(whole.end, anyElement(contains('theirs')), reason: 'the memo stays');
        final stopped = await firstRound(20, bindingChunk: 4, stopAt: 'L0005', theOtherHolds: last);
        expect(stopped.end, whole.end);
      });

      test('G254: a first round with a record from before the binding whose record.json cannot be read ends, the '
          'record on the quarantine shelf and not on the server', () async {
        final (x, there) = (SyncTestDevice('x'), FakeSyncServer());
        addTearDown(x.dispose);
        seedLegacy(x, 6);
        // Held in memory without a binding, and not readable on the disk once the round works its binding out.
        await x.open();
        final file = File((x.charaDetail / 'active' / 'L0002').filePath('record.json').path);
        file.writeAsStringSync('{not a record');
        expect((await x.round(there, bindingChunk: 2)).end, SyncRoundEnd.done);
        expect(syncListOfParts(there.currentParts()).rows.keys, unorderedEquals(legacyIds(6).toSet()..remove('L0002')));
        final shelf = await readQuarantineLedger(x.info.charaDetailQuarantineDir);
        expect([for (final record in shelf.kept) record.id], ['L0002']);
      });

      test('[G240]: a record the user recognises again while a round works out the binding of another is written at '
          'once, not once the round has worked out every binding', () async {
        seedLegacy(a, 3);
        final gate = SyncBindingGateFsBackend({'L0001'});
        final original = fsBackend;
        fsBackend = gate;
        addTearDown(() {
          gate.goAll();
          fsBackend = original;
        });
        final round = a.round(server);
        await gate.entered('L0001');
        // Written under the lock of L0003 alone, while the work on L0001's binding is held.
        await a.recognizeAgain('L0003', (result) => result['fans'] = 7);
        gate.go('L0001');
        expect((await round).end, SyncRoundEnd.done);
        final record = CharaDetailRecord.fromRecordJson(
          File((a.charaDetail / 'active' / 'L0003').filePath('record.json').path).readAsStringSync(),
        );
        expect(record.fans, 7);
        expect(_describe(onServer()), _describe(await listOf(a)));
      });

      /// Ids `R1`… on as many record parts of the root, [n] of them.
      List<String> apart(int n) {
        final ids = <String>[];
        final parts = <int>{};
        for (var i = 1; ids.length < n; i++) {
          if (parts.add(syncRecordPartOf('R$i'))) ids.add('R$i');
        }
        return ids;
      }

      test('a list that changes many record parts goes in as few replacements as their slots allow: the records of one '
          'record part go together, whatever their ids', () async {
        // Ids `R1`… on eight record parts of the root, two on each; in the order of their ids the parts come and go.
        final byPart = <int, List<String>>{};
        for (var i = 1; byPart.length < 8 || byPart.values.any((ids) => ids.length < 2); i++) {
          final part = syncRecordPartOf('R$i');
          final ids = byPart[part] ?? (byPart.length < 8 ? byPart[part] = [] : null);
          if (ids != null && ids.length < 2) ids.add('R$i');
        }
        seedUmas(a, [for (final ids in byPart.values) ...ids]);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(server.slotsChanged, [4, 4]);
        expect(_describe(onServer()), _describe(await listOf(a)));
      });

      test('a replacement the server refuses for the requests to the bucket it takes goes again with half as many '
          'slots, down to one; refused at one, the round stops and the next sends it', () async {
        final ids = apart(6);
        seedUmas(a, ids);
        final asked = <int>[];
        server.tooManyObjects = (slots) {
          asked.add(slots);
          return true;
        };
        expect((await a.round(server)).end, SyncRoundEnd.refused);
        expect(asked, [4, 2, 1]);
        expect(onServer().rows, isEmpty);

        asked.clear();
        server.tooManyObjects = (slots) {
          asked.add(slots);
          return slots > 1;
        };
        expect((await a.round(server)).end, SyncRoundEnd.done);
        expect(asked.take(3), [4, 2, 1]);
        expect(server.slotsChanged, everyElement(1));
        expect(_describe(onServer()), _describe(await listOf(a)));
      });

      test('F2: a replacement of one slot the server refuses for the requests to the bucket it takes is not asked for '
          'again, though it carries two operations: the round stops', () async {
        final part = syncRecordPartOf('R1');
        var other = 2;
        while (syncRecordPartOf('R$other') != part) {
          other++;
        }
        final ids = ['R1', 'R$other'];
        seedUmas(a, ids);
        final asked = <int>[];
        server.tooManyObjects = (slots) {
          asked.add(slots);
          return asked.length < 10;
        };
        expect((await a.round(server)).end, SyncRoundEnd.refused);
        expect(asked, [1]);
        expect(onServer().rows, isEmpty);
      });

      test('G142: a merge whose records fill more slots than one replacement takes is not split: the round stops, and '
          'the device, its base and the server stay as they were', () async {
        final ids = apart(5);
        seedUmas(a, ids);
        expect((await a.round(server)).end, SyncRoundEnd.done);
        for (final id in ids.skip(1)) {
          await a.merge(ids.first, id, keep: ids.first);
        }
        final base = File(syncBaseFile(a.info).path).readAsBytesSync();
        final before = _describe(await listOf(a));
        final (generation, held) = (server.generation, _describe(onServer()));

        expect((await a.round(server)).end, SyncRoundEnd.operationTooLarge);
        expect(File(syncBaseFile(a.info).path).readAsBytesSync(), base);
        expect(File(syncSentFile(a.info).path).existsSync(), isFalse);
        expect(_describe(await listOf(a)), before);
        expect(server.generation, generation);
        expect(_describe(onServer()), held);
      });
    });
  });

  // T2b-8 (C1 ii): what each answer of a sync endpoint other than a success means as the app's server over HTTP
  // ([HttpSyncServer]) reads it — the refusals as the fake throws them (the seconds of a day's limit, the generation of
  // a stale replacement, the slots of a replacement that changes too many), and an answer that does not tell whether
  // the server acted as one whose answer did not arrive, as the fake's dropped connection is.
  group('the server over HTTP', () {
    HttpSyncServer answering(ResponseBody Function() answer) => HttpSyncServer(
      Dio()..httpClientAdapter = _Canned(answer),
      origin: 'https://umacapture.com',
      token: 'token',
      timeout: const Duration(minutes: 15),
      onAnswer: (_, _, _) async {},
    );
    ResponseBody json(int status, Map<String, Object?> body, [Map<String, String> headers = const {}]) =>
        ResponseBody.fromString(
          jsonEncode(body),
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
            for (final MapEntry(:key, :value) in headers.entries) key: [value],
          },
        );
    TypeMatcher<SyncRefusal> refusal(int status, String error, [Object? detail]) => isA<SyncRefusal>()
        .having((r) => r.status, 'status', status)
        .having((r) => r.error, 'error', error)
        .having((r) => r.detail, 'detail', detail);
    final name = _hex(1);
    final lost = isA<SyncAnswerLost>();

    test('each refusal is the refusal the fake throws, and an answer that does not tell whether the server acted is '
        'one whose answer did not arrive', () async {
      final body = [(name: name, body: '{}')];
      final png = Uint8List.fromList([1, 2, 3]);
      final cases = <(String, Future<Object?> Function(HttpSyncServer), ResponseBody Function(), Matcher)>[
        (
          'a body put refused for the account\'s bytes',
          (s) => s.putBodies(body),
          () => json(507, {'error': 'account_limit', 'limit': 'bytes'}),
          refusal(507, 'account_limit', 'bytes'),
        ),
        (
          'a body put refused for the database\'s room',
          (s) => s.putBodies(body),
          () => json(507, {'error': 'database_full'}),
          refusal(507, 'database_full'),
        ),
        (
          'a body put refused for the day',
          (s) => s.putBodies(body),
          () => json(429, {'error': 'daily_limit', 'scope': 'account'}, {'retry-after': '3600'}),
          refusal(429, 'daily_limit', 3600),
        ),
        (
          'a replacement refused as stale',
          (s) => s.replaceRoot(3, name, '{}'),
          () => json(409, {'error': 'stale_generation', 'generation': 7}),
          refusal(409, 'stale_generation', 7).having((r) => r.isStaleGeneration, 'stale', isTrue),
        ),
        (
          'a replacement refused for its slots',
          (s) => s.replaceRoot(3, name, '{}'),
          () => json(400, {'error': 'too_many_parts', 'limit': 4}),
          isA<SyncRefusal>().having((r) => r.partsLimit, 'slots', 4),
        ),
        (
          'a replacement refused for the requests to the bucket',
          (s) => s.replaceRoot(3, name, '{}'),
          () => json(409, {'error': 'too_many_objects'}),
          isA<SyncRefusal>().having((r) => r.isTooManyObjects, 'too many objects', isTrue),
        ),
        (
          'a replacement naming parts the account does not hold',
          (s) => s.replaceRoot(3, name, '{}'),
          () => json(409, {
            'error': 'missing_objects',
            'names': [name],
          }),
          refusal(409, 'missing_objects', [name]),
        ),
        (
          'a replacement stopped after its commit (503)',
          (s) => s.replaceRoot(3, name, '{}'),
          () => json(503, {'error': 'temporarily_unavailable'}),
          lost,
        ),
        (
          'a replacement stopped after its commit (502)',
          (s) => s.replaceRoot(3, name, '{}'),
          () => json(502, {'error': 'storage_unavailable'}),
          lost,
        ),
        (
          'bodies the server does not hold',
          (s) => s.bodies([name]),
          () => json(404, {
            'error': 'not_found',
            'names': [name],
          }),
          refusal(404, 'not_found', [name]),
        ),
        (
          'a root the server does not hold',
          (s) => s.root(name),
          () => json(404, {'error': 'not_found'}),
          refusal(404, 'not_found'),
        ),
        (
          'a malformed part',
          (s) => s.putPart(name, '{}'),
          () => json(400, {'error': 'invalid_payload', 'field': 'part.records[0].id'}),
          refusal(400, 'invalid_payload', 'part.records[0].id'),
        ),
        (
          'no session',
          (s) => s.readGeneration(),
          () => json(401, {'error': 'session_required'}),
          refusal(401, 'session_required'),
        ),
        (
          'an account being deleted',
          (s) => s.readGeneration(),
          () => json(409, {'error': 'account_deleting'}),
          refusal(409, 'account_deleting'),
        ),
        (
          'sync switched off',
          (s) => s.imageForm(),
          () => json(503, {'error': 'sync_paused'}),
          refusal(503, 'sync_paused'),
        ),
        (
          'an image the form refuses',
          (s) => s.putImage(name, png, jpeg: false),
          () => json(409, {'error': 'images_not_synced'}),
          refusal(409, 'images_not_synced'),
        ),
        (
          'an image the bucket refuses',
          (s) => s.putImage(name, png, jpeg: false),
          () => json(502, {'error': 'storage_refused'}),
          refusal(502, 'storage_refused'),
        ),
        (
          'an image refused for the hidden bytes',
          (s) => s.putImage(name, png, jpeg: true),
          () => json(507, {'error': 'hidden_limit'}, {'retry-after': '60'}),
          refusal(507, 'hidden_limit', 60),
        ),
        (
          'a proxy\'s answer',
          (s) => s.readGeneration(),
          () => ResponseBody.fromString('<html>bad gateway</html>', 502),
          lost,
        ),
        (
          'a success the app cannot read',
          (s) => s.held([name]),
          () => ResponseBody.fromString('{"held": 1}', 200),
          lost,
        ),
        (
          'a connection that drops',
          (s) => s.readGeneration(),
          () => throw const SocketException('dropped'),
          isA<DioException>(),
        ),
      ];
      for (final (what, call, answer, matcher) in cases) {
        await expectLater(call(answering(answer)), throwsA(matcher), reason: what);
      }
      expect(await answering(() => json(404, {'error': 'not_found'})).image(name), isNull, reason: 'an image not held');
    });
  });
}

/// An HTTP adapter answering every request with what [answer] makes, or failing as it throws.
class _Canned implements HttpClientAdapter {
  _Canned(this.answer, {this.gate});

  final ResponseBody Function() answer;

  /// Awaited before each answer: a gate the test holds.
  final Future<void>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    await gate;
    return answer();
  }

  @override
  void close({bool force = false}) {}
}

/// One side of a second pair the merge offers, shaped as [preRecord] and [postRecord] are, on a card no other record
/// of these cases holds.
CharaDetailRecord _pairRecord(String id, {required int stars, required int whiteCount, required String capturedDate}) =>
    makeRecord(
      id: id,
      card: 8,
      self: [...coloured(stars, stars, stars), ...whites(whiteCount)],
      capturedDate: capturedDate,
    );

/// The io backend, refusing the deletes [refuse] picks, as for a file another program holds open.
class _RefusingIoFsBackend extends IoFsBackend {
  const _RefusingIoFsBackend(this.refuse);

  final bool Function(String path) refuse;

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    if (refuse(path)) {
      throw FileSystemException('The process cannot access the file because it is being used', path);
    }
    return super.delete(path, recursive: recursive);
  }
}
