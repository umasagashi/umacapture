// The image caches a storage-view delete has to drop (stage 6d). Nothing in
// this app used to evict an image, so a deleted picture went on being displayed
// from Flutter's own `ImageCache` (and, on web, from a second byte LRU) and the
// delete looked like it had not worked.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_image_cache_eviction_test.dart
//
// The claim under test: *a picture that was
// on screen a moment ago must not survive its own file*. Before this stage the
// app had no eviction at all -- `imageCache` appeared nowhere in `lib/` -- so a
// delete removed the bytes and left the decoded pixels reachable, and the user
// saw a picture the app had just told them was gone.
//
// Two caches answer for one picture, and they are keyed differently, so both are
// asserted:
//
//   * **desktop** resolves through `Image.file`, so the global `ImageCache` is
//     keyed by the *file*. That half is exercised end to end below: a real PNG is
//     written, rendered, deleted through `runStorageDelete`, and rendered again.
//   * **web** resolves through `Image.memory` over `RecordImageByteCache`, so the
//     global cache is keyed by the *identity of the byte list*. The byte cache is
//     ordinary Dart and is compiled by this suite, so the arrangement is
//     reproduced here directly: bytes in the LRU, the `MemoryImage` they decoded
//     to in the global cache, and one `evictRecordImages` call that has to reach
//     both.
//
// TWO CONTROLS, because "the delete evicts" is trivially satisfiable by flushing
// everything, and by evicting the paths the *caller asked about* rather than the
// ones that went:
//
//   * a picture in a different record, untouched by the delete, is still in the
//     cache afterwards -- a `imageCache.clear()` implementation fails here;
//   * a picture whose delete the platform *refused* is still in the cache -- an
//     implementation evicting `targets` instead of `report.deleted` fails here,
//     and it is the file still being on disk that makes that wrong.
//
// WHAT THIS SUITE DOES NOT REACH. It runs on the VM, so `kIsWeb` is false and the
// `FileImage` branch of `evictRecordImages` is the one that executes; the web
// branch is exercised by driving the byte cache and `MemoryImage` directly, which
// is the same production code but not the same widget path (`_WebRecordImage`
// only builds under `kIsWeb`). Nothing here runs in a browser: the browser suite
// is `dart test --platform chrome`, which cannot compile `package:flutter` at
// all, so no test anywhere can reach a real OPFS-backed `RecordImage`. Whether a
// browser's own HTTP/blob layer holds a second copy is outside both suites.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/record_image.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/web_like_fs_backend.dart';

/// A real 1x1 RGBA PNG, so the decode under test is the platform's own.
///
/// A stub of arbitrary bytes would fail to decode, and every assertion below
/// would then be satisfied by an image that was never in the cache in the first
/// place.
const _pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4z8DwHwAFAAH/VscvDQAAAABJRU5ErkJggg==';

/// Rendered in place of an image that can no longer be read.
const _unavailable = 'image-unavailable';

/// Delegates to the io backend but refuses to delete the paths [refuse] selects.
///
/// Holding a file open for real depends on the operating system's sharing rules,
/// so the refusal is injected at the boundary the delete engine talks to instead
/// — the same device `storage_delete_action_test.dart` uses.
class _RefusingFsBackend extends WebLikeFsBackend {
  _RefusingFsBackend(super.inner, {required this.refuse});

  final bool Function(String path) refuse;

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    if (refuse(path)) {
      throw FileSystemException('The process cannot access the file because it is being used', path);
    }
    return super.delete(path, recursive: recursive);
  }
}

late Directory _tempRoot;
late PathInfo _layout;
late FsBackend _realBackend;

