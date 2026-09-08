// The desktop half of `FsBackend.readHead`: which `dart:io` primitive the io
// backend actually issues, and over what range.
//
// `readHead` promises a **bounded read**, not a bounded return value. On io the
// two implementations of that signature -- `File.openRead(0, maxBytes)` and
// `readAsBytes()` followed by a cut -- return byte-identical results for every
// input, so no assertion on the value can tell them apart. Nor can a timing
// assertion: it would have to be a threshold, and a threshold drifts on a loaded
// machine. What separates them is *what was requested of the operating system*,
// and that is a fact about the call, not about the answer.
//
// So this suite makes the request itself observable. `dart:io` already ships the
// seam for it: `File(path)` is a factory that consults `IOOverrides.current`, so
// a zone can substitute the object every `File(...)` expression produces. The
// production code is not modified and not branched -- the statements exercised
// here are the same ones `createFsBackend()` runs in the app, reached through
// the process-wide `fsBackend`. A read-then-trim implementation cannot avoid
// this instrument, because it too has to construct a `File`.
//
// The web counterpart of the same claim is `fs_ranged_read_web_test.dart`, which
// establishes the `Blob.slice` behaviour `WebVfs.readHead` is written against.
// Its Dart side is unreachable from any test host (see that file's header), so
// nothing equivalent to this suite exists for web.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/fs_backend_io.dart';
import 'package:umacapture/src/core/storage/file_preview_source.dart';

/// One recorded byte-range request, exactly as the backend phrased it.
typedef _Range = ({int? start, int? end});

/// What the code under test asked the filesystem for, inside one override zone.
class _ReadLog {
  /// Every `openRead(start, end)`, in call order. A correct `readHead` puts one
  /// entry here, `(start: 0, end: maxBytes)`.
  final List<_Range> rangedReads = [];

  /// Every call that pulls a whole file in regardless of any bound, named by the
  /// method that made it. A correct `readHead` leaves this empty; a
  /// read-then-trim implementation cannot.
  final List<String> wholeFileReads = [];

  /// How many `File` objects were constructed in the zone at all, so "no bytes
  /// were requested" can be distinguished from "no file was even opened".
  int filesCreated = 0;
}

/// A `File` that records what was asked of it and forwards to the real one.
///
/// Only the members a filesystem read can plausibly go through are implemented;
/// `noSuchMethod` makes any other member a loud `NoSuchMethodError` rather than
/// a silent pass, so a future implementation that reaches for some third
/// primitive fails here instead of slipping past unrecorded.
class _SpyFile implements File {
  _SpyFile(this._inner, this._log);

  final File _inner;
  final _ReadLog _log;

  @override
  String get path => _inner.path;

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    _log.rangedReads.add((start: start, end: end));
    return _inner.openRead(start, end);
  }

  @override
  Future<Uint8List> readAsBytes() {
    _log.wholeFileReads.add('readAsBytes');
    return _inner.readAsBytes();
  }

  @override
  Uint8List readAsBytesSync() {
    _log.wholeFileReads.add('readAsBytesSync');
    return _inner.readAsBytesSync();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    _log.wholeFileReads.add('readAsString');
    return _inner.readAsString(encoding: encoding);
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    _log.wholeFileReads.add('readAsStringSync');
    return _inner.readAsStringSync(encoding: encoding);
  }

  /// Forwarded but **not** recorded as an unbounded read, because it is not
  /// one: `open` hands back a `RandomAccessFile` and reads no bytes by itself,
  /// and the SDK implements `openRead` on top of it (the stream re-enters the
  /// zone and arrives here). Counting it would make the ranged path indict
  /// itself.
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => _inner.open(mode: mode);

  @override
  Future<int> length() => _inner.length();

  @override
  int lengthSync() => _inner.lengthSync();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Reaches the unoverridden `File` the SDK would have built.
///
/// Inside the override below, a plain `File(path)` would re-enter the override
/// and recurse forever; `IOOverrides` carries the real construction as its own
/// default implementation, so an empty subclass is the way back out to it.
final class _RealIo extends IOOverrides {}

final _realIo = _RealIo();

/// Runs [body] with every `File(...)` construction inside it recorded into the
/// returned log.
Future<_ReadLog> _recording(Future<void> Function() body) async {
  final log = _ReadLog();
  await IOOverrides.runZoned(
    body,
    createFile: (path) {
      log.filesCreated++;
      return _SpyFile(_realIo.createFile(path), log);
    },
  );
  return log;
}

void main() {
  late Directory tempRoot;
  late String binary;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_ranged_read_io');
    binary = '${tempRoot.path}${Platform.pathSeparator}head.bin';
    File(binary).writeAsBytesSync(Uint8List.fromList(List.generate(4096, (i) => i & 0xff)));
  });

  tearDown(() => tempRoot.deleteSync(recursive: true));

  group('IoFsBackend.readHead issues a ranged read', () {
    test('the process-wide backend on this host is the io backend', () {
      // The rest of the group asserts through `fsBackend`, the instance
      // `createFsBackend()` chose. Stating that here keeps the group from
      // quietly measuring some substitute a future setUp installs.
      expect(fsBackend, isA<IoFsBackend>());
    });

    test('a head under the file size is fetched as [0, maxBytes) and nothing more', () async {
      late Uint8List head;
      final log = await _recording(() async => head = await fsBackend.readHead(binary, 8));

      expect(head.toList(), List.generate(8, (i) => i));
      expect(log.rangedReads, [(start: 0, end: 8)], reason: 'the bound has to reach the OS, not a later cut');
      expect(log.wholeFileReads, isEmpty, reason: 'read-then-trim returns the same bytes and is what this rejects');
    });

    test('a bound past the end is still a ranged read', () async {
      // The clamp case: the answer is the whole file either way, so the value
      // proves nothing and only the request distinguishes the implementations.
      late Uint8List head;
      final log = await _recording(() async => head = await fsBackend.readHead(binary, 1 << 20));

      expect(head.length, 4096);
      expect(log.rangedReads, [(start: 0, end: 1 << 20)]);
      expect(log.wholeFileReads, isEmpty);
    });

    test('a non-positive bound opens no file at all', () async {
      late Uint8List head;
      final log = await _recording(() async => head = await fsBackend.readHead(binary, 0));

      expect(head, isEmpty);
      expect(log.filesCreated, 0, reason: 'the short-circuit is meant to cost nothing, not to read and discard');
      expect(log.rangedReads, isEmpty);
      expect(log.wholeFileReads, isEmpty);
    });

    test('the preview source reaches the file through that same ranged read', () async {
      // Closes the chain end to end: `storage_file_preview_test.dart` pins
      // preview -> `FsBackend.readHead` by counting calls on a wrapper, and this
      // pins `readHead` -> the ranged OS call underneath it, which no wrapper
      // around the backend can see.
      late Uint8List head;
      final log = await _recording(() async => head = await FsBackendPreviewSource(binary).readHead(64));

      expect(head.length, 64);
      expect(log.rangedReads, [(start: 0, end: 64)]);
      expect(log.wholeFileReads, isEmpty);
    });
  });
}
