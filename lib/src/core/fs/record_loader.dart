/// Platform-specific fan-out for the bulk record scan.
///
/// Desktop/VM fans `record.json` decoding across worker isolates
/// (`record_loader_io.dart`); web has no `Isolate.run`/`Isolate.spawn`, so it
/// loads sequentially and asynchronously on the main isolate
/// (`record_loader_web.dart`). Both expose `loadRecordsUnder`, which lists the
/// record directories under a root and returns a `RecordScanResult`: one
/// `RecordLoadResult` per record it could open, plus the id and cause of every
/// record it could not.
///
/// Only web can *refuse* a record — an unusable directory name, a recovery gate
/// or a cross-tab lock — because only web has those. Both loaders nonetheless
/// report a `RecordQuarantineFailed`: a record whose decode failed and whose
/// quarantine move failed with it is missing from the list on both platforms,
/// and stays missing until someone resolves it, so neither may leave it out of
/// the set the store calls incomplete.
///
/// Failing to open the *store* is a different outcome from failing to open a
/// record in it, and both loaders express it the same way: a `RecordScanResult`
/// is returned only when the store itself could be listed, and a root-scope
/// failure is raised as a `RecordStoreUnavailable`. Both loaders take the root
/// scope; only web additionally runs whole-store recovery under it, because only
/// web has a transaction log to recover.
library;

export 'record_loader_io.dart' if (dart.library.js_interop) 'record_loader_web.dart';
