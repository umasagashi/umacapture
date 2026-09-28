// The registry of long-running readers, and the two folds the delete surfaces
// ask it (stage 1 of replacing the per-operation zip gates).
//
// **What these cases are and are not.** They are the registry's own algebra —
// what a claim puts on it, what a release takes off, and that the two delete
// predicates quantify over *every* hold of *every* claim rather than over the
// first one. The wiring from those answers to a real button is asserted by
// `storage_extraction_delete_gate_test.dart` and
// `record_delete_extraction_gate_test.dart`, which drive the actual widgets and
// which this change deliberately left untouched: they were green before the
// registry existed and are green after it, which is what says the swap moved no
// behaviour.
//
// Not covered here, and stated so it is not mistaken for covered:
//  * The web leg. The registry is platform-agnostic Dart with no branch in it,
//    but a long read a web worker performs under the same lock is invisible to
//    it — see the library doc for why that gap is the lock's to close and not
//    this one's.
//  * What either registered operation actually does. The zip's own wiring is
//    `storage_zip_export_test.dart`'s and the archive's is
//    `archive_long_read_claim_test.dart`'s; the cases below construct claims
//    directly, which is how arrangements no pair of operations can produce yet
//    (two claims of one kind, a batch of several holds) can be asked about at
//    all.
//
// Two of the groups below are about a claim's *lifetime* rather than its
// algebra, and they are here rather than in a widget suite because that is where
// the rule lives: `hold` owns the release, and the case that scans `lib/` is what
// keeps the unscoped pair from spreading past the one claimant that needs it.
import 'dart:async';
import 'dart:io';

// `analyzer` reaches this package transitively; see `support/source_syntax.dart` for why it is not a
// direct dependency.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/source_syntax.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

ProviderContainer _container() {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  return container;
}

LongReadRegistry _registry(ProviderContainer container) => container.read(longReadRegistryProvider.notifier);

/// A claim built by hand, so the folds can be asked about arrangements no
/// operation can produce yet (two claims at once, a batch of several holds).
LongReadClaim _claimOf(List<DirectoryPath> paths, {LongReadKind kind = LongReadKind.zip}) =>
    (kind: kind, holds: <StorageHold>[for (final path in paths) (directoryPath: path.path, fraction: 0)]);

/// What the app calls [kind], for the check that no withheld-delete sentence
/// names one.
///
/// The enum drives the loop, and this `switch` has no default, so a third long
/// reader cannot arrive with an empty vocabulary: adding a member stops the file
/// compiling until somebody writes down what the UI calls it. That naming is the
/// only part of the check a machine cannot derive — nothing in the code knows
/// that the app spells [LongReadKind.archive] 「殿堂入り」 — and `kind.name` is
/// folded in so the identifier itself is always covered without being repeated.
List<String> _namesOf(LongReadKind kind) => [
  kind.name,
  ...switch (kind) {
    LongReadKind.zip => const ['ZIP'],
    LongReadKind.archive => const ['殿堂入り', 'アーカイブ'],
    LongReadKind.export => const ['エクスポート', '書き出し', '取り出し'],
    LongReadKind.scan => const ['スキャン', '読み込み', '読み取り', '走査'],
    LongReadKind.repair => const ['修復', 'ジオメトリ'],
    LongReadKind.relocate => const ['移設', '移行'],
    LongReadKind.recover => const ['復旧', '回復'],
    LongReadKind.inherit => const ['継承'],
    LongReadKind.regeneration => const ['再認識'],
    LongReadKind.moduleInstall => const ['モジュール', 'module'],
    LongReadKind.import => const ['取り込み', 'インポート'],
    LongReadKind.videoImport => const ['動画', 'クリップ'],
    LongReadKind.liveCapture => const ['キャプチャ', '録画', '画面'],
    LongReadKind.merge => const ['統合', 'マージ'],
    LongReadKind.delete => const ['削除'],
  },
];

/// Which long reader [sentence] names, or `null` if it names none of them.
///
/// **The longest match wins, not the first member in declaration order**, because two members'
/// vocabularies can nest: `videoImport` contains `import`, so a first-match walk answered
/// `LongReadKind.import` for a sentence naming the video one — an answer that depends on which of
/// the two was declared first, which is not a fact about the sentence. Ties keep declaration order,
/// which only decides between two words of the same length.
LongReadKind? _holderNamedBy(String sentence) {
  final haystack = sentence.toLowerCase();
  LongReadKind? best;
  var bestLength = 0;
  for (final kind in LongReadKind.values) {
    for (final name in _namesOf(kind)) {
      if (name.length > bestLength && haystack.contains(name.toLowerCase())) {
        best = kind;
        bestLength = name.length;
      }
    }
  }
  return best;
}

/// Every Dart file under `lib/`, parsed once for all the cases that read it.
///
/// A top-level `final` is initialised on first read, so the cases that never look at `lib/` do not pay
/// for the parse.
final List<ParsedSource> _lib = parseDartTree('lib');

