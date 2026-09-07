// Verifies that the startup storage-maintenance boundary
// (`runPathInfoStartupMaintenance`) announces the record store to the long-read
// registry while the sweep runs, and gives it back however the sweep ends.
//
// **Why this is a runtime observation rather than a scan.** The scans in
// `long_read_registry_test.dart` read source text: they can tell that a
// declaration was written, and nothing more. Whether the declaration a boundary
// carries actually reaches `LongReadRegistry` — and whether it is released when
// the boundary throws — is only visible by watching the registry while the
// boundary runs, which is what every case here does.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/startup_maintenance_long_read_claim_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';

/// A maintenance whose sweep runs [duringSweep] after one asynchronous gap, so
/// what the registry holds is read from *inside* the boundary rather than from a
/// turn of the event loop that happens to be next to it.
class _ObservingMaintenance implements RootStorageMaintenance {
  _ObservingMaintenance(this.duringSweep, {this.failWith});

  final void Function(RootStorageMaintenanceRequest request) duringSweep;
  final Object? failWith;
  var ran = false;

  @override
  Future<RootMaintenanceOutcome> run(RootStorageMaintenanceRequest request) async {
    await Future<void>.delayed(Duration.zero);
    ran = true;
    duringSweep(request);
    final failure = failWith;
    if (failure != null) {
      throw failure;
    }
    return RootMaintenanceOutcome.none;
  }

  @override
  Future<RootMaintenanceOutcome> runUnlocked(RootStorageMaintenanceRequest request) async =>
      RootMaintenanceOutcome.none;
}

void main() {
  final info = PathInfo(
    documentDir: DirectoryPath(['documents', 'umacapture']),
    supportDir: DirectoryPath(['support']),
    executableDir: DirectoryPath(['executable']),
    downloadDir: DirectoryPath(['downloads']),
  );

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  LongReadDeclaration declarationFor(ProviderContainer container) =>
      startupStorageMaintenanceLongReadDeclaration(container.read(containerRefProvider), info);

  Map<LongReadToken, LongReadClaim> claimsOf(ProviderContainer container) => container.read(longReadRegistryProvider);

  test('the whole record store is claimed while the startup sweep runs, and given back after it', () async {
    final container = makeContainer();
    Map<LongReadToken, LongReadClaim>? duringSweep;
    DirectoryPath? sweptRoot;
    final maintenance = _ObservingMaintenance((request) {
      duringSweep = claimsOf(container);
      sweptRoot = request.recordDataRoot;
    });

    expect(claimsOf(container), isEmpty, reason: 'precondition: nothing is claimed before startup');

    await runPathInfoStartupMaintenance(info, declaration: declarationFor(container), maintenance: maintenance);

    expect(maintenance.ran, isTrue, reason: 'the sweep never ran, so nothing below observed anything');
    final claim = duringSweep?.values.single;
    expect(claim?.kind, LongReadKind.recover);
    expect(
      claim?.holds.map((hold) => hold.directoryPath),
      [info.charaDetailDir.path],
      reason: 'the claim has to name the store root the sweep was handed, or it withholds the wrong deletes',
    );
    // The claim is the store the request names, read off the request rather than
    // asserted twice from this file's own idea of the layout.
    expect(sweptRoot?.path, info.charaDetailDir.path);
    expect(
      claimsOf(container),
      isEmpty,
      reason: 'the claim outlived the sweep and would grey the store for the session',
    );
  });

  test('a sweep that fails gives the claim back, and still fails as a store outage', () async {
    final container = makeContainer();
    var claimedDuringSweep = false;
    final maintenance = _ObservingMaintenance(
      (_) => claimedDuringSweep = claimsOf(container).isNotEmpty,
      failWith: StateError('the record lock is unavailable'),
    );

    // Both halves matter and they are one case on purpose: the declaration has
    // to run *inside* the `try` that turns a maintenance failure into
    // `RecordStoreUnavailable`. Outside it, the claim would still be released —
    // `hold`'s `finally` sees to that — but the exception would leave the
    // boundary untranslated, and nearly every provider in the app is waiting on
    // this one.
    await expectLater(
      runPathInfoStartupMaintenance(info, declaration: declarationFor(container), maintenance: maintenance),
      throwsA(isA<RecordStoreUnavailable>()),
    );

    expect(claimedDuringSweep, isTrue, reason: 'nothing was claimed, so the release below proves nothing');
    expect(claimsOf(container), isEmpty);
  });
}
