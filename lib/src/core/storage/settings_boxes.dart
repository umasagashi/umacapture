/// The settings group's children: the app's settings *stores*, listed as
/// stores rather than as the files that happen to hold them.
///
/// This is the one group whose level is not a directory listing, and the
/// reason is different on each of the two platforms:
///
///  * **Windows.** The stores are `<settings>/<name>.hive` binaries. Nothing in
///    this repository can decode that format, so showing the bytes would put an
///    implementation detail on screen and nothing else.
///  * **Web.** `hive_ce` stores them in IndexedDB, not in OPFS, so the settings
///    directory the view can see is empty there. Listing it would show the user an
///    empty settings group while their settings plainly still work.
///
/// Enumerating the stores instead answers both at once, and the enumeration is
/// the enum itself — see [storageBoxNames].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/app_logger.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/preference/storage_box.dart';

/// One settings store on the view: its name, plus the size and timestamp where
/// the platform has them to report.
///
/// A record rather than a class for the same reason [FsListing] is one: it is a
/// row's worth of already-resolved facts, and structural equality lets a widget
/// test compare one without a hand-written `==`.
typedef SettingsBoxListing = ({StorageBoxKey key, String name, int? sizeBytes, DateTime? modified});

/// How one store's keys and values are read out of Hive.
///
/// A provider for the same reason `settingsStoreDeleteProvider` is one: the claim
/// "the row hands the store's values to the clipboard" is about what the view
/// does with entries, and `Hive.box(name)` throws unless a real Hive is open,
/// which a VM widget test has none of. Substituting the read is what lets that
/// claim be asserted; reading eight real stores would prove Hive works and say
/// nothing about the row.
///
/// **Synchronous, and that is a requirement rather than an accident.** A browser
/// clipboard write has to begin inside the gesture's
/// transient activation, so the copy path must not `await` before it writes. The
/// underlying read is a lookup in an already-open box, so it does not have to.
typedef SettingsStoreReader = List<SettingsBoxEntry> Function(StorageBoxKey key);

final settingsStoreReaderProvider = Provider<SettingsStoreReader>(
  (_) =>
      (key) => StorageBox(key).entries(),
);

/// The translation key of the name a store is shown under.
///
/// **A switch over the enum, deliberately, and not a map keyed by name.** The
/// audience for this level is a general user, and `column_spec` /
/// `data_migration` are the app's internal spelling — a name the user has no way
/// to read and no reason to. The switch expression is what keeps that from
/// coming back: a ninth [StorageBoxKey] makes this fail to compile
/// (`non_exhaustive_switch_expression`), where a `Map` lookup or an `if` chain
/// would answer `null` for it and let the caller fall back to the internal name
/// with nothing said. The row cannot render a name this function did not give it,
/// so the compiler is the thing that enforces the coverage.
///
/// A key rather than the sentence, following `StorageGroup.labelKey`: the
/// wording lives in `ja.json` and the widget resolves it.
String storageBoxLabelKey(StorageBoxKey key) => switch (key) {
  StorageBoxKey.settings => _boxLabelKey('settings'),
  StorageBoxKey.windowState => _boxLabelKey('window_state'),
  StorageBoxKey.trainerId => _boxLabelKey('trainer_id'),
  StorageBoxKey.columnSpec => _boxLabelKey('column_spec'),
  StorageBoxKey.versionCheck => _boxLabelKey('version_check'),
  StorageBoxKey.addon => _boxLabelKey('addon'),
  StorageBoxKey.dataMigration => _boxLabelKey('data_migration'),
  StorageBoxKey.telemetryId => _boxLabelKey('telemetry_id'),
};

String _boxLabelKey(String name) => 'pages.storage.store.name.$name';

/// The files one store occupies on a native filesystem.
///
/// **Both, never just the first.** `hive_ce`'s VM backend writes `<name>.lock`
/// beside `<name>.hive` (`hive_ce/lib/src/backend/vm/backend_manager.dart`), so
/// the eight stores are sixteen files on disk, and a size that counted only the
/// `.hive` would under-report every store by the lock's bytes.
///
/// **The delete does not use this list, and must not.** It was written expecting
/// stage 6 to remove the pair file by file; stage 0 then measured that doing so
/// is exactly what fails — a sharing violation on Windows, an indefinite block on
/// web — so `settings_store_delete.dart` goes through `Hive.deleteBoxFromDisk`,
/// which removes `.hive`, `.hivec` and `.lock` itself
/// (`hive_ce/src/backend/vm/backend_manager.dart`). This constant is the *size*
/// question's answer only, and it is deliberately not the delete's: a second
/// enumeration of a store's files, kept in step by hand, is how the `.hivec` a
/// compaction leaves behind would be missed.
const List<String> settingsBoxFileSuffixes = ['.hive', '.lock'];

