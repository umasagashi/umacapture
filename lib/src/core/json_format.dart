import 'dart:convert';

/// The deepest nesting [reindentJson] will re-indent.
///
/// **A bound in data, not a caught [StackOverflowError].** `JsonEncoder` walks
/// the decoded value recursively, so a deep enough document overruns the stack
/// instead of failing cleanly. Where that happens is not a property of the
/// document: it depends on how much stack is left, which differs between the VM
/// and `dart2js` and between a bare call and one made from inside a widget
/// build. Catching the overflow would therefore make the *same* file format on
/// one screen and not on another, and an overflow is not reliably recoverable in
/// the first place. Deciding from the text gives the same answer everywhere.
///
/// 200 has room on both sides. Measured with `JsonEncoder.withIndent('  ')` on
/// the Dart VM: 3000 levels of nesting still format and 5000 throw
/// `StackOverflowError`, so the floor is at least an order of magnitude above
/// this. The deepest JSON this repository ships is 23 levels
/// (`assets/config/chara_detail/scene_context.json`), so nothing the app writes
/// comes near it either, and a hand-written file that a person can read is
/// nowhere close.
const int jsonFormatMaxDepth = 200;

/// The longest source [reindentJson] will re-indent, in UTF-16 code units.
///
/// The same quarter megabyte as `textPreviewByteLimit`, which is the largest
/// text this app puts on a screen at once: a file preview is already cut to it
/// before it gets here, so this bound only ever fires for the *other* caller,
/// the settings store, whose values come out of Hive with no cap of their own.
/// Spelled as a number here rather than imported, because this library is pure
/// `dart:convert` on purpose (see [prettyPrintJson]) and `file_preview.dart`
/// carries the storage layer with it.
const int jsonFormatMaxLength = 262144;

/// Re-serializes [source] (parsed as JSON) with a stable 2-space indent, for
/// previewing arbitrary JSON files.
///
/// Pure Dart, no `package:flutter` import, so it stays reachable from
/// `dart test --platform chrome` on web as well as the VM.
///
/// Throws a [FormatException] if [source] is not valid JSON, and — for a
/// document that is valid but extreme — whatever `dart:convert` throws for it,
/// including [JsonUnsupportedObjectError] for a number that overflowed to
/// infinity while decoding. **Callers that are displaying a file want
/// [reindentJson] instead**; this is the formatting rule on its own, kept
/// separate so a test can state the exact output it produces.
String prettyPrintJson(String source) {
  final decoded = jsonDecode(source);
  return const JsonEncoder.withIndent('  ').convert(decoded);
}

/// [source] re-indented as JSON, or `null` when it cannot be.
///
/// **The one place the width of that "cannot" is decided.** Both callers — the
/// file preview and the settings-value view — are *viewers*, and for a viewer
/// indenting is decoration rather than a precondition: whatever goes wrong, the
/// answer is to show the text as it was read. So this catches everything and not
/// only [FormatException]. Narrowing it to that one type is what let a `.json`
/// holding `1e400` (which decodes to `Infinity` and then makes `JsonEncoder`
/// throw [JsonUnsupportedObjectError], an `Error` and not an `Exception`) escape
/// out of a `build()` and replace the panel with the framework's red error box.
///
/// The two bounds above are checked *before* decoding, so the extreme cases are
/// declined by a rule rather than by whatever the encoder happens to do with
/// them; see [jsonFormatMaxDepth] for why that distinction matters. The catch
/// stays as the backstop for the ones no bound predicts.
String? reindentJson(String source) {
  if (source.length > jsonFormatMaxLength) {
    return null;
  }
  if (!_nestingFitsWithin(source, jsonFormatMaxDepth)) {
    return null;
  }
  try {
    return prettyPrintJson(source);
  } catch (_) {
    return null;
  }
}

/// Whether the brackets in [source] nest no deeper than [maxDepth].
///
/// A flat scan rather than a walk of the decoded value: the walk would need the
/// decode this is deciding whether to do, and a recursive one would hit the
/// stack it exists to stay off. String literals are skipped so that a log line
/// holding `"[[["` is not read as nesting; for input that does not parse the
/// count is only an estimate, which costs nothing because such input has no
/// re-indented form anyway.
bool _nestingFitsWithin(String source, int maxDepth) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < source.length; i++) {
    final unit = source.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (unit == 0x5c) {
        escaped = true;
      } else if (unit == 0x22) {
        inString = false;
      }
      continue;
    }
    if (unit == 0x22) {
      inString = true;
    } else if (unit == 0x5b || unit == 0x7b) {
      depth++;
      if (depth > maxDepth) {
        return false;
      }
    } else if (unit == 0x5d || unit == 0x7d) {
      depth--;
    }
  }
  return true;
}
