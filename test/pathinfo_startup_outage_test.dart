// The record-store outage at its widest scope: the app's own startup.
//
// `record_scan_unavailable_test` covers a single record the scan could not open,
// and `record_page_outage_test` covers a whole store it could not list. Both of
// those leave the app running. This one does not: `pathInfoLoader` resolves the
// directory layout *and* runs the root-storage maintenance that takes the
// exclusive root lock before any scan, and capture, settings, addons and both
// record stores await it. A busy or refusing root there used to escape as a bare
// `RecordMutationLockBusy` / `StateError` and reach the screen as an English
// exception with a stack trace in a Japanese UI -- the exact outcome the two
// narrower scopes were fixed to remove.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/pathinfo_startup_outage_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/gui/chara_detail/storage_status_banner.dart';
import 'package:umacapture/src/gui/record_store_banner.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

const _busyRootLock = RecordMutationLockBusy('umacapture:v1:root', Duration(seconds: 150));

final _pathInfo = PathInfo(
  documentDir: DirectoryPath(['documents', 'umacapture']),
  supportDir: DirectoryPath(['support']),
  executableDir: DirectoryPath(['executable']),
  downloadDir: DirectoryPath(['downloads']),
);

/// Maintenance that fails the way the exclusive root gate does.
final class _FailingMaintenance implements RootStorageMaintenance {
  _FailingMaintenance(this.failure);

  final Object failure;

  @override
  Future<void> run(RootStorageMaintenanceRequest request) async => throw failure;

  @override
  Future<void> runUnlocked(RootStorageMaintenanceRequest request) async => throw failure;
}

Future<void> _pumpBanner(WidgetTester tester, RecordStoreUnavailable? outage) {
  final container = ProviderContainer(overrides: [pathInfoOutageProvider.overrideWithValue(outage)]);
  return pumpWithContainer(
    tester,
    container,
    const MaterialApp(home: Scaffold(body: RecordStoreStartupOutageBanner())),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  test('a busy root lock leaves the startup boundary as a transient store outage', () async {
    await expectLater(
      runPathInfoStartupMaintenance(_pathInfo, maintenance: _FailingMaintenance(_busyRootLock)),
      throwsA(
        isA<RecordStoreUnavailable>()
            .having((e) => e.transient, 'transient', isTrue)
            .having((e) => e.cause, 'cause', same(_busyRootLock)),
      ),
    );
  });

  test('a non-transient maintenance failure leaves it as a blocked one, not a bare StateError', () async {
    // The verdict has to survive: `blocked` is what picks the wording that
    // offers the retry as a retry, rather than the `busy` wording that explains
    // the wait by naming another tab (see `store_outage_remedy_test`).
    //
    // The cause is written as a bare `StateError` on purpose. Startup no longer
    // refuses for anything recovery reports -- what reaches here is the record
    // lock being unavailable at all, or the store itself failing to open -- and
    // quoting a production sentence would only pin a copy of it.
    await expectLater(
      runPathInfoStartupMaintenance(
        _pathInfo,
        maintenance: _FailingMaintenance(StateError('the record lock is unavailable')),
      ),
      throwsA(isA<RecordStoreUnavailable>().having((e) => e.transient, 'transient', isFalse)),
    );
  });

  test('a successful startup stays silent', () async {
    await runPathInfoStartupMaintenance(_pathInfo, maintenance: _SilentMaintenance());
  });

  test('a startup outage settles at once instead of retrying behind a spinner', () async {
    // An override keeps the *origin* provider's retry policy, so this exercises
    // the `retry:` the real `pathInfoLoader` declares. Without it riverpod re-runs
    // the failed build ten times, each attempt re-entering a lock acquisition that
    // already burned its 150 s budget, and holds the provider in `AsyncLoading`
    // with the error merely attached the whole time -- so `.future` never
    // completes and every page in the app sits on a spinner for minutes.
    final container = ProviderContainer(
      overrides: [pathInfoLoader.overrideWith((ref) async => throw RecordStoreUnavailable.from(_busyRootLock))],
    );
    addTearDown(container.dispose);

    await expectLater(container.read(pathInfoLoader.future), throwsA(isA<RecordStoreUnavailable>()));
    expect(container.read(pathInfoLoader).isLoading, isFalse);
    expect(container.read(pathInfoOutageProvider), isNotNull);
  });

  test('an ordinary startup failure keeps the framework retry', () async {
    // Only a store outage is claimed to be a settled, user-facing condition.
    // Anything else keeps riverpod's default, which is why the policy is
    // "unless" rather than "never".
    expect(retryUnlessStoreOutage(0, RecordStoreUnavailable.from(_busyRootLock)), isNull);
    expect(retryUnlessStoreOutage(0, const FormatException('a malformed settings file')), isNotNull);
  });

  testWidgets('the startup outage is stated app-level, in Japanese, with a retry', (tester) async {
    await _pumpBanner(tester, RecordStoreUnavailable.from(_busyRootLock));

    // The sentences are read out of `ja.json` as literals, not resolved with `.tr()`: an
    // unresolvable key renders AS the key, so `find.text(key.tr())` would match the raw key the
    // user is shown and stay green through the deletion this asserts against.
    expect(find.text(appSentenceAt("app.record_store_startup.busy")), findsOneWidget);
    expect(find.text(appSentenceAt("app.record_store_startup.retry")), findsOneWidget);
    // The whole point of the scope: no raw exception reaches the screen.
    expect(find.textContaining('RecordMutationLockBusy'), findsNothing);
    expect(find.textContaining('umacapture:v1:root'), findsNothing);
  });

  testWidgets('a blocked startup gets its own wording', (tester) async {
    await _pumpBanner(tester, RecordStoreUnavailable(StateError('the record lock is unavailable'), transient: false));

    expect(find.text(appSentenceAt("app.record_store_startup.blocked")), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
  });

  testWidgets('a healthy startup renders nothing at all', (tester) async {
    // Mounted above every page, so an always-present padding would shift the
    // whole app down on every ordinary startup.
    await _pumpBanner(tester, null);

    expect(find.byType(RecordStoreBanner), findsNothing);
    expect(tester.getSize(find.byType(RecordStoreStartupOutageBanner)), Size.zero);
  });
}

final class _SilentMaintenance implements RootStorageMaintenance {
  @override
  Future<void> run(RootStorageMaintenanceRequest request) async {}

  @override
  Future<void> runUnlocked(RootStorageMaintenanceRequest request) async {}
}
