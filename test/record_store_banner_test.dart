// The two persistent record-store banners.
//
// `RecordMutationLockUnavailable` used to be thrown by every persisted record
// read and write and caught by nothing, so a browser without `navigator.locks`
// (or a page served over plain HTTP) produced a total failure with no statement
// of the cause. The capability is now probed once and reported, and the three
// causes must stay distinguishable: the user's remedy differs for each.
//
// The incomplete-store banner is the persistent half of the same story for
// records the scan could not open -- previously visible only in a toast that
// scrolled away.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_store_banner_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/gui/chara_detail/storage_status_banner.dart';
import 'package:umacapture/src/gui/record_store_banner.dart';

import 'support/localization.dart';

/// Active storage whose scan reported [unavailable] ids.
class _FakeRecordStorage extends CharaDetailRecordStorage {
  _FakeRecordStorage(this.unavailable);

  final Set<String> unavailable;

  @override
  Future<List<CharaDetailRecord>> build() async => const [];

  @override
  Set<String> get unavailableRecordIds => unavailable;
}

class _FakeArchiveStorage extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];

  @override
  Set<String> get unavailableRecordIds => const {};
}

/// Mounts [child] under [container]. The container is built by each caller
/// because riverpod does not export the `Override` type, so it cannot be passed
/// through a typed parameter here.
Future<void> _pump(WidgetTester tester, ProviderContainer container, Widget child) async {
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
}

/// The message line of the banner currently on screen (`first`: the action
/// buttons contribute their own labels after it).
String _bannerMessage(WidgetTester tester) {
  final finder = find.descendant(of: find.byType(RecordStoreBanner), matching: find.byType(Text)).first;
  return tester.widget<Text>(finder).data ?? '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  testWidgets('an available lock renders nothing at all', (tester) async {
    await _pump(
      tester,
      ProviderContainer(overrides: [recordMutationLockUnavailabilityProvider.overrideWithValue(null)]),
      const RecordLockUnavailableBanner(),
    );
    // Nothing, not an empty banner: this widget sits above every page, so a
    // visible remnant would push the whole app down on every startup.
    expect(find.byType(RecordStoreBanner), findsNothing);
    expect(tester.getSize(find.byType(RecordLockUnavailableBanner)), Size.zero);
  });

  testWidgets('each unavailability reason states its own remedy', (tester) async {
    final rendered = <RecordMutationLockUnavailableReason, String>{};
    for (final reason in RecordMutationLockUnavailableReason.values) {
      await _pump(
        tester,
        ProviderContainer(overrides: [recordMutationLockUnavailabilityProvider.overrideWithValue(reason)]),
        const RecordLockUnavailableBanner(),
      );
      expect(find.byType(RecordStoreBanner), findsOneWidget, reason: reason.name);
      final text = tester.widget<Text>(
        find.descendant(of: find.byType(RecordStoreBanner), matching: find.byType(Text)),
      );
      final message = text.data ?? '';
      // A missing key would render the key itself, which reads as a message but
      // tells the user nothing.
      expect(message, isNot(contains('record_lock_unavailable')), reason: reason.name);
      expect(message, isNotEmpty, reason: reason.name);
      rendered[reason] = message;
    }
    // Three reasons, three remedies (serve over HTTPS / change browser / report a
    // wiring fault), so three different strings.
    expect(rendered.values.toSet(), hasLength(RecordMutationLockUnavailableReason.values.length));
  });

  testWidgets('the incomplete-store banner counts unavailable records and offers the rescan', (tester) async {
    final storage = _FakeRecordStorage({'a', 'b'});
    final container = ProviderContainer(
      overrides: [
        charaDetailRecordStorageLoaderProvider.overrideWith(() => storage),
        charaDetailArchiveStorageLoaderProvider.overrideWith(_FakeArchiveStorage.new),
      ],
    );
    await _pump(tester, container, const IncompleteStoreBanner());
    await tester.pump();

    expect(container.read(charaDetailUnavailableRecordsProvider), {'a', 'b'});
    expect(find.byType(RecordStoreBanner), findsOneWidget);
    expect(find.textContaining('2'), findsOneWidget);

    // The rescan is the whole of what the banner offers now. The repair button
    // that used to sit beside it is gone: everything it called reached the same
    // recovery a rescan runs, and every slot it existed to remove is set aside
    // by that recovery on its own. The label is read out of `ja.json` as a
    // literal: `.tr()` renders an unresolvable key AS the key, so
    // `find.text(key.tr())` would go on tapping the raw key the user is shown.
    expect(find.text(appSentenceAt("$tr_chara_detail.incomplete_banner.rescan")), findsOneWidget);
    expect(
      find.descendant(of: find.byType(RecordStoreBanner), matching: find.byType(TextButton)),
      findsOneWidget,
      reason: 'the banner offers the rescan and nothing else',
    );
  });

  testWidgets('a whole-store outage states whether waiting fixes it', (tester) async {
    final rendered = <bool, String>{};
    for (final transient in [true, false]) {
      final outage = RecordStoreUnavailable(
        transient ? const RecordMutationLockBusy('umacapture:v1:root', Duration(seconds: 150)) : StateError('blocked'),
        transient: transient,
      );
      await _pump(tester, ProviderContainer(), RecordStoreOutageBanner(outage: outage));
      final message = _bannerMessage(tester);
      expect(message, isNot(contains('store_outage')), reason: 'a missing key renders as the key itself');
      // The raw cause is a developer string in English; it must not be what the
      // user is handed in its place.
      expect(message, isNot(contains('RecordMutationLockBusy')));
      rendered[transient] = message;
    }
    // Wait-and-rescan versus act-now are different instructions.
    expect(rendered[true], isNot(rendered[false]));
  });

  testWidgets('a healthy archive renders no outage banner at all', (tester) async {
    await _pump(
      tester,
      ProviderContainer(overrides: [charaDetailArchiveOutageProvider.overrideWithValue(null)]),
      const ArchiveStoreOutageBanner(),
    );
    // Nothing, not an empty banner: this sits above the table on every load.
    expect(find.byType(RecordStoreBanner), findsNothing);
    expect(tester.getSize(find.byType(ArchiveStoreOutageBanner)), Size.zero);
  });

  testWidgets('an archive outage names the archive and offers its own rescan', (tester) async {
    final container = ProviderContainer(
      overrides: [
        charaDetailArchiveOutageProvider.overrideWithValue(
          RecordStoreUnavailable(StateError('blocked'), transient: false),
        ),
      ],
    );
    await _pump(tester, container, const ArchiveStoreOutageBanner());

    expect(find.byType(RecordStoreBanner), findsOneWidget);
    expect(_bannerMessage(tester), contains('アーカイブ'));
    // Rescanning the archive must not tear down the active table, which is fine.
    expect(find.text(appSentenceAt("$tr_chara_detail.store_outage.rescan")), findsOneWidget);
  });

  testWidgets('a complete store shows no banner', (tester) async {
    await _pump(
      tester,
      ProviderContainer(
        overrides: [
          charaDetailRecordStorageLoaderProvider.overrideWith(() => _FakeRecordStorage(const {})),
          charaDetailArchiveStorageLoaderProvider.overrideWith(_FakeArchiveStorage.new),
        ],
      ),
      const IncompleteStoreBanner(),
    );
    await tester.pump();
    expect(find.byType(RecordStoreBanner), findsNothing);
  });
}
