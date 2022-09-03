import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';

class PathEntity {
  static Context context = Context();

  final List<String> segments;

  static List<String> parseSegments(src) {
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

  static bool isFilePathCompatible(src) {
    return (src is String || src is PathEntity || src is FileSystemEntity) &&
        (src is! DirectoryPath && src is! Directory);
  }

  static bool isDirectoryPathCompatible(src) {
    return (src is String || src is PathEntity || src is FileSystemEntity) && (src is! FilePath && src is! File);
  }

  PathEntity(src) : segments = parseSegments(src);

  DirectoryPath get parent {
    return DirectoryPath(segments.sublist(0, segments.length - 1));
  }

  void deleteSync({bool recursive = false}) => toEntity().deleteSync(recursive: recursive);

  bool existsSync() => toEntity().existsSync();

  late final bool isFileSync = FileSystemEntity.isFileSync(path);

  FileSystemEntity toEntity() => isFileSync ? File(path) : Directory(path);

  Future<void> launch() {
    return Process.run("start", [path], runInShell: true);
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

  String get stem => basenameWithoutExtension(segments.last);

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

  Future<File> writeAsBytes(List<int> bytes) => toFile().writeAsBytes(bytes);

  Future<void> writeAsString(String contents) {
    return parent.create(recursive: true).then((_) => toFile().writeAsString(contents));
  }

  void writeAsStringSync(String contents) => toFile().writeAsStringSync(contents);
}

class DirectoryPath extends PathEntity {
  DirectoryPath(super.src);

  FilePath filePath(other) {
    assert(PathEntity.isFilePathCompatible(other));
    return FilePath([...segments, ...PathEntity.parseSegments(other)]);
  }

  DirectoryPath _directoryPath(other) {
    assert(PathEntity.isDirectoryPathCompatible(other));
    return DirectoryPath([...segments, ...PathEntity.parseSegments(other)]);
  }

  DirectoryPath operator /(other) => _directoryPath(other);

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

  void deleteSyncSafe() {
    listSync(recursive: false, followLinks: false).forEach((e) => e.deleteSync(recursive: false));
    deleteSync(recursive: false);
  }
}

extension DirectoryExtension on Directory {
  DirectoryPath toPath() => DirectoryPath(this);
}

extension FileExtension on File {
  FilePath toPath() => FilePath(this);
}
