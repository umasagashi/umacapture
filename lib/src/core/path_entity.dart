import 'dart:io';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '/src/core/utils.dart';
import '/src/gui/toast.dart';

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
    int attempts = 0;
    while (true) {
      try {
        toEntity().deleteSync(recursive: recursive);
        return; // Exit the loop on success.
      } catch (e) {
        if (++attempts >= 3) {
          rethrow; // Exit the loop on failure.
        }
        sleep(const Duration(milliseconds: 100));
      }
    }
  }

  /// Asynchronous counterpart of [deleteSync] for callers on the UI isolate.
  ///
  /// Retries the same way, but waits with [Future.delayed] instead of [sleep],
  /// so a locked file stalls only this chain rather than the whole isolate.
  Future<void> delete({bool recursive = false, bool emptyOk = false}) async {
    if (emptyOk && !existsSync()) {
      return;
    }

    // Retry up to 3 times to avoid file lock issues.
    int attempts = 0;
    while (true) {
      try {
        await toEntity().delete(recursive: recursive);
        return;
      } catch (e) {
        if (++attempts >= 3) {
          rethrow;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  void deleteSyncWithCheck({bool recursive = false, bool emptyOk = false}) {
    try {
      deleteSync(recursive: recursive, emptyOk: emptyOk);
    } catch (error, stackTrace) {
      logger.e("Failed to delete record.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
      parent.launch();
    }
  }

  bool existsSync() => toEntity().existsSync();

  late final bool isFileSync = FileSystemEntity.isFileSync(path);

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
  Future<void> launch() async {
    if (!await launchUrl(Uri.file(path))) {
      throw FileSystemException("The shell has no handler to open this path", path);
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

  File toFile() => File(path);

  Future<String> readAsString() => toFile().readAsString();

  String readAsStringSync() => toFile().readAsStringSync();

  Future<Uint8List> readAsBytes() => toFile().readAsBytes();

  Uint8List readAsBytesSync() => toFile().readAsBytesSync();

  Future<File> writeAsBytes(List<int> bytes) => toFile().writeAsBytes(bytes);

  Future<void> writeAsString(String contents) {
    return parent.create(recursive: true).then((_) => toFile().writeAsString(contents));
  }

  void writeAsStringSync(String contents) => toFile().writeAsStringSync(contents);

  /// Renames this file to [destination], replacing it if it already exists.
  ///
  /// Same-volume only, so callers must keep the temporary and final paths in the
  /// same directory. Throws (rather than reporting) so the caller can surface the
  /// underlying OS error, which carries the reason a replace was refused — most
  /// often a sharing violation because another process holds the destination.
  void renameSync(FilePath destination) => toFile().renameSync(destination.path);

  /// Asynchronous counterpart of [renameSync]; the same same-volume caveat applies.
  Future<void> rename(FilePath destination) => toFile().rename(destination.path);

  T deserializeSync<T>() => MapperContainer.globals.fromJson<T>(readAsStringSync());
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

  Directory toDirectory() => Directory(path);

  List<PathEntity> listSync({bool recursive = false, bool followLinks = false}) {
    return toDirectory().listSync(recursive: recursive, followLinks: followLinks).map((e) => PathEntity(e)).toList();
  }

  Stream<PathEntity> list({bool recursive = false, bool followLinks = false}) {
    return toDirectory().list(recursive: recursive, followLinks: followLinks).map((e) => PathEntity(e));
  }

  Future<void> create({bool recursive = false}) => toDirectory().create(recursive: recursive);

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

  /// Recursively copies this directory's contents into [destination].
  ///
  /// Unlike [moveSyncSafe] (a same-volume rename) this works across drives, so
  /// it is the basis of the data-root migration where the target is typically on
  /// another volume. The destination tree is created as needed; existing files
  /// are overwritten. Returns `true` on success, or `false` if any entry fails
  /// (logged), leaving partially-copied data for the caller to clean up.
  Future<bool> copyTreeInto(DirectoryPath destination) async {
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
        if (entity.isFileSync) {
          final target = destination.filePath(relative);
          await ensureDir(target.parent);
          await entity.asFilePath.toFile().copy(target.path);
        } else {
          // Preserve empty directories, which the per-file branch never creates.
          await ensureDir(destination / relative);
        }
      }
      return true;
    } catch (error, stackTrace) {
      logger.e("Failed to copy directory tree.", error, stackTrace);
      return false;
    }
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

  void deleteSyncSafeWithCheck() {
    try {
      listSync(recursive: false, followLinks: false).forEach((e) => e.deleteSync(recursive: false));
      deleteSync(recursive: false);
    } catch (error, stackTrace) {
      logger.e("Failed to delete record.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
      launch();
    }
  }
}

extension DirectoryExtension on Directory {
  DirectoryPath toPath() => DirectoryPath(this);
}

extension FileExtension on File {
  FilePath toPath() => FilePath(this);
}
