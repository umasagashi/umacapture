import 'dart:typed_data';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/image_converter.dart';
import '/src/chara_detail/record_archive_state.dart';
import '/src/chara_detail/record_binding.dart';
import '/src/core/fs/record_directory_transaction.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/path_entity.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';

import 'archive_executor_types.dart';

const _archiveImageNames = ['skill.png', 'factor.png', 'campaign.png'];

/// What an archived record carries in the archive store beside its images, as the archive left it: its `record.json`
/// with the binding placed before the move (null where none could be read), and its archive note.
typedef ArchivedRecord = ({Uint8List? recordJson, RecordArchiveNote note});

/// Native implementation, called from [archive_executor_io.dart] in one worker
/// isolate. Its directory rename preserves the native filesystem's atomic
/// behavior, while image cleanup uses the same asynchronous implementation as
/// the web transaction path.
///
/// Each item answers what its record carries in the archive store, or null where it was not archived.
Future<List<ArchivedRecord?>> archiveRecordsOnNative(ArchiveBatchArgs args) async {
  final results = <ArchivedRecord?>[];
  for (final item in args.items) {
    results.add(await archiveRecordOnNative(item));
  }
  return results;
}

/// Archives one record; answers what it carries in the archive store, or null where it was not archived.
Future<ArchivedRecord?> archiveRecordOnNative(ArchiveRecordArgs args) async {
  try {
    final srcDir = DirectoryPath(args.srcDirPath);
    if (!srcDir.existsSync()) return null;
    if (DirectoryPath(args.dstDirPath).existsSync()) {
      logger.e('Cannot archive ${args.srcDirPath}: destination ${args.dstDirPath} already exists.');
      return null;
    }
    final recordJson = await placeRecordBindingUnlocked(srcDir);
    // The rename carries the choice with the record: it is in archive/ with this state, or still in active/.
    final note = await noteArchiveChoiceUnlocked(srcDir, args.option);
    final dstDir = srcDir.moveSyncSafe(DirectoryPath(args.dstDirPath));
    if (dstDir == null) return null;
    await _disposeArchivedImagesAsync(dstDir, args.option);
    return (recordJson: recordJson, note: note);
  } catch (error, stackTrace) {
    logger.e('Failed to archive record ${args.srcDirPath}.', error, stackTrace);
    return null;
  }
}

/// Web/OPFS implementation. A pre-existing destination is only resumed when it
/// is an exact duplicate of the active tree; any partial or divergent tree is
/// deliberately left untouched for recovery instead of being overwritten.
///
/// Answers per item as [archiveRecordsOnNative] does.
Future<List<ArchivedRecord?>> archiveRecordsAsync(ArchiveBatchArgs args, {RecordRecoveryGate? recoveryGate}) async {
  final results = <ArchivedRecord?>[];
  for (final item in args.items) {
    results.add(await archiveRecordAsync(item, recoveryGate: recoveryGate));
  }
  return results;
}

/// Archives one record under its lock; answers as [archiveRecordOnNative] does.
Future<ArchivedRecord?> archiveRecordAsync(
  ArchiveRecordArgs args, {
  RecordRecoveryGate? recoveryGate,
  RecordMutationLock? mutationLock,
}) {
  final source = DirectoryPath(args.srcDirPath);
  final gate = recoveryGate ?? createPlatformRecordRecoveryGate(mutationLock: mutationLock);
  return gate.runForRecord(
    source.parent.parent.parent,
    source.name,
    () => _archiveRecordAsyncLocked(args),
    // Same claim as the desktop leg's, and it is deliberately not taken here:
    // this leg locks one record at a time, so claiming per record would release
    // a batch a record at a time and bring the early ones back live while the
    // rest still had handles open.
    declaration: const LongReadDeclaration.none(
      reason: 'CharaArchiveController.archive holds the claim for the whole batch, above this platform leg',
    ),
  );
}

