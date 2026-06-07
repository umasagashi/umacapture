import 'package:flutter/services.dart';

import '/src/addon/execution/execution_models.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

/// A function performing a built-in action. Receives the long-lived dispatcher
/// [RefBase] (for reaching providers), the event [payload], and the optional
/// user-configured [argument] (already declared by the descriptor).
typedef BuiltinFn = Future<void> Function(RefBase ref, PayloadMap payload, String? argument);

/// Metadata + behavior for one entry in the built-in action registry.
class BuiltinActionDescriptor {
  /// Stable key persisted in [BuiltinAction.actionKey].
  final String key;

  /// Translation key for the human-readable label.
  final String labelKey;

  /// Whether this action takes a free-form [BuiltinAction.argument]. When true,
  /// the edit dialog shows a template field seeded with [defaultArgument].
  final bool usesArgument;

  /// Translation key for the argument field's label (only used when [usesArgument]).
  final String? argumentLabelKey;

  /// Default argument template for a freshly configured action.
  final String defaultArgument;

  final BuiltinFn run;

  const BuiltinActionDescriptor({
    required this.key,
    required this.labelKey,
    required this.run,
    this.usesArgument = false,
    this.argumentLabelKey,
    this.defaultArgument = '',
  });
}

const _trBuiltin = "pages.addon.builtin";

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
};
