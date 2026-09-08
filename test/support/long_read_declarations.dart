import 'package:umacapture/src/core/storage/long_read_registry.dart';

/// What a suite declares when it drives `RecordRecoveryGate` (or one of the
/// helpers that fronts it) directly, and the long-read registry is not what it
/// is testing.
///
/// **Shared deliberately, and only for tests.** In `lib/` every call writes its
/// own reason, because there the argument exists to make one caller state one
/// decision. A suite that drives the gate to observe lock ordering, recovery
/// hooks or a loader has no user-visible operation to announce at all: there is
/// no button anywhere that could be offered over what it holds, so one sentence
/// is the true account of every such call and repeating it per file would only
/// invite a second, different, equally meaningless wording.
///
/// A suite that *is* about the registry claims explicitly instead — see
/// `export_long_read_claim_test.dart` and `archive_long_read_claim_test.dart`.
const undeclaredInTest = LongReadDeclaration.none(
  reason: 'driven directly by a test; there is no user-visible operation to announce',
);