/// [_lib], once it is established that the parser read every file of it.
///
/// The scan below reports an absence — no unsanctioned claim — and a file the parser had to recover
/// from is a tree with statements missing, which can produce it by having dropped the statement that held
/// the finding. `lib/` compiles, so
/// this fails only if the parser and the compiler have come to disagree about the language.
List<ParsedSource> _libParsed() {
  expect(_lib, isNotEmpty, reason: 'no Dart file under lib/; the scans are not running from the package root');
  expect(
    [
      for (final source in _lib)
        if (source.diagnostics.isNotEmpty) '${source.path}: ${source.diagnostics.first.message}',
    ],
    isEmpty,
    reason: 'the parser could not read these files, so a finding in them would be missing rather than reported',
  );
  return _lib;
}

/// [content] parsed as the file at [path], for an instrument control.
///
/// Parsed cleanly or not at all: a probe the parser had to recover would be testing the recovery
/// rather than the rule it was written to exercise.
ParsedSource _probe(String path, String content) {
  final source = ParsedSource.parse(content, path: path);
  expect(source.diagnostics, isEmpty, reason: 'the probe $path does not parse, so it controls nothing');
  return source;
}

/// How many times each declaration in [source] refers to [name] — a call or a tear-off — keyed by
/// [enclosingDeclarationName].
Map<String, int> _referencesByDeclaration(ParsedSource source, String name) {
  final counts = <String, int>{};
  for (final reference in referencesIn(source.unit)) {
    if (reference.name != name) {
      continue;
    }
    final at = enclosingDeclarationName(reference.node) ?? '<outside any declaration>';
    counts[at] = (counts[at] ?? 0) + 1;
  }
  return counts;
}

