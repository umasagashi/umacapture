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
/// Only the web loader *refuses* a record — an unusable directory name, a
/// recovery gate or a cross-tab lock — and only part of that is a capability web
/// has and desktop has not. The cross-tab lock is one (Web Locks), and the name
/// check is web's own because there an id is also an OPFS path segment, a
/// transaction slot key and a lock name. **The recovery gate is not**: desktop
/// installs a per-record gate too — `record_recovery_gate_io.dart` wires
/// `ensureReady`, and every other desktop caller goes through it. What this
/// loader cannot do is take anything *per record*: it decodes in spawned
/// isolates, where a lock request sees that isolate's own empty state and would
/// exclude nobody (`InProcessNamedLocks`), so the acquisition that covers the
/// decode has to be the outer root one, held across the whole scan.
/// `record_loader_io.dart` states that at the leg itself. Both loaders nonetheless
/// report a `RecordQuarantineFailed`: a record whose decode failed and whose
/// quarantine move failed with it is missing from the list on both platforms,
/// and stays missing until someone resolves it, so neither may leave it out of
/// the set the store calls incomplete.
///
/// Failing to open the *store* is a different outcome from failing to open a
/// record in it, and both loaders express it the same way: a `RecordScanResult`
/// is returned only when the store itself could be listed, and a root-scope
/// failure is raised as a `RecordStoreUnavailable`. Both loaders take the root
/// scope, and whole-store recovery runs under it on both: the write journal is
/// written by shared code that the Windows zip import drives as well. Web has a
/// second journal to recover under the same scope, the archive move's, because
/// only web stages that move through a manifest.
library;

export 'record_loader_io.dart' if (dart.library.js_interop) 'record_loader_web.dart';