StorageGroup _groupOf(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

/// Writes the PNG at [relative] under the temp root and answers it as a
/// [FilePath].
///
/// Spelled through [PathEntity] rather than with a literal separator: the report
/// carries the paths the engine saw, and on Windows those are backslash-joined —
/// a slash-joined literal compares unequal to every one of them, so an eviction
/// keyed by it would silently address nothing.
FilePath _seedImage(String relative) {
  final parts = relative.split('/');
  var directory = DirectoryPath(_tempRoot.path);
  for (final part in parts.take(parts.length - 1)) {
    directory = directory / part;
  }
  final path = directory.filePath(parts.last);
  final file = File(path.path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(base64.decode(_pngBase64));
  return path;
}

/// The box every bounded case here asks for, small enough that the seeded PNG is
/// not upscaled and large enough to be a real bound.
const Size _decodeBox = Size(8, 8);

/// A screen of bounded [RecordImage]s, one per entry of [paths].
Widget _boundedScreen(Map<String, FilePath> paths) {
  return MaterialApp(
    home: Row(
      children: [
        for (final entry in paths.entries)
          SizedBox(
            width: 40,
            height: 40,
            child: RecordImage(entry.value, key: ValueKey(entry.key), fit: BoxFit.contain, maxDecodePixels: _decodeBox),
          ),
      ],
    ),
  );
}

/// The [ImageCache] key the bounded widget filed its decode under.
///
/// Rebuilt from the *held* bytes rather than from the path: `MemoryImage`
/// compares by identity, so the instance the LRU is holding is the only one that
/// produces an equal key.
Future<Object> _boundedKeyOf(FilePath path) {
  final bytes = RecordImageByteCache.instance.get(path.path);
  expect(bytes, isA<Uint8List>(), reason: 'the bounded widget did not fill the byte cache');
  return boundedRecordImageProvider(MemoryImage(bytes as Uint8List), _decodeBox).obtainKey(ImageConfiguration.empty);
}

ImageCache get _imageCache => PaintingBinding.instance.imageCache;

bool _cached(FilePath path) => _imageCache.containsKey(FileImage(File(path.path)));

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      // The delete path resolves its own directories from the layout rather than
      // from `pathInfoProvider`, so it keeps working while the record store is
      // unavailable.
      pathLayoutLoader.overrideWith((ref) async => _layout),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// One [RecordImage] whose element is distinct from the others in the tree.
///
/// The key matters: `Image` re-resolves its provider when the element is *new* or
/// the provider changed, and `FileImage` has value equality, so re-pumping the
/// same path into the same element resolves nothing and could never observe a
/// cache miss. A new key is what forces the second lookup this suite is about.
Widget _tile(String id, FilePath path) {
  return RecordImage(
    path,
    key: ValueKey(id),
    width: 8,
    height: 8,
    errorBuilder: (_, _, _) => const Text(_unavailable, textDirection: TextDirection.ltr),
  );
}

Widget _screen(List<Widget> children) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does
/// not: an io delete, a file read and an image decode all complete off it.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// Decodes [provider] into the global cache and waits for it, without a widget.
///
/// Used for the web arrangement, where the cache key is a `MemoryImage` over
/// bytes the LRU is holding and no widget on this platform would ever build one.
Future<void> _warm(WidgetTester tester, ImageProvider provider) async {
  await tester.runAsync(() async {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (_, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) {
          completer.completeError(StateError('the test PNG did not decode'));
        }
      },
    );
    stream.addListener(listener);
    await completer.future;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // `runStorageDelete` builds its outcome sentence before it consults `silent`, so the
  // shipped strings are loaded here even though nothing below reads one.
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_storage_image_evict');
    _realBackend = fsBackend;
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    _imageCache.clear();
    _imageCache.clearLiveImages();
  });

  tearDown(() {
    fsBackend = _realBackend;
    _imageCache.clear();
    _imageCache.clearLiveImages();
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  group('a deleted picture is not shown again', () {
    testWidgets('re-displaying a deleted image fails instead of coming out of the cache', (tester) async {
      final shown = _seedImage('documents/storage/chara_detail/active/rec-1/skill.png');
      final untouched = _seedImage('documents/storage/chara_detail/active/rec-2/skill.png');
      final container = _container();

      // The picture is on screen, and stays on screen across the delete: that is
      // the scenario the eviction requirement was written for -- the picture the
      // user was just looking at -- and it is what puts the entry in the cache's *live*
      // table as well as the cache proper. (Whether the live half is dropped is
      // not falsifiable from here -- `ImageCache.evict` includes live images by
      // default -- so this arrangement covers the live case without pinning it.)
      await tester.pumpWidget(_screen([_tile('shown', shown), _tile('other', untouched)]));
      await _settle(tester);
      expect(find.text(_unavailable), findsNothing, reason: 'the seeded PNG never decoded');
      expect(_cached(shown), isTrue, reason: 'the premise of this test — nothing was cached to evict');
      expect(_cached(untouched), isTrue);

      // Through `runAsync`: the delete is io, and a `testWidgets` body's fake
      // clock never advances the real event loop the io completes on.
      await tester.runAsync(
        () => runStorageDelete(
          container.read(refBaseProvider),
          group: _groupOf(StorageGroupId.activeRecords),
          request: StorageDeletePathsRequest([shown.parent]),
          silent: true,
        ),
      );
      await _settle(tester);
      expect(File(shown.path).existsSync(), isFalse, reason: 'the delete itself did not run');

      // A second, freshly-keyed widget for the same path: what the user does when
      // they open the picture again.
      await tester.pumpWidget(_screen([_tile('shown', shown), _tile('other', untouched), _tile('reopened', shown)]));
      await _settle(tester);
      expect(find.text(_unavailable), findsOneWidget, reason: 'the deleted image was served out of the cache');

      // Control: the eviction is addressed, not a flush. `imageCache.clear()`
      // would satisfy every assertion above and fail this one.
      expect(_cached(untouched), isTrue, reason: 'a picture nothing deleted was dropped from the cache');
    });

    testWidgets('an image whose delete was refused stays cached', (tester) async {
      final held = _seedImage('documents/storage/chara_detail/active/rec-1/skill.png');
      final container = _container();
      fsBackend = _RefusingFsBackend(fsBackend, refuse: (path) => path == held.path);

      await tester.pumpWidget(_screen([_tile('shown', held)]));
      await _settle(tester);
      expect(_cached(held), isTrue);

      final report = await tester.runAsync(
        () => runStorageDelete(
          container.read(refBaseProvider),
          group: _groupOf(StorageGroupId.activeRecords),
          request: StorageDeletePathsRequest([held.parent]),
          silent: true,
        ),
      );
      await _settle(tester);

      expect(report?.deletedPaths, isNot(contains(held.path)), reason: 'the refusal was not injected');
      expect(File(held.path).existsSync(), isTrue);
      // The file is still there, so its decoded pixels are still correct. An
      // eviction keyed off the *requested* targets instead of the report would
      // drop them and buy a re-decode of an unchanged picture.
      expect(_cached(held), isTrue, reason: 'a picture that was not deleted was evicted anyway');
    });
  });

  group('the web half of the eviction: the byte LRU and the identity-keyed decode', () {
    test('remove answers the held instance, which is the only key to the decode', () {
      final bytes = base64.decode(_pngBase64);
      RecordImageByteCache.instance.put('/opfs/a.png', bytes);
      addTearDown(() => RecordImageByteCache.instance.remove('/opfs/a.png'));

      expect(RecordImageByteCache.instance.get('/opfs/a.png'), same(bytes));
      expect(RecordImageByteCache.instance.remove('/opfs/a.png')?.bytes, same(bytes));
      expect(RecordImageByteCache.instance.get('/opfs/a.png'), isNull);
      expect(RecordImageByteCache.instance.remove('/opfs/a.png'), isNull, reason: 'a second remove must be harmless');
    });

    testWidgets('evictRecordImages drops both the bytes and the picture they decoded to', (tester) async {
      final bytes = base64.decode(_pngBase64);
      final other = base64.decode(_pngBase64);
      RecordImageByteCache.instance.put('/opfs/gone.png', bytes);
      RecordImageByteCache.instance.put('/opfs/stays.png', other);
      addTearDown(() {
        RecordImageByteCache.instance.remove('/opfs/gone.png');
        RecordImageByteCache.instance.remove('/opfs/stays.png');
      });

      await _warm(tester, MemoryImage(bytes));
      await _warm(tester, MemoryImage(other));
      expect(_imageCache.containsKey(MemoryImage(bytes)), isTrue);

      evictRecordImages(['/opfs/gone.png']);

      expect(RecordImageByteCache.instance.get('/opfs/gone.png'), isNull, reason: 'the LRU still holds the bytes');
      expect(
        _imageCache.containsKey(MemoryImage(bytes)),
        isFalse,
        reason: 'the decoded picture outlived the bytes that keyed it',
      );
      // Control again, on the other cache: a path nobody deleted keeps both halves.
      expect(RecordImageByteCache.instance.get('/opfs/stays.png'), same(other));
      expect(_imageCache.containsKey(MemoryImage(other)), isTrue);
    });
  });

  // A bounded decode is filed under a `ResizeImageKey`, which is equal to
  // neither `FileImage` (compares paths) nor `MemoryImage` (compares bytes by
  // identity). So the two bare evictions below cannot reach it, and on the
  // desktop path there is no "the bytes went first" argument to fall back on
  // either -- `FileImage` would be rebuilt equal after a delete. Both halves are
  // asserted here, because either one alone still leaves a deleted picture
  // reachable.
  group('a bounded decode is evicted by name', () {
    testWidgets('a bounded RecordImage resolves through the bytes, not through FileImage', (tester) async {
      final path = _seedImage('documents/unclassified/bounded.png');
      addTearDown(() => RecordImageByteCache.instance.remove(path.path));

      await tester.pumpWidget(_boundedScreen({'only': path}));
      await _settle(tester);

      final provider = (find.byType(Image).evaluate().single.widget as Image).image as ResizeImage;
      expect(
        provider.imageProvider,
        isA<MemoryImage>(),
        reason: 'a ResizeImage over FileImage keys by path, so a delete could not make it unreachable',
      );
      expect(RecordImageByteCache.instance.get(path.path), isNotNull, reason: 'the LRU owns the key to the decode');
    });

    testWidgets('evictRecordImages drops the bounded picture, and only the one that was deleted', (tester) async {
      final gone = _seedImage('documents/unclassified/gone.png');
      final kept = _seedImage('documents/unclassified/kept.png');
      addTearDown(() {
        RecordImageByteCache.instance.remove(gone.path);
        RecordImageByteCache.instance.remove(kept.path);
      });

      await tester.pumpWidget(_boundedScreen({'gone': gone, 'kept': kept}));
      await _settle(tester);
      // Taken before the eviction: the key is only nameable while the LRU still
      // holds the bytes it wraps, which is the whole reason the registration
      // lives beside them.
      final goneKey = await _boundedKeyOf(gone);
      final keptKey = await _boundedKeyOf(kept);
      expect(_imageCache.containsKey(goneKey), isTrue, reason: 'nothing was cached, so the eviction proves nothing');

      evictRecordImages([gone.path]);

      expect(_imageCache.containsKey(goneKey), isFalse, reason: 'the bounded entry outlived the delete');
      // Control on the same key shape: a path nobody deleted keeps its picture.
      expect(_imageCache.containsKey(keptKey), isTrue);
    });
  });

  // The entry count was the LRU's only bound, and a count is not a memory
  // bound: measured over this installation's 834 image files, the 48 largest
  // sum to 117,428,186 B, so the count cap alone admits 112 MiB of held bytes
  // from files the app wrote itself.
  group('the byte LRU is bounded in bytes as well as in entries', () {
    tearDown(() {
      for (var i = 0; i < 64; i++) {
        RecordImageByteCache.instance.remove('/opfs/bulk$i.png');
      }
    });

    test('holding 48 median-sized images does not evict, so the count cap still does its job', () {
      // 839,044 B is the median image on the store the cap was measured against;
      // 48 of them is 38.4 MB, under the byte bound. If this evicted, the LRU
      // would miss on the re-layout it exists to serve.
      for (var i = 0; i < 48; i++) {
        RecordImageByteCache.instance.put('/opfs/bulk$i.png', Uint8List(839044));
      }

      expect(RecordImageByteCache.instance.get('/opfs/bulk0.png'), isNotNull, reason: 'the oldest was evicted');
      expect(RecordImageByteCache.instance.heldBytes, 48 * 839044);
    });

    test('a run of large images is bounded by bytes long before the count cap is reached', () {
      // Eight images at the largest size the read bound permits: 128 MiB, which
      // the entry cap would hold in full.
      for (var i = 0; i < 8; i++) {
        RecordImageByteCache.instance.put('/opfs/bulk$i.png', Uint8List(16777216));
      }

      expect(RecordImageByteCache.instance.heldBytes, lessThanOrEqualTo(67108864));
      expect(RecordImageByteCache.instance.get('/opfs/bulk7.png'), isNotNull, reason: 'the newest read must be a hit');
      expect(RecordImageByteCache.instance.get('/opfs/bulk0.png'), isNull, reason: 'the oldest must have gone first');
    });

    test('an entry larger than the whole bound is still answered, alone', () {
      // The read side is what refuses an oversized file; a cache that dropped
      // what it was just asked to hold would make that read a permanent miss.
      final huge = Uint8List(67108864 + 1024);
      RecordImageByteCache.instance.put('/opfs/bulk0.png', huge);

      expect(RecordImageByteCache.instance.get('/opfs/bulk0.png'), same(huge));
      expect(RecordImageByteCache.instance.heldBytes, huge.lengthInBytes);
    });

    test('remove keeps the byte count honest', () {
      RecordImageByteCache.instance.put('/opfs/bulk0.png', Uint8List(1024));
      RecordImageByteCache.instance.put('/opfs/bulk1.png', Uint8List(2048));
      RecordImageByteCache.instance.remove('/opfs/bulk0.png');

      // A count that only ever grew would evict everything after enough
      // deletes, silently, and no existing case would notice.
      expect(RecordImageByteCache.instance.heldBytes, 2048);
    });
  });
}
