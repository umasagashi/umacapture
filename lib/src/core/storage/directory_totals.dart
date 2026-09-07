/// Recursive size and timestamp totals for a directory in the storage view.
///
/// The tree shows a directory's total bytes and its newest timestamp, and
/// neither exists as a filesystem value: a directory's own `stat().size` is an
/// inode figure unrelated to its contents, and on web a `FileSystemDirectoryHandle`
/// exposes no metadata at all. Both have to be aggregated over the descendants.
///
/// **This never runs by itself.** Expanding a node lists one level; the totals
/// are computed only when [DirectoryTotalsCache.totalsOf] is called for a
/// specific directory. Nothing in this file is invoked from a constructor, a
/// provider build, or an expansion callback.
library;

import '/src/core/path_entity.dart';

/// What one aggregation found.
///
/// [knownBytes] and [unknownSizeFiles] are separate fields because they are
/// separate facts. A file whose size the enumeration could not resolve is not a
/// zero-byte file, and folding it in either direction states something the walk
/// did not observe: adding zero claims a total that is exact when it is a lower
/// bound, and answering "unknown" for the whole directory throws away every size
/// that *was* read. The caller therefore has both, and can render `1.2 MB` when
/// [unknownSizeFiles] is zero and a qualified form (`1.2 MB` with a note, or
/// `1.2 MB 以上`) when it is not.
///
/// [computedAt] is here for the same reason: this number was true at a moment,
/// and nothing on either platform will tell the cache when it stops being true
/// (see [DirectoryTotalsCache]). Carrying the moment lets the UI say so instead
/// of implying the value is live.
typedef DirectoryTotals = ({
  int knownBytes,
  int unknownSizeFiles,
  int fileCount,
  DateTime? latestModified,
  DateTime computedAt,
});

/// The answer for a directory that holds no files, and the answer for one that
/// does not exist.
///
/// [latestModified] is `null`, not the epoch and not "now": an empty directory
/// has no descendant to take a timestamp from, so the value does not exist.
/// The view renders that as `—`.
DirectoryTotals _empty() =>
    (knownBytes: 0, unknownSizeFiles: 0, fileCount: 0, latestModified: null, computedAt: DateTime.now());

/// Walks [directory] and totals its descendants.
///
/// One enumeration, `recursive: true`, `withMetadata: true` — the sizes and
/// timestamps come back *with* the listing. Calling `length()` (or `modified()`)
/// per entry instead would be one extra root-to-leaf handle walk per file on
/// OPFS, which is the cost `FsEntry`'s metadata surface was added to avoid; the
/// io backend measures the same shape as ~96x on a 2,000-entry directory.
///
/// Only files contribute to [DirectoryTotals.latestModified]. A directory's own
/// timestamp is readable on Windows and does not exist on web, so counting it
/// would make the same tree answer differently on the two platforms for the same
/// content — the web value would be "newest descendant file" and the Windows one
/// "newest of that and every folder's own mtime", which changes when a folder is
/// created but no file is written. Files are what both platforms can see.
Future<DirectoryTotals> aggregateDirectoryTotals(DirectoryPath directory) async {
  // A group's directory legitimately does not exist yet (nothing quarantined, no
  // temp session). That is an empty total, not an error; letting the backend
  // throw would make an ordinary empty group look like a failure.
  if (!await directory.exists()) {
    return _empty();
  }

  var knownBytes = 0;
  var unknownSizeFiles = 0;
  var fileCount = 0;
  DateTime? latestModified;

  for (final listing in await directory.listWithMetadata(recursive: true)) {
    // The kind comes off the entity's type, which the enumeration already
    // decided. A directory has no size on either backend by contract, so it must
    // not be counted as an unresolved one.
    if (listing.entity is DirectoryPath) {
      continue;
    }
    fileCount++;
    final size = listing.size;
    if (size == null) {
      unknownSizeFiles++;
    } else {
      knownBytes += size;
    }
    final modified = listing.modified;
    if (modified != null && (latestModified == null || modified.isAfter(latestModified))) {
      latestModified = modified;
    }
  }

  return (
    knownBytes: knownBytes,
    unknownSizeFiles: unknownSizeFiles,
    fileCount: fileCount,
    latestModified: latestModified,
    computedAt: DateTime.now(),
  );
}

/// Remembers what [aggregateDirectoryTotals] found, per directory.
///
/// ## What makes an entry stale
///
/// Exactly two things, and the cache can only see one of them:
///
/// 1. **This app changed the tree.** Deleting a group, importing records,
///    capturing, clearing temp. Every one of those is a call site inside this
///    app, and each must call [invalidate] with the path it touched;
///    [invalidate] also drops the touched path's ancestors, whose totals include
///    it, and its descendants, which a directory delete removes. Stage 6 owns
///    wiring the deletes; the entry point exists now so that wiring is a call and
///    not a redesign.
/// 2. **Something outside this app changed the tree** — Explorer, a second copy
///    of the app, another browser tab writing the same OPFS origin. Neither
///    backend offers change notification and this app runs no watcher, so the
///    cache *cannot* detect it and must not pretend to. That is why
///    [DirectoryTotals.computedAt] is part of the value and why [clear] exists:
///    the honest handling is to show when the number was taken and let the user
///    ask again.
///
/// There is no time-based expiry. A duration would be a guess at how often case 2
/// happens, and would replace "this number is from 14:02" with "this number is
/// from some point in the last N seconds", which is strictly less information.
///
/// ## Concurrency
///
/// Two expansions of the same directory share one walk: an in-flight computation
/// is handed to the second caller rather than started again. On OPFS a duplicate
/// walk is a duplicate of the whole handle-chain traversal, on the one thread the
/// UI also runs on.
///
/// **Sharing stops at an invalidation.** A walk carries the [_generation] it
/// started in, and only a caller asking in that same generation may join it. A
/// walk that began before a delete read the tree in unknown proportion either
/// side of it, so handing it to someone who asked *after* the delete would answer
/// a question about the new tree with a measurement of the old one — the user
/// deletes files and the size does not move. Such a caller gets a walk of its
/// own; the two run concurrently, which is the price of the walk not being
/// cancellable, and the duplicate is bounded by the invalidation being a
/// deliberate, rare gesture rather than by anything periodic.
class DirectoryTotalsCache {
  final Map<String, DirectoryTotals> _totals = {};
  final Map<String, _RunningWalk> _inFlight = {};

