/// What the bulk record scan announces to the long-read registry, for both legs.
///
/// **One function, above the platform seam, for the same reason
/// `exportLongReadDeclaration` is one function for both zip-export legs.** The
/// two scan legs hold the store for different lengths — `record_loader_io.dart`
/// keeps the root name across the listing *and* the worker decodes, while
/// `record_loader_web.dart` holds it for the listing only and takes a per-record
/// acquisition for each decode — and both of those files said, in a comment, that
/// they would get *the same* claim so that the legs could not be given different
/// ones. Built here and handed in as an argument, they cannot: the object each
/// leg declares is the object this function returned.
///
/// **Why the claim is the record store's root and not a list of directories.**
/// The first version of this named two: the store being scanned, and the sibling
/// `quarantine/` a record that will not decode is moved into. That list was
/// wrong within the same commit, and it was wrong in the way a list is always
/// wrong — by being one enumeration of something nobody enumerates.
///
/// What the pass writes is not decided by the scan body alone. The acquisition
/// it makes is a *recovery* gate, and its two hooks run inside this claim:
/// `ensureRootReady` runs `JournalRootStorageMaintenance` over this platform's
/// transaction journals before anything is listed, and `ensureReady` runs
/// write-transaction recovery — and on web directory-transaction recovery
/// beside it — again for **every record it decodes**. Finishing an interrupted archive move creates the record at
/// `archive/<id>` and deletes it from `active/<id>`, so a scan of `active/`
/// writes into `archive/`; giving up on a slot promotes it into `quarantine/`.
/// `PathInfo.charaDetailRetiredDir`'s own doc already describes this path.
///
/// **This paragraph deliberately does not finish with a list of them**, and the
/// omission is the point rather than an economy: the first draft of it wrote out
/// "the directories one scan can write are, in full" and left `retired/` off —
/// `RecordDirectoryTransaction` and `WebRecordWriteTransaction` both retire a
/// slot they will not replay, and `archive_executor_shared.dart` says so in as
/// many words. A doc that enumerates goes stale exactly as the claim did, and
/// this one had already started to. Read the destinations off the recovery
/// entry points instead; every one of them is under the store root, which is why
/// naming that root is *one* derivation and stays true when the store gains
/// another directory. A claim over `chara_detail/` withholds a delete of
/// anything under it and of the group roots above it, because
/// `storageDeleteAwaitsExtraction` asks containment both ways round.
///
/// **What that over-refuses, stated rather than glossed.** `metadata/` (ratings
/// and memos) is under the store root and is the one subtree no scan touches, so
/// its delete is withheld for the length of a scan and would not have had to
/// wait: its group is `StorageLockScope.providerSerialized`, which takes no
/// record lock, unlike every other directory here — those are `perRecord` or
/// `exclusiveRoot` and would queue behind the exclusive root name this scan holds
/// anyway.
///
/// **It is accepted because excluding it would put the list back, and not
/// because the window is short.** The window is not short: the measured 250 ms
/// in `record_loader_io.dart` is eight isolates, the same measurement puts a
/// single isolate at ~1330 ms, and the web leg decodes sequentially and calls a
/// large store "a known, out-of-scope cost" in its own doc. What makes the cost
/// acceptable is its shape — a delete deferred, never a delete lost — against
/// the alternative, which is an inclusion list naming five of the store's
/// directories. That is precisely the construction that shipped a hole here.
///
/// **"Scan" describes what the pass is for, not what it does to the store.** The
/// quarantine moves, the promotions and the resumed archive moves above are all
/// writes, on both legs for the first and on web for the rest — which is why the
/// claim is [LongReadKind.scan] and its doc says so, and not a kind whose name
/// promises the store is only being read.
library;

import '/src/core/path_entity.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';

/// The declaration a scan of [scanRoot] carries.
///
/// [scanRoot] is `chara_detail/active` or `chara_detail/archive`, so its parent
/// is the record store's own root — the same `<data-root>` every recovery hook
/// in the paragraphs above is handed, and the one `PathInfo.charaDetailDir`
/// names.
LongReadDeclaration bulkRecordScanLongReadDeclaration(RefBase ref, DirectoryPath scanRoot) {
  return LongReadDeclaration.claim(
    registry: ref.read(longReadRegistryProvider.notifier),
    kind: LongReadKind.scan,
    paths: [scanRoot.parent],
  );
}
