import 'package:flutter/services.dart';

import '/src/addon/execution/execution_models.dart';
import '/src/addon/payload_enricher.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/clipboard_image_writer.dart';
import '/src/core/path_entity.dart';
import '/src/core/sound_player.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

/// A function performing a built-in action. Receives the long-lived dispatcher
/// [RefBase] (for reaching providers), the event [payload], the optional
/// user-configured [argument], and the optional [secondaryArgument] (both already
/// declared by the descriptor; actions that take fewer simply ignore the rest).
typedef BuiltinFn = Future<void> Function(RefBase ref, PayloadMap payload, String? argument, String? secondaryArgument);

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

  /// Whether this action takes a second free-form argument (e.g. a destination
  /// path), shown as an additional text field below the first. Used by actions
  /// that need two inputs at once, where the first is an options dropdown.
  final bool usesSecondArgument;

  /// Translation key for the second argument field's label (only used when
  /// [usesSecondArgument]).
  final String? secondaryArgumentLabelKey;

  /// Translation key for the second argument field's helper text. Defaults to the
  /// shared "placeholders are substituted" hint.
  final String? secondaryArgumentHelperKey;

  /// Whether the second argument accepts payload `{placeholders}` (and so shows
  /// the placeholder dropdown beneath its field).
  final bool secondaryArgumentUsesPlaceholders;

  /// Default template for the second argument of a freshly configured action.
  final String defaultSecondArgument;

  /// Whether a browser offers any API at all for what this action does.
  ///
  /// False only where no browser counterpart exists in any circumstance: putting
  /// a *file reference* on the clipboard (a page can only offer bytes) and
  /// writing to an arbitrary host path (OPFS is origin-private). The task editor
  /// keeps those visible but unselectable on web, and the runtime checks remain
  /// as a backstop for definitions saved by an older version.
  ///
  /// An action a browser *can* perform, but only under some condition, stays
  /// true here and names the condition instead — see [requiresUserGesture].
  final bool supportsWeb;

  /// Whether the action only succeeds while the transient user activation from a
  /// real click is still alive.
  ///
  /// This names a property of the *trigger*, not of the platform: the action is
  /// selectable on every host, and where the clipboard demands a gesture
  /// ([clipboardWriteNeedsGesture], i.e. in a browser) the ▶ manual run is the
  /// one trigger that carries one — it reaches the clipboard write inside the
  /// click's own task. An automatic trigger there fails with an explicit reason
  /// (see [gestureRefusesRun]) instead of silently doing nothing.
  final bool requiresUserGesture;

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
    this.usesSecondArgument = false,
    this.secondaryArgumentLabelKey,
    this.secondaryArgumentHelperKey,
    this.secondaryArgumentUsesPlaceholders = true,
    this.defaultSecondArgument = '',
    this.supportsWeb = true,
    this.requiresUserGesture = false,
  });
}

const _trBuiltin = "pages.addon.builtin";

/// The diagnostic text persisted when [gestureRefusesRun] refuses a run.
///
/// Deliberately English and untranslated, matching every other persisted
/// [ExecutionResult.error] (see the same statement on `webhookWebBlockedHint` in
/// `webhook_runner.dart`): history entries hold diagnostic text that is shown
/// verbatim in the detail dialog and is meant to be pasted into a bug report,
/// not localized prose. This threw `pages.addon.action.unsupported_on_web`
/// **already translated**, so the one Japanese sentence in the field arrived
/// wearing Dart's `Bad state: ` prefix.
///
/// The user-facing half of this condition is not lost by saying it in English
/// here: it is `_BuiltinManualRunNote` in the task editor, which renders that
/// same translation key beside the action picker *before* the pairing is saved.
/// The two are separate on purpose — the note explains, this records.
const builtinGestureBlockedHint =
    "This action needs the transient user activation of a click, which an "
    "automatic trigger does not carry. Only the manual run button can execute "
    "it on this host.";

/// Whether [payload] belongs to a run started by the ▶ button.
///
/// `AddonExecutionController.runManual` is the only producer of `event: manual`
/// (every automatic trigger writes its own event name, and a chain hop rewrites
/// it to `task_executed`), so this is the payload-level expression of "the click
/// that started this run is still in progress".
bool isManualRun(PayloadMap payload) => payload["event"] == "manual";

