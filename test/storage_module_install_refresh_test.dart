// The storage view's totals, after a module install replaced the recognizer
// while the view was open.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_module_install_refresh_test.dart
//
// WHY THIS WRITER. `modules/` and `temp/` are siblings of the record root, so the
// record write's declaration cannot answer for them -- `invalidate` drops a
// path's ancestors and descendants, and a sibling is neither. And unlike the
// record mutations, an install does not need a dialog in front of it: the two
// automatic routes are started by the startup version check, so a multi-megabyte
// download and extraction can still be running when the user opens the storage
// manager, leaving the `modules` row describing the module that was just
// replaced.
//
// Asserted at `runModuleInstall`, which is the one seam all four routes replace
// the module through, and at `DirectoryTotalsCache`, which is where a directory's
// recursive size comes from.
//
// WHAT THIS SUITE DOES NOT REACH. It builds no widgets. It does not drive the
// desktop auto-updater's own tail -- the second announcement, made once the
// staged `temp/modules.zip` has been deleted -- because that lives inside
// `moduleVersionLoader`'s body, which every suite overrides and which would
// otherwise download from the network. It does not reach the web routes either:
// `_downloadAndExtractModuleToOpfs` is private and OPFS is not `dart:io`. What is
// asserted here is the seam those routes hand their extraction to.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/module_install_invalidation.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_module_install_refresh');
    final root = DirectoryPath(tempRoot.path);
    layout = PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  void seed(DirectoryPath directory, String name, int bytes) {
    final file = File(directory.filePath(name).path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('x' * bytes);
  }

  ProviderContainer container() {
    final scope = ProviderContainer(
      overrides: [pathInfoProvider.overrideWithValue(layout), pathLayoutLoader.overrideWith((ref) async => layout)],
    );
    addTearDown(scope.dispose);
    return scope;
  }

  test('the module tree loses its cached total when an install lands', () async {
    seed(layout.modulesDir, 'version_info.json', 64);
    final scope = container();
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.modulesDir)).knownBytes, 64);

    await runModuleInstall(scope.read(containerRefProvider), layout, () async {
      // What an extraction does: more bytes under `modules/`, with nothing
      // telling the cache. The cached 64 is what the open view would keep
      // showing.
      seed(layout.modulesDir, 'prediction.onnx', 32);
    }, contention: LongReadContention.defer);

    expect(cache.peek(layout.modulesDir), isNull);
    expect((await cache.totalsOf(layout.modulesDir)).knownBytes, 96);
  });

  // The desktop automatic route stages the published archive in the scratch tree
  // before extracting it, and the scratch tree is a row of the view in its own
  // right. Asserted separately from the module tree: the two are siblings, so
  // naming one says nothing about the other.
  test('the scratch tree loses its cached total too', () async {
    seed(layout.tempDir, 'modules.zip', 128);
    final scope = container();
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.tempDir)).knownBytes, 128);

    await runModuleInstall(scope.read(containerRefProvider), layout, () async {}, contention: LongReadContention.defer);

    expect(cache.peek(layout.tempDir), isNull);
  });

  // An install must not be reported as a change to everything. A fix that cleared
  // the whole cache would satisfy the two cases above and throw away totals
  // nothing falsified -- a re-walk of every record group on the next visit.
  test('a tree the install cannot have touched keeps its cached total', () async {
    seed(layout.charaDetailActiveDir, 'existing.bin', 64);
    final scope = container();
    final cache = scope.read(directoryTotalsCacheProvider);
    await cache.totalsOf(layout.charaDetailDir);

    await runModuleInstall(scope.read(containerRefProvider), layout, () async {}, contention: LongReadContention.defer);

    expect(cache.peek(layout.charaDetailDir)?.knownBytes, 64);
  });

  // An extraction that threw part-way has still written some of the module, and
  // the archive it was refused for was still staged. The numbers on screen
  // describe the tree and not the outcome, so the announcement is in a `finally`.
  test('an extraction that throws re-measures before the error is rethrown', () async {
    seed(layout.modulesDir, 'version_info.json', 64);
    final scope = container();
    final cache = scope.read(directoryTotalsCacheProvider);
    await cache.totalsOf(layout.modulesDir);

    await expectLater(
      runModuleInstall(scope.read(containerRefProvider), layout, () async {
        seed(layout.modulesDir, 'half.onnx', 32);
        throw const FormatException('the archive carries no recognition module');
      }, contention: LongReadContention.defer),
      throwsA(isA<FormatException>()),
    );

    expect(cache.peek(layout.modulesDir), isNull);
  });

  // The guard the announcement carries, at the state it exists for: a manual
  // install's dialog is gone as soon as it dismisses, and an automatic one can be
  // parked behind another job for longer than its container lives. Reading a
  // provider past that throws, and an install that landed must not be turned into
  // an error by the announcement of it.
  test('announcing through a ref that is gone is a no-op, not a throw', () {
    final scope = ProviderContainer(
      overrides: [pathInfoProvider.overrideWithValue(layout), pathLayoutLoader.overrideWith((ref) async => layout)],
    );
    final ref = scope.read(containerRefProvider);
    scope.dispose();

    expect(() => refreshStorageTabAfterModuleInstall(ref, layout), returnsNormally);
  });
}
