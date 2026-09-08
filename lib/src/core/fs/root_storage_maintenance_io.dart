import 'root_storage_maintenance.dart';
import 'root_storage_maintenance_shared.dart';

/// Desktop drains the write journal, and only that one.
///
/// **It has a write journal.** The `Web` prefix on
/// `web_record_write_transaction.dart` names OPFS's missing directory rename,
/// which is why the machine was written, and not the platform that runs it:
/// neither that file nor `web_record_persistence.dart` carries a conditional
/// import, and the zip import — `RecordZipService.import` ->
/// `platformWebRecordPersistence.persistFiles` -> `publish` — is offered on the
/// Windows UI from `column_preset_bar_widget.dart` with no `kIsWeb` in front of
/// it. So a Windows session interrupted mid-publication leaves exactly the slot
/// this sweep exists to drain, and until that was wired the slot was left for
/// the delete of 「アプリの残骸」 to remove.
///
/// **It has no archive journal, and that is a real divergence with a platform
/// reason.** `archiveRecords` resolves to `archive_executor_io.dart` here, whose
/// move is a same-volume `rename` — atomic, so there is no half-moved state for
/// a manifest to describe. `archiveRecordAsync`, the only thing that drives a
/// `RecordDirectoryTransaction`, is reached only from
/// `archive_executor_web.dart`. The day a desktop archive becomes transactional,
/// this line becomes `bothJournals` and nothing else changes.
///
/// **It looks in that journal all the same, for the slots it can tell it did not
/// write.** "This build stages no archive move here" is a fact about this build;
/// the data root is whatever folder the user pointed the app at
/// (`data_root.json`), so a directory left by another version — a machine
/// restored from a copy, or the transactional desktop build the paragraph above
/// anticipates — is an ordinary thing to find in it. Carrying such a slot to
/// `quarantine/` needs no manifest to read and no atomic rename, which is all
/// the divergence above is about, so [JournalRootStorageMaintenance.writeJournalOnly]
/// runs that half here too. Leaving it put another version's staging, which may
/// hold the only copy of a record it saved, one confirmation away from removal
/// under 「アプリの残骸」 — a group offered at that friction on the stated basis
/// that nothing on it is the only copy of anything.
RootStorageMaintenance createRootStorageMaintenance() => JournalRootStorageMaintenance.writeJournalOnly();
