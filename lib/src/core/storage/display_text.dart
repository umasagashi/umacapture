/// The last step between a string this app read and a string it lays out.
///
/// **Only for text that is being *shown*.** Copying a file to the clipboard,
/// downloading one, and zipping one all hand over *bytes*, and a line terminator
/// is part of those bytes: rewriting it there would change the file the user
/// receives. Nothing in `clipboard_alt.dart`, `file_download.dart` or the archive
/// path goes through here, and nothing in them should. A preview is a rendering
/// and may normalise; an export is the file and may not.
///
/// Pure Dart, no `package:flutter` import, so it is reachable from
/// `dart test --platform chrome` as well as from the VM.
library;

/// [source] with every line terminator rendered as a bare `\n`.
///
/// **Why this exists.** A `TextField` whose text still holds `\r` costs
/// approximately `n²` to lay out for `n` characters, and on a real installation
/// that is not a rounding error: the same 172,670-character `prediction.json`
/// took 45,000 ms to open with its CRLF terminators intact and 100 ms with them
/// removed — a factor of about 456, measured in a profile build of the real app.
/// The blow-up is invisible to `flutter_test`, which laid the same CRLF text out
/// in 58 ms, so this is a property that has to be asserted on the *string* rather
/// than on a duration.
///
/// The reason only some previews were slow is the same reason this function sits
/// here and not in `file_preview.dart`: a JSON file small enough to parse is
/// re-serialised by `prettyPrintJson`, and `JsonEncoder` writes a carriage
/// return inside a string as the two characters `\r` and never as a raw one — so
/// that path was already terminator-clean, and everything else (a `.log`, a
/// `.txt`, a JSON head cut by the read cap, a settings value shown as plain
/// text) was not. Running this over an already-clean string is free: the scan
/// below finds nothing and returns the same instance.
///
/// **Converted, not deleted.** Dropping every `\r` would be enough for CRLF, but
/// a lone `\r` is a line terminator in its own right, and deleting it would join
/// two of the file's lines into one — a viewer silently showing fewer lines than
/// the file has. Mapping `\r\n` and a lone `\r` alike onto `\n` keeps the line
/// count of every input exactly as it was.
String textForDisplay(String source) {
  // `contains` before `replaceAll` so the common case allocates nothing: most of
  // what reaches a preview is either LF-terminated already or has been through
  // `prettyPrintJson`.
  if (!source.contains('\r')) {
    return source;
  }
  return source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}
