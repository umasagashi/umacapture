/// What one write does to what the app remembers about the files it changed.
///
/// A writer that replaces bytes under a record's directory leaves the paths as they were, and
/// everything the app keyed by those paths goes on answering with the old contents: the decoded
/// pictures and the byte LRU a [RecordImage] reads, the picture already on screen, the preview
/// providers memoized per record, and the storage view's measured totals. None of them can notice
/// on its own, so the writer has to say what its write did to them.
///
/// **Declared by the caller, applied by the seam.** The caller writes *whether* (with the ref to do
/// it through) or, with a reason, why not; the seam hands [RecordImageEffect.apply] and
/// [RecordTotalsEffect.apply] *what* changed, out of the result of the write itself. A seam that
/// takes a [RecordWriteEffects] as a required argument therefore cannot be called without the
/// question being answered.
///
/// Reaches into `gui/` for the reason `record_write_invalidation.dart` does: the seam that finishes
/// a write is where its consequences are applied, and the state they drop lives next to the widgets
/// that watch it.
library;

import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/preview_dialog.dart';
import '/src/gui/record_image.dart';

import 'record_write_invalidation.dart';
import 'storage_delete_invalidation.dart';

/// What one write does to what the app remembers about the files it changed.
///
/// Both halves are required, and each says either what to do or, with a reason, why nothing: the
/// pixels and preview data cached by path, and the storage view's measured totals.
final class RecordWriteEffects {
  const RecordWriteEffects({required this.images, required this.totals});

  final RecordImageEffect images;
  final RecordTotalsEffect totals;
}

/// The pixels and preview data a write can have made stale.
sealed class RecordImageEffect {
  const RecordImageEffect();

  /// Drops every cached read of a path in the scope the seam hands to [apply].
  ///
  /// [ref] must live as long as the container -- `containerRefProvider`, read
  /// before the write's first `await`. A widget's ref, or the ref of a provider that can be disposed
  /// or invalidated (a record store's notifier included), may be gone by the time the write ends.
  const factory RecordImageEffect.drop(RefBase ref) = RecordImageDrop;

  /// Drops nothing, and says why.
  const factory RecordImageEffect.none({required String reason}) = RecordImageUnaffected;

  /// Applies this effect to what [scope] names. Never throws.
  void apply(RecordImageScope scope);
}

/// What a write changed, as the seam knows it from the write's own result.
final class RecordImageScope {
  const RecordImageScope({required this.info, required this.changed});

  /// Locates the record a changed path belongs to, for the preview providers' keys.
  final PathInfo info;

  /// Files or directories whose contents were replaced, removed or moved away.
  ///
  /// A cached path is in scope when it equals one of these or lies under one.
  final Iterable<String> changed;
}

/// Drops the pixel caches, refreshes the pictures on screen and re-reads the preview providers.
///
/// **Three stages, each failing on its own.** Each one's failure leaves only what that stage covers
/// stale and is written to [logger]; the stages after it still run. That is what the write's caller
/// relies on when it counts the write as done whatever this reports. Ordered so the two that need no
/// [ref] come first.
///
/// The guarantee is that all three are attempted after a write that declared this; a stage that
/// fails is logged, not retried.
final class RecordImageDrop extends RecordImageEffect {
  const RecordImageDrop(this.ref);

  final RefBase ref;

  @override
  void apply(RecordImageScope scope) {
    final changed = scope.changed.toList();
    try {
      evictRecordImagesWithin(changed);
    } catch (error, stackTrace) {
      logger.e('Record write: dropping the cached pixels of $changed failed.', error, stackTrace);
    }
    try {
      RecordImageInvalidations.instance.announce(changed);
    } catch (error, stackTrace) {
      logger.e('Record write: refreshing the images on screen under $changed failed.', error, stackTrace);
    }
    if (!ref.mounted) {
      // The container is gone, and every preview reader with it.
      logger.w('Record write: the container ended before the preview providers under $changed were dropped.');
      return;
    }
    try {
      invalidateRecordPreviews(ref, scope.info, changed);
    } catch (error, stackTrace) {
      logger.e('Record write: dropping the preview providers under $changed failed.', error, stackTrace);
    }
  }
}

/// A write that leaves every cached picture and preview correct.
final class RecordImageUnaffected extends RecordImageEffect {
  const RecordImageUnaffected({required this.reason})
    : assert(reason != '', 'a write that drops nothing has to say why; an empty reason says nothing');

  /// Why this write leaves the cached pictures and previews correct.
  final String reason;

  @override
  void apply(RecordImageScope scope) {
    assert(reason.trim().isNotEmpty, 'a write that drops nothing has to say why; a blank reason says nothing');
  }
}

/// The storage view's totals a write can have falsified.
sealed class RecordTotalsEffect {
  const RecordTotalsEffect();

