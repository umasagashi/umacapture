/// A directory resolved once, and the questions a caller then asks of what lies beneath it.
///
/// Kept free of `package:flutter` so that the OPFS implementation (`opfs_directory.dart`) can implement it and still be
/// compiled by `dart test --platform chrome`, the only runner that reaches OPFS.
library;

import 'dart:typed_data';

/// A directory resolved once, whose descendants are then reached from that resolution instead of from the storage
/// root ([FsBackend.openDirectory]).
///
/// On web every path operation walks OPFS from the origin root one directory handle at a time, so a caller with
/// several questions about one directory — a record's three files, a record's slots in two journals — pays that walk
/// once per question unless it resolves the directory first and asks here. On io a path is one call into the
/// operating system and there is nothing to carry, so the io directory hands each full path to the backend.
///
/// Every method takes the **full path** of a descendant, as [PathEntity.path] spells it, so a caller names files the
/// way it does everywhere else; a path that is not beneath [path] is an [ArgumentError].
///
/// Each answer is about the disk at the moment it is asked: a directory that was not there when it was opened, or
/// has been removed since, has no descendants, so a read finds nothing and [isDirectory] says false. Nothing is
/// remembered between two questions beyond the directory itself, so a caller that hands one of these from one
/// operation to the next is the one deciding that no writer can replace the directory in between.
abstract interface class FsDirectory {
  /// The directory's own path.
  String get path;

  /// Reads the file at [descendant] as a UTF-8 string; throws where there is no file there.
  Future<String> readString(String descendant);

  /// Reads the file at [descendant] as raw bytes; throws where there is no file there.
  Future<Uint8List> readBytes(String descendant);

  /// Reads the file at [descendant] as raw bytes, or null where there is no file there.
  Future<Uint8List?> readBytesIfPresent(String descendant);

  /// Whether [descendant] is a directory — false for a file and for nothing.
  ///
  /// One lookup per segment below [path], so a name that is not there costs one failed lookup.
  Future<bool> isDirectory(String descendant);
}

final RegExp _separators = RegExp(r'[/\\]');

/// The segments of [descendant] below [directory], both split on either separator; an [ArgumentError] where
/// [descendant] is not [directory] or beneath it. Every [FsDirectory] checks its argument through this, so a path
/// from the wrong tree is refused the same way on both backends.
List<String> segmentsBelow(String directory, String descendant) {
  List<String> split(String path) => path.split(_separators).where((s) => s.isNotEmpty).toList();
  final own = split(directory);
  final segments = split(descendant);
  final beneath =
      segments.length >= own.length && Iterable<int>.generate(own.length).every((i) => segments[i] == own[i]);
  if (!beneath) {
    throw ArgumentError.value(descendant, 'descendant', 'is not beneath $directory');
  }
  return segments.sublist(own.length);
}
