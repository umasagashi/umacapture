import 'dart:async';
import 'dart:io';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '/const.dart';
import '/src/core/fs/fs_backend.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

/// How long a refused delete waits before the next attempt.
///
/// This is a **wall-clock** quantity, not a scheduling one: what it waits for is
/// whoever still holds the file -- an engine image decode, an indexer, a virus
/// scanner, another process -- to let go, and that release happens in operating
/// system time whatever any Dart code believes the time to be. Both retry loops
/// below spend it, and both have to spend it on a clock that measures the world.
const _deleteRetryBackoff = Duration(milliseconds: 100);

class PathEntity {
  static p.Context context = p.Context();

  final List<String> segments;

  static List<String> parseSegments(dynamic src) {
    if (src is String) {
      return context.split(src);
    } else if (src is Directory || src is File) {
      return context.split(src.path);
    } else if (src is PathEntity) {
      return src.segments;
    } else if (src is List<String>) {
      return src;
    } else if (src is List<PathEntity>) {
      return src.expand((e) => e.segments).toList();
    } else {
      throw UnsupportedError("${src.runtimeType} is not supported Path input.");
    }
  }

  static bool startsWithSeparator(String src) {
    return src.startsWith("/") || src.startsWith("\\");
  }

  static bool isFilePathCompatible(dynamic src) {
    return (src is String || src is PathEntity || src is FileSystemEntity) &&
        (src is! DirectoryPath && src is! Directory);
  }

  static bool isDirectoryPathCompatible(dynamic src) {
    return (src is String || src is PathEntity || src is FileSystemEntity) && (src is! FilePath && src is! File);
  }

  PathEntity(dynamic src) : segments = parseSegments(src);

  DirectoryPath get parent {
    return DirectoryPath(segments.sublist(0, segments.length - 1));
  }

  void deleteSync({bool recursive = false, bool emptyOk = false}) {
    if (emptyOk && !existsSync()) {
      return;
    }

    // Retry up to 3 times to avoid file lock issues.
    //
    // The `catch` below selects on nothing -- it takes `Object` -- for the same
    // deliberate reasons as the one in [delete], which carries them in full: the
    // distinction between a refusal that clears and one that never will is real,
    // but nobody can enumerate the first kind, and the two ways of getting the
    // predicate wrong are not symmetric. Only the evidence differs. This variant
    // never reaches web (the web backend's synchronous surface throws
    // `UnsupportedError` -- which this loop would dutifully retry three times
    // before rethrowing, one instance of the cost described there), so the
    // browser measurements cited there bear on [delete] and not on this loop.
    // What is common to both is that neither platform's set of transient modes
    // has been enumerated, and desktop -- the platform this loop is for -- has no
    // measurement of its failure modes at all.
    int attempts = 0;
    while (true) {
      try {
        fsBackend.deleteSync(path, recursive: recursive);
        return; // Exit the loop on success.
      } catch (e) {
        if (++attempts >= 3) {
          rethrow; // Exit the loop on failure.
        }
        // No zone treatment needed here, and that is not an omission: `sleep`
        // blocks the OS thread, so it is real time by construction. There is no
        // zone hook it could be routed through and no clock a zone could
        // substitute -- the wall-clock guarantee [delete] has to ask for
        // explicitly (see the `Zone.root` note there) this one gets for free.
        sleep(_deleteRetryBackoff);
      }
    }
  }

