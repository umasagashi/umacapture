import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/storage/file_kind.dart';

/// Icon for a storage-tree entry's kind.
///
/// Split from [StorageFileKind] on purpose: the preview stage asks the same
/// classifier what it may read as a string, and must not have to import icons to
/// do it. This switch is exhaustive over the enum, so adding a kind is a compile
/// error here rather than a silently missing icon.
///
/// No colour is chosen here. The caller supplies one from the theme
/// (`Theme.of(context).colorScheme`), because which role applies depends on the
/// row's state -- selected, disabled, warned -- which this function cannot see.
IconData storageFileKindIcon(StorageFileKind kind) {
  return switch (kind) {
    StorageFileKind.directory => Symbols.folder_rounded,
    StorageFileKind.image => Symbols.image_rounded,
    StorageFileKind.text => Symbols.description_rounded,
    StorageFileKind.json => Symbols.data_object_rounded,
    StorageFileKind.binary => Symbols.draft_rounded,
  };
}