/// Every settings store, in the order [StorageBoxKey] declares them.
///
/// [onWeb] is a parameter rather than a read of `kIsWeb` so that both answers are
/// reachable from a VM test; the view passes `storageOnWebProvider`. Reading the
/// constant here would fold the web arrangement out of the program before any
/// test ran, which is how a settings group that came out empty on web could ship
/// with a green suite.
Future<List<SettingsBoxListing>> listSettingsBoxes(PathInfo info, {required bool onWeb}) async {
  if (onWeb) {
    // The divergence, and the two platform constraints that force it. Both facts
    // are absent, and for different browser reasons:
    //
    //  * **Size.** The stores live in IndexedDB, which reports no per-database
    //    usage at all. The only figure the browser will give is
    //    `navigator.storage.estimate()`, which covers the whole origin and is
    //    already the view's second summary row — there is nothing finer to ask
    //    for. So a store's size here is *unknown*, which is not `0 B`: the stores
    //    hold on web exactly what they hold on Windows, and a zero would be a
    //    measurement of the empty OPFS directory they are not in.
    //  * **Timestamp.** An IndexedDB record has no modification time — the store
    //    is a set of key/value records, and neither the records nor the database
    //    carry a "last written" the API exposes. There is nothing to read at all,
    //    as opposed to something readable that this code declines to read.
    return [
      for (final key in StorageBoxKey.values) (key: key, name: storageBoxNameOf(key), sizeBytes: null, modified: null),
    ];
  }
  final directory = info.settingsDir;
  final listings = <SettingsBoxListing>[];
  for (final key in StorageBoxKey.values) {
    final name = storageBoxNameOf(key);
    listings.add((
      key: key,
      name: name,
      sizeBytes: await _bytesOnDisk(directory, name),
      modified: await _lastWritten(directory, name),
    ));
  }
  return listings;
}

/// When the store was last written: the `.hive`'s timestamp, never the `.lock`'s.
///
/// The pair is treated differently here than it is for the size, and the reason
/// is what each file means. The size question is "how much disk does this store
/// occupy", and both files occupy some. The timestamp question is "when did this
/// setting last change", and only the `.hive` answers it: `hive_ce` opens every
/// box at startup and takes the lock then, so every `.lock` on this machine
/// carries the time the app last *launched* — identical across all eight, and
/// newer than the `.hive` for any store the user has not touched this session.
/// Showing that would give eight rows the same meaningless timestamp and hide the
/// one fact the column exists to show.
Future<DateTime?> _lastWritten(DirectoryPath directory, String name) async {
  final file = directory.filePath('$name.hive');
  try {
    if (!await file.exists()) {
      return null;
    }
    return await file.modified();
  } catch (error, stackTrace) {
    logger.w('Could not read the timestamp of a settings store.', error, stackTrace);
    return null;
  }
}

/// The store's bytes: its `.hive` and its `.lock` added together.
///
/// `null` — not `0` — when nothing could be measured, either because neither file
/// is there yet or because reading one threw. A store whose files are absent is
/// one whose size this view has not observed, and the em dash the caller renders
/// for that says so; `0 B` would assert an emptiness nobody checked.
Future<int?> _bytesOnDisk(DirectoryPath directory, String name) async {
  var total = 0;
  var measured = false;
  for (final suffix in settingsBoxFileSuffixes) {
    final file = directory.filePath('$name$suffix');
    try {
      if (!await file.exists()) {
        continue;
      }
      total += await file.length();
      measured = true;
    } catch (error, stackTrace) {
      // Half a pair is not a smaller store, it is an unmeasured one: reporting
      // the half that read would understate the size while looking exact.
      logger.w('Could not read the size of a settings store.', error, stackTrace);
      return null;
    }
  }
  return measured ? total : null;
}
