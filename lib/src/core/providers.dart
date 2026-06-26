import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '/const.dart';
import '/src/core/bootstrap.dart';
import '/src/core/path_entity.dart';

final packageInfoLoader = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

/// A module-level broadcast event stream exposed as a [StreamProvider].
///
/// Replaces the duplicated boilerplate that recreated a single-subscription
/// `StreamController` whenever the provider was re-listened
/// (`if (controller.hasListener) controller = StreamController()`). That pattern
/// leaked the orphaned controller and was fragile under multiple subscribers. A
/// broadcast controller tolerates re-listening (hot-restart, tests, provider
/// rebuilds) without the recreate-and-leak dance, so a single controller can
/// live for the app's lifetime. Events emitted with no current listener are
/// dropped, which matches the old behavior (the recreate discarded buffered
/// events too): these are live UI signals, not buffered state.
class EventStreamProvider<T> {
  final _controller = StreamController<T>.broadcast();

  late final StreamProvider<T> provider = StreamProvider<T>((ref) => _controller.stream);

  void add(T event) => _controller.add(event);
}

/// A minimal [Notifier] holding an externally-settable value seeded with
/// [initial]. Replaces the many one-off `build() => default; set(v) => state = v`
/// notifiers the riverpod 3 migration produced when `StateProvider` was dropped.
/// Use [settableNotifierProvider] to declare a provider backed by it.
class SettableNotifier<T> extends Notifier<T> {
  SettableNotifier(this._initial);

  final T _initial;

  @override
  T build() => _initial;

  void set(T value) => state = value;
}

/// Convenience constructor for a [NotifierProvider] backed by [SettableNotifier].
NotifierProvider<SettableNotifier<T>, T> settableNotifierProvider<T>(T initial) {
  return NotifierProvider<SettableNotifier<T>, T>(() => SettableNotifier<T>(initial));
}

class PathInfo {
  final DirectoryPath documentDir;
  final DirectoryPath supportDir;
  final DirectoryPath executableDir;
  final DirectoryPath downloadDir;

  /// User-configured data root override (see `bootstrap.dart`).
  ///
  /// When non-null, the relocatable data directories ([tempDir], [storageDir],
  /// [modulesDir], [settingsDir]) live under this root instead of their native
  /// defaults. `null` keeps the original behavior. [executableDir] and
  /// [downloadDir] are intentionally never relocated.
  final DirectoryPath? dataRoot;

  const PathInfo({
    required this.documentDir,
    required this.supportDir,
    required this.executableDir,
    required this.downloadDir,
    this.dataRoot,
  });

  DirectoryPath get tempDir => (dataRoot ?? documentDir) / "temp";

  DirectoryPath get storageDir => (dataRoot ?? documentDir) / "storage";

  DirectoryPath get modulesDir => (dataRoot ?? supportDir) / "modules";

  /// Directory holding the Hive settings boxes.
  ///
  /// Mirrors the location `StorageBox.ensureOpened` opens so the migration flow
  /// can copy the settings database alongside the other data directories. The
  /// default base is [documentDir] because `Hive.initFlutter` resolves against
  /// `getApplicationDocumentsDirectory()` (i.e. `<documentDir>/settings`), not
  /// the support dir.
  DirectoryPath get settingsDir => (dataRoot ?? documentDir) / settingsBoxDirName;

  DirectoryPath get charaDetailDir => storageDir / "chara_detail";

  DirectoryPath get charaDetailActiveDir => charaDetailDir / "active";

  /// Sibling of [charaDetailActiveDir] holding archived records.
  ///
  /// Archived records are moved here, out of the scanned `active/` tree, so they
  /// are excluded from re-recognition while remaining browsable. They are still
  /// considered for capture dedup and inheritance resolution, which read both the
  /// active and archive sets.
  DirectoryPath get charaDetailArchiveDir => charaDetailDir / "archive";

  DirectoryPath get charaDetailQuarantineDir => charaDetailDir / "quarantine";

  DirectoryPath get charaDetailMetadataDir => charaDetailDir / "metadata";

  DirectoryPath get charaDetailRatingDir => charaDetailMetadataDir / "rating";

  DirectoryPath get charaDetailMemoDir => charaDetailMetadataDir / "memo";

  /// Returns a copy resolving its relocatable directories against [root].
  ///
  /// Passing `null` yields the native-default layout. Used by the migration flow
  /// to describe the source (current) and target (chosen) layouts with the same
  /// getters, so the two stay in lock-step.
  PathInfo withDataRoot(DirectoryPath? root) => PathInfo(
    documentDir: documentDir,
    supportDir: supportDir,
    executableDir: executableDir,
    downloadDir: downloadDir,
    dataRoot: root,
  );

  @override
  String toString() => 'PathInfo{documentDir: $documentDir, supportDir: $supportDir, dataRoot: $dataRoot}';
}

final pathInfoLoader = FutureProvider<PathInfo>((ref) async {
  final appName = (await ref.watch(packageInfoLoader.future)).appName;
  late final DirectoryPath documentDir;
  if (CurrentPlatform.isAndroid()) {
    // To make it easier for users to export manually.
    documentDir = DirectoryPath(
      await getExternalStorageDirectories(type: StorageDirectory.documents).then((e) => e!.first),
    );
  } else {
    documentDir = DirectoryPath(await getApplicationDocumentsDirectory());
  }
  final supportDir = DirectoryPath(await getApplicationSupportDirectory());
  // getDownloadsDirectory returns null on Android/unsupported platforms; fall
  // back to the app's document dir so DirectoryPath never receives null.
  final downloadDirRaw = await getDownloadsDirectory();
  final override = resolvedDataRoot;
  final info = PathInfo(
    documentDir: documentDir / appName,
    supportDir: supportDir,
    executableDir: FilePath.resolvedExecutable.parent,
    downloadDir: downloadDirRaw != null ? DirectoryPath(downloadDirRaw) : documentDir / appName,
    dataRoot: override == null ? null : DirectoryPath(override),
  );
  return info;
});

final pathInfoProvider = Provider<PathInfo>((ref) {
  return ref.watch(pathInfoLoader).value!;
});

final isInstallerModeLoader = FutureProvider<bool>((ref) async {
  final info = await ref.watch(pathInfoLoader.future);
  return info.executableDir
      .listSync(recursive: false, followLinks: false)
      .where((e) => Const.uninstallerPattern.hasMatch(e.path))
      .isNotEmpty;
});