Future<ArchivedRecord?> _archiveRecordAsyncLocked(ArchiveRecordArgs args) async {
  try {
    final srcDir = DirectoryPath(args.srcDirPath);
    final dstDir = DirectoryPath(args.dstDirPath);
    // Before the images are let go of, under the record lock this leg holds; the desktop leg does the same.
    final recordJson = await placeRecordBindingUnlocked(srcDir);
    // The transaction carries the choice with the record, and a reload resumes or rolls back both together.
    final note = await noteArchiveChoiceUnlocked(srcDir, args.option);
    final result = await RecordDirectoryTransaction().execute(
      RecordDirectoryTransactionSpec(
        recordId: srcDir.name,
        source: srcDir,
        destination: dstDir,
        metadata: {'imageOption': args.option.name},
      ),
      beforeCommittedCleanup: (spec) => cleanupCommittedArchiveTransactionUnlocked(spec, failOnError: true),
    );
    if (!result.isCommitted) {
      logger.e('Archive transaction for ${args.srcDirPath} stopped with ${result.name}.');
      return null;
    }
    return (recordJson: recordJson, note: note);
  } catch (error, stackTrace) {
    logger.e('Failed to archive record ${args.srcDirPath}.', error, stackTrace);
    return null;
  }
}

/// Recovers manifests while the caller holds the whole-store mutation lock.
Future<List<RecordTransactionRecovery>> recoverArchiveTransactionsUnlocked(DirectoryPath dataRoot) {
  return RecordDirectoryTransaction().recoverAll(
    dataRoot,
    beforeCommittedCleanup: (spec) => cleanupCommittedArchiveTransactionUnlocked(spec, failOnError: true),
  );
}

/// Applies post-archive image disposition while the caller still owns the root
/// lock used for recovery.
Future<void> cleanupRecoveredArchiveTransactionsUnlocked(List<RecordTransactionRecovery> recoveries) async {
  for (final recovery in recoveries) {
    final spec = recovery.spec;
    if (recovery.result != RecordTransactionResult.completed || spec == null) {
      continue;
    }
    await cleanupCommittedArchiveTransactionUnlocked(spec);
  }
}

/// Applies one committed archive's deferred image disposition before its
/// transaction slot is removed. Exact-record recovery uses [failOnError] so a
/// failed cleanup keeps the slot retryable and prevents the following action.
///
/// [failOnError] only escalates failures that a retry can plausibly clear — the
/// filesystem steps, and nothing else. Content-driven failures stay best-effort
/// on every platform: see [_disposeArchivedImagesAsync].
Future<void> cleanupCommittedArchiveTransactionUnlocked(
  RecordDirectoryTransactionSpec spec, {
  bool failOnError = false,
}) async {
  final optionName = spec.metadata['imageOption'];
  final option = ArchiveImageOption.values.where((value) => value.name == optionName).firstOrNull;
  if (option == null) {
    // Content, not a transient fault, and therefore never escalated. The
    // disposition is written once when the slot is created and never rewritten,
    // so a value that does not map to an [ArchiveImageOption] will not map on
    // any retry either — escalating it under [failOnError] would leave the
    // manifest at `cleaning` forever and make every later acquisition of this
    // record's lock throw. That is the same defect an undecodable PNG used to
    // cause (see [_disposeArchivedImagesAsync]); the fix is the same.
    //
    // The archive move itself has already committed, so the transaction is
    // allowed to finish. The only consequence is that this record keeps its
    // recognition images: strictly the conservative direction, since the
    // disposition only ever deletes or downscales them.
    logger.e(
      'Archive transaction for ${spec.recordId} has no valid image disposition ("$optionName"); '
      'the archived record keeps its recognition images.',
    );
    return;
  }
  await _disposeArchivedImagesAsync(spec.destination, option, failOnError: failOnError);
}

