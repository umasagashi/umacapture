/// Human-readable byte sizes, and the storage-management view's timestamp
/// format, for that view.
///
/// [formatStorageTimestamp] lives in this file rather than in the view for the
/// same reason as [formatByteSize]: it needs nothing but the Dart VM, which lets
/// `storage_timestamp_format_test.dart` exercise it in a child process with a
/// non-zero `TZ` to observe the UTC-to-local conversion. See that function's own
/// doc for the detail. A widget-library import anywhere in this file's chain
/// would put that invariant back out of reach of anything but the host's own
/// zone, so no such import belongs here even for a future addition.
///
/// Where a size *comes from* differs per platform, but nothing upstream says how
/// it is spelled, so the spelling is decided here and the
/// decisions are written down rather than left to be re-derived from the code:
///
/// * **Base 1024, labelled `KB`/`MB`/`GB`.** The view's own completion condition
///   is that a file's size matches what Windows Explorer shows for it, and
///   Explorer divides by 1024 while writing `KB`. Using 1000 would put this view
///   permanently ~2.4% below the number the user can see next to it in another
///   window, for every file, with no way to tell the two apart. `KiB` would be
///   unambiguous and is what this repository's *code* comments use
///   (`record_zip.dart`'s `20 MiB`), but the audience here is a general user,
///   not a reader of the source, and no shipped Japanese string in
///   `assets/translations/ja.json` has ever used the binary spelling.
/// * **One decimal place above `B`, none at `B`.** `1.2 MB` is the form the
///   requirement itself writes. Bytes are integers and a fractional byte is
///   meaningless, so `B` prints the exact count.
/// * **Round to nearest** (`toStringAsFixed`, ties away from zero). Neither
///   direction is safer here: this number is shown, not compared against a quota,
///   so the closest value is the honest one. Rounding that carries into the next
///   unit is promoted rather than printed as `1024.0 KB` (see [formatByteSize]).
/// * **`null` is not zero.** An absent size means "the enumeration could not
///   resolve one" — a web directory, or an entry deleted between listing and
///   metadata — and rendering that as `0 B` would state something false. It
///   prints [unknownSizeLabel], the same em dash a timestamp that does not exist
///   gets.
///
/// Nothing here depends on a locale: the value is always below 1024 in its unit,
/// so there are no digit-group separators to place, and the decimal point stays
/// `.` as every other number in this app's UI already shows it.
library;

import 'package:intl/intl.dart' as intl;

/// Shown where a size or a timestamp exists as a concept but not as a value.
///
/// Deliberately one spelling shared by both, so the view cannot end up with two
/// different-looking kinds of "unknown" in adjacent columns.
const String unknownSizeLabel = '—';

/// Unit ladder, ascending. The last entry is the ceiling: a value that would
/// carry past it is printed in it rather than promoted.
const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/// Bytes per step of [_units].
const int _step = 1024;

/// Formats [bytes] for display, or [unknownSizeLabel] when it is `null`.
///
/// A negative count is not a size this app can produce; it is formatted through
/// the `B` branch (`-5 B`) rather than being hidden behind the unknown label,
/// which would turn a caller's arithmetic bug into a plausible-looking dash.
String formatByteSize(int? bytes) {
  if (bytes == null) {
    return unknownSizeLabel;
  }
  if (bytes < _step) {
    return '$bytes ${_units.first}';
  }

  var value = bytes / _step;
  var unit = 1;
  while (unit < _units.length - 1 && value >= _step) {
    value /= _step;
    unit++;
  }

  var text = value.toStringAsFixed(1);
  // The rounding itself can cross the boundary: 1,048,575 B is 1023.999… KB,
  // which prints as "1024.0 KB" -- a number the ladder says cannot exist in that
  // unit. Promote once; a second carry is impossible, because the promoted value
  // is 1.0.
  if (unit < _units.length - 1 && double.parse(text) >= _step) {
    value /= _step;
    unit++;
    text = value.toStringAsFixed(1);
  }
  return '$text ${_units[unit]}';
}

/// The timestamp column's text.
///
/// A fixed numeric pattern, not a locale-dependent one: the column is narrow and
/// sorted-looking, and this is the first use of `DateFormat` in the app, so
/// there is no house style to follow yet. An absent timestamp is
/// [unknownSizeLabel] — the same em dash a missing size gets. A directory has no
/// readable timestamp on web at all, and an empty one has none anywhere.
///
/// **The value is rendered in the host's local zone.** `DateFormat.format` reads
/// the field getters, which on a UTC-flagged `DateTime` return UTC fields, so
/// dropping the conversion shifts every row by the host's offset — a silent
/// error that still looks like a plausible timestamp. Whether that conversion
/// happens cannot be observed at all on a host whose own offset is zero, so
/// `storage_timestamp_format_test.dart` renders this in a **child process with a
/// non-zero `TZ`**. This function lives here, beside [unknownSizeLabel] and
/// [formatByteSize] rather than in the view, so that child needs nothing but the
/// Dart VM: a widget library in its imports would put the invariant back out of
/// reach of anything but the host's own zone.
String formatStorageTimestamp(DateTime? value) {
  if (value == null) {
    return unknownSizeLabel;
  }
  return intl.DateFormat('yyyy/MM/dd HH:mm').format(value.toLocal());
}