/// The ways to take a claim that somebody has to release by hand, read off `LongReadRegistry`'s
/// declaration rather than listed here: every public instance method that answers a `LongReadToken`.
///
/// The token is the release handle, so a method that hands one back is a claim whose release is the
/// caller's to remember. A list would miss the next such method, and a scan counting only the names on
/// it would answer "nothing found" about a hand-written claim spelt with the new name.
Set<String> _handReleasedClaimsOf(ParsedSource registrySource) {
  final registry = topLevelDeclaration<ClassDeclaration>(registrySource.unit, 'LongReadRegistry');
  if (registry == null) {
    return const {};
  }
  return {
    for (final method in registry.members.whereType<MethodDeclaration>())
      if (!method.isStatic && !method.name.lexeme.startsWith('_') && method.returnType?.toSource() == 'LongReadToken')
        method.name.lexeme,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_long_read_registry');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  group('the registry', () {
    test('a claim puts every path it names on the registry, at zero', () {
      final container = _container();
      final a = _activeDir / 'a';
      final b = _activeDir / 'b';

      final token = _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: [a, b]);

      final claims = container.read(longReadRegistryProvider);
      expect(claims, hasLength(1));
      expect(claims[token]?.kind, LongReadKind.zip);
      expect(claims[token]?.holds, [(directoryPath: a.path, fraction: 0.0), (directoryPath: b.path, fraction: 0.0)]);
    });

    test('release takes the claim off, and a second release is not an error', () {
      final container = _container();
      final token = _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: [_activeDir / 'a']);

      _registry(container).release(token);
      expect(container.read(longReadRegistryProvider), isEmpty);

      // A `finally` that runs twice, or a late isolate message, must not be able
      // to drop somebody else's entry.
      _registry(container).release(token);
      expect(container.read(longReadRegistryProvider), isEmpty);
    });

    test('a claim cannot outlive the element it is stored in', () {
      // This is the whole reason `release` may return early once its `Ref` is
      // unmounted: the claim is not registered *somewhere else* that would go on
      // holding it, it is this element's own state. Asserted rather than argued,
      // because "skipping the release leaks the claim" and "skipping it cannot
      // leak anything" look identical from the call site and differ only here.
      final container = _container();
      _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: [_activeDir / 'a']);
      expect(container.read(longReadRegistryProvider), hasLength(1));

      container.invalidate(longReadRegistryProvider);

      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'a claim that survived its element would be one no token could ever reach again',
      );
    });

    test('two claims are held at once, and releasing one leaves the other standing', () {
      final container = _container();
      final first = _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: [_activeDir / 'a']);
      final second = _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: [_activeDir / 'b']);
      expect(container.read(longReadRegistryProvider), hasLength(2));
      expect(first, isNot(same(second)), reason: 'two claims over distinct work are two entries');

      _registry(container).release(first);

      final remaining = container.read(longReadRegistryProvider);
      expect(remaining.keys, [second]);
      expect(remaining[second]?.holds.single.directoryPath, (_activeDir / 'b').path);
    });

    test('report advances every hold of its claim, clamped, and is dropped once released', () {
      final container = _container();
      final a = _activeDir / 'a';
      final b = _activeDir / 'b';
      final token = _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: [a, b]);

      _registry(container).report(token, 0.4);
      expect(container.read(longReadRegistryProvider)[token]?.holds.map((hold) => hold.fraction), [0.4, 0.4]);

      _registry(container).report(token, 5);
      expect(container.read(longReadRegistryProvider)[token]?.holds.map((hold) => hold.fraction), [1.0, 1.0]);

      _registry(container).release(token);
      _registry(container).report(token, 0.9);
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'a late report must not resurrect a claim');
    });
  });

  group('a scoped hold', () {
    test('releases its claim when the action returns, and answers what the action answered', () async {
      final container = _container();
      final a = _activeDir / 'a';

      final answer = await _registry(container).hold(
        kind: LongReadKind.zip,
        paths: [a],
        action: (token) async {
          expect(container.read(longReadRegistryProvider)[token]?.holds.single.directoryPath, a.path);
          return 'bundled';
        },
      );

      expect(answer, 'bundled');
      expect(container.read(longReadRegistryProvider), isEmpty);
    });

    test('releases its claim when the action throws, and the error still reaches the caller', () async {
      final container = _container();

      await expectLater(
        _registry(container).hold(
          kind: LongReadKind.zip,
          paths: [_activeDir / 'a'],
          action: (_) async => throw StateError('the run blew up'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'the release is the registry\'s finally, so the publisher has none of its own to forget',
      );
    });

    test('releases without throwing when the container goes away under it', () async {
      // The window is real and not hypothetical: `CharaArchiveController.archive`
      // is started from a dialog without being awaited, so an app shutdown or a
      // test teardown lands here while the action is still suspended. Anything
      // this `finally` throws is an uncaught asynchronous error with no caller to
      // meet it — a Sentry event for a shutdown that went exactly as it should.
      final container = _container();
      final until = Completer<void>();
      final held = _registry(
        container,
      ).hold(kind: LongReadKind.archive, paths: [_activeDir / 'a'], action: (_) => until.future);

      container.dispose();
      until.complete();

      await expectLater(held, completes, reason: 'the release ran against a disposed element and threw');
    });

    test('is the only way lib holds paths, apart from sanctioned members', () {
      // A claim nobody releases blocks its paths for the rest of the session with
      // nothing to notice it, so the unscoped half of the protocol is not left to
      // a reading of the doc: a member in `lib/` reaching for it uninvited turns
      // this red.
      //
      // **The permission is a member, not a file.** Spelt as a file, `storage.dart`
      // — the largest file in `lib/` — would be a licence for a second hand-written
      // claim anywhere in it. Spelt per member and per method, a claim written into
      // any other member of a sanctioned file is a finding.
      //
      // **Every hand-released claim method is looked for, not one name.** The
      // methods are read off `LongReadRegistry` (every public one answering a
      // `LongReadToken`), so a claim written with whatever method comes next is
      // found exactly as a `claimUntilReleased` is.
      //
      // What is looked for is every reference to the name in code — a call, and a
      // tear-off, which is the same claim with the call moved somewhere this scan
      // cannot follow — read off the syntax tree, so a doc line naming it is not
      // one and a call the formatter wrapped still is.
      //
      // Only one direction is asserted: a sanctioned member that stops claiming is
      // a legitimate edit and not a finding, so it does not turn this red.
      const sanctioned = {
        // The one call inside `hold` -- the `finally` every other long reader
        // borrows instead of writing its own release -- and the one inside
        // `claimUntilReleasedWhenFree`, which asks and then registers exactly
        // as `claimUntilReleased` does. (A definition declares its name and
        // does not refer to it.)
        'lib/src/core/storage/long_read_registry.dart': {
          'LongReadRegistry.hold: claimUntilReleased',
          'LongReadRegistry.claimUntilReleasedWhenFree: claimUntilReleased',
        },
        // `StorageZipProgress.begin`, and `StorageZipProgress.reclaimAfterDialog`
        // which retakes the same claim after `releaseForDialog` gave the folder
        // back for the length of a save dialog. One claim whose lifetime is the
        // notifier's, driven by `begin` … `report` … `finish` from the zip's
        // screen furniture, and reopened once in the middle of that run — which
        // is why it is two hand-written claims and not a `hold`: neither end of
        // either stretch is on the starter's stack.
        // The retake asks first, in the same call, because somebody may have
        // claimed the folder while the dialog stood open.
        'lib/src/core/storage/zip_export.dart': {
          'StorageZipProgress.begin: claimUntilReleased',
          'StorageZipProgress.reclaimAfterDialog: claimUntilReleasedWhenFree',
        },
        // `CharaDetailRecordRegenerationController.start`: a batch whose end is a
        // state transition reached from a native callback and from a timer,
        // neither of them on the starter's stack. It asks in the same call,
        // which is also what refuses a start while a batch is running.
        'lib/src/chara_detail/storage.dart': {
          'CharaDetailRecordRegenerationController.start: claimUntilReleasedWhenFree',
        },
        // `listenLiveCaptureLongRead`: a live capture session, whose two edges are
        // both the core's. A session begins and ends with a `captureTriggered`
        // event and nothing in Dart is on the stack in between, so there is no
        // block to put a `hold` around -- the same situation the two above are in.
        'lib/src/gui/capture.dart': {'listenLiveCaptureLongRead: claimUntilReleased'},
      };

      // The instrument's control, on a synthetic source: a doc reference and a
      // string are not claims, a call the formatter broke before the dot and a
      // tear-off are, and each is charged to the member it is written in.
      expect(
        _referencesByDeclaration(
          _probe(
            'probe/claims.dart',
            'class Probe {\n'
                '  /// Takes a [LongReadRegistry.claimUntilReleased] claim.\n'
                '  void wrapped(LongReadRegistry registry) {\n'
                '    logger.i("claimUntilReleased(");\n'
                '    registry\n'
                '        .claimUntilReleased(kind: LongReadKind.zip, paths: const []);\n'
                '  }\n'
                '\n'
                '  Object torn(LongReadRegistry registry) => registry.claimUntilReleased;\n'
                '}\n',
          ),
          'claimUntilReleased',
        ),
        {'Probe.wrapped': 1, 'Probe.torn': 1},
        reason:
            'the scan counts a comment or a string as a claim, misses a wrapped call or a tear-off, or charges '
            'a claim to the wrong member — so what it reads out of lib/ is not the set of claims either',
      );

      // The method list's control: a method answering the token is read, one answering anything else is
      // not, and a private one is the registry's own business.
      expect(
        _handReleasedClaimsOf(
          _probe(
            'probe/registry.dart',
            'class LongReadRegistry {\n'
                '  LongReadToken first() => LongReadToken();\n'
                '  LongReadToken second({required int x}) => first();\n'
                '  LongReadKind? heldBy() => null;\n'
                '  LongReadToken _private() => first();\n'
                '}\n',
          ),
        ),
        {'first', 'second'},
        reason:
            'the method reader cannot tell a token-answering method from another, so the names it reads '
            'out of the registry are not the set of hand-released claims either',
      );

      final lib = _libParsed();
      final registry = lib.where((source) => source.path == 'lib/src/core/storage/long_read_registry.dart').first;
      final names = _handReleasedClaimsOf(registry);
      expect(
        names,
        isNotEmpty,
        reason: 'the registry no longer declares a method answering a LongReadToken, or the reader lost them',
      );

      final found = <String>[];
      final unsanctioned = <String>[];
      for (final source in lib) {
        for (final name in names) {
          for (final member in _referencesByDeclaration(source, name).keys) {
            final site = '$member: $name';
            found.add('${source.path}: $site');
            if (!(sanctioned[source.path]?.contains(site) ?? false)) {
              unsanctioned.add('${source.path}: $site');
            }
          }
        }
      }

      expect(
        found,
        isNotEmpty,
        reason: 'the scan found no hand-written claim anywhere in lib, so it is reading nothing',
      );
      expect(
        unsanctioned,
        isEmpty,
        reason:
            'a long reader whose work is one Future must use LongReadRegistry.hold; '
            'claiming by hand is only for a claim whose lifetime is an object\'s, as StorageZipProgress\'s is',
      );
    });
  });

  group('asking and claiming in one turn', () {
    // The rule [LongReadRegistry.holdWhenFree] states for a scoped hold, in its two other shapes. What each
    // case asserts is that the registration is on the registry by the time the call returns, with no
    // `await` between: a writer that asks and then claims across a turn can be overtaken by a claim that
    // arrives in the gap, and the ask has then answered a question about a registry that no longer exists.
    test('a hand-released claim over free paths is on the registry when the call returns', () {
      final container = _container();
      final a = _activeDir / 'a';

      final token = _registry(container).claimUntilReleasedWhenFree(kind: LongReadKind.zip, paths: [a]);

      final claim = container.read(longReadRegistryProvider)[token];
      expect(claim?.kind, LongReadKind.zip, reason: 'the call returned a token the registry does not hold');
      expect(claim?.holds.map((hold) => hold.directoryPath), [a.path]);

      _registry(container).release(token);
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the token does not release the claim');
    });

    test('a hand-released claim over held paths is refused in the call, and registers nothing', () {
      final container = _container();
      final a = _activeDir / 'a';
      final holder = _registry(container).claimUntilReleased(kind: LongReadKind.archive, paths: [_activeDir]);
      final before = container.read(longReadRegistryProvider);

      expect(
        () => _registry(container).claimUntilReleasedWhenFree(kind: LongReadKind.zip, paths: [a]),
        throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.archive)),
        reason: 'a claim was taken over a folder another long reader holds',
      );
      expect(container.read(longReadRegistryProvider), same(before), reason: 'the refusal registered something');

      // The control: a path the holder does not cover is claimed, so the refusal above was about the paths.
      final elsewhere = _registry(
        container,
      ).claimUntilReleasedWhenFree(kind: LongReadKind.zip, paths: [_layout.downloadDir / 'other']);
      expect(container.read(longReadRegistryProvider).keys, unorderedEquals([holder, elsewhere]));
    });

    test('a disregarded kind does not stop a writer, and another kind on the same path still does', () async {
      final container = _container();
      final registry = _registry(container);
      final a = _activeDir / 'a';
      const disregarding = {LongReadKind.liveCapture};
      final capture = registry.claimUntilReleased(kind: LongReadKind.liveCapture, paths: [a]);

      expect(registry.heldBy([a], disregarding: disregarding), isNull);
      expect(registry.heldBy([a]), LongReadKind.liveCapture, reason: 'the default must still see every kind');
      final claimed = registry.claimUntilReleasedWhenFree(
        kind: LongReadKind.zip,
        paths: [a],
        disregarding: disregarding,
      );
      registry.release(claimed);
      expect(
        await registry.holdWhenFree(
          kind: LongReadKind.delete,
          paths: [a],
          contention: LongReadContention.refuse,
          disregarding: disregarding,
          action: (_) async => 'ran',
        ),
        'ran',
      );

      // The same path held by a kind outside the set is still an answer, on all three.
      final zip = registry.claimUntilReleased(kind: LongReadKind.zip, paths: [a]);
      expect(registry.heldBy([a], disregarding: disregarding), LongReadKind.zip);
      expect(
        () => registry.claimUntilReleasedWhenFree(kind: LongReadKind.archive, paths: [a], disregarding: disregarding),
        throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.zip)),
      );
      await expectLater(
        registry.holdWhenFree(
          kind: LongReadKind.delete,
          paths: [a],
          contention: LongReadContention.refuse,
          disregarding: disregarding,
          action: (_) async => 'ran',
        ),
        throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.zip)),
      );
      expect(container.read(longReadRegistryProvider).keys, unorderedEquals([capture, zip]));
    });

    test('a declaration that asks registers in the turn runDeclared is called, before its action runs', () async {
      final container = _container();
      final a = _activeDir / 'a';
      final declaration = LongReadDeclaration.claimWhenFree(
        registry: _registry(container),
        kind: LongReadKind.zip,
        paths: [a],
        contention: LongReadContention.refuse,
      );
      final until = Completer<void>();
      var began = false;

      final run = declaration.runDeclared(() async {
        began = true;
        await until.future;
        return 'done';
      });

      // Not awaited: the claim has to be there already, in the caller's own turn.
      expect(
        container.read(longReadRegistryProvider).values.map((claim) => claim.kind),
        [LongReadKind.zip],
        reason: 'the declaration had not registered by the time runDeclared returned',
      );
      expect(began, isTrue);
      until.complete();
      expect(await run, 'done');
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the claim outlived the region');
    });

    test(
      'a declaration that asks over held paths does not run its action, and a throwing action is released',
      () async {
        final container = _container();
        final registry = _registry(container);
        final a = _activeDir / 'a';
        LongReadDeclaration declaration() => LongReadDeclaration.claimWhenFree(
          registry: registry,
          kind: LongReadKind.zip,
          paths: [a],
          contention: LongReadContention.refuse,
        );
        final holder = registry.claimUntilReleased(kind: LongReadKind.delete, paths: [a]);
        var ran = false;

        await expectLater(
          declaration().runDeclared(() async => ran = true),
          throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.delete)),
        );
        expect(ran, isFalse, reason: 'the guarded action ran over a claim the declaration was told to refuse');
        expect(container.read(longReadRegistryProvider).keys, [holder]);

        registry.release(holder);
        await expectLater(
          declaration().runDeclared<void>(() async => throw StateError('the run blew up')),
          throwsA(isA<StateError>()),
        );
        expect(container.read(longReadRegistryProvider), isEmpty, reason: 'a throwing action left its claim behind');
      },
    );
  });

  group('a declaration that announces nothing', () {
    // The guard makes writing a declaration mandatory; it did not make *saying
    // something* mandatory, and `reason: ''` passed analysis. That is the same
    // failure the required argument exists to prevent — a decision nobody
    // recorded, indistinguishable from an oversight — arriving through the
    // argument rather than around it. The reason a machine cannot judge is
    // whether the sentence explains anything; that a sentence was written is
    // decidable, and is what these two cases hold.
    test('will not be constructed with an empty reason', () {
      // Not `const`: the same expression written `const` is rejected by the
      // analyzer instead, which is the stronger half of this and the half a test
      // cannot execute. `test/../lib` has no const site with an empty reason for
      // exactly that reason.
      expect(
        () => LongReadDeclaration.none(reason: ''),
        throwsA(isA<AssertionError>()),
        reason: 'an empty reason records nothing, and the constructor accepted it',
      );
    });

    test('will not run a guarded action behind a blank reason', () async {
      var ran = false;
      Future<int> action() async {
        ran = true;
        return 1;
      }

      // Whitespace is what the constructor's assert cannot reach: a const
      // constructor's assert must be a potentially-constant expression and
      // `trim()` is not one, so this half is checked where the declaration is
      // used instead.
      await expectLater(
        () => const LongReadDeclaration.none(reason: '   ').runDeclared(action),
        throwsA(isA<AssertionError>()),
        reason: 'a reason of spaces is a reason nobody wrote, and it was trusted anyway',
      );
      expect(ran, isFalse, reason: 'the action ran before the declaration was found to be blank');

      // The control: the same call with a reason behaves exactly as before.
      expect(await const LongReadDeclaration.none(reason: 'nothing to announce').runDeclared(action), 1);
      expect(ran, isTrue);
    });
  });

  group('the identity of a token', () {
    test('two claims over the same paths are two entries, and one release leaves the other holding', () async {
      final container = _container();
      final shared = _activeDir / 'a';
      final tokens = <LongReadToken>[];

      Future<void> read(Completer<void> until) => _registry(container).hold(
        kind: LongReadKind.zip,
        paths: [shared],
        action: (token) async {
          tokens.add(token);
          await until.future;
        },
      );

      // Both claims are on before either awaits anything: `hold` registers
      // before its first suspension, which is what the zip's single-flight guard
      // depends on too.
      final firstDone = Completer<void>();
      final secondDone = Completer<void>();
      final first = read(firstDone);
      final second = read(secondDone);

      expect(tokens, hasLength(2));
      expect(tokens.first, isNot(same(tokens.last)), reason: 'the token is an identity, not a value');
      expect(
        container.read(longReadRegistryProvider),
        hasLength(2),
        reason: 'a value key would merge two simultaneous claims over the same paths into one entry',
      );

      firstDone.complete();
      await first;

      final remaining = container.read(longReadRegistryProvider);
      expect(remaining.keys.single, same(tokens.last), reason: 'the one that finished released its own entry only');
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([shared]), remaining.values),
        LongReadKind.zip,
        reason:
            'merged, the first to finish would release both and the delete would come back live '
            'while the second reader still had the handles open',
      );

      secondDone.complete();
      await second;
      expect(container.read(longReadRegistryProvider), isEmpty);
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([shared]), const []), isNull);
    });
  });

  group('the zip projection', () {
    test('is null while nothing is claimed, and again once the claim is released', () {
      final container = _container();
      expect(container.read(storageZipProgressProvider), isNull);

      final progress = container.read(storageZipProgressProvider.notifier);
      expect(progress.begin(_activeDir / 'a'), isTrue);
      expect(container.read(storageZipProgressProvider), (directoryPath: (_activeDir / 'a').path, fraction: 0.0));

      progress.finish();
      expect(container.read(storageZipProgressProvider), isNull);
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'finish releases, it does not merely hide');
    });

    test('holdsKind keeps the zip single-flight, synchronously and across directories', () {
      final container = _container();
      final progress = container.read(storageZipProgressProvider.notifier);

      // No pump, no await between the two calls: the guard has to be decided
      // off the registry rather than off a value that is recomputed later.
      expect(progress.begin(_activeDir / 'a'), isTrue);
      expect(progress.begin(_activeDir / 'b'), isFalse, reason: 'one archive at a time, whichever folder');
      expect(_registry(container).holdsKind(LongReadKind.zip), isTrue);
      expect(container.read(longReadRegistryProvider), hasLength(1));

      progress.finish();
      expect(_registry(container).holdsKind(LongReadKind.zip), isFalse);
      expect(progress.begin(_activeDir / 'b'), isTrue, reason: 'the slot is free again');
    });

    test('answers null rather than throwing when its claim holds nothing yet', () {
      final container = _container();
      _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: []);

      expect(
        () => container.read(storageZipProgressProvider),
        returnsNormally,
        reason: 'a zero-hold claim of this kind has to answer something, not throw a ProviderException',
      );
      expect(container.read(storageZipProgressProvider), isNull);
    });

    test('answers the first hold rather than throwing when its claim holds more than one', () {
      final container = _container();
      final a = _activeDir / 'a';
      final b = _activeDir / 'b';
      _registry(container).claimUntilReleased(kind: LongReadKind.zip, paths: [a, b]);

      expect(
        () => container.read(storageZipProgressProvider),
        returnsNormally,
        reason: 'a batch claim of this kind has to answer something, not throw a ProviderException',
      );
      expect(container.read(storageZipProgressProvider), (directoryPath: a.path, fraction: 0.0));
    });

    test('its late calls are no-ops once the container is gone, rather than throws', () {
      // The unscoped half of the protocol has no registry `finally` behind it:
      // the release is pinned to `exportDirectoryAsZip`'s own, which runs on a
      // shutdown too, and both of these reach through *this* notifier's `Ref`
      // before the registry's own guard is ever consulted.
      final container = _container();
      final progress = container.read(storageZipProgressProvider.notifier);
      expect(progress.begin(_activeDir / 'a'), isTrue);

      container.dispose();

      expect(() {
        progress.report(0.5);
        progress.finish();
      }, returnsNormally);
    });

    test('report moves the projected fraction forward and never backward', () {
      final container = _container();
      final progress = container.read(storageZipProgressProvider.notifier);
      expect(progress.begin(_activeDir / 'a'), isTrue);

      progress.report(0.5);
      expect(container.read(storageZipProgressProvider)?.fraction, 0.5);

      progress.report(0.2);
      expect(container.read(storageZipProgressProvider)?.fraction, 0.5, reason: 'a bar that retreats is a defect');

      progress.report(0.75);
      expect(container.read(storageZipProgressProvider)?.fraction, 0.75);
    });
  });

  group('the folds', () {
    test('either surface is blocked when any one hold of any one claim covers it', () {
      final covered = _activeDir / 'a';
      final free = _activeDir / 'c';
      // The covering hold is neither the first claim nor the first hold of its
      // claim: a fold that looked only at the head would answer "not blocked".
      final claims = [
        _claimOf([_activeDir / 'x']),
        _claimOf([_activeDir / 'y', covered]),
      ];

      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([covered]), claims), LongReadKind.zip);
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([free]), claims), isNull);
      expect(storageDeleteBlockedBy(null, claims), isNull, reason: 'a row with no delete has nothing to withhold');
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([covered]), const []), isNull);

      LongReadKind? recordBlocked(List<String> ids) =>
          recordDeleteBlockedBy(pathInfo: _layout, source: RecordSource.active, recordIds: ids, claims: claims);

      expect(recordBlocked(['a']), LongReadKind.zip);
      expect(recordBlocked(['c', 'a']), LongReadKind.zip, reason: 'one covered record withholds the whole batch');
      expect(recordBlocked(['c']), isNull);
      expect(recordBlocked(const []), isNull);
    });
  });

  // The sentence a withheld control shows names no kind of holder — not the zip,
  // not the archive. With every other assertion in the repository written as
  // `appSentenceAt('<key>')`, nothing else holds that: putting 「ZIP」 back into
  // it would leave the rest of the suite green.
  //
  // There is **one** such sentence, `app.long_read_busy`, so that a newly
  // withheld surface costs no translation entry. This group is where that one sentence is
  // held to its requirements, because the sentence belongs to the registry rather
  // than to any of the screens that show it.
  //
  // What is asserted is the *invariant*, not the wording. The shipped text is free
  // to be re-edited, translated or shortened; what it may not do is stop giving
  // the reason, promise something that never happened, or name a particular
  // holder again — the last because the holder it names is right for one kind of
  // long reader and a lie for every other one, and the sentence is chosen long
  // before anybody knows which kind is holding.
  group('the sentence a withheld control shows', () {
    test('it resolves, and it is the one every surface reads', () {
      // `.tr()` renders a key it cannot resolve *as the key*, so a deleted or
      // renamed entry would make every assertion below a check on a raw key.
      // `appSentenceAt` reads `ja.json` and throws instead.
      expect(longReadBusyMessage(), appSentenceAt(longReadBusyKey));
      expect(longReadBusyMessage(), isNot(contains(longReadBusyKey)));
      expect(longReadBusyMessage(), isNotEmpty);
      expect(longReadBusyMessage(), isNot(contains('{')));
    });

    test('it gives the reason, and promises nothing that has not happened', () {
      // Not a full-text comparison — that would freeze the wording against every
      // deliberate edit. These are the words the sentence exists to carry.
      final sentence = longReadBusyMessage();
      // Why the control is dead. Without this the user is left with a grey button
      // and no idea that waiting is what fixes it.
      expect(sentence, contains('使用中'), reason: 'the reason is what makes waiting the obvious response');
      // Nothing was pressed: the control is inert before the first tap, or goes
      // inert while the dialog is open. A past tense or a retry would be
      // describing an attempt that was never made — which is exactly how the
      // *toasts* that follow a real attempt are phrased, and why they may not be
      // reused here.
      expect(sentence, isNot(contains('もう一度')));
      expect(sentence, isNot(contains('できませんでした')));
      // No registered long reader has a stop; each runs to completion and
      // releases itself. Telling the user to stop one is worse than saying
      // nothing, which is what separates this sentence from
      // `pages.storage.blocked.template`.
      expect(sentence, isNot(contains('止めて')));
    });

    test('it names no long reader in particular', () {
      // The check first: a vocabulary that matched nothing would agree with any
      // sentence at all, including the ones this case exists to reject. Driven
      // off `LongReadKind.values`, so a kind whose words were forgotten fails
      // here instead of being quietly skipped.
      for (final kind in LongReadKind.values) {
        for (final name in _namesOf(kind)) {
          expect(
            _holderNamedBy('この処理は$nameを使用中です。'),
            kind,
            reason: '"$name" has to be recognised as naming ${kind.name}, or nothing below is being checked',
          );
        }
      }

      expect(
        _holderNamedBy(longReadBusyMessage()),
        isNull,
        reason:
            '$longReadBusyKey names a specific long reader again; it is shown for whichever kind holds the path, '
            'so naming one makes it wrong for every other kind — the enumeration this registry exists to delete',
      );
    });

    // A press whose claim is refused at the moment its work would start is told
    // the same sentence as a withheld control, once; one whose registry went away
    // is told nothing, because nobody is left to read it.
    Future<List<ToastData>> toastsOf(LongReadNotStartedException exception) async {
      final container = _container();
      final toasts = <ToastData>[];
      final subscription = container.listen<AsyncValue<ToastData>>(
        plainToastEventProvider,
        (_, current) => current.whenData(toasts.add),
      );
      addTearDown(subscription.close);
      // Subscribe before announcing: the toast stream is broadcast, so an event
      // added before the provider listens is lost rather than delivered late.
      await pumpEventQueue();
      announceLongReadNotStarted(exception, operation: 'A test press');
      await pumpEventQueue();
      return toasts;
    }

    test('a refused press is told the busy sentence once', () async {
      final toasts = await toastsOf(const LongReadNotStartedException.busy(LongReadKind.regeneration));
      expect(
        toasts.map((toast) => (toast.type, toast.description)),
        [(ToastType.error, appSentenceAt(longReadBusyKey))],
        reason: 'a refused press has to say why nothing happened, once, in the sentence a withheld control shows',
      );
    });

    test('an abandoned press is told nothing', () async {
      final toasts = await toastsOf(const LongReadNotStartedException.abandoned());
      expect(toasts, isEmpty, reason: 'the container the toast would speak through is the one that went away');
    });
  });

  // A claim's kind is read in three places, and each of them decides something.
  // With one registered member every one of these passed whether or not the kind
  // was consulted at all; a second member is what makes them separable, so there
  // is one case per reading and each fails on its own.
  group('the kind of a claim', () {
    test('holdsKind answers about the kind it was asked for, not about the registry being non-empty', () {
      final container = _container();
      _registry(container).claimUntilReleased(kind: LongReadKind.archive, paths: [_activeDir / 'a']);

      expect(_registry(container).holdsKind(LongReadKind.archive), isTrue);
      expect(_registry(container).holdsKind(LongReadKind.zip), isFalse);
      // The consequence, at the one production reading that depends on it: the
      // zip's "one archive at a time" is a rule about zips. An archive that
      // consumed the slot would refuse the bundle button for a reason the user
      // cannot see and the tooltip does not give.
      expect(
        container.read(storageZipProgressProvider.notifier).begin(_activeDir / 'b'),
        isTrue,
        reason: 'an archive is not a zip and must not take the zip slot',
      );
    });

    test('the zip projection skips a claim of another kind', () {
      final container = _container();
      final a = _activeDir / 'a';
      _registry(container).claimUntilReleased(kind: LongReadKind.archive, paths: [a, _activeDir / 'b']);

      expect(
        container.read(storageZipProgressProvider),
        isNull,
        reason:
            'the archive is the first operation to register a multi-hold claim, so a projection that took the '
            'first hold of any claim would render its progress ring for a job the user never started',
      );
    });

    test('a fold answers the kind of the claim that covers the request, not the first one it was given', () {
      final covered = _activeDir / 'a';
      // The covering claim is deliberately second and of the other kind: an
      // answer taken from `claims.first`, or a constant, agrees with the real one
      // in every arrangement but this.
      final archiveCovers = [
        _claimOf([_activeDir / 'x']),
        _claimOf([covered], kind: LongReadKind.archive),
      ];
      final zipCovers = [
        _claimOf([_activeDir / 'x'], kind: LongReadKind.archive),
        _claimOf([covered]),
      ];

      LongReadKind? storageBlocked(List<LongReadClaim> claims) =>
          storageDeleteBlockedBy(StorageDeletePathsRequest([covered]), claims);
      LongReadKind? recordBlocked(List<LongReadClaim> claims) =>
          recordDeleteBlockedBy(pathInfo: _layout, source: RecordSource.active, recordIds: const ['a'], claims: claims);

      expect(storageBlocked(archiveCovers), LongReadKind.archive);
      expect(recordBlocked(archiveCovers), LongReadKind.archive);
      // The control that stops "always answer archive" from passing.
      expect(storageBlocked(zipCovers), LongReadKind.zip);
      expect(recordBlocked(zipCovers), LongReadKind.zip);
    });
  });
}
