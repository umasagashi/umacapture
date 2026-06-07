import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';

import '/src/addon/execution/execution_models.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

/// A function performing a built-in action. Receives the long-lived dispatcher
/// [RefBase] (for reaching providers) and the event [payload].
typedef BuiltinFn = Future<void> Function(RefBase ref, PayloadMap payload);

/// Metadata + behavior for one entry in the built-in action registry.
class BuiltinActionDescriptor {
  /// Stable key persisted in [BuiltinAction.actionKey].
  final String key;

  /// Translation key for the human-readable label.
  final String labelKey;

  final BuiltinFn run;

  const BuiltinActionDescriptor({required this.key, required this.labelKey, required this.run});
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
    run: (ref, payload) async {
      final event = payload["event"] ?? "";
      Toaster.show(ToastData.info(description: "$_trBuiltin.show_toast_message".tr(namedArgs: {"event": event})));
    },
  ),
  "copy_payload_to_clipboard": BuiltinActionDescriptor(
    key: "copy_payload_to_clipboard",
    labelKey: "$_trBuiltin.copy_payload_to_clipboard",
    run: (ref, payload) async {
      final text = payload["record_id"] ?? payload["export_path"] ?? payload["event"] ?? "";
      await Clipboard.setData(ClipboardData(text: text));
    },
  ),
};
