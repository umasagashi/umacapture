import 'package:flutter/services.dart';

import '/src/addon/execution/execution_models.dart';
import '/src/addon/payload_enricher.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/path_entity.dart';
import '/src/core/sound_player.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

/// A function performing a built-in action. Receives the long-lived dispatcher
/// [RefBase] (for reaching providers), the event [payload], and the optional
/// user-configured [argument] (already declared by the descriptor).
typedef BuiltinFn = Future<void> Function(RefBase ref, PayloadMap payload, String? argument);

/// A selectable value for a built-in action argument, shown as a dropdown option
/// in the edit dialog instead of a free-text field.
class BuiltinArgumentOption {
  /// The value persisted in [BuiltinAction.argument].
  final String value;

  /// Translation key for the option's human-readable label.
  final String labelKey;

  const BuiltinArgumentOption(this.value, this.labelKey);
}

/// Metadata + behavior for one entry in the built-in action registry.
class BuiltinActionDescriptor {
  /// Stable key persisted in [BuiltinAction.actionKey].
  final String key;

  /// Translation key for the human-readable label.
  final String labelKey;

  /// Whether this action takes a free-form [BuiltinAction.argument]. When true,
  /// the edit dialog shows a template field seeded with [defaultArgument].
  final bool usesArgument;

  /// Whether the action requires the payload to carry a `record_id`. When true,
  /// the edit dialog rejects pairing it with a trigger that never supplies one
  /// (so the user gets immediate feedback instead of a recurring runtime failure),
  /// and [_requireRecord] enforces it at run time.
  final bool requiresRecord;

  /// Translation key for the argument field's label (only used when [usesArgument]).
  final String? argumentLabelKey;

  /// Translation key for the argument field's helper text. Defaults to the shared
  /// "placeholders are substituted" hint; override for arguments that take no
  /// placeholders (e.g. a fixed set of keywords).
  final String? argumentHelperKey;

  /// Whether the argument accepts payload `{placeholders}`. When false the edit
  /// dialog hides the placeholder dropdown (the argument is a plain keyword, not
  /// a template).
  final bool argumentUsesPlaceholders;

  /// When set, the argument is chosen from these fixed options via a dropdown
  /// instead of typed into a text field. Implies a keyword argument that takes
  /// no placeholders.
  final List<BuiltinArgumentOption>? argumentOptions;

  /// Default argument template for a freshly configured action.
  final String defaultArgument;

  final BuiltinFn run;

  const BuiltinActionDescriptor({
    required this.key,
    required this.labelKey,
    required this.run,
    this.usesArgument = false,
    this.requiresRecord = false,
    this.argumentLabelKey,
    this.argumentHelperKey,
    this.argumentUsesPlaceholders = true,
    this.argumentOptions,
    this.defaultArgument = '',
  });
}

const _trBuiltin = "pages.addon.builtin";

/// Maps an image-kind keyword to the record file it resolves to, shared by the
/// `copy_image` / `copy_file` argument dropdowns and [_recordImagePath] so the
/// keyword set is defined once. Adding a kind here surfaces it in both dropdowns
/// and the path resolver at the same time, so an option can never reference a
/// keyword the resolver does not handle (which would silently copy the wrong
/// image via the fallback).
final _recordImageKinds = <String, FilePath Function(CharaDetailRecordStorage, CharaDetailRecord)>{
  "trainee": (storage, record) => storage.traineeIconPathOf(record),
  "skill": (storage, record) => storage.imagePathOf(record, CharaDetailRecordImageMode.skillPlain),
  "factor": (storage, record) => storage.imagePathOf(record, CharaDetailRecordImageMode.factorPlain),
  "campaign": (storage, record) => storage.imagePathOf(record, CharaDetailRecordImageMode.campaignPlain),
};

/// The argument options for an image-kind builtin, labeled under [labelPrefix]
/// (e.g. `image` or `file`), derived from [_recordImageKinds].
List<BuiltinArgumentOption> _imageKindOptions(String labelPrefix) => [
  for (final kind in _recordImageKinds.keys) BuiltinArgumentOption(kind, "$_trBuiltin.options.${labelPrefix}_$kind"),
];

