/// How one settings value is put on screen.
///
/// **Three general rules and no per-type formatting.** A value is shown as JSON
/// when `dart_mappable` can produce JSON for it, and as `toString()` otherwise;
/// see [SettingsValueTier] for the three tiers. Formatting a settings value
/// type by type was rejected: the set of types a settings box holds grows, and a
/// hand-kept table of them would silently stop covering it.
///
/// This is the **decision**, not the display, for the same reason
/// `file_preview.dart` is: nothing here knows about widgets, and nothing here
/// knows about Hive. The tier a value lands in is the whole of that rule, so it
/// has to be assertable on its own — a widget test can see that *something* was
/// rendered, but not which of the three rules produced it, and the interesting
/// failure (a value quietly falling through to `toString()`) looks like a
/// successful render.
///
/// **Pure Dart, deliberately.** It imports `dart:convert` (through
/// `json_format.dart`) and nothing else, so it compiles for the browser as well
/// as the VM and `dart test --platform chrome` can reach it. The tier-2 encoder
/// is a *parameter* rather than an import for exactly that reason: the registered
/// types are `dart:ui` / Material ones (`Size`, `Offset`, `ThemeMode`), so
/// naming them here would pull `package:flutter` in and put this decision back
/// out of the browser's reach — the defect `web_vfs.dart` already carries in this
/// repository.
library;

import '/src/core/json_format.dart';

/// Which of [renderSettingsValue]'s three rules produced a rendering.
///
/// Reported rather than inferred: tiers 1 and 2 both yield JSON, so
/// [SettingsValueView.isJson] cannot tell them apart, and tier 3 is reached both
/// by values that are *meant* to be plain (an `int`, a `bool`) and by ones that
/// fell through. Only the tier itself distinguishes "shown as text because it is
/// text" from "shown as text because nothing else worked".
enum SettingsValueTier {
  /// The value is a `String` that parses as JSON, so it is re-indented.
  ///
  /// This is where the largest store on a real installation lands: `column_spec`
  /// holds its presets as plain JSON strings (`spec/base.dart`), not as mapped
  /// objects, so without this rule the view's biggest payload would be one
  /// unbroken line.
  jsonString,

  /// The value's runtime type carries a registered Hive adapter, so
  /// `dart_mappable` was asked for its JSON.
  registeredType,

  /// Everything else, shown as `toString()` — the last resort.
  plain,
}

/// A rendered value: the text to show, whether to colour it as JSON, and which
/// rule got there.
typedef SettingsValueView = ({String text, bool isJson, SettingsValueTier tier});

/// Tier 2's encoder: the value's `dart_mappable` JSON when its runtime type is
/// one the app registered a Hive adapter for, and `null` when it is not.
///
/// `null` rather than a throw, because "this type is not one of the registered
/// ones" is the ordinary case for most of what a settings box holds (strings,
/// ints, bools) and not an error.
typedef RegisteredValueJsonEncoder = String? Function(Object value);

/// Applies the three rendering rules to [value], in order.
///
/// [encodeRegistered] supplies tier 2; omitting it leaves tiers 1 and 3, which is
/// what a caller that cannot reach Flutter (the browser suite) is left with.
SettingsValueView renderSettingsValue(Object? value, {RegisteredValueJsonEncoder? encodeRegistered}) {
  // Tier 1. Before tier 2 on purpose: a `String` is never one of the registered
  // types, so the order costs nothing, and putting the cheap total-function first
  // keeps the JSON-string case independent of whether an encoder was supplied at
  // all.
  if (value is String) {
    final formatted = reindentJson(value);
    if (formatted != null) {
      return (text: formatted, isJson: true, tier: SettingsValueTier.jsonString);
    }
  }

  // Tier 2.
  if (value != null && encodeRegistered != null) {
    final encoded = _encode(value, encodeRegistered);
    if (encoded != null) {
      final formatted = reindentJson(encoded);
      if (formatted != null) {
        return (text: formatted, isJson: true, tier: SettingsValueTier.registeredType);
      }
    }
  }

  // Tier 3. `'$value'` and not `value.toString()` so that a null — a key whose
  // value was written and later cleared — renders as `null` instead of throwing
  // here, which would take the whole store's listing down with it.
  return (text: '$value', isJson: false, tier: SettingsValueTier.plain);
}

/// A whole store as the plain text the settings group's copy action puts on the
/// clipboard.
///
/// **Built from [renderSettingsValue], not beside it.** What the store dialog
/// shows and what the clipboard receives are the same rendering, so a value that
/// reaches tier 2 is copied as the JSON the screen showed and not as the
/// `toString()` a second spelling would have produced. A separate formatter here
/// would be a second place for the tier rule to be implemented, and the two would agree
/// only until one of them was touched.
///
/// The key sits on its own line above its value because that is where the dialog
/// puts it (`_SettingsEntryTile`), and a blank line separates the pairs because a
/// value can itself be several lines of JSON — without it, a reader cannot tell a
/// key from a line of the value above it.
///
/// [entries] is the record shape `StorageBox.entries()` yields, spelled
/// structurally rather than imported: this library is pure Dart on purpose (see
/// the library doc) and `storage_box.dart` reaches `package:hive_ce`.
String renderSettingsStoreAsText(
  Iterable<({String key, Object? value})> entries, {
  RegisteredValueJsonEncoder? encodeRegistered,
}) {
  return entries
      .map((entry) => '${entry.key}\n${renderSettingsValue(entry.value, encodeRegistered: encodeRegistered).text}')
      .join('\n\n');
}

/// [encodeRegistered] applied to [value], with a failure treated as "not
/// encodable".
///
/// A mapper can throw for a registered type whose own fields lost their mappers
/// (`MapperException`), and that has to degrade to tier 3 rather than escape:
/// this runs once per key, so one unmappable value would otherwise blank the
/// whole store. Nothing is logged here because logging lives in
/// `app_logger.dart`, which reaches `package:flutter`; the caller that owns the
/// widget is where a report belongs.
String? _encode(Object value, RegisteredValueJsonEncoder encodeRegistered) {
  try {
    return encodeRegistered(value);
  } catch (_) {
    return null;
  }
}
