import '/src/core/path_entity.dart';
import '/src/core/providers.dart';

/// How many slots the transaction journals under [charaDetailDir] hold **right
/// now**, without acquiring anything.
///
/// For a caller that has to know whether whole-store recovery was going to have
/// anything to do *before* it ran: the sweep's own `RootMaintenanceOutcome`
/// names only what it could not finish, so a slot it published or restored
/// successfully leaves no trace in the result — and that publication is exactly
/// what makes the caller's in-memory view of the store stale. The count is
/// therefore taken in `RecordRecoveryGate.runForRoot`'s `beforeMaintenance`
/// seam, which is the only point inside the exclusive root lock that is ahead of
/// the drain.
///
/// **Counted per version directory rather than against the literal `v1`.** Both
/// journals put their slots one level under a versioned root
/// (`…/<journal>/v1/<slot>`), and a drained journal keeps that root — so counting
/// the journal directory's own children would answer 1 forever after the first
/// slot this installation ever staged, and naming `v1` here would be a third
/// copy of a constant each journal already owns. Every entry under every version
/// directory is counted instead: an emptied journal answers 0, and a second
/// journal version is counted without this function being edited.
///
/// A file sitting directly in a version directory counts as an entry. That is
/// deliberate: the question is "was there anything in the journals", and a stray
/// file there is something the sweep may have dealt with.
Future<int> journalEntryCountUnlocked(DirectoryPath charaDetailDir) async {
  var count = 0;
  for (final journal in charaDetailTransactionJournalDirsOf(charaDetailDir)) {
    if (!await journal.exists()) {
      continue;
    }
    await for (final version in journal.list()) {
      if (version is! DirectoryPath) {
        continue;
      }
      count += await version.list().length;
    }
  }
  return count;
}