/// Gives the images of the archived record in [recordDir] the form [state] holds them in, as an archive does: reduced
/// JPEGs for [RecordArchiveState.jpeg], none for [RecordArchiveState.none]. Best-effort, as an archive's disposition
/// is. The caller holds the record's lock.
Future<void> shapeArchivedImagesUnlocked(DirectoryPath recordDir, RecordArchiveState state) async {
  final option = switch (state) {
    RecordArchiveState.normal => null,
    RecordArchiveState.jpeg => ArchiveImageOption.resizedJpeg,
    RecordArchiveState.none => ArchiveImageOption.none,
  };
  if (option != null) await _disposeArchivedImagesAsync(recordDir, option);
}

/// Drops or downscales a committed archive's recognition images.
///
/// Image disposition is best-effort on every platform ("once the move succeeded,
/// the record is archived"): a PNG the decoder rejects, or a geometry json that
/// cannot be parsed, fails identically on every retry. Escalating such a failure
/// under [failOnError] would leave the archive manifest at `cleaning` forever,
/// which makes every later record-lock acquisition throw and takes the whole web
/// archive store down permanently. [failOnError] therefore covers only the
/// filesystem steps, where a retry can actually succeed.
Future<void> _disposeArchivedImagesAsync(
  DirectoryPath recordDir,
  ArchiveImageOption option, {
  bool failOnError = false,
}) async {
  try {
    await recordDir.filePath('prediction.json').delete(emptyOk: true);
    if (option == ArchiveImageOption.resizedJpeg) {
      final imageNames = <String>[];
      final srcs = <String>[];
      final dsts = <String>[];
      for (final imageName in _archiveImageNames) {
        final png = recordDir.filePath(imageName);
        if (await png.exists()) {
          imageNames.add(imageName);
          srcs.add(png.path);
          dsts.add(recordDir.filePath(imageName.replaceAll('.png', '.jpg')).path);
        }
      }
      final results = srcs.isEmpty
          ? const <ImageConvertResult?>[]
          : await convertPngBatchAsync(ImageConvertArgs(srcs, dsts));
      for (var i = 0; i < imageNames.length; i++) {
        final imageName = imageNames[i];
        final jpg = recordDir.filePath(imageName.replaceAll('.png', '.jpg'));
        final result = i < results.length ? results[i] : null;
        if (result == null) {
          // Undecodable input: keep the original PNG and its unscaled geometry.
          logger.w('Kept archived image ${recordDir.filePath(imageName).path}: it could not be converted.');
          continue;
        }
        try {
          await scaleIntersectionJsonAsync(
            recordDir.filePath(imageName.replaceAll('.png', '.json')),
            newWidth: result.dstWidth,
            newHeight: result.dstHeight,
          );
        } catch (error, stackTrace) {
          // Malformed geometry json: also record content, so also never fatal.
          // The JPEG below still replaces the PNG; only the (already broken)
          // layout box stays at its original size.
          logger.e('Failed to rescale geometry for ${recordDir.filePath(imageName).path}.', error, stackTrace);
        }
        if (await jpg.exists()) {
          await recordDir.filePath(imageName).delete(emptyOk: true);
        }
      }
    } else {
      // Every form of every image goes, the reduced JPEGs as well as the PNGs, and the icon cut from the factor image
      // with them: a record with no images holds none of either form.
      for (final imageName in _archiveImageNames) {
        await recordDir.filePath(imageName).delete(emptyOk: true);
        await recordDir.filePath(imageName.replaceAll('.png', '.jpg')).delete(emptyOk: true);
        await recordDir.filePath(imageName.replaceAll('.png', '.json')).delete(emptyOk: true);
      }
      await recordDir.filePath(traineeIconFileName).delete(emptyOk: true);
    }
  } catch (error, stackTrace) {
    logger.e('Failed to dispose archived images in ${recordDir.path}.', error, stackTrace);
    if (failOnError) rethrow;
  }
}
