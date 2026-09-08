/// What one confirmed storage-view delete removes.
///
/// **Two shapes, and the second is not a special case of the first.** Eleven of
/// the twelve groups delete paths; the settings group deletes *stores*, which
/// exist on web with no filesystem presence at all. Before this type
/// the button carried `List<PathEntity>` and the settings group answered it with
/// an empty list — the value that also means "this group offers no delete", so
/// the view could not tell the two apart and the settings group's row was
/// therefore buttonless.
///
/// Written as a sealed union rather than as a nullable extra field so that the
/// runner's `switch` is exhaustive: a third kind of delete stops the app
/// compiling instead of falling into the path branch with nothing to delete.
/// "Which delete is this" is then data, not the order in which two fields were
/// checked.
library;

import '/src/core/path_entity.dart';

sealed class StorageDeleteRequest {
  const StorageDeleteRequest();
}

/// Removes filesystem entries, under the exclusion their group declares.
class StorageDeletePathsRequest extends StorageDeleteRequest {
  const StorageDeletePathsRequest(this.targets);

  /// Never empty. A group with nothing to delete has no request at all, so that
  /// "no delete" and "a delete that removes nothing" cannot be spelled the same
  /// way.
  final List<PathEntity> targets;
}

/// Removes every settings store.
///
/// Carries no field: the stores are enumerated from [StorageBoxKey] at the point
/// of deletion (`settings_store_delete.dart`), and a list captured here would be
/// a second enumeration to keep in step with the first.
class StorageDeleteSettingsRequest extends StorageDeleteRequest {
  const StorageDeleteSettingsRequest();
}
