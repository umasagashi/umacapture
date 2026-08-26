// Asserts the provenance contract of `DirectoryPath.copyTreeInto`'s failure
// cleanup directly: **what this copy did not create is not removed when it
// fails**, even when it sits inside a directory the copy did create.
//
// The contract is written at `path_entity.dart` ("everything this call created
// is removed … A [destination] (or ancestor) that already existed before the
// copy started is left untouched"). The cleanup used to satisfy it only under an
// invariant nothing asserted: that no other writer touched the created chain
// between the pre-copy snapshot and the failure. On web every record publish
// targets the same `active/`, so that invariant does not hold, and a recursive
// delete of the snapshot path took a sibling record with it.
//
// The backend is swapped for `WebLikeFsBackend`, which pins OPFS's *synchronous*
// prohibition and nothing else: the async surface is delegated to io, so what
// runs here is io semantics with the sync surface forbidden, not OPFS semantics
// -- see `support/web_like_fs_backend.dart` for what it does not model. Every
// assertion reads the real on-disk result through `dart:io`, bypassing the
// installed backend. All paths live under a per-test system temp directory.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/copy_tree_cleanup_provenance_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempRoot;
  late FsBackend original;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_copy_tree_cleanup_test');
    original = fsBackend;
    fsBackend = WebLikeFsBackend(original);
  });

  tearDown(() {
    fsBackend = original;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  /// A source tree whose second file fails to copy.
  Future<DirectoryPath> makeSource() async {
    final src = DirectoryPath('${tempRoot.path}/src');
    await src.filePath('a.txt').writeAsString('alpha');
    await src.filePath('b.txt').writeAsString('beta');
    return src;
  }

  bool failsOnB(String source) => source.endsWith('b.txt');

  test('a record another writer created inside the created chain survives the failure', () async {
    final src = await makeSource();
    // `active/` does not exist yet: this copy will create it, which is what made
    // the old cleanup delete it (and everything under it) wholesale.
    expect(Directory('${tempRoot.path}/active').existsSync(), isFalse);

    // Another writer publishes `active/X` after the pre-copy snapshot was taken
    // and before this copy fails. Writing it from the copyFile hook makes the
    // interleaving deterministic rather than timing-dependent.
    fsBackend = _ForeignWriteThenFailBackend(original, failsOnB, () {
      Directory('${tempRoot.path}/active/X').createSync(recursive: true);
      File('${tempRoot.path}/active/X/record.json').writeAsStringSync('{"id":"X"}');
    });

    final ok = await src.copyTreeInto(DirectoryPath('${tempRoot.path}/active/Y'));

    expect(ok, isFalse);
    // The other writer's record was never this call's to remove.
    expect(File('${tempRoot.path}/active/X/record.json').readAsStringSync(), '{"id":"X"}');
    // And neither was the directory that now holds it, even though this call
    // created it: it is no longer empty, so undoing the create would destroy
    // someone else's data.
    expect(Directory('${tempRoot.path}/active').existsSync(), isTrue);
    // This call's own partial copy is still cleaned up.
    expect(Directory('${tempRoot.path}/active/Y').existsSync(), isFalse);
  });

  test('a foreign entry in an intermediate created directory stops the prune there', () async {
    final src = await makeSource();
    final existing = DirectoryPath('${tempRoot.path}/existing');
    await existing.create(recursive: true);

    // The chain created here is outer/ -> middle/ -> dst/. The foreign entry
    // lands in `middle/`, not in the chain's root, so an implementation that
    // checks emptiness only at the root (and deletes the intermediates on the
    // way up) destroys it.
    fsBackend = _ForeignWriteThenFailBackend(original, failsOnB, () {
      Directory('${tempRoot.path}/existing/outer/middle/foreign').createSync(recursive: true);
      File('${tempRoot.path}/existing/outer/middle/foreign/record.json').writeAsStringSync('{"id":"F"}');
    });

    final ok = await src.copyTreeInto(existing / 'outer' / 'middle' / 'dst');

    expect(ok, isFalse);
    expect(File('${tempRoot.path}/existing/outer/middle/foreign/record.json').readAsStringSync(), '{"id":"F"}');
    expect(Directory('${tempRoot.path}/existing/outer/middle').existsSync(), isTrue);
    // Everything above the surviving directory has to stay too, or the survivor
    // would have nowhere to live.
    expect(Directory('${tempRoot.path}/existing/outer').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/existing/outer/middle/dst').existsSync(), isFalse);
  });

  test('an empty created chain is still removed in full (no orphan left behind)', () async {
    final src = await makeSource();
    // Positive control for the two tests above: with nobody else writing, the
    // whole created chain is this call's own and must still be undone. Without
    // it, "never remove an ancestor" would pass every other case here.
    fsBackend = _ForeignWriteThenFailBackend(original, failsOnB, () {});

    final ok = await src.copyTreeInto(DirectoryPath('${tempRoot.path}/active/Y'));

    expect(ok, isFalse);
    expect(Directory('${tempRoot.path}/active/Y').existsSync(), isFalse);
    expect(Directory('${tempRoot.path}/active').existsSync(), isFalse);
  });

  test('a pre-existing empty parent is not swept up by the prune', () async {
    final src = await makeSource();
    // `active/` predates the copy and is empty, so "delete every empty ancestor"
    // would reach it. It is not part of the created chain, and emptiness is not
    // a licence to delete something this call did not create.
    final active = DirectoryPath('${tempRoot.path}/active');
    await active.create(recursive: true);

    fsBackend = _ForeignWriteThenFailBackend(original, failsOnB, () {});

    final ok = await src.copyTreeInto(active / 'Y');

    expect(ok, isFalse);
    expect(Directory('${tempRoot.path}/active/Y').existsSync(), isFalse);
    expect(Directory('${tempRoot.path}/active').existsSync(), isTrue);
  });

  test('a sibling record that predates the copy survives the failure', () async {
    final src = await makeSource();
    // Negative control: with `active/` already on disk the old cleanup stopped
    // at `active/Y`, so this case passed before the fix too. It has to keep
    // passing — the fix must not have changed behaviour here.
    final active = DirectoryPath('${tempRoot.path}/active');
    await (active / 'X').filePath('record.json').writeAsString('{"id":"X"}');

    fsBackend = _ForeignWriteThenFailBackend(original, failsOnB, () {});

    final ok = await src.copyTreeInto(active / 'Y');

    expect(ok, isFalse);
    expect(File('${tempRoot.path}/active/X/record.json').readAsStringSync(), '{"id":"X"}');
    expect(Directory('${tempRoot.path}/active').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/active/Y').existsSync(), isFalse);
  });
}

/// A web-like backend that runs [onFailure] and then throws when [failWhen]
/// matches a [copyFile] source.
///
/// The callback runs inside the copy, i.e. after `copyTreeInto` took its
/// pre-copy snapshot and before the cleanup runs, which is the interleaving a
/// concurrent publish produces.
class _ForeignWriteThenFailBackend extends WebLikeFsBackend {
  _ForeignWriteThenFailBackend(super.inner, this.failWhen, this.onFailure);

  final bool Function(String source) failWhen;
  final void Function() onFailure;

  @override
  Future<void> copyFile(String source, String destination) async {
    if (failWhen(source)) {
      onFailure();
      throw Exception('injected copy failure for $source');
    }
    return super.copyFile(source, destination);
  }
}
