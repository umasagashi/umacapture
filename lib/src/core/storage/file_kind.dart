/// What kind of thing an entry in the storage-management tree is.
///
/// The tree needs icons that tell a directory, an image, text, JSON and "other
/// binary" apart, and there is no `mime` package here and no general extension
/// mapping to reuse: `PathEntity.contentType` answers for three extensions and
/// *throws* for everything else, and `customSoundMimeType` answers for two. Both
/// exist to fill in an HTTP/media content-type header for a file the app itself
/// just produced, not to classify an arbitrary file a user is browsing, so
/// neither can be the classifier here.
///
/// **This is deliberately not the icon table.** The preview stage has to decide
/// "is this text, an image, or bytes I must not read as a string" and that is the
/// same question; keeping the answer in a Flutter-free file means the preview can
/// ask it without importing icons.
///
/// **Only one of the two readers is an exhaustive `switch`.** `storageFileKindIcon`
/// (`storage_file_icon.dart`) is, so a new member here is a compile error there
/// and the compiler names the place to fill in. The preview is not, and that is
/// its own decision rather than an omission: `file_preview.dart` settles what a
/// file *is* from its bytes and asks this enum only for a fast path
/// (`kind == StorageFileKind.image`, `isJson`, `!kind.isTextual`), so a member
/// nothing there has heard of is sniffed like any unknown extension — which is
/// the answer a new kind should get. Do not read "the compiler will name both"
/// into this file: on the preview side the check is that fall-through, not a
/// `switch`.
///
/// That "Flutter-free" claim is load-bearing and, until stage 4a, was **false**:
/// this library imported `path_entity.dart` for the one overload that takes a
/// [PathEntity], and that library pulls in `dart:io` *and*
/// `package:flutter/foundation.dart`. A `dart:io` import cannot be compiled for
/// the browser at all, so the classifier — the half of the preview decision that
/// is pure string work and identical on both platforms — was reachable only from
/// a VM test. The [PathEntity] overload now lives in `file_kind_entity.dart`, and
/// nothing here imports anything but `package:path`.
library;

import 'package:path/path.dart' as p;

/// The kinds the tree distinguishes.
///
/// [binary] is what an extension the table does not list falls back to, and it
/// means *"this name told us nothing"* -- not *"these bytes are binary"*. The
/// icon it picks is the generic one, which is the right answer for an unknown
/// name. It is **not** an answer about the content, and the preview no longer
/// reads it as one: `resolveFilePreview` sniffs the head of a [binary] file and
/// shows it as text when there is no NUL in it. See that function for why the
/// table cannot be the authority on readability.
enum StorageFileKind {
  /// A directory. Decided by the entry's type, never by its name.
  directory,

  /// A raster image the app can decode and show.
  image,

  /// Plain text, safe to read into a string and display as-is.
  text,

  /// Text that is also JSON, and gets the structured/highlighted rendering.
  json,

  /// Anything else. Sized, never decoded.
  binary;

  /// Whether the content can be read as a string for preview.
  ///
  /// Derived from the enum rather than from a second table, so a new kind cannot
  /// be added to one list and forgotten in the other.
  bool get isTextual => this == StorageFileKind.text || this == StorageFileKind.json;
}

/// Lower-cased extension (including the leading dot) to kind.
///
/// Covers what this app actually keeps: its records and configs (`.json`), the
/// captured and converted images (`.png`/`.jpg`), the exports and logs it writes
/// (`.csv`/`.txt`/`.log`), plus the ordinary text formats a user may have dropped
/// into a data folder.
///
/// **It is a fast path, and it is not exhaustive by design.** Absences here are
/// not verdicts: the recogniser modules (`.onnx`), the font cache (`.ttf`), the
/// sounds, the Hive boxes and the zips are missing because nothing needed to
/// name them, and `.html` or `.tsv` are missing because nobody thought of them.
/// Those two cases are indistinguishable from inside this table, which is
/// exactly why `resolveFilePreview` decides readability from the bytes and asks
/// this table only what a *name* can answer -- is it an image, and is it JSON.
const Map<String, StorageFileKind> _kindByExtension = {
  '.png': StorageFileKind.image,
  '.jpg': StorageFileKind.image,
  '.jpeg': StorageFileKind.image,
  '.gif': StorageFileKind.image,
  '.webp': StorageFileKind.image,
  '.bmp': StorageFileKind.image,
  '.json': StorageFileKind.json,
  '.txt': StorageFileKind.text,
  '.log': StorageFileKind.text,
  '.csv': StorageFileKind.text,
  '.md': StorageFileKind.text,
  '.xml': StorageFileKind.text,
  '.yaml': StorageFileKind.text,
  '.yml': StorageFileKind.text,
};

/// Classifies a file by its name alone.
///
/// Name-only, so it can be answered for a listing entry without a second
/// filesystem probe -- on OPFS every probe re-walks the handle chain from the
/// storage root. A name with no extension (`LICENSE`, `.gitignore` -- `p`
/// treats a leading dot as the whole basename, not as a suffix) is
/// [StorageFileKind.binary], i.e. "the name says nothing"; both of those are in
/// fact text, and the preview will find that out by reading them.
StorageFileKind storageFileKindOfName(String name) {
  return _kindByExtension[p.extension(name).toLowerCase()] ?? StorageFileKind.binary;
}