  /// Re-measures the scope the seam hands to [apply]. [ref] as for [RecordImageEffect.drop].
  const factory RecordTotalsEffect.remeasure(RefBase ref) = RecordTotalsRemeasure;

  /// Re-measures nothing, and says why.
  const factory RecordTotalsEffect.none({required String reason}) = RecordTotalsUnaffected;

  /// Applies this effect to what [scope] names. Never throws.
  void apply(TotalsScope scope);
}

/// Which totals a write can have falsified.
///
/// The three shapes the storage view distinguishes, kept as data rather than folded into one list
/// in which "empty" would have to mean "everything".
sealed class TotalsScope {
  const TotalsScope();

  /// The record root: what a record write can reach ([recordWriteTotalsTargets]).
  const factory TotalsScope.recordRoot(PathInfo info) = _RecordRootTotals;

  /// The paths a storage-view delete touched ([storageDeleteTotalsTargets]). Never empty.
  const factory TotalsScope.paths(List<PathEntity> touched) = _PathTotals;

  /// Every total: the settings delete, which removes files its request does not
  /// name — it names only the directory the stores live in, for its claim, and
  /// none on web.
  const factory TotalsScope.everything() = _AllTotals;
}

final class _RecordRootTotals extends TotalsScope {
  const _RecordRootTotals(this.info);

  final PathInfo info;
}

final class _PathTotals extends TotalsScope {
  const _PathTotals(this.touched);

  final List<PathEntity> touched;
}

final class _AllTotals extends TotalsScope {
  const _AllTotals();
}

/// Makes the storage view re-measure what a write changed.
///
/// Skipped when [ref] is no longer mounted, as `module_install_invalidation.dart` does: the
/// container that held the view is gone.
///
/// Equal to another [RecordTotalsRemeasure] over the identical [ref], so a batch of writes that each
/// declared one collapses to a single re-measure.
final class RecordTotalsRemeasure extends RecordTotalsEffect {
  const RecordTotalsRemeasure(this.ref);

  final RefBase ref;

  @override
  void apply(TotalsScope scope) {
    if (!ref.mounted) {
      logger.w('Record write: the container ended before the storage totals were re-measured.');
      return;
    }
    try {
      switch (scope) {
        case _RecordRootTotals(:final info):
          refreshStorageTabAfterRecordWrite(ref, info);
        case _PathTotals(:final touched):
          assert(touched.isNotEmpty, 'an empty list of touched paths is TotalsScope.everything()');
          refreshStorageTabAfterDelete(ref, touched: touched);
        case _AllTotals():
          refreshStorageTabAfterDelete(ref, touched: const []);
      }
    } catch (error, stackTrace) {
      logger.e('Record write: re-measuring the storage totals failed.', error, stackTrace);
    }
  }

  @override
  bool operator ==(Object other) => other is RecordTotalsRemeasure && identical(other.ref, ref);

  @override
  int get hashCode => identityHashCode(ref);
}

/// A write that leaves every total correct.
final class RecordTotalsUnaffected extends RecordTotalsEffect {
  const RecordTotalsUnaffected({required this.reason})
    : assert(reason != '', 'a write that re-measures nothing has to say why; an empty reason says nothing');

  /// Why this write leaves the storage view's totals correct.
  final String reason;

  @override
  void apply(TotalsScope scope) {
    assert(reason.trim().isNotEmpty, 'a write that re-measures nothing has to say why; a blank reason says nothing');
  }
}

/// Drops every [recordPreviewReaders] entry a write under [changed] can have made stale.
///
/// **Keyed by rebuilding the readers' key, not by reusing the writer's path.** Every reader keys a
/// record by `recordDirOfId(...).path`, so a changed path under `<store>/<id>` is mapped back to that
/// record's id and the key is built with the same function: how the writer spelled its directory
/// does not have to match. A path at a store directory or above it drops every record's entry; a
/// path outside the record stores drops nothing.
void invalidateRecordPreviews(RefBase ref, PathInfo info, Iterable<String> changed) {
  final keys = <String>{};
  var everything = false;
  for (final path in changed) {
    final segments = PathEntity.parseSegments(path);
    for (final source in RecordSource.values) {
      final storeDir = switch (source) {
        RecordSource.active => info.charaDetailActiveDir,
        RecordSource.archive => info.charaDetailArchiveDir,
      };
      if (isRecordPathWithin(storeDir.path, path)) {
        everything = true;
      } else if (isRecordPathWithin(path, storeDir.path)) {
        keys.add(recordDirOfId(info, source, segments[PathEntity.parseSegments(storeDir.path).length]).path);
      }
    }
  }
  for (final reader in recordPreviewReaders) {
    if (everything) {
      ref.invalidate(reader.family);
      continue;
    }
    for (final key in keys) {
      ref.invalidate(reader.at(key));
    }
  }
}
