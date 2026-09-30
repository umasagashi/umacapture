// Protocol 2 of the write journal: publications and recoveries interrupted once — at a
// checkpoint, or part-way through one copy or delete — on both backends. What every case
// asserts is described in `support/web_record_write_protocol_v2.dart`.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';

import 'support/web_record_write_protocol_v2.dart';

void main() => protocolV2Suites(_suite);

void _suite(ProtocolSuite suite) {
  group('interrupted at every checkpoint, and its first recovery at every checkpoint', () {
    test('an uninterrupted publication commits, in every layout', () async {
      for (final layout in PublicationLayout.values) {
        final s = await suite.scene(layout);
        expect(await s.publish(WebRecordWriteTransaction()), WebRecordWriteResult.completed, reason: layout.name);
        await s.expectPublished(layout.name);
      }
    });

    test('a publication interrupted before ready converges to the old tree and no slot', () async {
      // `building` is discarded by design, so these rows cannot reach the
      // new tree. A first publication is not among them: its whole staging is
      // published by the give-up path, which the older suite covers.
      for (final layout in PublicationLayout.withOldTree) {
        for (final stop in preReady) {
          final where = '${layout.name} / $stop';
          final s = await suite.scene(layout);
          final death = ProtocolDeath(at: stop, observe: (_) => s.expectInvariants(where), violations: s.violations);
          expect(await s.publish(death.transaction), WebRecordWriteResult.incomplete, reason: where);
          await s.expectInvariants('$where, after death');
          await s.recover(WebRecordWriteTransaction());
          await s.expectOld(where);
        }
      }
    });
  });

  test('an unverified superseded copy found in ready is rebuilt from the displaced tree, never merged '
      'into', () async {
    for (final layout in PublicationLayout.withOldTree) {
      final s = await suite.scene(layout);
      await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.readyPersisted).transaction);
      // What an earlier resume that died inside the copy could have left, plus
      // a file the old tree never had: a copy *into* this keeps it.
      await s.oldTree.copyTreeInto(s.parked);
      await s.parked.filePath('stray.bin').writeAsBytes([9]);

      var checked = false;
      await s.recover(
        ProtocolDeath(
          at: WebRecordWriteCheckpoint.supersededCopied,
          violations: s.violations,
          observe: (checkpoint) async {
            if (checkpoint != WebRecordWriteCheckpoint.supersededCopied) return;
            checked = true;
            expect(await sameDirectoryTree(s.parked, s.oldTree), isTrue, reason: layout.name);
          },
        ).transaction,
      );
      expect(checked, isTrue, reason: '${layout.name}: the resume never parked');
      expect(await s.manifestState(), 'ready', reason: layout.name);
      await s.recover(WebRecordWriteTransaction());
      await s.expectPublished(layout.name);
    }
  });

  group('a copy or delete that dies half-way leaves a state the next recovery finishes', () {
    /// Drives [s] to the state the step runs in, recovers with [death] once,
    /// checks the invariants on what that left, then recovers cleanly.
    Future<void> interruptStep(
      ProtocolScene s,
      String where, {
      required WebRecordWriteCheckpoint parkAt,
      bool loseStaging = false,
      required ProtocolDeath death,
      required bool published,
    }) async {
      await s.publish(ProtocolDeath(at: parkAt).transaction);
      if (loseStaging) await s.staged.delete(recursive: true, emptyOk: true);
      await s.recover(death.transaction);
      expect(death.dead, isTrue, reason: '$where: the step was never reached');
      await s.expectInvariants('$where, after the step died');
      await s.recover(WebRecordWriteTransaction());
      if (published) {
        await s.expectPublished(where);
      } else {
        await s.expectOld(where);
      }
    }

    test('r3: inside the copy of the displaced tree into superseded/', () async {
      for (final layout in PublicationLayout.withOldTree) {
        final s = await suite.scene(layout);
        await interruptStep(
          s,
          'r3 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.readyPersisted,
          death: ProtocolDeath(partialCopy: (_, target) => target.path == s.parked.path),
          published: true,
        );
      }
    });

    test('p1: inside the delete of the displaced tree', () async {
      for (final layout in PublicationLayout.withOldTree) {
        final s = await suite.scene(layout);
        await interruptStep(
          s,
          'p1 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.parkedPersisted,
          death: ProtocolDeath(partialDelete: (target) => target.path == s.displaced!.path),
          published: true,
        );
      }
    });

    test('p2: inside the delete of a cross-store target a previous copy left half-written', () async {
      for (final layout in [
        PublicationLayout.activeToArchive,
        PublicationLayout.archiveToActive,
        PublicationLayout.firstPublication,
      ]) {
        final where = 'p2 ${layout.name}';
        final s = await suite.scene(layout);
        // The first recovery dies inside p3, leaving part of the new tree at T;
        // the second dies inside p2's delete of it.
        await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
        await s.recover(ProtocolDeath(partialCopy: (source, _) => source.path == s.staged.path).transaction);
        expect(await s.target.exists(), isTrue, reason: '$where: no half-written target to delete');
        final death = ProtocolDeath(partialDelete: (target) => target.path == s.target.path);
        await s.recover(death.transaction);
        expect(death.dead, isTrue, reason: where);
        await s.expectInvariants(where);
        await s.recover(WebRecordWriteTransaction());
        await s.expectPublished(where);
      }
    });

    test('p3: inside the copy of the staged tree into the target', () async {
      for (final layout in PublicationLayout.values) {
        final s = await suite.scene(layout);
        await interruptStep(
          s,
          'p3 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.parkedPersisted,
          death: ProtocolDeath(partialCopy: (source, _) => source.path == s.staged.path),
          published: true,
        );
      }
    });

    test('x1: inside the restore\'s delete of the target and of the displaced tree', () async {
      for (final layout in PublicationLayout.withOldTree) {
        for (final parkAt in [WebRecordWriteCheckpoint.parkedPersisted, WebRecordWriteCheckpoint.finalCopied]) {
          final s = await suite.scene(layout);
          // Parked at `finalCopied`, T holds the new tree whole; in one store
          // that is also D.
          final victim = parkAt == WebRecordWriteCheckpoint.finalCopied ? s.target : s.displaced!;
          await interruptStep(
            s,
            'x1 ${layout.name} parked at ${parkAt.name}',
            parkAt: parkAt,
            loseStaging: true,
            death: ProtocolDeath(partialDelete: (target) => target.path == victim.path),
            published: false,
          );
        }
      }
    });

    test('x2: inside the copy of superseded/ back into the displaced tree', () async {
      for (final layout in PublicationLayout.withOldTree) {
        final s = await suite.scene(layout);
        await interruptStep(
          s,
          'x2 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.finalSetAside,
          loseStaging: true,
          death: ProtocolDeath(partialCopy: (source, _) => source.path == s.parked.path),
          published: false,
        );
      }
    });

    test('u1: inside the delete of superseded/ after published', () async {
      for (final layout in PublicationLayout.withOldTree) {
        final s = await suite.scene(layout);
        await interruptStep(
          s,
          'u1 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.publishedPersisted,
          death: ProtocolDeath(partialDelete: (target) => target.path == s.parked.path),
          published: true,
        );
      }
    });

    test('v1: inside the delete of superseded/ after restored', () async {
      for (final layout in PublicationLayout.withOldTree) {
        final s = await suite.scene(layout);
        await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
        await s.staged.delete(recursive: true, emptyOk: true);
        await s.recover(ProtocolDeath(at: WebRecordWriteCheckpoint.restoredPersisted).transaction);
        expect(await s.manifestState(), 'restored', reason: layout.name);
        final death = ProtocolDeath(partialDelete: (target) => target.path == s.parked.path);
        await s.recover(death.transaction);
        expect(death.dead, isTrue, reason: layout.name);
        await s.recover(WebRecordWriteTransaction());
        await s.expectOld('v1 ${layout.name}');
      }
    });

    test('building: a staging retired half-way is retired again, and the displaced tree is untouched', () async {
      // Table A, first row: `_discardSlot` died inside `_retireStaging`'s move,
      // leaving a partial `desired/` and a partial `retired/` entry.
      for (final layout in PublicationLayout.replacing) {
        final s = await suite.scene(layout);
        await s.publish(ProtocolDeath(at: WebRecordWriteCheckpoint.overlayApplied).transaction);
        await writeTree(s.dataRoot / 'retired' / olderId, {
          'record.json': await s.staged.filePath('record.json').readAsBytes(),
        });
        await s.staged.filePath('shared.bin').delete();
        await s.recover(WebRecordWriteTransaction());
        await s.expectOld(layout.name);
        expect(await childNames(s.dataRoot / 'retired'), hasLength(2), reason: layout.name);
      }
    });
  });
}
