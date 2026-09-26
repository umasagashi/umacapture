import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/record_write_effects.dart';
import 'package:umacapture/src/gui/chara_detail/archive_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/data_table_widget.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/enhancement_merge_dialog.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';

/// The declaration a record's arrival makes in the app: the store's capture listener and the web
/// harvest both drop the arriving directory's cached reads and re-measure the record root.
RecordWriteEffects arrivalEffects(ProviderContainer container) =>
    recordArrivalEffects(container.read(containerRefProvider));

/// The declaration the app's whole-store inheritance resolution makes (`enhancementMergeActionsProvider`).
RecordWriteEffects inheritanceResolutionEffects(ProviderContainer container) =>
    inheritanceResolutionDeclaration(container.read(containerRefProvider));

/// The declaration a successful re-recognition makes (`onCharaDetailUpdated` in `platform_controller.dart`).
RecordWriteEffects regenerationEffects(ProviderContainer container) =>
    recordRegenerationEffects(container.read(containerRefProvider));

/// The declaration the storage view's delete makes (`StorageDeleteConfirmDialog` in `storage_delete_action.dart`).
RecordWriteEffects storageDeleteEffects(ProviderContainer container) =>
    storageViewDeleteEffects(container.read(containerRefProvider));

/// The declaration an ordinary record delete makes (`delete_record_dialog.dart`, both dialogs).
RecordWriteEffects recordDeleteEffects(ProviderContainer container) =>
    recordDeleteDialogEffects(container.read(containerRefProvider));

/// The declaration an archive makes (`archive_record_dialog.dart`, both dialogs).
RecordWriteEffects archiveEffects(ProviderContainer container) =>
    archiveDialogEffects(container.read(containerRefProvider));

/// The declaration an enhancement merge makes (`enhancementMergeActionsProvider`).
RecordWriteEffects mergeEffects(ProviderContainer container) =>
    enhancementMergeEffects(container.read(containerRefProvider));

/// The declaration the one-time archive geometry repair makes (`charaDetailInitialDataLoader`).
RecordWriteEffects geometryRepairEffects(ProviderContainer container) =>
    archiveGeometryRepairEffects(container.read(containerRefProvider));

/// The long-read declaration the same repair makes.
LongReadDeclaration geometryRepairLongReadDeclaration(ProviderContainer container, PathInfo layout) =>
    archiveGeometryRepairLongReadDeclaration(container.read(containerRefProvider), layout);
