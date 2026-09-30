// Protocol 2 of the write journal: the states a recovery finds — a lost staging, a torn
// manifest, a frozen slot, an interrupted give-up — and the publish API's refusals, on both
// backends. What every case asserts is described in `support/web_record_write_protocol_v2.dart`.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_recovery_reason.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';

import 'support/web_record_write_protocol_v2.dart';

void main() => protocolV2Suites(_suite);

void _suite(ProtocolSuite suite) {
  group('staging lost after parked', () {
    test('the restore reports why the publication did not commit', () async {
      for (final layout in PublicationLayout.withOldTree) {
        final s = await suite.scene(layout);
        await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.finalSetAside).transaction);
        await s.staged.delete(recursive: true, emptyOk: true);
        final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;
        expect(recovered.result, WebRecordWriteResult.incomplete, reason: layout.name);
        expect(recovered.reason, RecordRecoveryIncompleteReason.stagedTreeGoneRestored, reason: layout.name);
        await s.expectOld(layout.name);
      }
    });

    test('a restored slot whose removal was interrupted is removed by the next recovery', () async {
      // Table B, last row: the slot delete took S and stopped at the manifest,
      // or took the manifest too.
      for (final manifestSurvived in [true, false]) {
        final s = await suite.scene(PublicationLayout.sameStore);
        await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
        await s.staged.delete(recursive: true, emptyOk: true);
        await s.recover(ProtocolDeath(at: WebRecordWriteCheckpoint.supersededDropped).transaction);
        expect(await s.parked.exists(), isFalse);
        if (!manifestSurvived) await s.slot.filePath('manifest.json').delete();
        await s.recover(WebRecordWriteTransaction());
        await s.expectOld('manifest survived: $manifestSurvived');
      }
    });

    test('a first publication that lost its staging after parked has nothing to restore and is given up', () async {
      final s = await suite.scene(PublicationLayout.firstPublication);
      await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
      await s.staged.delete(recursive: true, emptyOk: true);
      final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;
      expect(recovered.reason, RecordRecoveryIncompleteReason.stagedTreeGone);
      expect(await s.holders(), isEmpty);
      expect(await s.slot.exists(), isFalse);
    });
  });

  test('a torn manifest at each transition leaves the id whole in a record store', () async {
    for (final layout in PublicationLayout.withOldTree) {
      for (final state in ['building', 'ready', 'parked', 'published', 'restored']) {
        final where = '${layout.name} / torn $state';
        final s = await suite.scene(layout);
        if (state == 'restored') {
          await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
          await s.staged.delete(recursive: true, emptyOk: true);
          final death = ProtocolDeath(tornState: state);
          await s.recover(death.transaction);
          expect(death.dead, isTrue, reason: where);
        } else {
          final death = ProtocolDeath(tornState: state);
          await s.publish(death.transaction);
          expect(death.dead, isTrue, reason: where);
        }
        expect(await s.manifestState(), isNull, reason: '$where: the manifest is not torn');
        await s.recover(WebRecordWriteTransaction());
        await s.expectInvariants(where);
        expect(await s.slot.exists(), isFalse, reason: where);
        final holding = await s.holders();
        expect(holding, hasLength(1), reason: where);
        final expected = state == 'published' ? s.newTree : s.oldTree;
        expect(
          await sameDirectoryTree(s.dataRoot / holding.single / olderId, expected),
          isTrue,
          reason: '$where: the store does not hold the ${state == 'published' ? 'new' : 'old'} tree',
        );
      }
    }
  });

  group('frozen states delete nothing', () {
    test('parked without desired and without superseded deletes nothing', () async {
      for (final layout in PublicationLayout.withOldTree) {
        for (final parkAt in [WebRecordWriteCheckpoint.parkedPersisted, WebRecordWriteCheckpoint.finalCopied]) {
          final where = '${layout.name} / ${parkAt.name}';
          final s = await suite.scene(layout);
          await s.publish(ProtocolDeath(at: parkAt).transaction);
          await s.staged.delete(recursive: true, emptyOk: true);
          await s.parked.delete(recursive: true, emptyOk: true);
          final before = await treeSnapshot(s.dataRoot);

          final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;

          expect(recovered.result, WebRecordWriteResult.incomplete, reason: where);
          expect(recovered.reason, RecordRecoveryIncompleteReason.supersededCopyGone, reason: where);
          expect(await treeSnapshot(s.dataRoot), before, reason: '$where: something was written or deleted');
        }
      }
    });

    test('ready with its displaced tree gone deletes nothing', () async {
      for (final layout in PublicationLayout.withOldTree) {
        final s = await suite.scene(layout);
        await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.readyPersisted).transaction);
        await s.displaced!.delete(recursive: true, emptyOk: true);
        final before = await treeSnapshot(s.dataRoot);

        final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;

        expect(recovered.result, WebRecordWriteResult.incomplete, reason: layout.name);
        expect(recovered.reason, RecordRecoveryIncompleteReason.displacedTreeGone, reason: layout.name);
        expect(await treeSnapshot(s.dataRoot), before, reason: '${layout.name}: something was written or deleted');
      }
    });
  });

  group('the publish API', () {
    test('baseFrom with the id in no store, or in two, is refused before anything is staged', () async {
      final s = await suite.scene(PublicationLayout.firstPublication);
      final base = s.dataRoot / 'active' / newerId;
      await s.baseTree.copyTreeInto(base);
      final transactionRoot = s.dataRoot / WebRecordWriteTransaction.transactionRootName;

      expect(
        await WebRecordWriteTransaction().publish(s.dataRoot, olderId, s.overlays, baseFrom: base),
        WebRecordWriteResult.invalidInput,
        reason: 'no store holds the id',
      );
      expect(await transactionRoot.exists(), isFalse);

      await s.oldTree.copyTreeInto(s.dataRoot / 'active' / olderId);
      await s.oldTree.copyTreeInto(s.dataRoot / 'archive' / olderId);
      final before = await treeSnapshot(s.dataRoot);
      for (final store in WebRecordWriteTransaction.recordStoreNames) {
        expect(
          await WebRecordWriteTransaction().publish(s.dataRoot, olderId, s.overlays, store: store, baseFrom: base),
          WebRecordWriteResult.invalidInput,
          reason: 'two stores hold the id; target $store',
        );
      }
      expect(await transactionRoot.exists(), isFalse);
      expect(await treeSnapshot(s.dataRoot), before);
    });

    test('a baseFrom that is not there, or a store that is not a record store, is refused', () async {
      final s = await suite.scene(PublicationLayout.sameStore);
      expect(
        await WebRecordWriteTransaction().publish(
          s.dataRoot,
          olderId,
          s.overlays,
          baseFrom: s.dataRoot / 'active' / 'gone',
        ),
        WebRecordWriteResult.invalidInput,
      );
      expect(
        await WebRecordWriteTransaction().publish(s.dataRoot, olderId, s.overlays, store: 'quarantine'),
        WebRecordWriteResult.invalidInput,
      );
      expect(await (s.dataRoot / WebRecordWriteTransaction.transactionRootName).exists(), isFalse);
    });

    test('blockedByOtherStore is unchanged when baseFrom is null', () async {
      for (final (held, target) in [('archive', 'active'), ('active', 'archive')]) {
        final s = await suite.scene(PublicationLayout.firstPublication);
        await s.oldTree.copyTreeInto(s.dataRoot / held / olderId);
        final before = await treeSnapshot(s.dataRoot);
        expect(
          await WebRecordWriteTransaction().publish(s.dataRoot, olderId, s.overlays, store: target),
          WebRecordWriteResult.blockedByOtherStore,
          reason: '$held holds it, target $target',
        );
        expect(await treeSnapshot(s.dataRoot), before);
      }
    });

    test('a staged copy of baseFrom that does not match it is refused before ready', () async {
      final s = await suite.scene(PublicationLayout.activeToArchive);
      final truncating = WebRecordWriteTransaction(
        copyTree: (source, target) async {
          final copied = await source.copyTreeInto(target);
          if (source.path == s.base!.path) await target.filePath('r-only.bin').delete();
          return copied;
        },
      );
      expect(await s.publish(truncating), WebRecordWriteResult.incomplete);
      await s.recover(WebRecordWriteTransaction());
      await s.expectOld('a staging that is not baseFrom was published');
    });
  });

  group('table D: give-up paths interrupted', () {
    // A slot whose manifest cannot be read is given up on: its parked copy and
    // its staging go to quarantine/. These are the states a death inside
    // those moves leaves; the next give-up promotes again under a fresh name
    // and never overwrites what an earlier one put there.
    Future<ProtocolScene> tornAfterParked() async {
      final s = await suite.scene(PublicationLayout.activeToArchive);
      await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
      await s.slot.filePath('manifest.json').writeAsString('{ torn');
      return s;
    }

    test('inside the copy of superseded/ into quarantine', () async {
      final s = await tornAfterParked();
      await writeTree(s.dataRoot / 'quarantine' / olderId, {
        'record.json': recordJson({'self': olderId, 'v': 'old'}),
      });
      await s.recover(WebRecordWriteTransaction());
      expect(await s.slot.exists(), isFalse);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / '${olderId}_1', s.oldTree), isTrue);
      expect(await sameDirectoryTree(s.displaced!, s.oldTree), isTrue);
    });

    test('after that copy, inside the delete of superseded/', () async {
      final s = await tornAfterParked();
      await s.parked.copyTreeInto(s.dataRoot / 'quarantine' / olderId);
      await s.parked.filePath('old-only.bin').delete();
      await s.recover(WebRecordWriteTransaction());
      expect(await s.slot.exists(), isFalse);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / olderId, s.oldTree), isTrue);
      expect(await sameDirectoryTree(s.displaced!, s.oldTree), isTrue);
    });

    test('inside the set-aside of the staging', () async {
      final s = await tornAfterParked();
      // The parked copy already went; the staging's move died half-way.
      await s.parked.copyTreeInto(s.dataRoot / 'quarantine' / olderId);
      await s.parked.delete(recursive: true, emptyOk: true);
      await writeTree(s.dataRoot / 'quarantine' / '${olderId}_1', {
        'record.json': recordJson({'self': olderId, 'v': 'survivor'}),
      });
      await s.recover(WebRecordWriteTransaction());
      expect(await s.slot.exists(), isFalse);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / olderId, s.oldTree), isTrue);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / '${olderId}_2', s.newTree), isTrue);
      expect(await sameDirectoryTree(s.displaced!, s.oldTree), isTrue);
    });
  });

  test('a parked cross-store target holding a file the staging lacks is rebuilt from empty', () async {
    // Not a state the steps above produce — T is written only by the copy of
    // Q — but the guard that deletes a cross-store T before that copy is what
    // makes the comparison after it a verdict on Q rather than on T's history.
    for (final layout in [PublicationLayout.activeToArchive, PublicationLayout.archiveToActive]) {
      final s = await suite.scene(layout);
      await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.finalSetAside).transaction);
      await writeTree(s.target, {
        'stale.bin': [3],
      });
      await s.recover(WebRecordWriteTransaction());
      await s.expectPublished(layout.name);
    }
  });
}
