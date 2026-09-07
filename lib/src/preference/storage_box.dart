import 'package:hive_ce_flutter/adapters.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:recase/recase.dart';

import '/const.dart';
import '/src/preference/hive_adapter.dart';

enum StorageBoxKey { settings, windowState, trainerId, columnSpec, versionCheck, addon, dataMigration, telemetryId }

/// The name each box is opened and stored under, derived from [StorageBoxKey].
///
/// Counted by the machine and never written out. Two things now depend on "the
/// app's settings are these boxes" — [StorageBox.ensureOpened], which opens them,
/// and the storage-management view, which lists them as the settings group's
/// children — and a hand-kept list in either place would silently stop
/// matching the enum the first time a key was added.
Iterable<String> get storageBoxNames => StorageBoxKey.values.map(storageBoxNameOf);

/// The name [key]'s box is opened and stored under.
///
/// The single spelling of the derivation. Named because three callers now need
/// one key's name rather than the whole list — [StorageBox]'s constructor, the
/// storage view's listing, and [storageBoxKeyOfName]'s inverse — and a second
/// `key.name.snakeCase` written out at any of them is a place the naming rule
/// could be changed in one spot and not the others.
String storageBoxNameOf(StorageBoxKey key) => key.name.snakeCase;

/// The [StorageBoxKey] stored under [name], or `null` when nothing is.
///
/// The inverse of [storageBoxNames], and derived from it rather than from a
/// second table, so the two cannot disagree. Needed because the storage tab
/// carries a store's *name* down from its row (a name is all a store has on web,
/// where there is no file) and has to get back to the key to open it.
StorageBoxKey? storageBoxKeyOfName(String name) {
  for (final key in StorageBoxKey.values) {
    if (storageBoxNameOf(key) == name) {
      return key;
    }
  }
  return null;
}

/// One key/value pair held in a settings store.
///
/// The key is stringified at the boundary: Hive types its keys `dynamic` (they
/// may be ints for an auto-incrementing box), while every box this app opens is
/// keyed by string, and leaving `dynamic` in the type would push the question
/// onto every reader of the storage view.
typedef SettingsBoxEntry = ({String key, Object? value});

class StorageBox {
  /// Set once something has taken this process's boxes away for good.
  ///
  /// After this every box operation becomes a no-op so the many non-interactive
  /// writers that may still fire before the forced restart (window move/resize,
  /// preference notifiers, sentry counters, version checks, addon history) cannot
  /// throw on a box that is no longer open. The flag is intentionally one-way:
  /// both of the things that set it end in restart/quit, and on failure the boxes
  /// are gone anyway.
  static bool _hiveClosed = false;

  /// Marks Hive as closed for the rest of the process, neutralizing every
  /// [StorageBox] read/write.
  ///
  /// **Two callers, and neither of them is optional.** The data-root migration
  /// calls it before `Hive.close()` (`data_root_migration.dart`), and the storage
  /// view's settings delete calls it before removing the stores
  /// (`settings_store_delete.dart`). Named for what it means rather than
  /// for the first caller that needed it: after either, `Hive.box(name)` throws
  /// `HiveError('Box not found')`, which this class's constructor would raise in
  /// the middle of an unrelated widget build.
  static void markHiveClosed() => _hiveClosed = true;

  /// Null when constructed after [markHiveClosed]; otherwise the open box.
  final Box? _box;

  StorageBox(StorageBoxKey key) : _box = _hiveClosed ? null : Hive.box(storageBoxNameOf(key));

  T? pull<T>(String key) {
    if (_hiveClosed) return null;
    // Guard the implicit dynamic->T cast: if a key's stored type ever diverges from the caller's T (a key
    // repurposed across versions), degrade to the default instead of throwing a TypeError inside a notifier's
    // build().
    final value = _box?.get(key);
    return value is T ? value : null;
  }

  void push<T>(String key, T value) {
    if (_hiveClosed) return;
    _box?.put(key, value);
  }

  void delete(String key) {
    if (_hiveClosed) return;
    _box?.delete(key);
  }

  StorageEntry<T> entry<T>(String key) {
    return StorageEntry<T>(box: this, key: key);
  }

  /// Everything the box currently holds, in Hive's own key order.
  ///
  /// The one read on this class that is not keyed by a caller who already knows
  /// what it wants, and it exists for the storage view: showing a store's contents
  /// means enumerating keys nobody hardcoded, and until now `pull`/`push`/
  /// `delete`/`entry` could only reach a key whose name was already written
  /// somewhere in the app. A store therefore had no way to be *read out*, only
  /// consulted.
  ///
  /// Values arrive decoded, so a key written through a [JsonAdapter] comes back
  /// as its mapped object rather than as the JSON on disk — which is what makes
  /// the storage view's second value-rendering tier reachable at all.
  ///
  /// Empty, never throwing, once [markHiveClosed] has been called: the view stays
  /// open across that window and an exception here would take the whole listing
  /// down for a state that is expected — the settings delete leaves the
  /// view looking at stores that are gone until the restart it demands.
  List<SettingsBoxEntry> entries() {
    final box = _hiveClosed ? null : _box;
    if (box == null) {
      return const [];
    }
    return [for (final key in box.keys) (key: '$key', value: box.get(key))];
  }

  /// Opens every box, initializing Hive under the app's settings directory.
  ///
  /// [directory] overrides the storage location with an absolute path — used by
  /// tests (e.g. the integration test) to keep Hive away from the real settings
  /// directory, so test runs cannot clear or pollute the user's persisted data.
  ///
  /// [dataRoot] is the user-configured data root resolved at startup (see
  /// `bootstrap.dart`). When set, the settings boxes live under
  /// `<dataRoot>/settings` instead of the native default location. [directory]
  /// takes precedence so tests stay isolated.
  static Future<void> ensureOpened({bool reset = false, String? directory, String? dataRoot}) async {
    final String location;
    if (directory != null) {
      location = directory;
      Hive.init(directory);
    } else if (dataRoot != null) {
      location = join(dataRoot, settingsBoxDirName);
      Hive.init(location);
    } else {
      final packageInfo = await PackageInfo.fromPlatform();
      location = join(packageInfo.appName, settingsBoxDirName);
      await Hive.initFlutter(location);
    }
    if (reset) {
      for (final name in storageBoxNames) {
        // Delete under Hive's initialized home directory (set by init/initFlutter above) rather than passing an
        // explicit path: in the native-default branch `location` is relative (appName/settings) while initFlutter
        // resolves it under the documents dir, so an explicit path would target the wrong (or a missing) folder
        // and silently no-op the reset.
        await Hive.deleteBoxFromDisk(name);
      }
    }
    registerHiveAdapters();
    for (final name in storageBoxNames) {
      await Hive.openBox(name);
    }
    return Future.value();
  }
}

class StorageEntry<T> {
  final StorageBox _box;
  final String _key;

  StorageEntry({required this._box, required this._key});

  T? pull() {
    return _box.pull<T>(_key);
  }

  void push(T value) {
    _box.push<T>(_key, value);
  }

  void delete() {
    _box.delete(_key);
  }
}
