// What the record page shows when the *whole* record store cannot be scanned.
//
// The per-record half of this story is covered by record_scan_unavailable_test:
// a record the scan cannot open is skipped and reported, and the store stays
// usable. The root scope has no partial result, so the store provider ends up in
// an error state -- and the page's generic error branch renders that error
// verbatim, which for a busy root lock means an English `RecordMutationLockBusy`
// and a stack trace in a Japanese UI, with no statement of what to do about it.
// The same reason `RecordLockUnavailableBanner` short-circuits ahead of the
// loader applies here, so these tests pin that the raw exception never reaches
// the screen.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_page_outage_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/gui/chara_detail/data_table_widget.dart';
import 'package:umacapture/src/gui/chara_detail/storage_status_banner.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/record_store_banner.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

const _busyRootLock = RecordMutationLockBusy('umacapture:v1:root', Duration(seconds: 150));

/// Active storage whose scan cannot open the store at all.
class _OutageStorage extends CharaDetailRecordStorage {
  _OutageStorage(this.outage);

  final Object outage;

  @override
  Future<List<CharaDetailRecord>> build() async => throw outage;
}

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  // Fallback only: [pumpWithContainer] owns the container from here on, and
  // disposing twice is a no-op. This still covers a test that throws before it
  // ever pumps.
  addTearDown(container.dispose);
  await pumpWithContainer(
    tester,
    container,
    const MaterialApp(home: Scaffold(body: CharaDetailDataTableLoaderLayer())),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  /// Overrides the page down to the one seam under test: the initial loader
  /// awaits the record store, exactly as the real one does, so a store outage
  /// reaches the page the same way it does in production.
  ProviderContainer containerWith(
    CharaDetailRecordStorage Function() storage, {
    RecordStoreUnavailable? startup,
    RecordMutationLockUnavailableReason? lock,
  }) {
    return ProviderContainer(
      overrides: [
        recordMutationLockUnavailabilityProvider.overrideWithValue(lock),
        // The widest scope, pinned to "healthy" for every case but the last: the
        // page defers to the app-level banner when startup itself failed, and
        // leaving this to resolve for real would drag `path_provider` into a
        // test about the store below it.
        pathInfoOutageProvider.overrideWithValue(startup),
        charaDetailRecordStorageLoaderProvider.overrideWith(storage),
        charaDetailInitialDataLoader.overrideWith((ref) async {
          return [await ref.watch(charaDetailRecordStorageLoaderProvider.future)];
        }),
      ],
    );
  }

  testWidgets('a busy root lock is stated, not printed as an exception', (tester) async {
    final container = containerWith(() => _OutageStorage(RecordStoreUnavailable.from(_busyRootLock)));
    await _pumpPage(tester, container);
    await tester.pump();

    // The whole point: the page says something the user can read and act on.
    expect(find.byType(RecordStoreBanner), findsOneWidget);
    expect(find.byType(ErrorLogView), findsNothing);
    expect(find.textContaining('RecordMutationLockBusy'), findsNothing);
    expect(find.textContaining('umacapture:v1:root'), findsNothing);
    // And it offers the retry, because for this cause retrying is the remedy.
    expect(find.byType(TextButton), findsOneWidget);
  });

  testWidgets('a blocked root scope is stated too, with its own wording', (tester) async {
    final container = containerWith(
      () => _OutageStorage(RecordStoreUnavailable(StateError('whole-store migration cannot finish'), transient: false)),
    );
    await _pumpPage(tester, container);
    await tester.pump();

    expect(find.byType(RecordStoreBanner), findsOneWidget);
    expect(find.byType(ErrorLogView), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
  });

  testWidgets('a startup outage is left to the app-level banner, not repeated here', (tester) async {
    // A startup failure reaches this loader too -- it awaits the path info -- so
    // without the deferral the page would state it a second time and offer a
    // rescan that cannot work: the stores are downstream of the path info that
    // failed, so invalidating them only replays the cached rejection. The
    // statement itself is not lost: `RecordStoreStartupOutageBanner` sits above
    // every page (see pathinfo_startup_outage_test).
    final container = containerWith(
      () => _OutageStorage(RecordStoreUnavailable.from(_busyRootLock)),
      startup: RecordStoreUnavailable.from(_busyRootLock),
    );
    await _pumpPage(tester, container);
    await tester.pump();

    expect(find.byType(RecordStoreBanner), findsNothing);
    expect(find.byType(ErrorLogView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an unavailable lock is stated once, by the app-level banner and not again by the page', (tester) async {
    // The app-level [RecordLockUnavailableBanner] is mounted here rather than
    // asserted about from a distance, because the defect this pins is only
    // visible when BOTH copies are in the same tree: the page used to return the
    // very same banner as its body, so a record tab opened without the cross-tab
    // lock stacked two identical remedies. Mounting the page alone cannot see
    // that -- it would find one banner either way -- which is why the rest of
    // this file and `record_store_banner_test` stayed green through it.
    //
    // The Column/Expanded shape is the one `app_widget.dart` builds around the
    // router outlet (banner, banner, Expanded(child)); only the second banner and
    // the router are left out, neither of which can add a lock banner.
    final container = containerWith(
      () => _OutageStorage(RecordStoreUnavailable.from(_busyRootLock)),
      lock: RecordMutationLockUnavailableReason.insecureContext,
    );
    addTearDown(container.dispose);
    await pumpWithContainer(
      tester,
      container,
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RecordLockUnavailableBanner(),
              Expanded(child: CharaDetailDataTableLoaderLayer()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RecordLockUnavailableBanner), findsOneWidget);
    expect(find.byType(RecordStoreBanner), findsOneWidget, reason: 'one cause, one remedy, said once');
    // And the page still refuses to pretend it is loading, or to paint the raw
    // lock exception its loader would otherwise reach.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ErrorLogView), findsNothing);
  });

  testWidgets('an ordinary load failure still reaches the error log', (tester) async {
    // Only a store outage is claimed to be a user-facing condition. Anything else
    // is a defect worth reporting verbatim, and this short-circuit must not start
    // swallowing those.
    final container = containerWith(() => _OutageStorage(StateError('a loader bug')));
    await _pumpPage(tester, container);
    await tester.pump();

    expect(find.byType(RecordStoreBanner), findsNothing);
    expect(find.byType(ErrorLogView), findsOneWidget);
  });

  testWidgets('a retryable load failure keeps the loader up, and leaves no retry pending', (tester) async {
    // The case above fails with an `Error`, which riverpod never retries. A plain
    // `Exception` is retried -- `retryUnlessStoreOutage` defers to the framework
    // default for anything that is not an outage -- so the page stays on the
    // spinner with the error attached instead of reaching either branch above.
    // That is the very state the outage short-circuit exists to avoid, and it is
    // also the one that arms a 200 ms retry timer on the failed element.
    // `flutter_test` fails a test whose timer is still pending once the tree is
    // gone, so this case only passes because `pumpWithContainer` ties the
    // container to the tree; with a container that outlives it, it fails outright.
    final container = containerWith(() => _OutageStorage(const FormatException('a malformed record file')));
    await _pumpPage(tester, container);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(RecordStoreBanner), findsNothing);
    expect(find.byType(ErrorLogView), findsNothing);
  });
}

// A store that loads is deliberately not pumped here: the data branch builds the
// whole table (grid, presets, Hive-backed preferences), which is a different test
// with a different setup. `record_store_banner_test` covers "no outage renders
// nothing" at the widget level.