  /// The cached total for [directory], or `null` if none has been computed.
  ///
  /// Synchronous, so a widget's `build` can choose between the value and the
  /// "計算中…" placeholder without starting anything.
  DirectoryTotals? peek(DirectoryPath directory) => _totals[_key(directory)];

  /// Whether a walk for [directory] is running right now.
  bool isComputing(DirectoryPath directory) => _inFlight.containsKey(_key(directory));

  /// Returns the cached total for [directory], computing it if there is none.
  ///
  /// This is the only thing in this file that touches the filesystem, and it runs
  /// only when called.
  Future<DirectoryTotals> totalsOf(DirectoryPath directory) {
    final key = _key(directory);
    final cached = _totals[key];
    if (cached != null) {
      return Future.value(cached);
    }
    final startedAt = _generation;
    final running = _inFlight[key];
    // Only a walk from this generation. One started before an invalidation
    // answers a question about a tree that no longer exists; see the class doc.
    if (running != null && running.generation == startedAt) {
      return running.future;
    }
    final walk = _RunningWalk(startedAt);
    walk.future = aggregateDirectoryTotals(directory)
        .then((totals) {
          // An invalidation that arrived while this walk was running means the walk
          // may have read the tree before the change and after it, in unknown
          // proportion. Storing that would re-introduce the stale value the caller
          // just took the trouble to drop, so the result is returned to whoever
          // asked *before* the invalidation -- nobody else can have joined -- and
          // not cached.
          if (_generation == startedAt) {
            _totals[key] = totals;
          }
          return totals;
        })
        // Statement body, not an expression one: `Map.remove` returns the value it
        // removed, and `whenComplete` waits on a future its callback returns -- so
        // an arrow form deadlocked the walk against itself back when the map held
        // the future directly, and `totalsOf` never completed.
        //
        // The identity check is what makes an overtaken walk harmless. Once an
        // invalidation has been overtaken, a newer walk owns this key, and a bare
        // `remove` here would evict *it* -- leaving `isComputing` false while a
        // walk runs and sending the next caller off on a third traversal of the
        // same tree, which is the duplicate the sharing above exists to avoid.
        .whenComplete(() {
          if (identical(_inFlight[key], walk)) {
            _inFlight.remove(key);
          }
        });
    _inFlight[key] = walk;
    return walk.future;
  }

  /// Drops everything whose total [changed] can have altered: [changed] itself,
  /// every ancestor of it (their totals contain it) and everything under it (a
  /// directory delete takes its subtree with it).
  ///
  /// A walk already in flight is left alone rather than cancelled — it cannot be
  /// — but its result reaches nobody who was not already waiting on it:
  /// [_generation] moves, so the completion handler will not store a total whose
  /// generation no longer matches, and [totalsOf] will not hand that walk to a
  /// caller asking from the new generation either. The caller that started it
  /// still receives it, because dropping an answer someone is awaiting would
  /// leave that row with nothing at all.
  void invalidate(PathEntity changed) {
    _generation++;
    final target = PathEntity.context.normalize(changed.path);
    _totals.removeWhere((key, _) {
      final other = PathEntity.context.normalize(key);
      return PathEntity.context.equals(other, target) ||
          PathEntity.context.isWithin(other, target) ||
          PathEntity.context.isWithin(target, other);
    });
  }

  /// Drops every cached total. The refresh gesture, and what a tab close or a
  /// data-root change uses.
  void clear() {
    _generation++;
    _totals.clear();
  }

  int _generation = 0;

  String _key(DirectoryPath directory) => PathEntity.context.normalize(directory.path);
}

/// One running walk, and the generation it started in.
///
/// **A class because the walk has to name itself before it exists.** The
/// completion handler installed on [future] closes over the very object that
/// holds it, so the object must be constructed first and its future assigned
/// after — which is what `late final` buys and what no record can express: a
/// record is built from its fields, and this field is built from the record.
///
/// The `identical` check the handler then makes is also why a record would be
/// the wrong shape even if one could be built. Records are values, and applying
/// `identical` to a value is *unspecified* in Dart — two structurally equal
/// records may or may not be the same object — so the handler's question ("is
/// the entry under this key still mine?") would have no defined answer. Note it
/// is not that a record would compare *equal* here: a record's `==` is
/// field-wise, and a `Future` field compares by identity, so two walks of one
/// directory in one generation would already differ. They cannot both be running
/// in any case — [DirectoryTotalsCache.totalsOf] hands the first one to the
/// second caller.
class _RunningWalk {
  _RunningWalk(this.generation);

  final int generation;
  late final Future<DirectoryTotals> future;
}