/// Whether an action declaring [BuiltinActionDescriptor.requiresUserGesture]
/// must refuse this run: the host's clipboard needs a transient user activation
/// and the run did not start from the ▶ button.
///
/// [needsGesture] defaults to the host capability and is injectable only because
/// `flutter test` always runs on the VM, where the browser answer is otherwise
/// unreachable.
bool gestureRefusesRun(PayloadMap payload, {bool needsGesture = clipboardWriteNeedsGesture}) =>
    needsGesture && !isManualRun(payload);

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
    run: (ref, payload, argument, secondaryArgument) async {
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
    run: (ref, payload, argument, secondaryArgument) async {
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
    // Copying image *bytes* is something a browser can do — `ClipboardItem`
    // carries them — but only within a click's transient user activation. The
    // limit is the trigger, not the platform, so the action stays available on
    // web and declares the gesture requirement instead.
    requiresUserGesture: true,
    run: (ref, payload, argument, secondaryArgument) async {
      // Refuse before touching the record so an automatic trigger reports the
      // actual reason rather than a bare "failed". Never taken on a host whose
      // clipboard needs no gesture (Windows), where every trigger still works.
      if (gestureRefusesRun(payload)) throw StateError(builtinGestureBlockedHint);
      final record = _requireRecord(ref, payload);
      // silent: the execution-history entry already reports the outcome, so an
      // automated/chained run shouldn't also pop a clipboard toast.
      final ok = await ClipboardAlt.pasteImage(
        ref,
        _recordImagePath(ref, record, (argument ?? "trainee").trim()),
        silent: true,
        // The ▶ run reaches this synchronously from the button's callback, so
        // the browser still sees the click as the write's originating gesture.
        userInitiated: isManualRun(payload),
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
    supportsWeb: false,
    run: (ref, payload, argument, secondaryArgument) async {
      final record = _requireRecord(ref, payload);
      final path = _recordFilePath(ref, record, (argument ?? "trainee").trim());
      final ok = await ClipboardAlt.pasteEntity(ref, path, silent: true);
      if (!ok) throw StateError("Failed to copy file to clipboard.");
    },
  ),
  "copy_file_to_path": BuiltinActionDescriptor(
    key: "copy_file_to_path",
    labelKey: "$_trBuiltin.copy_file_to_path",
    usesArgument: true,
    requiresRecord: true,
    argumentLabelKey: "$_trBuiltin.copy_file_argument",
    argumentUsesPlaceholders: false,
    argumentOptions: [
      ..._imageKindOptions("file"),
      BuiltinArgumentOption("record_json", "$_trBuiltin.options.file_record"),
    ],
    defaultArgument: "trainee",
    usesSecondArgument: true,
    secondaryArgumentLabelKey: "$_trBuiltin.copy_file_to_path_destination",
    defaultSecondArgument: "",
    supportsWeb: false,
    run: (ref, payload, argument, secondaryArgument) async {
      final record = _requireRecord(ref, payload);
      final source = _recordFilePath(ref, record, (argument ?? "trainee").trim());
      final destination = substitutePayload(secondaryArgument ?? "", payload).trim();
      if (destination.isEmpty) {
        throw StateError("No destination path configured for the copy-to-path action.");
      }
      final target = FilePath(destination);
      // Create the destination's parent folders so a template pointing into a new
      // subfolder works on the first run, then overwrite any existing file.
      await target.parent.create(recursive: true);
      await source.toFile().copy(target.path);
    },
  ),
  "play_sound": BuiltinActionDescriptor(
    key: "play_sound",
    labelKey: "$_trBuiltin.play_sound",
    usesArgument: true,
    argumentLabelKey: "$_trBuiltin.play_sound_argument",
    argumentUsesPlaceholders: false,
    argumentOptions: const [
      BuiltinArgumentOption("success", "$_trBuiltin.options.sound_success"),
      BuiltinArgumentOption("standby", "$_trBuiltin.options.sound_standby"),
      BuiltinArgumentOption("error", "$_trBuiltin.options.sound_error"),
    ],
    defaultArgument: "success",
    run: (ref, payload, argument, secondaryArgument) async {
      // Accept the pre-rename argument strings ("attention_weak"/"attention_normal") as aliases so
      // addon definitions authored before the role rename keep working.
      final type = switch ((argument ?? "success").trim()) {
        "standby" || "attention_weak" => SoundType.standby,
        "error" => SoundType.error,
        _ => SoundType.success,
      };
      await ref.read(soundEffectProvider(type).future).playSafely();
    },
  ),
};

/// Resolves the record referenced by the payload, throwing when the trigger
/// carries no `record_id` or the record is gone.
CharaDetailRecord _requireRecord(RefBase ref, PayloadMap payload) {
  final recordId = payload["record_id"];
  if (recordId == null || recordId.isEmpty) {
    throw StateError(
      "No record_id in the payload: this action needs a record "
      "(record-captured trigger, a chain from it, or a manual run with at least one captured record).",
    );
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

/// Resolves the file referenced by a `copy_file_*` action's [kind] keyword:
/// `record_json` maps to the record's json file, every other keyword to an image
/// via [_recordImagePath]. Shared by the clipboard and the copy-to-path actions.
FilePath _recordFilePath(RefBase ref, CharaDetailRecord record, String kind) {
  if (kind == "record_json") {
    final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    return storage.recordPathOf(record).filePath(recordJsonName);
  }
  return _recordImagePath(ref, record, kind);
}
