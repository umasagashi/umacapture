/// Keeping an export's own output out of the archive it is producing.
///
/// `ZipFileEncoder.create` brings the staging file into existence — with
/// `FileMode.write` — *before* `addDirectory` takes its recursive `listSync` of
/// the source, so the staging file is already on disk when the walk enumerates
/// it. Nothing keeps it out of the source tree: the save dialog is asked with no
/// `initialDirectory` and no caller checks where the answer landed, so a
/// destination inside the folder being bundled — or inside one of its subfolders
/// — is an answer the dialog can give. The walk then finds the half-written
/// archive, `addFile` opens it, and whatever had been flushed so far becomes an
/// entry. Nothing throws, so the export reports success and hands the user an
/// archive quietly carrying a truncated copy of itself.
///
/// **The destination has to be excluded as well as the staging file.** The
/// staging file is only the *first* export's own output; on a second export to
/// the same destination the previous archive is an ordinary file sitting under
/// the source when the walk starts, and it would be swallowed whole.
///
/// **Why a filter, and not a staging file somewhere else.** The staging file is a
/// sibling of the destination on purpose: the `rename` that delivers it then
/// stays on one volume and is a move rather than a copy, which is what makes "the
/// destination is written exactly once, when there is a whole archive to put
/// there" true. Staging under the system temp directory can land on a different
/// volume from the destination, where `File.rename` fails and delivery has to
/// become copy-then-delete — a destination written in pieces, which is the
/// property the sibling exists to protect. Excluding two paths from a walk costs
/// nothing, so the exclusion is what moves.
///
/// **Identity is the path, never the name.** `<destination>.<micros>.part` is a
/// shape this code chose, not a fact about the file; matching on `.part` — or on
/// `.zip` — would drop a file the user happens to keep in the folder and call it
/// a fix. Comparison goes through `package:path`'s `equals`, the
/// case-insensitive, separator-insensitive path identity this repository already
/// uses (`data_root_migration.dart`) and the one Windows needs.
///
/// Here rather than in `zip_bundle.dart`: that file is deliberately free of
/// `dart:io` so `dart test --platform chrome` can build it, and a
/// `ZipFileProgress` is a function over `FileSystemEntity`. Both call sites —
/// `zip_export_io.dart`'s `_buildZip` and `exporter.dart`'s `ZipExporter._run` —
/// already reach `package:archive/archive_io.dart`, so this file adds no
/// dependency to either.
library;

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// A `ZipFileEncoder.addDirectory` filter that skips this export's own output.
///
/// The two paths are separate required parameters rather than one list, so that
/// neither call site can pass one and quietly forget the other.
ZipFileProgress zipOwnOutputFilter({required String stagingPath, required String destinationPath}) {
  final own = [stagingPath, destinationPath];
  return (entity, _) =>
      own.any((path) => p.equals(path, entity.path)) ? ZipFileOperation.skip : ZipFileOperation.include;
}