  /// Asynchronous counterpart of [deleteSync] for callers on the UI isolate.
  ///
  /// Retries the same way, but waits with [Future.delayed] instead of [sleep],
  /// so a locked file stalls only this chain rather than the whole isolate.
  Future<void> delete({bool recursive = false, bool emptyOk = false}) async {
    if (emptyOk && !await exists()) {
      return;
    }

    // Retry up to 3 times to avoid file lock issues.
    //
    // The `catch` below selects on nothing -- it takes `Object` -- and that
    // breadth is a decision rather than an oversight. The distinction it declines
    // to draw does exist, and on web it has been measured: an entry held by an
    // open writable is refused with `NoModificationAllowedError`, and the *same*
    // delete succeeds once the holder closes -- exactly the shape this retry was
    // written for -- while `NotFoundError`, `InvalidModificationError` and
    // `TypeMismatchError` come back identical on all three attempts, so retrying
    // them only makes the failure later.
    //
    // Narrowing to the recoverable set is refused all the same, for two reasons.
    // It cannot be enumerated: nothing establishes that every transient mode has
    // been seen, and the desktop side -- the one this retry was originally
    // written for -- has no measurement of its failure modes at all, so the only
    // evidence that retrying rescues anything there is this comment. And the two
    // ways of being wrong are not symmetric: a `catch` that is too wide spends
    // one backoff on a failure that was never going to clear, whereas a predicate
    // that is too narrow drops a transient mode outright, and does it invisibly
    // -- a rescue that stops happening reports nothing to anyone.
    //
    // The price accepted in exchange is stated plainly: a programming error
    // reaching here -- a `NoSuchMethodError`, a `TypeError` -- is retried three
    // times and rethrown two backoffs late, so a defect arrives wearing the face
    // of a timing problem. That is known, and taken, for the reasons above.
    //
    // A narrowing by type would also have to begin from what web actually
    // delivers here, and that is two kinds, not one. OPFS rejects with a bare
    // `JSObject` (a DOMException), but `WebVfs.delete` does not pass all of them
    // on: every "it is not there" case -- a missing segment in the parent walk,
    // a file occupying a directory name, a leaf that is already gone -- it
    // converts into web_vfs's own `FileSystemException`. Only a refusal whose
    // entry still exists is rethrown raw, and that set is exactly the
    // interesting one: `InvalidModificationError`, and the
    // `NoModificationAllowedError` this retry was written for.
    //
    // So neither obvious tidy-up is safe, and they fail in opposite directions.
    // `on FileSystemException` -- meaning `dart:io`'s -- selects nothing web
    // throws, of either kind, and would silently end every retry there. And
    // `on Exception` selects the converted half only, so it would go on
    // retrying the failures measured above to be identical on all three
    // attempts, while dropping the held-entry refusal that is the one thing
    // retrying rescues. Getting it exactly backwards is available; getting it
    // right is not, for the reasons above.
    //
    // What the measurements rest on: `test/opfs_delete_failure_web_test.dart`
    // drives the OPFS API directly, one layer below this `catch`, so read it as
    // evidence about the browser rather than about this boundary. It pins the
    // identical-on-three-attempts result for `NotFoundError` and
    // `InvalidModificationError`, and pins that no refusal is selectable by
    // `dart:io`'s `FileSystemException`. It does *not* pin the
    // `NoModificationAllowedError` name: that is a recorded observation, and
    // what the test asserts is the shape behind it -- whatever the browser
    // refuses a held entry with, the same delete succeeds once the writable
    // closes. A browser that stopped refusing at all would leave that case
    // green, so the name above is worth re-measuring rather than trusting.
    int attempts = 0;
    while (true) {
      try {
        await fsBackend.delete(path, recursive: recursive);
        return;
      } catch (e) {
        if (++attempts >= 3) {
          rethrow;
        }
        // The backoff timer is created on the ROOT zone, never the ambient one.
        // This wait is the real time an operating-system lock needs to be
        // released, and a zone-installed clock does not model the OS: whatever
        // an intervening zone decides the time is, the file goes on being held
        // or released in wall-clock time regardless, so this wait must not be
        // captured by such a clock. Concretely, under `testWidgets` the ambient
        // clock is fake and only advances when the test pumps a *duration* --
        // the repository's own wait helpers (`test/support/settling.dart`) pump
        // without one -- so a delay created there never fires, and a delete that
        // was refused once would never complete for the rest of the test.
        //
        // Only the timer leaves the zone. `await` resumes where it was written,
        // so the retry below, the rethrow, and any error either raises stay in
        // the caller's zone and remain visible to whatever instruments it.
        await Zone.root.run(() => Future<void>.delayed(_deleteRetryBackoff));
      }
    }
  }

