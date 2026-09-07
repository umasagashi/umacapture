/// The [PathEntity] adapter for [StorageFileKind].
///
/// Kept apart from `file_kind.dart` so that the classifier itself stays pure
/// Dart. `path_entity.dart` imports `dart:io` and `package:flutter/foundation.dart`,
/// and a library that imports `dart:io` cannot be compiled for the browser --
/// which would put the extension table, and everything the preview decision
/// derives from it, out of reach of a `--platform chrome` run for no reason
/// other than this one type test.
library;

import '/src/core/path_entity.dart';
import '/src/core/storage/file_kind.dart';

/// Classifies a listed entry.
///
/// The kind of a [DirectoryPath] is its type. `DirectoryPath.listWithMetadata`
/// already wrapped each entry in the matching subtype from the enumeration, so
/// this is a type test and not a filesystem question -- and a directory whose
/// name ends in `.json` is still a directory.
StorageFileKind storageFileKindOf(PathEntity entity) {
  return entity is DirectoryPath ? StorageFileKind.directory : storageFileKindOfName(entity.name);
}