/// Registry of built-in actions, keyed by [BuiltinActionDescriptor.key].
///
/// Kept intentionally side-effect-light for the MVP. Each entry reaches existing
/// app facilities (toast, clipboard); new entries only need to be added here.
final builtinActionRegistry = <String, BuiltinActionDescriptor>{
  "show_toast": BuiltinActionDescriptor(
    key: "show_toast",
    labelKey: "$_trBuiltin.show_toast",
    usesArgument: true,
    argumentLabelKey: "$_trBuiltin.show_toast_argument",
    defaultArgument: "{event}",
    run: (ref, payload, argument) async {
      final text = substitutePayload(argument ?? "{event}", payload);
      Toaster.show(ToastData.info(description: text));
    },
  ),
  "copy_payload_to_clipboard": BuiltinActionDescriptor(
    key: "copy_payload_to_clipboard",
    labelKey: "$_trBuiltin.copy_payload_to_clipboard",
    usesArgument: true,
    argumentLabelKey: "$_trBuiltin.copy_payload_argument",
    defaultArgument: "{record_id}",
    run: (ref, payload, argument) async {
      final text = substitutePayload(argument ?? "{record_id}", payload);
      await Clipboard.setData(ClipboardData(text: text));
    },
  ),
  "copy_image_to_clipboard": BuiltinActionDescriptor(
    key: "copy_image_to_clipboard",
    labelKey: "$_trBuiltin.copy_image_to_clipboard",
    usesArgument: true,
    requiresRecord: true,
    argumentLabelKey: "$_trBuiltin.copy_image_argument",
    argumentUsesPlaceholders: false,
    argumentOptions: _imageKindOptions("image"),
    defaultArgument: "trainee",
    run: (ref, payload, argument) async {
      final record = _requireRecord(ref, payload);
      // silent: the execution-history entry already reports the outcome, so an
      // automated/chained run shouldn't also pop a clipboard toast.
      final ok = await ClipboardAlt.pasteImage(
        ref,
        _recordImagePath(ref, record, (argument ?? "trainee").trim()),
        silent: true,
      );
      if (!ok) throw StateError("Failed to copy image to clipboard.");
    },
  ),
  "copy_file_to_clipboard": BuiltinActionDescriptor(
    key: "copy_file_to_clipboard",
    labelKey: "$_trBuiltin.copy_file_to_clipboard",
    usesArgument: true,
    requiresRecord: true,
    argumentLabelKey: "$_trBuiltin.copy_file_argument",
    argumentUsesPlaceholders: false,
    argumentOptions: [
      ..._imageKindOptions("file"),
      BuiltinArgumentOption("record_json", "$_trBuiltin.options.file_record"),
    ],
    defaultArgument: "trainee",
    run: (ref, payload, argument) async {
      final record = _requireRecord(ref, payload);
      final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
      final kind = (argument ?? "trainee").trim();
      final path = kind == "record_json"
          ? storage.recordPathOf(record).filePath(recordJsonName)
          : _recordImagePath(ref, record, kind);
      final ok = await ClipboardAlt.pasteFile(ref, path, silent: true);
      if (!ok) throw StateError("Failed to copy file to clipboard.");
    },
  ),
  "play_sound": BuiltinActionDescriptor(
    key: "play_sound",
    labelKey: "$_trBuiltin.play_sound",
    usesArgument: true,
    argumentLabelKey: "$_trBuiltin.play_sound_argument",
    argumentUsesPlaceholders: false,
    argumentOptions: const [
      BuiltinArgumentOption("attention_normal", "$_trBuiltin.options.sound_attention_normal"),
      BuiltinArgumentOption("attention_weak", "$_trBuiltin.options.sound_attention_weak"),
      BuiltinArgumentOption("error", "$_trBuiltin.options.sound_error"),
    ],
    defaultArgument: "attention_normal",
    run: (ref, payload, argument) async {
      final type = switch ((argument ?? "attention_normal").trim()) {
        "attention_weak" => SoundType.attentionWeak,
        "error" => SoundType.error,
        _ => SoundType.attentionNormal,
      };
      final effect = await ref.read(soundEffectProvider(type).future);
      await effect.play();
    },
  ),
};

/// Resolves the record referenced by the payload, throwing when the trigger
/// carries no `record_id` or the record is gone.
CharaDetailRecord _requireRecord(RefBase ref, PayloadMap payload) {
  final recordId = payload["record_id"];
  if (recordId == null || recordId.isEmpty) {
    throw StateError("This action requires a record_id (use the record-captured trigger).");
  }
  // Reuse the enricher's resolver so a just-captured record is found on disk even
  // when the storage notifier hasn't folded it in yet (the capture-event race).
  final record = resolveRecordById(ref, recordId);
  if (record == null) throw StateError("Record not found: $recordId");
  return record;
}

/// Maps an image-kind keyword to its file path within [record], falling back to
/// the trainee icon for an unknown keyword (matches the dropdown's default).
FilePath _recordImagePath(RefBase ref, CharaDetailRecord record, String kind) {
  final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
  final resolver = _recordImageKinds[kind] ?? _recordImageKinds["trainee"]!;
  return resolver(storage, record);
}