  void deleteSyncWithCheck({bool recursive = false, bool emptyOk = false}) {
    try {
      deleteSync(recursive: recursive, emptyOk: emptyOk);
    } catch (error, stackTrace) {
      logger.e("Failed to delete record.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
      parent.launchQuietly();
    }
  }

  /// Asynchronous counterpart of [deleteSyncWithCheck] for callers on the UI
  /// isolate (and the only variant usable on web, where the sync FS throws).
  Future<void> deleteWithCheck({bool recursive = false, bool emptyOk = false}) async {
    try {
      await delete(recursive: recursive, emptyOk: emptyOk);
    } catch (error, stackTrace) {
      logger.e("Failed to delete record.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
      await parent.launchQuietly();
    }
  }

  /// Whether a file or directory exists at this path.
  ///
  /// Primary, cross-platform surface; delegates to the async FS backend.
  Future<bool> exists() => fsBackend.exists(path);

  /// Synchronous counterpart of [exists] (desktop-only escape hatch; throws
  /// [UnsupportedError] on web).
  bool existsSync() => fsBackend.existsSync(path);

  late final bool isFileSync = fsBackend.isFileSync(path);

  /// Whether this path currently resolves to a file (as opposed to a directory).
  ///
  /// Async, cross-platform counterpart of [isFileSync]: it is the only variant
  /// usable on web, where the synchronous FS backend throws. Base implementation
  /// probes the backend; [FilePath] and [DirectoryPath] short-circuit to their
  /// statically known kind, matching the [isFileSync] overrides.
  Future<bool> isFile() => fsBackend.isFile(path);

  FileSystemEntity toEntity() => isFileSync ? File(path) : Directory(path);

  /// Opens this path with the shell's default action: Explorer for a
  /// directory, execution or the associated application for a file.
  ///
  /// Goes through ShellExecuteW (via url_launcher) instead of a `cmd start`
  /// command line, because cmd re-parses the path: spaces turn it into a
  /// window title and `&` splits it into two commands, so such paths fail to
  /// open without any error. ShellExecuteW takes the path as data, reports
  /// failures (which this method rethrows so awaiting callers can surface
  /// them), and handles UAC elevation when the target is an installer.
  ///
  /// Where the platform has no OS file manager ([CurrentPlatform.canRevealInFileManager]
  /// is false) this returns without acting. The gate lives here, not at the call
  /// sites: the sites are UI entries *and* internal failure handlers, and gating
  /// them one by one is what left the web covered at 1 site out of 4. UI entries
  /// still hide themselves with the same capability so nothing offers a button
  /// that does nothing; this is the backstop for every other route in.
  ///
  /// It is deliberately silent rather than throwing: a browser cannot open a
  /// path, and whether `launchUrl(Uri.file(...))` would throw or merely return
  /// false there is engine-dependent, so callers must not have to handle either.
  Future<void> launch() async {
    if (!CurrentPlatform.canRevealInFileManager()) {
      logger.i("Ignoring a reveal request on a platform with no file manager: $path");
      return;
    }
    if (!await launchUrl(Uri.file(path))) {
      throw FileSystemException("The shell has no handler to open this path", path);
    }
  }

  /// Best-effort [launch] for handlers that are already reporting a failure.
  ///
  /// The delete failure paths below open the containing folder as a courtesy on
  /// top of an error the user has just been told about. That courtesy must not
  /// raise a second error: it is called without an owner (from a `catch`, and in
  /// the synchronous variants without an `await` at all), so a shell that
  /// refuses would otherwise surface as an unhandled asynchronous exception
  /// instead of the failure that actually matters.
  Future<void> launchQuietly() async {
    try {
      await launch();
    } catch (error, stackTrace) {
      logger.w("Failed to open the containing folder.", error, stackTrace);
    }
  }

  FilePath toFilePath() {
    assert(isFileSync);
    return asFilePath;
  }

  DirectoryPath toDirectoryPath() {
    assert(!isFileSync);
    return asDirectoryPath;
  }

  FilePath get asFilePath => FilePath(segments);

  DirectoryPath get asDirectoryPath => DirectoryPath(segments);

  String get path => context.joinAll(segments);

  String get stem => p.basenameWithoutExtension(segments.last);

  String get name => segments.last;

  String get extension => p.extension(segments.last);

  String get contentType {
    switch (extension) {
      case ".png":
        return "image/png";
      case ".jpg":
      case ".jpeg":
        return "image/jpeg";
      case ".json":
        return "application/json";
      default:
        throw UnsupportedError("$extension is not supported.");
    }
  }

  @override
  @Deprecated("toString is disabled to prevent implicit conversion. Use path getter instead.")
  String toString() {
    if (kDebugMode) {
      throw UnimplementedError("toString is disabled to prevent implicit conversion. Use path getter instead.");
    }
    return path;
  }
}

class FilePath extends PathEntity {
  FilePath(super.src);

  static FilePath get resolvedExecutable => FilePath(Platform.resolvedExecutable);

  @override
  bool get isFileSync => true;

  @override
  Future<bool> isFile() async => true;

  File toFile() => File(path);

  Future<String> readAsString() => fsBackend.readString(path);

  String readAsStringSync() => fsBackend.readStringSync(path);

  Future<Uint8List> readAsBytes() => fsBackend.readBytes(path);

  Uint8List readAsBytesSync() => fsBackend.readBytesSync(path);

  Future<void> writeAsBytes(List<int> bytes) => fsBackend.writeBytes(path, bytes);

  /// The size of this file in bytes. Throws when it does not exist.
  Future<int> length() => fsBackend.length(path);

  /// Whether this file and [other] hold exactly the same bytes.
  ///
  /// Streams both sides in chunks rather than reading them whole, so comparing
  /// large records does not scale peak memory with the file size.
  Future<bool> sameBytesAs(FilePath other) => fsBackend.sameFileBytes(path, other.path);

  Future<void> writeAsString(String contents) {
    return parent.create(recursive: true).then((_) => fsBackend.writeString(path, contents));
  }

  void writeAsStringSync(String contents) => fsBackend.writeStringSync(path, contents);

  /// Renames this file to [destination], replacing it if it already exists.
  ///
  /// Same-volume only, so callers must keep the temporary and final paths in the
  /// same directory. Throws (rather than reporting) so the caller can surface the
  /// underlying OS error, which carries the reason a replace was refused — most
  /// often a sharing violation because another process holds the destination.
  void renameSync(FilePath destination) => fsBackend.renameSync(path, destination.path);

  /// Asynchronous counterpart of [renameSync]; the same same-volume caveat applies.
  Future<void> rename(FilePath destination) => fsBackend.rename(path, destination.path);

  T deserializeSync<T>() => MapperContainer.globals.fromJson<T>(readAsStringSync());

  /// Asynchronous counterpart of [deserializeSync]; the only variant usable on
  /// web, where the synchronous FS backend throws.
  Future<T> deserialize<T>() async => MapperContainer.globals.fromJson<T>(await readAsString());
}

class DirectoryPath extends PathEntity {
  DirectoryPath(super.src);

  FilePath filePath(dynamic other) {
    assert(PathEntity.isFilePathCompatible(other));
    return FilePath([...segments, ...PathEntity.parseSegments(other)]);
  }

  DirectoryPath _directoryPath(dynamic other) {
    assert(PathEntity.isDirectoryPathCompatible(other));
    return DirectoryPath([...segments, ...PathEntity.parseSegments(other)]);
  }

  DirectoryPath operator /(dynamic other) => _directoryPath(other);

  @override
  bool get isFileSync => false;

  @override
  Future<bool> isFile() async => false;

  Directory toDirectory() => Directory(path);

  /// Wraps a listed entry in the [PathEntity] subtype matching its kind.
  ///
  /// The backend already knows each entry's kind from the listing itself, so
  /// returning a [FilePath]/[DirectoryPath] makes the subsequent
  /// [PathEntity.isFile] / [PathEntity.isFileSync] a constant instead of a second
  /// filesystem probe per entry. That probe is a full root-to-leaf handle walk on
  /// OPFS, and tree walks issue it once per entry per side.
  static PathEntity _typed(FsEntry entry) => entry.isDirectory ? DirectoryPath(entry.path) : FilePath(entry.path);

  List<PathEntity> listSync({bool recursive = false, bool followLinks = false}) {
    return fsBackend.listSync(path, recursive: recursive, followLinks: followLinks).map(_typed).toList();
  }

  Stream<PathEntity> list({bool recursive = false, bool followLinks = false}) async* {
    for (final entry in await fsBackend.list(path, recursive: recursive, followLinks: followLinks)) {
      yield _typed(entry);
    }
  }

  Future<void> create({bool recursive = false}) => fsBackend.createDir(path, recursive: recursive);

  /// Moves this directory to [destination], creating the destination's parent
  /// folders as needed.
  ///
  /// Unlike [deleteSyncSafeWithCheck] this preserves the contents; it is meant
  /// for quarantining data that must not be erased. Returns the destination on
  /// success, or `null` if the move failed (e.g. a file lock), in which case the
  /// directory is left untouched.
  DirectoryPath? moveSyncSafe(DirectoryPath destination) {
    try {
      destination.parent.toDirectory().createSync(recursive: true);
      toDirectory().renameSync(destination.path);
      return destination;
    } catch (error, stackTrace) {
      logger.e("Failed to move directory.", error, stackTrace);
      return null;
    }
  }

  /// Asynchronous, cross-platform counterpart of [moveSyncSafe] for the web /
  /// main-isolate quarantine path.
  ///
  /// The web FS backend's [FilePath.rename] moves a single file only (OPFS has no
  /// directory rename), so this moves the directory by [copyTreeInto] followed by
  /// [deleteWithCheck] of the source, rather than an atomic same-volume rename.
  /// Returns the destination on success, or `null` if the copy failed, in which
  /// case the source is left in place (the move is not atomic: a copy that fails
  /// part-way may leave a partial [destination] behind, which is harmless for the
  /// quarantine use case).
  Future<DirectoryPath?> moveAsyncSafe(DirectoryPath destination) async {
    if (!await copyTreeInto(destination)) {
      return null;
    }
    await deleteWithCheck(recursive: true);
    return destination;
  }

  /// Recursively copies this directory's contents into [destination].
  ///
  /// Unlike [moveSyncSafe] (a same-volume rename) this works across drives, so
  /// it is the basis of the data-root migration where the target is typically on
  /// another volume. The destination tree is created as needed; existing files
  /// are overwritten. Returns `true` on success, or `false` if any entry fails
  /// (logged).
  ///
  /// Cross-platform: the file/directory branch goes through the async
  /// [PathEntity.isFile] rather than the sync `isFileSync`, so it works on the
  /// web (OPFS) backend, whose synchronous surface throws.
  ///
  /// On failure, everything this call created is removed (partial copies
  /// included) so nothing is left behind as an orphan that a caller's
  /// "destination already exists" guard would later refuse. That is the whole
  /// created chain, not just [destination]: the `create(recursive: true)` below
  /// materialises every missing ancestor too. A [destination] (or ancestor) that
  /// already existed before the copy started is left untouched, and so is
  /// anything a *different* writer put inside the created chain while this copy
  /// was running — see [_pruneCreatedChain].
  Future<bool> copyTreeInto(DirectoryPath destination) async {
    // A source that is not a directory is not copyable, and must never be
    // reported as "copied into an empty destination": callers compare the two
    // trees afterwards and act on the comparison, up to deleting the source.
    if (await fsBackend.isFile(path)) {
      logger.e("Refusing to copy a tree from a non-directory source: $path");
      return false;
    }
    final createdRoot = await _shallowestMissingAncestorOf(destination);
    try {
      // Track directories we have already created so each one is made at most
      // once: without this both the per-directory entry and every file's parent
      // would issue a redundant recursive create (D + N syscalls for N files in
      // D directories).
      final created = <String>{};
      Future<void> ensureDir(DirectoryPath dir) async {
        if (created.add(dir.path)) {
          await dir.create(recursive: true);
        }
      }

      await ensureDir(destination);
      await for (final entity in list(recursive: true)) {
        final relative = PathEntity.context.relative(entity.path, from: path);
        if (await entity.isFile()) {
          final target = destination.filePath(relative);
          await ensureDir(target.parent);
          await fsBackend.copyFile(entity.path, target.path);
        } else {
          // Preserve empty directories, which the per-file branch never creates.
          await ensureDir(destination / relative);
        }
      }
      return true;
    } catch (error, stackTrace) {
      logger.e("Failed to copy directory tree.", error, stackTrace);
      // Remove the chain we created so a failed copy leaves no orphan
      // directory; keep anything that predated the copy (the caller owns it).
      if (createdRoot != null) {
        try {
          await _pruneCreatedChain(destination, createdRoot);
        } catch (cleanupError, cleanupStackTrace) {
          logger.e("Failed to clean up partial copy destination.", cleanupError, cleanupStackTrace);
        }
      }
      return false;
    }
  }

  /// Undoes the directory chain [copyTreeInto] created, from [destination] up to
  /// and including [createdRoot], removing an ancestor only while it is still
  /// empty.
  ///
  /// [createdRoot] is a snapshot taken *before* the copy, so deleting that path
  /// recursively would delete by location what the contract defines by
  /// provenance. The two sets differ as soon as anyone else writes into the
  /// chain meanwhile: on the web every record publish targets the same
  /// `active/`, so a sibling record that finished during this copy sits inside
  /// the chain without having been created by this call. Emptiness is therefore
  /// re-checked against the filesystem at deletion time instead of trusting the
  /// snapshot — the walk stops at the first directory that holds anything, which
  /// covers every writer, present or future, without enumerating who they are.
  ///
  /// [destination] itself is the one path this call exclusively owns: the probe
  /// in [_shallowestMissingAncestorOf] proved it absent, so what stands there is
  /// this call's own partial copy, and it is removed with everything inside it.
  /// Reaching into it would mean writing the very record the caller is
  /// publishing, which its record lock excludes.
  static Future<void> _pruneCreatedChain(DirectoryPath destination, DirectoryPath createdRoot) async {
    await destination.delete(recursive: true, emptyOk: true);
    // Guard on the segment count as well: the chain is bounded by [createdRoot],
    // which is never the topmost segment, so this only stops a walk that has
    // already left the chain it was given.
    for (var dir = destination; dir.path != createdRoot.path && dir.segments.length > 2;) {
      dir = dir.parent;
      final isEmpty = await dir.list().isEmpty;
      if (!isEmpty) {
        return;
      }
      // Non-recursive on purpose: if the directory gains an entry between the
      // check and the delete, the delete fails instead of taking it with it.
      await dir.delete(emptyOk: true);
    }
  }

  /// The shallowest directory a `create(recursive: true)` of [destination] would
  /// have to bring into existence, or `null` if [destination] already exists.
  ///
  /// It bounds the chain the create produced: nothing above it was created, so
  /// nothing above it may be removed. It is not by itself a licence to delete —
  /// what is inside the chain at cleanup time is a separate question, answered in
  /// [_pruneCreatedChain]. The walk stops before the topmost segment (a drive
  /// root or `/`), which is never a directory this call could have created.
  static Future<DirectoryPath?> _shallowestMissingAncestorOf(DirectoryPath destination) async {
    if (await destination.exists()) {
      return null;
    }
    var shallowest = destination;
    for (var ancestor = destination.parent; ancestor.segments.length > 1; ancestor = ancestor.parent) {
      if (await ancestor.exists()) {
        break;
      }
      shallowest = ancestor;
    }
    return shallowest;
  }

  /// Deletes every entry inside this directory, leaving the (now empty)
  /// directory itself in place.
  ///
  /// Used to reclaim scratch space (e.g. the `temp` tree the native pipeline
  /// leaves scraping fragments in after an incomplete capture) without removing
  /// the directory the app expects to exist. Each child is removed recursively
  /// via [PathEntity.deleteSync], inheriting its file-lock retry. A missing
  /// directory is a no-op when [emptyOk]; individual entries that fail to delete
  /// are skipped so a single locked file does not abort the rest.
  void clearSync({bool emptyOk = true}) {
    if (emptyOk && !existsSync()) {
      return;
    }
    for (final entry in listSync(recursive: false, followLinks: false)) {
      try {
        entry.deleteSync(recursive: true, emptyOk: true);
      } catch (error, stackTrace) {
        logger.e("Failed to delete temp entry: ${entry.path}", error, stackTrace);
      }
    }
  }

  /// Asynchronous, cross-platform counterpart of [clearSync].
  ///
  /// [clearSync] goes through the synchronous FS surface, which the web (OPFS)
  /// backend does not implement, so any caller that also runs on web must take
  /// this route. The contract is otherwise identical: a missing directory is a
  /// no-op when [emptyOk], the directory itself survives, and an entry that
  /// refuses to be deleted is logged and skipped so one stubborn entry does not
  /// abandon the rest.
  Future<void> clear({bool emptyOk = true}) async {
    if (emptyOk && !await exists()) {
      return;
    }
    await for (final entry in list(recursive: false, followLinks: false)) {
      try {
        await entry.delete(recursive: true, emptyOk: true);
      } catch (error, stackTrace) {
        logger.e("Failed to delete temp entry: ${entry.path}", error, stackTrace);
      }
    }
  }

  void deleteSyncSafeWithCheck() {
    try {
      listSync(recursive: false, followLinks: false).forEach((e) => e.deleteSync(recursive: false));
      deleteSync(recursive: false);
    } catch (error, stackTrace) {
      logger.e("Failed to delete record.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
      launchQuietly();
    }
  }
}

extension DirectoryExtension on Directory {
  DirectoryPath toPath() => DirectoryPath(this);
}

extension FileExtension on File {
  FilePath toPath() => FilePath(this);
}
