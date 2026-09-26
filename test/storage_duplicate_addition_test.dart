// The store's duplicate verdict must not depend on the order its records happen
// to be listed in, and a rejection must never delete a record the store holds.
//
// A store can end up holding one chara twice: a record the scan could not open is
// in neither candidate set, so a re-capture of that trainee is admitted as new
// (CharaDetailRecordStorage._warnIfCandidateSetIncomplete says so in as many
// words). Re-adding a record under one of that pair's ids is answered against
// every record the store holds, not against whichever of the two the directory
// scan reached first, so the verdict is the same in either order and a rejection
// leaves the stored record's own directory where it is.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_duplicate_addition_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/records.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  late Directory tempRoot;
  setUp(() => tempRoot = Directory.systemTemp.createTempSync('uma_dup_add'));
  tearDown(() => tempRoot.deleteSync(recursive: true));

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  // Writes [record] as record.json under [storeDir]/<id>, as the recognizer would.
  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  ProviderContainer makeContainer(DirectoryPath root) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        // Skip the (network/version) module check so build() returns immediately.
        moduleVersionLoader.overrideWith((ref) async => null),
        // The accepting branch of add() ends in this preference. Its shipped
        // notifier reads the settings box, which no test has; answering "none"
        // keeps the branch running to its end without one.
        autoCopyClipboardStateProvider.overrideWith(
          () => ExclusiveItemsNotifier<CharaDetailRecordImageMode>(
            values: CharaDetailRecordImageMode.values,
            defaultValue: CharaDetailRecordImageMode.none,
            entryKey: null,
          ),
        ),
      ],
    );
  }

  CharaDetailRecord twinContent(String id) => makeRecord(id: id, card: 77, self: const [Factor(9, 3)]);

  // Seeds a store already holding one chara twice, then re-adds the record stored
  // under [reAddedId] through both duplicate entrances and reports what happened.
  // The re-added contents are the other stored record's too, so both entrances
  // refuse the replacement -- and the capture one must not take the stored
  // record's directory with it.
  //
  // [firstSeeded] and the id re-added are varied by the callers so the pair is
  // presented to the scan both ways round.
  Future<void> expectKnownIdDuplicateIsRefusedInPlace({required String firstSeeded, required String reAddedId}) async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;
    final secondSeeded = firstSeeded == 'aaa' ? 'bbb' : 'aaa';

    writeRecord(activeDir, twinContent(firstSeeded));
    writeRecord(activeDir, twinContent(secondSeeded));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    expect(active.length, 2, reason: 'precondition: the store holds the same chara twice');

    final incoming = twinContent(reAddedId);

    // The capture entrance. Its verdict shows in the capture state, and a
    // rejection takes the directory named by the incoming id with it -- which
    // here is the stored record's own. That loss is asserted first, because it is
    // the one that costs the user something no later step can give back.
    final recordDir = activeDir / reAddedId;
    expect(recordDir.existsSync(), isTrue, reason: 'precondition');
    container.read(charaDetailCaptureStateProvider.notifier).started(reAddedId);
    final duplicateEvents = <int>[];
    final subscription = container.listen(
      duplicatedCharaEventProvider,
      (_, next) => next.whenData(duplicateEvents.add),
    );
    addTearDown(subscription.close);

    active.add(incoming);
    await Future<void>.delayed(Duration.zero);

    expect(recordDir.existsSync(), isTrue, reason: 're-adding a known id must not delete that stored record');
    expect(container.read(charaDetailCaptureStateProvider).error, 'duplicated_character');
    expect(duplicateEvents, hasLength(1));
    expect(active.length, 2, reason: 'the refused replacement neither adds nor drops a row');

    // The import entrance, asked the same question about the same store.
    expect(
      active.duplicateCharaIdOf(incoming),
      reAddedId == 'aaa' ? 'bbb' : 'aaa',
      reason: 'a replacement is weighed against every other record, whichever twin the scan lists first',
    );
  }

  test('re-adding a known id as a copy of another record is refused in place when its twin is listed first', () async {
    await expectKnownIdDuplicateIsRefusedInPlace(firstSeeded: 'aaa', reAddedId: 'bbb');
  });

  test('re-adding a known id as a copy of another record is refused in place when it is itself listed first', () async {
    await expectKnownIdDuplicateIsRefusedInPlace(firstSeeded: 'aaa', reAddedId: 'aaa');
  });

  test('both entrances still refuse a fresh id whose contents the store holds', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;

    writeRecord(activeDir, twinContent('aaa'));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    // Counterpart of the two tests above: the same content under an id the store
    // does not hold is refused too, and here the arrival's own directory is the
    // one dropped -- so those tests keep a directory because of the id rule and
    // not because a rejection never drops one.
    final incoming = twinContent('ccc');
    expect(active.duplicateCharaIdOf(incoming), 'aaa');

    writeRecord(activeDir, incoming); // the recognizer drops the dir before add()
    container.read(charaDetailCaptureStateProvider.notifier).started('ccc');

    active.add(incoming);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(charaDetailCaptureStateProvider).error, 'duplicated_character');
    expect((activeDir / 'ccc').existsSync(), isFalse, reason: 'the rejected arrival is the one that is dropped');
    expect((activeDir / 'aaa').existsSync(), isTrue, reason: 'the record it duplicates is untouched');
    expect(active.length, 1);
  });

  group('duplicateCharaIdIn', () {
    final self = makeRecord(id: 'self', card: 77, self: const [Factor(9, 3)]);
    final other = makeRecord(id: 'other', card: 77, self: const [Factor(9, 3)]);
    final orders = {
      'self first': [self, other],
      'twin first': [other, self],
    };

    for (final order in orders.entries) {
      // A known id replaces its record, but the replacement is still weighed against every
      // *other* record: here each id's new contents are the other one's, so each is refused.
      test('names the other record a replacement would duplicate, ${order.key}', () {
        expect(duplicateCharaIdIn(order.value, twinContent('self')), 'other');
        expect(duplicateCharaIdIn(order.value, twinContent('other')), 'self');
      });

      // Negative control: the same pair, the same order, and only the incoming id
      // is one the set does not hold.
      test('still names a duplicate held under another id, ${order.key}', () {
        expect(duplicateCharaIdIn(order.value, twinContent('fresh')), isNotNull);
      });
    }

    // Negative control: a record replaced by its own contents duplicates nothing -- the record
    // it replaces is left out by id, whatever else the set holds.
    test('answers a replacement by its own contents with no duplicate', () {
      final third = makeRecord(id: 'third', card: 88, self: const [Factor(4, 1)]);
      for (final order in orders.values) {
        expect(
          duplicateCharaIdIn([...order, third], makeRecord(id: 'third', card: 88, self: const [Factor(4, 1)])),
          isNull,
        );
      }
      expect(duplicateCharaIdIn([self], twinContent('self')), isNull);
    });
  });
  // Asked on its own as well as through a rejection: a replacement whose contents
  // are another record's is refused with an id the set holds, and what that
  // rejection may erase is this decision, which costs a stored record if wrong.
}
