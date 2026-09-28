import 'dart:typed_data';

import '/src/core/app_logger.dart';
import '/src/core/fs/record_directory_transaction.dart' show sameDirectoryTree;
import '/src/core/fs/web_record_write_transaction.dart';
import '/src/core/path_entity.dart';

/// Whether [recordId] is published in [store] as [base] with [overlays] applied.
///
/// **The commit is read off disk, never inferred from a result.** A publication
/// reports through two machines with different vocabularies — `publish` and the
/// recovery it hands an interrupted slot to — and neither of them answers the
/// question the caller has to decide before it destroys anything: *is the tree
/// the user approved the one the store now holds?* `recoverRecord` answers
/// "completed" when there is no slot at all, which is also what a publication
/// that never started leaves behind, so no value it produces can stand in for
/// this.
///
/// The relation asserted is the journal's own: **published = base + overlays**,
/// in both directions, which is what `sameDirectoryTree` proves inside the
/// transaction between the staged tree and the target.
///
/// * every overlay is present under `<store>/<recordId>` with exactly its bytes;
/// * when [base] is a *different* tree (a replacing publication, where the tree
///   that survives is a copy of another record's), every other file of [base] is
///   there with equal bytes and nothing else is — the overlays themselves are
///   excluded from that comparison on both sides, because they are what the
///   publication was for;
/// * no other record store holds [recordId], which is the invariant one id
///   belongs to one store.
///
/// Whether [base] is the published tree is read from the two paths rather than
/// passed as a flag: when they are the same directory the base *is* the result,
/// so the overlay checks are the whole claim and a tree comparison would be
/// asking whether a directory equals itself.
///
/// Answers false rather than throwing. A read that fails is a postcondition this
/// could not establish, and a caller about to delete the only other copy of the
/// content has to treat "could not establish" as "did not hold".
Future<bool> survivorPublishedUnlocked(
  DirectoryPath dataRoot,
  String recordId, {
  required String store,
  required DirectoryPath base,
  required List<WebRecordWriteFile> overlays,
}) async {
  final published = dataRoot / store / recordId;
  try {
    for (final other in WebRecordWriteTransaction.recordStoreNames) {
      if (other == store) {
        continue;
      }
      if (await (dataRoot / other / recordId).exists()) {
        logger.w('The survivor postcondition failed: $other also holds $recordId.');
        return false;
      }
    }
    final overlayPaths = <String>{};
    for (final overlay in overlays) {
      final relative = PathEntity.context.joinAll(overlay.relativeSegments);
      overlayPaths.add(relative);
      final file = published.filePath(relative);
      if (!await file.exists() || !_sameBytes(await file.readAsBytes(), overlay.bytes)) {
        logger.w('The survivor postcondition failed: ${file.path} is not the published overlay.');
        return false;
      }
    }
    if (published.path == base.path) {
      return true;
    }
    if (!await sameDirectoryTree(base, published, except: overlayPaths)) {
      logger.w('The survivor postcondition failed: ${published.path} is not ${base.path} plus the overlays.');
      return false;
    }
    return true;
  } catch (error, stackTrace) {
    logger.w('The survivor postcondition could not be read for ${published.path}.', error, stackTrace);
    return false;
  }
}

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}
