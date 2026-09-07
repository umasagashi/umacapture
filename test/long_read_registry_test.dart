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
//    but a claim held in another browser tab is invisible to it — see the
//    library doc for why that gap is the lock's to close and not this one's.
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';

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

/// Matches an extension declared directly on `RecordMutationLock` anywhere in
/// its header, up to the brace that opens the extension body.
///
/// This is the one shape that can call an acquisition method with an implicit
/// `this` — no leading dot for `\.$method(` to find — and can wrap that call
/// under a name of its own choosing, which is invisible to a search for the
/// acquisition method names themselves. See the test that uses this for the
/// falsifying example and why the fix is refusing the shape rather than
/// parsing what is inside it.
final RegExp _extensionOnRecordMutationLock = RegExp(r'\bextension\b[^{]*?\bon\s+RecordMutationLock\b\s*\{');

/// The call by which a surface says it is about to delete or extract.
///
/// Named once and used by both the scan and its reason, so a rename shows up as
/// the "found nothing" control failing rather than as a case that keeps passing
/// about a function that no longer exists.
const String _blockerCall = 'storageActionBlockerOf';

/// What a surface has to be reading to have asked the other half of the same
/// question.
const String _registryRead = 'longReadRegistryProvider';

/// Where each top-level declaration in [source] begins.
///
/// Dart puts top-level declarations, and only those, at column 0 — a member, a
/// statement and an indented doc comment are all indented, and a `}` at column 0
/// is the end of the declaration above rather than the start of a new one. So the
/// line starts that begin with any other non-space character are exactly the
/// boundaries, which is enough to slice a declaration without parsing one. (This
/// would be wrong inside a multi-line string whose content starts at column 0;
/// `lib/` contains no `'''` or `"""` at all, and a scan that started splitting
/// one would show up as the compliant probe failing rather than as a silent
/// pass.)
List<int> _topLevelBoundaries(String source) => [
  0,
  ...RegExp(r'^[^\s}]', multiLine: true).allMatches(source).map((match) => match.start),
];

/// Whether the match at [matchStart] is the declaration of the name it matched
/// rather than a call of it.
///
/// A declaration's own name sits on the first line of the top-level declaration
/// that contains it — `Future<bool> installModuleFromZip(` — while every call of
/// it is inside some body and therefore on a later line of whichever declaration
/// encloses it. Deciding this by position rather than by file name is what keeps
/// a defining file in scope for a real violation written *into* it later, which a
/// sanction on the file name would cover forever.
bool _isOwnDeclaration(String source, List<int> boundaries, int matchStart) {
  final start = boundaries.lastWhere((boundary) => boundary <= matchStart);
  return source.lastIndexOf('\n', matchStart) + 1 == start;
}

/// Whether any declaration in [source] asks the capture/import blocker without
/// also subscribing to the registry somewhere in the same declaration.
///
/// The blocker's own declaration is not a call and is skipped by [_isOwnDeclaration],
/// the same rule that finds the slices.
///
/// [source] must already have been through [_codeOnly] when it comes from a real
/// file, for [_subscribesToRegistry]'s reason: until the sixth pass this one
/// case handed over raw text, so a declaration that called the blocker and named
/// `longReadRegistryProvider` only in a doc line or a log string paired itself
/// on the strength of what it said about itself. The `talkingProbe` control in
/// the case below is what holds that shut.
bool _blockerWithoutRegistry(String source) {
  final boundaries = _topLevelBoundaries(source);
  for (final match in '$_blockerCall('.allMatches(source)) {
    if (_isOwnDeclaration(source, boundaries, match.start)) {
      continue;
    }
    final start = boundaries.lastWhere((boundary) => boundary <= match.start);
    final end = boundaries.firstWhere((boundary) => boundary > match.start, orElse: () => source.length);
    if (!_subscribesToRegistry(source.substring(start, end))) {
      return true;
    }
  }
  return false;
}

/// The closed set of calls by which a file in `lib/` has already said it is
/// about to destroy, or spend a long time rewriting, something in the user's
/// stores.
///
/// The same move the blocker case makes, with a wider anchor: nothing in the
/// code says "this widget is destructive", but a file that calls
/// `runStorageDelete` or `RecordZipService.import` has declared it *by calling
/// it*. So the rule below is a pairing rule over an existing classification
/// rather than a judgement about widgets.
///
/// **Each entry is spelled as far as the notifier it belongs to, not as a
/// verb.** A bare `.start(` matches five unrelated files (`action_runner.dart`,
/// `execution_controller.dart`, `external_program_runner.dart`, `spec/script.dart`,
/// `sentry_util.dart`), none of which touches a record store; qualifying it with
/// the provider it is reached through leaves only the re-recognition surfaces.
/// `.archive(` is qualified for the same reason. A new entry is worth adding
/// only after its file count in `lib/` has been looked at — the census below
/// asserts that count, so an entry that suddenly matches half the tree fails
/// loudly rather than quietly widening the rule.
///
/// **A claim wrapper is not an entry point.** `runModuleInstall` was listed here
/// and is not: it *is* the registration — it takes the `moduleInstall` claim
/// around whatever it is handed — so every one of its call sites has announced
/// by construction, and anchoring on it asked the registrar to also subscribe.
/// The four module-install routes are still anchored where a surface reaches
/// them, through `installModuleFromZip` / `installModuleFromZipBytes`; what drops
/// out is `version_check.dart`, which declares those two and calls the wrapper.
/// That file is the claim's issuer and not a surface: it has no control of its
/// own, and the thing it would subscribe to is the claim it just took. The
/// exclusion is derived, not listed — the file is out because [_isOwnDeclaration]
/// says its only matches are its own declarations, so a destructive *call* added
/// to it later puts it straight back in.
const List<String> _destructiveEntries = [
  'runStorageDelete(',
  '.deleteAsync(',
  'charaArchiveControllerProvider.notifier).archive(',
  'RecordZipService.import(',
  'installModuleFromZip(',
  'installModuleFromZipBytes(',
  'charaDetailRecordRegenerationControllerProvider.notifier).start(',
  '.migrate(',
  // **The video import is deliberately not an entry here, and the reason is that
  // it has a stronger obligation than this census can express.** Every spelling
  // of its entry point matches the five files that *declare* a
  // `startVideoImport(` — the three front ends, the method channel and the wasm
  // client — rather than the one that calls it, and a spelling narrow enough to
  // pick out the call depends on where the formatter puts a line break. What
  // replaces it is a required argument: `startVideoImport` takes a
  // `LongReadDeclaration`, so a session cannot be opened without somebody having
  // written down whether it announces one, which the compiler checks and this
  // scan could only have noticed after the fact.
];

/// Every spelling by which a file subscribes to the registry — reads the answer,
/// rather than putting an answer into it.
///
/// The two refusal helpers are here because they *are* a registry read —
/// `storageDeleteRefusalOf` and `storageExtractRefusalOf` both resolve
/// [longReadRegistryProvider] themselves and order the answer against the
/// capture blocker, which is exactly what a surface is being asked to do. The
/// folds they call (`storageDeleteBlockedBy`, `storageExtractBlockedBy`) are
/// deliberately *not* here: those are pure over a claim list handed to them, so
/// a file could call one with an empty list and never have asked anybody.
const List<String> _registryReads = [_registryRead, 'storageDeleteRefusalOf', 'storageExtractRefusalOf'];

/// The claim side of the same provider, which [_subscribesToRegistry] refuses to
/// count as a subscription.
///
/// `.notifier` is how a file *registers* a hold; the state the surfaces watch is
/// reached without it. Counting the handle as a read is what let a file pass this
/// census by announcing itself — `version_check.dart`'s only code mention of the
/// provider is this spelling, taking the `moduleInstall` claim, and it was being
/// read as "that file asked whether anybody else was holding the modules". The
/// bounded false negative is deliberate and stated: a surface that only ever
/// point-queries through the handle (`.notifier).holdsKind(…)`) and never watches
/// is not counted as subscribing, because a query at the moment of acting is not
/// the subscription that keeps a control from being *offered*. The one anchored
/// file that spells it that way (`storage_tree.dart`) also watches, so the
/// exclusion costs the census nothing today.
const String _claimHandle = '$_registryRead.notifier';

/// Whether [code] reads the registry's answer anywhere.
///
/// [code] must already have been through [_codeOnly] when it comes from a real
/// file, and both censuses that reach here now do it: the round through
/// [_roundOver] and the blocker case through the same [_libSources] map. One
/// rule about what counts as a mention, applied in one place — the blocker case
/// used to carry no rule at all, which is a difference no reader of either case
/// could see from the case itself.
bool _subscribesToRegistry(String code) {
  for (final read in _registryReads) {
    for (final match in read.allMatches(code)) {
      if (read == _registryRead && code.startsWith(_claimHandle, match.start)) {
        continue;
      }
      return true;
    }
  }
  return false;
}

/// [source] with its comments and string literals replaced by nothing.
///
/// **Without this the scan reports what a file says about itself.**
/// `storage_delete_action.dart` has a doc line reading "Watches
/// `longReadRegistryProvider` as well as …" and no such identifier anywhere in
/// its code — the subscription is really `storageDeleteRefusalOf`. A census that
/// counted raw text would pass that file *on the strength of its own comment*,
/// and would keep passing it after the subscription was deleted. String
/// literals go for the same reason: a name in a log message or a test-only
/// string is not a call.
///
/// Newlines inside comments are kept so offsets stay roughly readable; nothing
/// here depends on line numbers. Interpolation inside a string is dropped with
/// the string, so an anchor written only inside `'${…}'` is invisible — a
/// deliberate false negative rather than an oversight, and the anchored count
/// below would fall by one if it ever mattered.
String _codeOnly(String source) {
  final buffer = StringBuffer();
  var index = 0;
  var blockDepth = 0;
  while (index < source.length) {
    if (blockDepth > 0) {
      // Dart nests block comments, so the depth has to be counted rather than
      // scanned to the first `*/`.
      if (source.startsWith('/*', index)) {
        blockDepth++;
        index += 2;
      } else if (source.startsWith('*/', index)) {
        blockDepth--;
        index += 2;
      } else {
        if (source[index] == '\n') {
          buffer.write('\n');
        }
        index++;
      }
      continue;
    }
    if (source.startsWith('/*', index)) {
      blockDepth = 1;
      index += 2;
      continue;
    }
    if (source.startsWith('//', index)) {
      final end = source.indexOf('\n', index);
      index = end < 0 ? source.length : end;
      continue;
    }
    final char = source[index];
    if (char == "'" || char == '"') {
      index = _endOfString(source, index);
      continue;
    }
    buffer.write(char);
    index++;
  }
  return buffer.toString();
}

/// Where the string literal opening at [start] ends, one past its closing quote.
///
/// A raw string is skipped by the same walk: the only shape it would get wrong
/// is one ending in a backslash, which Dart cannot express at all.
int _endOfString(String source, int start) {
  final quote = source[start];
  final closing = source.startsWith(quote * 3, start) ? quote * 3 : quote;
  var index = start + closing.length;
  while (index < source.length) {
    if (source[index] == r'\') {
      index += 2;
      continue;
    }
    if (source.startsWith(closing, index)) {
      return index + closing.length;
    }
    if (closing.length == 1 && source[index] == '\n') {
      // Unterminated on its line: bail rather than swallow the rest of the file.
      return index;
    }
    index++;
  }
  return source.length;
}

/// The round of the surfaces, counted: which files declared themselves
/// destructive, which of them never subscribe to the registry, and how many
/// files each anchor is still finding.
///
/// A file that only *declares* an entry point has not called it, so its
/// declaration alone does not anchor it ([_isOwnDeclaration]); and a file that
/// only *registers* a claim has not asked anybody, so the claim handle alone does
/// not pair it ([_subscribesToRegistry]).
({List<String> anchored, Set<String> unpaired, Map<String, int> filesPerEntry}) _roundOver(
  Map<String, String> sources,
) {
  final anchored = <String>[];
  final unpaired = <String>{};
  final filesPerEntry = {for (final entry in _destructiveEntries) entry: 0};
  for (final path in sources.keys.toList()..sort()) {
    final code = _codeOnly(sources[path]!);
    final boundaries = _topLevelBoundaries(code);
    final hits = _destructiveEntries
        .where((entry) => entry.allMatches(code).any((match) => !_isOwnDeclaration(code, boundaries, match.start)))
        .toList();
    if (hits.isEmpty) {
      continue;
    }
    anchored.add(path);
    for (final hit in hits) {
      filesPerEntry[hit] = filesPerEntry[hit]! + 1;
    }
    if (!_subscribesToRegistry(code)) {
      unpaired.add(path);
    }
  }
  return (anchored: anchored, unpaired: unpaired, filesPerEntry: filesPerEntry);
}

/// Every Dart file under `lib/`, keyed by its slash-separated path.
Map<String, String> _libSources() {
  final sources = <String, String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    sources[entity.path.replaceAll(r'\', '/')] = entity.readAsStringSync();
  }
  return sources;
}

/// The members of `enum LongReadKind`, read out of the source rather than
/// written down here.
///
/// Listing them in the test would be the enumeration the enum exists to remove:
/// a member added without a claim site would be added to this list too, by the
/// same hand, in the same commit.
List<String> _kindMembersIn(String registrySource) {
  final body = RegExp(r'\benum\s+LongReadKind\s*\{([^}]*)\}').firstMatch(_codeOnly(registrySource));
  if (body == null) {
    return const [];
  }
  return body
      .group(1)!
      .split(',')
      .map((member) => member.trim())
      .where((member) => member.isNotEmpty)
      .toList(growable: false);
}

/// How many times each member of [members] is named as the kind of a claim.
///
/// `long_read_registry.dart` is excluded because the enum's own declaration and
/// its doc are not claim sites; every other file in `lib/` is in scope, so a
/// claim site moving between files does not need this counted again.
Map<String, int> _claimSiteCounts(Map<String, String> sources, List<String> members) {
  final counts = {for (final member in members) member: 0};
  for (final path in sources.keys) {
    if (path.endsWith('lib/src/core/storage/long_read_registry.dart')) {
      continue;
    }
    final code = _codeOnly(sources[path]!);
    for (final member in members) {
      counts[member] = counts[member]! + RegExp('kind: LongReadKind\\.$member\\b').allMatches(code).length;
    }
  }
  return counts;
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

    test('is the only way lib holds paths, apart from three counted exceptions', () {
      // A claim nobody releases blocks its paths for the rest of the session with
      // nothing to notice it, so the unscoped half of the protocol is not left to
      // a reading of the doc: a file in `lib/` reaching for it uninvited turns
      // this red.
      //
      // **The permission is a number and not a name, and the difference is the
      // whole reason this reads `allMatches` rather than `contains`.** A
      // sanctioned *file* says "this file is an exception", which is not what any
      // of these three files earned: what they earned is "this file has exactly
      // this many". Spelt as a name, the third entry below would have been a real
      // loss of discrimination -- `storage.dart` is the largest file in `lib/`,
      // and a fourth hand-written claim appearing in it would have been invisible
      // here. Spelt as a count, adding an entry costs nothing, because the
      // sanction stops covering the file the moment the file stops matching it.
      //
      // The counts are asserted in both directions from one comparison, so
      // renaming the method cannot quietly turn the scan into a search for a
      // string that no longer occurs anywhere: every expected count is positive,
      // so a scan that found nothing fails as loudly as one that found too much.
      const sanctioned = {
        // The definition itself, plus the one call inside `hold` -- the `finally`
        // every other long reader borrows instead of writing its own release.
        'lib/src/core/storage/long_read_registry.dart': 2,
        // `StorageZipProgress.begin`, and `StorageZipProgress.reclaimAfterDialog`
        // which retakes the same claim after `releaseForDialog` gave the folder
        // back for the length of a save dialog. One claim whose lifetime is the
        // notifier's, driven by `begin` … `report` … `finish` from the zip's
        // screen furniture, and reopened once in the middle of that run — which
        // is why it is two hand-written claims and not a `hold`: neither end of
        // either stretch is on the starter's stack.
        'lib/src/core/storage/zip_export.dart': 2,
        // `CharaDetailRecordRegenerationController._claimBatch`: a batch whose end
        // is a state transition reached from a native callback and from a timer,
        // neither of them on the starter's stack.
        'lib/src/chara_detail/storage.dart': 1,
        // `listenLiveCaptureLongRead`: a live capture session, whose two edges are
        // both the core's. A session begins and ends with a `captureTriggered`
        // event and nothing in Dart is on the stack in between, so there is no
        // block to put a `hold` around -- the same situation the two above are in.
        'lib/src/gui/capture.dart': 1,
      };

      final found = <String, int>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final count = 'claimUntilReleased('.allMatches(entity.readAsStringSync()).length;
        if (count == 0) {
          continue;
        }
        found[entity.path.replaceAll(r'\', '/')] = count;
      }

      expect(
        found.keys.where((path) => !sanctioned.keys.any(path.endsWith)),
        isEmpty,
        reason:
            'a long reader whose work is one Future must use LongReadRegistry.hold; '
            'claiming by hand is only for a claim whose lifetime is an object\'s, as StorageZipProgress\'s is',
      );
      expect(
        {
          for (final entry in sanctioned.entries)
            entry.key: found.entries
                .firstWhere((seen) => seen.key.endsWith(entry.key), orElse: () => const MapEntry('', 0))
                .value,
        },
        sanctioned,
        reason:
            'a sanctioned file is allowed a stated number of hand-written claims, not a licence to hold paths: '
            'a count of 0 means the scan is searching for a string that no longer occurs, and a count above the '
            'sanctioned one means a claim was added where the release is nobody\'s to forget by construction',
      );
    });

    test('the gate is the only way lib takes the record lock, apart from one recovery path', () {
      // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *somewhere in
      // `lib/`, the record mutation lock is acquired without the
      // `LongReadDeclaration` the gate makes mandatory.*
      //
      // It used to falsify something narrower, and the difference was not
      // academic. The old scan asked "does a file call `runFor…` on a receiver
      // whose **name** contains `lock`?" — a question about a variable name,
      // which is the author's to choose and carries no meaning. A third bypass
      // written as `final mutex = platformRecordMutationLock; await
      // mutex.runForRoot(…);` compiled, ran, held the whole store open, left
      // every delete button live, and left this case green; renaming `mutex` to
      // `lock` and changing nothing else turned it red. A test whose answer
      // depends on an identifier reports "nothing found" for every spelling
      // nobody thought of, and there is no spelling it could not have missed.
      //
      // So the axis is the claim rather than the value. What actually separates
      // a gate call from a direct acquisition is not who the receiver is but
      // what is passed: `RecordRecoveryGate`'s three methods take a *required*
      // `declaration:`, and `RecordMutationLock`'s take no such parameter, so an
      // acquisition that skips the declaration cannot be spelled with one and a
      // call that carries one cannot be reaching the lock. Every call of an
      // acquisition method is therefore examined, whatever its receiver looks
      // like, and judged on its argument list.
      //
      // WHAT THIS STILL CANNOT SEE — the list is short but it is not empty, and
      // "nothing found" from this case means "none of these":
      //  * A tear-off: `final run = lock.runForRoot; await run(…);` has no
      //    argument list at the mention, so there is nothing to inspect.
      //  * An acquisition that does not go through `RecordMutationLock` at all —
      //    a caller building its own `ExclusiveLockRunner`, using
      //    `InProcessNamedLocks` directly, or reaching `navigator.locks`.
      //  * Dart outside `lib/` (the Windows runner and the wasm side take no
      //    Dart lock, but nothing here would notice if they started to).
      //  * A future acquisition method on `RecordMutationLock` that does not
      //    return `Future<T>` — the derivation below reads that shape.
      //  * A call whose argument list this file cannot parse is reported as a
      //    finding rather than passed over, so that hole fails closed.
      //
      // Not on this list any more: an extension declared on
      // `RecordMutationLock` used to hide both halves of a bypass from this
      // case at once — the wrapper call, because it is defined outside the
      // class body the acquisition-method names are read from below, and the
      // acquisition inside the wrapper, because an extension body's implicit
      // `this` leaves no leading dot for `\.$method(` to match. The companion
      // case right after this one closes that by refusing the shape itself —
      // an extension on `RecordMutationLock` anywhere in `lib/` — rather than
      // by parsing what is inside it.
      //
      // WHY THE ONE NON-GATE MEMBER IS SANCTIONED. `JournalRootStorageMaintenance`
      // is the locked wrapper around the startup sweep whose unlocked half is
      // what the gate's own `ensureRootReadyUnlocked` hook runs, so routing it
      // through the gate would call it from inside itself. Not as a deadlock —
      // the hook acquires nothing, so the lock is still taken once — but as a
      // relocation: the hook's pass would perform the sweep, `run`'s own
      // `runUnlocked` would then find the root already marked swept and do
      // nothing, and the execution site would be decided by a memo table rather
      // than by the call. It says so at the call.
      //
      // There used to be a second: a locked wrapper around the same archive
      // recovery, in `archive_executor_shared.dart`. Nothing in `lib/` ever
      // called it, and it was deleted rather than kept as an entry point for a
      // caller that had not appeared; the sweep still runs the unlocked half.
      //
      // Being sanctioned here is about the *acquisition* and nothing else, and
      // the member is not unannounced: the sweep is claimed at the
      // `runPathInfoStartupMaintenance` boundary above it. This case would stay
      // green if it lost that claim again — what it can see is the argument
      // list of the acquisition, and the acquisition is the half it is excused
      // from.
      const sanctioned = {
        // The gate's own implementation: the one place the acquisition lives.
        'lib/src/core/fs/record_recovery_gate_shared.dart',
        'lib/src/core/fs/root_storage_maintenance_shared.dart',
      };

      // The acquisition methods are read out of the lock's own source instead of
      // being listed here. A list would be an enumeration to keep in step by
      // hand, and the failure it invites is exactly the one above: a fourth
      // method arrives, nobody adds it, and the scan answers "nothing found"
      // about a method it was never looking for.
      final lockSource = File('lib/src/core/fs/record_mutation_lock_shared.dart').readAsStringSync();
      final lockBody = RegExp(r'final class RecordMutationLock \{(.*?)\n\}', dotAll: true).firstMatch(lockSource);
      expect(lockBody, isNotNull, reason: 'RecordMutationLock was renamed or moved; the scan derived nothing');
      final acquisitionMethods = RegExp(
        r'Future<[A-Za-z?]+>\s+([A-Za-z][A-Za-z0-9_]*)\s*<',
      ).allMatches(lockBody?.group(1) ?? '').map((match) => match.group(1)).whereType<String>().toSet();
      expect(
        acquisitionMethods,
        isNotEmpty,
        reason: 'the scan found no public acquisition method on RecordMutationLock, so it is searching for nothing',
      );

      final undeclared = <String>{};
      final declared = <String>[];
      final declaredAcrossLines = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        final path = entity.path.replaceAll(r'\', '/');
        for (final method in acquisitionMethods) {
          // A leading `.` and an optional explicit type argument, and nothing
          // about the receiver: `lock.runForRoot(`, `mutex.runForRoot(`,
          // `ref.read(gate).runForRoot(`, `..runForRoot(` and
          // `x.runForRoot<void>(` all match, while the declaration in the gate
          // and in the lock — which has no leading dot — does not.
          for (final match in RegExp('\\.$method\\s*(?:<[^<>()]*>)?\\s*\\(').allMatches(source)) {
            final arguments = _argumentListAt(source, match.end - 1);
            if (arguments == null || !arguments.contains('declaration:')) {
              undeclared.add(path);
              continue;
            }
            declared.add(path);
            if (arguments.contains('\n')) {
              declaredAcrossLines.add(path);
            }
          }
        }
      }

      expect(
        undeclared.where((path) => !sanctioned.any(path.endsWith)),
        isEmpty,
        reason:
            'a caller taking RecordMutationLock directly skips the declaration the gate requires; '
            'either go through RecordRecoveryGate, or say at the call why the gate cannot be used',
      );
      expect(
        sanctioned.map((path) => undeclared.any((seen) => seen.endsWith(path))),
        everyElement(isTrue),
        reason: 'the scan no longer finds the calls it was written to bound, so it is checking nothing',
      );
      // Two controls on the instrument rather than on `lib/`. Without the first,
      // a scan that recognised no `declaration:` anywhere would call every gate
      // call a bypass — which is loud — but a scan whose regex matched nothing
      // at all would be silent, and both are answered by requiring that declared
      // calls were actually seen. The second is the one the old scan could not
      // have had: the argument list is found by walking parentheses, so a walk
      // that stopped at the first newline would still pass every single-line
      // call and quietly misjudge the wrapped ones.
      expect(
        declared,
        isNotEmpty,
        reason: 'no call anywhere in lib passes declaration:, so the scan is not recognising a gate call',
      );
      expect(
        declaredAcrossLines,
        isNotEmpty,
        reason: 'the argument-list walk never crossed a newline, so it is not reading wrapped call sites',
      );
    });

    test('no extension on RecordMutationLock reaches lib, because that is the one shape the case above cannot see '
        'through', () {
      // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *somewhere in
      // `lib/`, an extension is declared directly on `RecordMutationLock`.*
      //
      // The case above judges every acquisition call by whether its argument
      // list carries `declaration:`, but that judgement depends on the call
      // being spelled with a leading dot and on the wrapper that makes the call
      // living inside the class body the acquisition-method names are read
      // from. An extension breaks both assumptions with nothing exotic — no
      // reflection, no `dynamic`, just ordinary Dart:
      //
      //   extension _Sneaky on RecordMutationLock {
      //     Future<T> sneaky<T>(Future<T> Function() action) => runForRoot(action);
      //   }
      //   // ... await lock.sneaky(() async { ... });
      //
      // `sneaky` is defined outside `final class RecordMutationLock { ... }`,
      // so the class-body slice the case above reads never sees it, and inside
      // `sneaky`, `runForRoot(action)` calls through Dart's implicit `this` —
      // legal without a leading dot inside an extension body — so
      // `\.runForRoot\(` never matches it either. Both the wrapper and the real
      // acquisition are invisible to that regex at once, and this was found
      // and demonstrated by an earlier independent verification pass, not
      // predicted in advance.
      //
      // Parsing every extension body for an implicit-`this` call was rejected
      // in favour of a simpler axis: `RecordMutationLock` has no legitimate
      // extension anywhere in `lib/` today, and an extension is the only shape
      // that can hide an acquisition from the case above, so refusing the
      // shape itself is fail-closed without having to understand what is
      // inside it. A real need can still be met by adding the file below with
      // a reason, the same way the recovery path above is sanctioned.
      const sanctioned = <String>{};

      // The instrument's control: prove the regex actually recognises the
      // falsifying shape above, so a pattern that matched nothing, ever, could
      // not pass this case by finding nothing in `lib/` for the wrong reason.
      const probe =
          'extension _Sneaky on RecordMutationLock {\n'
          '  Future<T> sneaky<T>(Future<T> Function() action) => runForRoot(action);\n'
          '}\n';
      expect(
        _extensionOnRecordMutationLock.hasMatch(probe),
        isTrue,
        reason: 'the regex does not recognise its own falsifying example, so it is not checking anything',
      );
      // A second control: an ordinary extension on some other type must not
      // trip the same regex, or this case would be banning extensions in
      // general rather than the one shape that matters.
      expect(
        _extensionOnRecordMutationLock.hasMatch('extension _Other on SomeOtherType {\n  void f() {}\n}\n'),
        isFalse,
        reason: 'the regex matched a type it was not looking for, so it is not judging the shape it claims to',
      );

      final found = <String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        if (_extensionOnRecordMutationLock.hasMatch(entity.readAsStringSync())) {
          found.add(entity.path.replaceAll(r'\', '/'));
        }
      }

      expect(
        found.where((path) => !sanctioned.any(path.endsWith)),
        isEmpty,
        reason:
            'an extension on RecordMutationLock can call its acquisition methods through an implicit `this`, which '
            'has no leading dot for the case above to find, under a name of its own choosing, which the case above '
            'never looks for either; go through RecordMutationLock directly and RecordRecoveryGate on top of it, or '
            'add the file here with a reason if an extension is genuinely needed',
      );

      // WHAT THIS STILL CANNOT SEE — refusing the shape closes the hole the
      // case above had, but this case is its own narrow text search and has
      // blind spots of its own, stated so "nothing found" is not read as
      // "nothing like this exists":
      //  * An extension on a type alias or a supertype of `RecordMutationLock`
      //    rather than on the name itself — there is none in this codebase
      //    today, but the regex looks for the literal identifier, not the type.
      //  * An extension whose `on` clause and opening `{` are separated by a
      //    `{` from an unrelated nested construct in between (a collection
      //    literal or a function-typed parameter in the `on` clause) — Dart's
      //    `on` clause cannot actually contain one, so this is not reachable
      //    from valid syntax, but it is why the regex stops at the first `{`
      //    rather than trusting a wider search.
      //  * Everything the case above already could not see stays unseen here
      //    too where it does not route through an extension: a tear-off, a
      //    caller building its own `ExclusiveLockRunner`, Dart outside `lib/`,
      //    and a future acquisition method that does not return `Future<T>`.
    });
  });

  group('the round of the surfaces', () {
    test('a surface that asks the capture blocker asks the registry too, because the step that used to check that '
        'was a human one', () {
      // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *somewhere in
      // `lib/`, a surface decides whether to offer a destructive or an
      // extracting control from the capture/import blocker alone, without ever
      // asking the registry whether a long reader is holding the same thing.*
      //
      // WHY THIS IS A CASE AND NOT A PARAGRAPH IN A DOC. Adding a long reader
      // takes several steps, and the last of them — "go round the surfaces that
      // could act on what it holds and make each one subscribe" — is the only one
      // with no mechanical half at all: forgetting it compiles, runs, and leaves
      // a live button over a folder something else is rewriting.
      // `long_read_registry.dart` says as much in its own words, that the round
      // is "still owed once per surface rather than once per long-reader kind",
      // and the file that first shipped without it was found by hand rather than
      // by anything here. This case is that round done by machine, for the part
      // of it a machine can decide.
      //
      // THE AXIS IS A DECLARATION THAT ALREADY CLASSIFIED ITSELF. Nothing in the
      // code says "this widget is destructive"; asking for that would be asking a
      // scan to understand what a button does. But a surface that calls
      // `storageActionBlockerOf` has *already declared* it is about to delete or
      // extract — that is what [StorageAction] is — and the registry is the
      // second half of the same question the blocker is the first half of. So the
      // rule is a pairing rule over an existing classification, not a judgement
      // about widgets.
      //
      // THE UNIT IS THE SURFACE, NOT THE STATEMENT. A widget may resolve the
      // blocker in `build`, where a watch is legal, and ask the registry in a
      // callback or a nested builder it hands that answer to; `storage_tree.dart`
      // was shaped that way when this case was written, and a per-method rule
      // would have called it a violation and been wrong. So the slice is the
      // whole top-level declaration — which for a widget is the class, and for
      // the two `storage_tree.dart` helpers, which are the only anchored
      // declarations left in `lib` today, is the function.
      //
      // WHAT THIS CANNOT SEE. "Nothing found" here means "none of these", and
      // the list is not short:
      //  * **A surface that asks neither.** This is the big one and it is the
      //    reason the paragraph above says "for the part a machine can decide":
      //    the scan is anchored on the blocker call, so a control with no anchor
      //    at all is outside its field of view entirely. Three record-page
      //    surfaces were in exactly that position when this case was written
      //    (`chara_detail/export_button.dart`, `archive_record_dialog.dart`,
      //    `regenerate_record_dialog.dart`); they subscribe to the registry now,
      //    and this case saw neither the gap nor its closing, because none of the
      //    three asks the capture blocker and so none of them is in scope here at
      //    all. The same is true of the three surfaces the same round added it to
      //    afterwards (the record table's re-recognition entry,
      //    `CharaDetailRecordRegenerationController.start`, and the data-root
      //    relocation). Every one of them was found by a person reading the tree.
      //    The initial inventory was human work and this case does not replace it;
      //    what it does is stop the inventory from decaying once it has been made.
      //  * **A surface that asks both and uses neither.** The scan sees that the
      //    registry was read, never that the answer reached an `enabled` or an
      //    `onPressed`.
      //  * **A surface that asks about the wrong path.** `storage_tree.dart`
      //    asks separately about the row's entity and about its zip target
      //    precisely because they are not always the same; a scan that counts
      //    readings cannot tell a right subject from a wrong one.
      //  * **A class holding two controls where only one of them subscribes.**
      //    The slice is the declaration, so one reading anywhere in it satisfies
      //    the whole class.
      //  * **Dart outside `lib/`, and the non-Dart front ends.** The same
      //    boundary the two cases above have.
      //  * **THE OTHER DIRECTION, WHICH THIS CASE NEVER ASKS FOR.** The pairing
      //    is one-way: the anchor is the capture blocker and the requirement is
      //    the registry, so a surface that asks the *registry* and never the
      //    capture blocker is not a violation here and is not even in scope --
      //    it has no anchor. That is not a corner case, it is most of the app:
      //    the record page's deletes, exports, archives and re-recognitions, the
      //    two module installs and the settings page's inheritance pass all ask
      //    the registry alone, and every one of them was blind to a running
      //    capture for the whole of this branch while passing this case green.
      //    Two defects lived in that gap -- a module install that could be
      //    started mid-capture, and a capture that could be started mid-zip --
      //    and neither case in this group could see either. What closed them was
      //    putting the capture on the registry
      //    ([LongReadKind.liveCapture]) so that the one question these cases do
      //    ask now covers it; the missing direction itself is still not asked
      //    for, and a third census asking it would be a third round of the same
      //    inventory rather than a new fact.
      const sanctioned = <String>{};

      // The instrument's controls, on synthetic sources rather than on `lib/`,
      // so a scan that had stopped recognising either shape could not pass by
      // finding nothing. The compliant probe is the one that matters most: it is
      // what says a green result comes from surfaces that subscribe rather than
      // from a slicer that quietly returned the whole file every time.
      const violatingProbe =
          'class _Probe extends ConsumerWidget {\n'
          '  @override\n'
          '  Widget build(BuildContext context, WidgetRef ref) {\n'
          '    final blocker = storageActionBlockerOf(ref, group, StorageAction.delete);\n'
          '    return Text(blocker.toString());\n'
          '  }\n'
          '}\n'
          '\n'
          'final somethingElse = longReadRegistryProvider;\n';
      const compliantProbe =
          'class _Probe extends ConsumerWidget {\n'
          '  @override\n'
          '  Widget build(BuildContext context, WidgetRef ref) {\n'
          '    final blocker = storageActionBlockerOf(ref, group, StorageAction.delete);\n'
          '    return _menu(ref);\n'
          '  }\n'
          '\n'
          '  Widget _menu(WidgetRef ref) => Text(ref.watch(longReadRegistryProvider).toString());\n'
          '}\n';
      expect(
        _blockerWithoutRegistry(violatingProbe),
        isTrue,
        reason:
            'the scan does not recognise its own falsifying example — a surface reading the blocker whose file '
            'mentions the registry somewhere else entirely — so it is not checking anything',
      );
      expect(
        _blockerWithoutRegistry(compliantProbe),
        isFalse,
        reason:
            'the scan called a subscribing surface a violation, so its slice is not the declaration it claims to be '
            'and every green result below is green for the wrong reason',
      );
      // The third shape: the blocker's own declaration mentions the name without
      // calling it, and reads no registry because it is not a surface. Skipping
      // it by its column rather than by its file name is what keeps the defining
      // file in scope for a violation written *into* it later, so the rule that
      // does the skipping is worth a control of its own.
      const declarationProbe =
          'StorageActionBlocker? storageActionBlockerOf(WidgetRef ref, StorageGroup group, StorageAction action) {\n'
          '  return storageActionBlocker(group, action, activity: ref.watch(captureActivityProvider));\n'
          '}\n';
      expect(
        _blockerWithoutRegistry(declarationProbe),
        isFalse,
        reason: 'the scan read the blocker\'s own declaration as a surface that failed to subscribe',
      );
      // The fourth shape, and the instrument's own defect until the sixth pass:
      // a surface whose only mention of the registry is a doc line or a log
      // string has not subscribed to anything. This case ran on raw text and so
      // paired that surface on the strength of what it said about itself — the
      // exact failure its sister census holds down with `talkingFixture`, which
      // is why the probe is written to the same shape. `storage_delete_action.dart`
      // carries that doc line today and is compliant for an entirely different
      // reason, so the shape is not hypothetical.
      const talkingProbe =
          '/// Watches longReadRegistryProvider as well as the capture blocker.\n'
          'class _Probe extends ConsumerWidget {\n'
          '  @override\n'
          '  Widget build(BuildContext context, WidgetRef ref) {\n'
          '    logger.i("longReadRegistryProvider says nothing here");\n'
          '    final blocker = storageActionBlockerOf(ref, group, StorageAction.delete);\n'
          '    return Text(blocker.toString());\n'
          '  }\n'
          '}\n';
      expect(
        _blockerWithoutRegistry(_codeOnly(talkingProbe)),
        isTrue,
        reason:
            'the scan let a surface pass on the strength of a comment or a log string, which is what it did for '
            'five passes: strip comments and literals before asking, as the round below has always done',
      );

      // The same corpus the round below reads, so neither census can be looking
      // at a different `lib/` from the other, and stripped by the same rule.
      final anchored = <String>[];
      final unpaired = <String>{};
      final blockerSources = _libSources();
      for (final path in blockerSources.keys.toList()..sort()) {
        final code = _codeOnly(blockerSources[path]!);
        if (!code.contains('$_blockerCall(')) {
          continue;
        }
        anchored.add(path);
        if (_blockerWithoutRegistry(code)) {
          unpaired.add(path);
        }
      }

      expect(
        unpaired.where((path) => !sanctioned.any(path.endsWith)),
        isEmpty,
        reason:
            'this surface has already said it is about to delete or extract, and it is weighing only the half of '
            'that question a capture answers; go through storageDeleteRefusalOf / storageExtractRefusalOf, which '
            'read both and order them, or say here why this one cannot',
      );
      // Without this the case would be green on a codebase where the helper had
      // been renamed and the scan therefore matched nothing at all — the exact
      // shape of silence the two cases above are also built to refuse.
      expect(
        anchored.length,
        2,
        reason:
            'the set of files that call $_blockerCall changed size. If it fell to zero the classification this case '
            'is anchored on was renamed and the scan is searching for a string that no longer occurs; if it moved '
            'either way, check that each file still weighs both halves and correct this number — a count is what '
            'makes the change visible, which emptiness alone never was',
      );
    });

    test('a file that calls a destructive entry point reaches the registry somewhere in the same file, because four '
        'rounds of this were done by hand and two files were still missed', () {
      // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *somewhere in
      // `lib/`, a file calls one of the app's named destructive or long-writing
      // entry points without anything in that file ever asking the registry
      // whether a long reader is already holding what it is about to write.*
      //
      // WHY THIS AND NOT THE CASE ABOVE. That case is anchored on
      // `storageActionBlockerOf`, and says in its own words that a surface which
      // asks neither is outside its field of view — "the big one". Two files
      // were sitting in exactly that blind spot for the whole of this branch:
      // `chara_detail/import_button.dart` called `RecordZipService.import` and
      // `module_update_dialog.dart` called `installModuleFromZip` /
      // `installModuleFromZipBytes`, and neither read the registry at all. Both
      // were found by a person reading the tree, on the fourth pass. This case
      // widens the anchor to the destructive calls themselves so that the fifth
      // one does not have to be a person.
      //
      // THE UNIT IS THE FILE, NOT THE DECLARATION, and that is a real
      // difference from the case above. `archive_record_dialog.dart` calls
      // `.archive(` from inside two `State` classes and reads the registry from
      // a top-level helper above them; sliced per declaration it is a violation,
      // and it is not one. A `ConsumerStatefulWidget` is two top-level
      // declarations by construction, so the declaration slice cannot express a
      // widget that decides in its `State` what its file resolved at the top.
      // The price is stated below.
      //
      // WHAT THIS CANNOT SEE.
      //  * **A file with no anchor.** Still the big one, and it has only moved:
      //    a screen calling `PathEntity.delete` or `writeAsBytes` straight is
      //    outside the closed set. Widening the set stays a human judgement;
      //    what stops decaying is the inventory, not the making of it.
      //  * **The wrong subject.** The scan sees that the registry was read, not
      //    that the paths asked about are the paths written. That is what
      //    `recordImportLongReadPaths` and `archiveRecordLongReadPaths` are for
      //    — one definition both the claim and the check read — and no census
      //    can substitute for it.
      //  * **A read whose answer goes nowhere**, and **a file holding two
      //    operations where only one subscribes**: the file slice's price.
      //  * **`read` versus `watch`.** Both count. Four of the anchored files
      //    resolve once on purpose, so requiring `watch` would open with four
      //    sanctions, and a table of exceptions is not an assertion.
      //  * **THE CAPTURE BLOCKER, WHICH THIS CASE NEVER REQUIRES.** The one
      //    thing an anchored file has to reach is the registry: `_registryReads`
      //    lists `longReadRegistryProvider`, `storageDeleteRefusalOf` and
      //    `storageExtractRefusalOf`, and `storageActionBlockerOf` is not in that
      //    vocabulary. So a file that asks the registry and never asks what the
      //    capture card is doing is green here, and until
      //    [LongReadKind.liveCapture] existed that was seven of the nine anchored
      //    files -- only `storage_delete_action.dart` reached both, and
      //    `storage_settings.dart` reads the capture flag to *stop* a capture
      //    rather than to refuse for one. Together with the same omission in the
      //    case above, that is why a running capture was invisible to every
      //    record-page and settings-page control for four rounds. It is a
      //    property of what these cases require, not of the files they scan, and
      //    what removed the exposure was making the capture answerable through
      //    the question they do require rather than adding a third census.
      const sanctioned = <String>{};

      // The instrument's controls, on synthetic sources. The first is the shape
      // this case exists for; the second is the `StatefulWidget` shape that the
      // declaration slice gets wrong, and it is the one that says a green result
      // below comes from files that subscribe rather than from a scan that has
      // stopped recognising the anchor.
      const violatingFixture =
          'class _Probe extends ConsumerWidget {\n'
          '  Future<void> _go(WidgetRef ref) async {\n'
          '    await RecordZipService.import(bytes, dir);\n'
          '  }\n'
          '}\n';
      const compliantFixture =
          'LongReadKind? _blocking(WidgetRef ref) => storageDeleteRefusalOf(ref, group: g, request: r)?.kind;\n'
          '\n'
          'class _ProbeState extends ConsumerState<_Probe> {\n'
          '  Future<void> _go() async {\n'
          '    await RecordZipService.import(bytes, dir);\n'
          '  }\n'
          '}\n';
      // The instrument's own defect, held as a control: a file whose only
      // mention of the registry is in a doc comment or a log string has not
      // subscribed to anything, and a census over raw text would pass it. This
      // is not hypothetical — `storage_delete_action.dart` has that exact doc
      // line today, and is compliant for an entirely different reason.
      const talkingFixture =
          '/// Watches longReadRegistryProvider as well as the capture blocker.\n'
          'class _Probe extends ConsumerWidget {\n'
          '  Future<void> _go(WidgetRef ref) async {\n'
          '    logger.i("longReadRegistryProvider says nothing here");\n'
          '    await RecordZipService.import(bytes, dir);\n'
          '  }\n'
          '}\n';
      // The instrument's second known defect, held as a control: a file that
      // takes a claim of its own has put an answer *into* the registry and has
      // not asked it anything, so the claim handle must not pair it. Until the
      // fifth pass it did, and `version_check.dart` was passing this census on
      // the strength of the `moduleInstall` claim it takes itself.
      const registeringFixture =
          'class _Probe extends ConsumerWidget {\n'
          '  Future<void> _go(WidgetRef ref) async {\n'
          '    await ref\n'
          '        .read(longReadRegistryProvider.notifier)\n'
          '        .hold(kind: LongReadKind.import, paths: p, action: (_) => RecordZipService.import(bytes, dir));\n'
          '  }\n'
          '}\n';
      // And the declaring file: the name is here because this is where it is
      // defined, which is not a surface calling it.
      const declaringFixture =
          'Future<bool> installModuleFromZip(RefBase ref, FilePath zipPath) async {\n'
          '  return _extract(ref, zipPath);\n'
          '}\n';
      final probes = _roundOver({
        'probe/violating.dart': violatingFixture,
        'probe/compliant.dart': compliantFixture,
        'probe/talking.dart': talkingFixture,
        'probe/registering.dart': registeringFixture,
        'probe/declaring.dart': declaringFixture,
        'probe/silent.dart': 'class _Probe extends StatelessWidget {}\n',
      });
      expect(
        probes.anchored,
        ['probe/compliant.dart', 'probe/registering.dart', 'probe/talking.dart', 'probe/violating.dart'],
        reason:
            'the scan does not anchor on its own examples, or it anchored on the declaring probe — either the entry '
            'points below were renamed, or the anchoring is matching something other than a call',
      );
      expect(
        probes.unpaired,
        {'probe/violating.dart', 'probe/talking.dart', 'probe/registering.dart'},
        reason:
            'the scan either called a subscribing file a violation (so the file slice is not what it claims and every '
            'green result below is green for the wrong reason), or it let a file pass on the strength of a comment, '
            'a log string, or a claim of its own — the three failures this instrument was built knowing about',
      );

      // The two lists the census is made of, pinned. Widening either is the edit
      // that has to be looked at, and neither can be widened by accident while
      // these numbers stand.
      expect(
        _destructiveEntries.length,
        8,
        reason:
            'the closed set of destructive entry points changed size; an entry was added without its file count in '
            'lib being looked at, or one was dropped without saying what now covers the calls it was finding',
      );
      expect(
        _registryReads.length,
        3,
        reason:
            'the set of spellings that count as subscribing to the registry changed size, which is the edit that '
            'decides what this census will accept as having asked — widening it silently is how a surface that '
            'never asks starts passing',
      );

      // The old form, taken verbatim from the two files as they stood at
      // `47de8295`, before the fourth pass reached them. Slices rather than the
      // whole files: what is reproduced is the shape — a destructive call with
      // no registry read beside it — and the whole-file measurement at that
      // revision was two unpaired files out of ten anchored.
      const oldImportButton =
          '      for (final file in result.files) {\n'
          '        try {\n'
          '          final bytes = await file.readAsBytes();\n'
          '          final importResult = await RecordZipService.import(bytes, pathInfo.storageDir);\n'
          '          committed = true;\n'
          '          // Union, because the same record may appear in more than one of the\n'
          '          // pieces a single export was split into, and it is imported once.\n'
          '          importedIds.addAll(importResult.recordIds);\n';
      const oldModuleUpdateDialog =
          '/// [installModuleFromZip] where the archive has a filesystem path and via\n'
          '/// [installModuleFromZipBytes] in a browser, where it does not.\n'
          '  Future<bool> _runInstall(RefBase base, String? path, Future<Uint8List> Function() readBytes) async {\n'
          '    if (path != null) {\n'
          '      return installModuleFromZip(base, FilePath(path));\n'
          '    }\n'
          '    try {\n'
          '      return await installModuleFromZipBytes(base, await readBytes());\n'
          '    } catch (exception, stackTrace) {\n';
      final oldForm = _roundOver({
        'lib/src/gui/chara_detail/import_button.dart': oldImportButton,
        'lib/src/gui/module_update_dialog.dart': oldModuleUpdateDialog,
      });
      expect(
        oldForm.unpaired,
        {'lib/src/gui/chara_detail/import_button.dart', 'lib/src/gui/module_update_dialog.dart'},
        reason:
            'the two files this case was written for do not fail it, so it would not have caught the defect it '
            'exists to catch and the green result below means nothing',
      );

      final round = _roundOver(_libSources());

      expect(
        round.unpaired.where((path) => !sanctioned.any(path.endsWith)),
        isEmpty,
        reason:
            'this file calls one of the app\'s destructive entry points and nothing in it asks the registry whether a '
            'long reader is already holding what it is about to write; go through storageDeleteRefusalOf / '
            'storageExtractRefusalOf, or watch longReadRegistryProvider and fold it, or say here why this one cannot',
      );
      // The count, not the emptiness. A file that starts calling one of these
      // has to move this number, which is the edit that makes somebody look at
      // whether it subscribes.
      expect(
        round.anchored.length,
        9,
        reason:
            'the set of files that call a destructive entry point changed. If one was added, check that it reads the '
            'registry and raise this number; if one was removed or an entry point was renamed, lower it — a scan '
            'that quietly finds fewer files every release is the failure mode this number exists to refuse',
      );
      // Per entry, because `anchored.length` alone stays right while seven of
      // the eight entries have been renamed out from under it.
      expect(
        round.filesPerEntry.entries.where((entry) => entry.value == 0).map((entry) => entry.key),
        isEmpty,
        reason:
            'this destructive entry point is no longer called anywhere in lib, so it was renamed or removed and '
            'the scan is now searching for a string that does not occur',
      );
    });
  });

  group('the kinds and their claim sites', () {
    test('every member of LongReadKind is claimed somewhere in lib, because a member with no claim site is the '
        'enumeration of long readers this file exists to remove', () {
      // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *`LongReadKind`
      // carries a member that no operation ever passes to `LongReadClaim`, so
      // the enum has gone back to being a list of jobs somebody thought were
      // long.*
      //
      // The enum's own doc states this rule in the present tense — "a member
      // arrives with its claim site and not before" — and until this case
      // nothing checked it. That is the ordinary way a doc becomes false: not
      // by being wrong when written, but by nobody being able to tell.
      //
      // WHAT THIS DOES NOT DO, and it is worth being blunt about it: **it finds
      // no missing claim.** The import claim was missing for the whole of this
      // branch and this case would have been green throughout, because a member
      // that was never added has no row to be missing from. Catching *that*
      // needs "this operation is long" to exist as data somewhere other than
      // this enum, and it does not — the enum is where that fact lives, so the
      // check is circular by construction. What this case holds is the other
      // direction, which is the direction a future edit takes: the member
      // arrives first, and its claim site never does.
      final registry = File('lib/src/core/storage/long_read_registry.dart').readAsStringSync();
      final members = _kindMembersIn(registry);

      // Controls first: the extractor has to be able to return the wrong answer.
      expect(
        _kindMembersIn(
          'enum LongReadKind {\n'
          '  /// Doc with a comma, which is not a separator.\n'
          '  alpha,\n'
          '\n'
          '  beta,\n'
          '}\n',
        ),
        ['alpha', 'beta'],
        reason:
            'the member extractor cannot read a two-member enum, so what it reads out of the real file is not '
            'the member list either',
      );
      expect(
        _kindMembersIn('enum SomethingElse { alpha, beta }\n'),
        isEmpty,
        reason: 'the member extractor matches an enum that is not LongReadKind, so it is not reading the kind at all',
      );

      expect(
        members.length,
        13,
        reason:
            'the number of long-reader kinds changed. Raise or lower this number in the same edit that adds or '
            'removes the member, so that adding one is a change somebody has to look at rather than a line nobody '
            'reviews',
      );

      final sources = _libSources();
      final counts = _claimSiteCounts(sources, members);
      expect(
        counts.entries.where((entry) => entry.value == 0).map((entry) => entry.key),
        isEmpty,
        reason:
            'this kind is declared and nothing claims it, which is the enumeration of long readers the registry was '
            'built to replace; wire the operation that motivated it, or take the member out until it is wired',
      );
      // Fourteen sites for thirteen kinds: `zip` is claimed twice, by
      // `StorageZipProgress.begin` and again by `reclaimAfterDialog` when the
      // save dialog it stood aside for closes. That is the "a second surface may
      // legitimately claim an existing kind" the reason below allows for, and it
      // is the first time this number and the member count have differed.
      expect(
        counts.values.fold(0, (sum, count) => sum + count),
        14,
        reason:
            'the number of claim sites changed. One kind, one claim site is not a law — a second surface may '
            'legitimately claim an existing kind — but it is a fact somebody should have to write down, so move '
            'this number in the same edit',
      );

      // The falsifying example, on the real corpus with the one line that
      // announces the import claim taken out: this is what a member arriving
      // without its claim site looks like from here.
      final withoutImportClaim = _claimSiteCounts(
        sources.map((path, source) => MapEntry(path, source.replaceAll('kind: LongReadKind.import', 'kind: null'))),
        members,
      );
      expect(
        withoutImportClaim['import'],
        0,
        reason:
            'removing the only claim site of a kind left this case green, so the count is not being read off the '
            'corpus and every number above is decoration',
      );
    });
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

  // The sentence a withheld control shows was rewritten to stop naming the zip
  // when the archive became the second registered kind. Nothing was holding that
  // rewrite in place: with every assertion in the repository written as
  // `appSentenceAt('<key>')`, putting 「ZIP」 back left the whole suite green.
  //
  // There were three of them then, and eight by the time the last subscriber was
  // wired; they are now **one**, `app.long_read_busy`, so that a newly withheld
  // surface costs no translation entry. This group is where that one sentence is
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

/// The text between the parenthesis at [open] in [source] and the one that
/// closes it, or `null` when [source] runs out first.
///
/// **Returning `null` rather than a best guess is the point.** The caller treats
/// an unparsable call site as a finding, so the one thing this walk must never
/// do is answer confidently about a call it did not actually delimit.
///
/// String literals and comments are stepped over instead of being counted: a
/// `(` inside a log message or a `//` line would otherwise move the closing
/// parenthesis and change which arguments a call is judged on. Interpolation
/// that itself contains the quote character (`'${map['k']}'`) is the known limit
/// — the walk ends the literal early there — and it fails towards `null`, which
/// is the safe direction.
String? _argumentListAt(String source, int open) {
  var depth = 0;
  var index = open;
  while (index < source.length) {
    final character = source[index];
    if (character == '(') {
      depth++;
      index++;
      continue;
    }
    if (character == ')') {
      depth--;
      if (depth == 0) {
        return source.substring(open + 1, index);
      }
      index++;
      continue;
    }
    if (source.startsWith('//', index)) {
      final newline = source.indexOf('\n', index);
      index = newline == -1 ? source.length : newline;
      continue;
    }
    if (source.startsWith('/*', index)) {
      final end = source.indexOf('*/', index + 2);
      if (end == -1) {
        return null;
      }
      index = end + 2;
      continue;
    }
    if (character == "'" || character == '"') {
      final end = _stringLiteralEnd(source, index);
      if (end == null) {
        return null;
      }
      index = end;
      continue;
    }
    index++;
  }
  return null;
}

/// The index just past the string literal that starts at [start], or `null` when
/// it is not terminated on this line (or at all, for a triple-quoted one).
int? _stringLiteralEnd(String source, int start) {
  final quote = source[start];
  final triple = source.startsWith(quote * 3, start);
  final delimiter = triple ? quote * 3 : quote;
  final raw = start > 0 && source[start - 1] == 'r';
  var index = start + delimiter.length;
  while (index < source.length) {
    if (!raw && source[index] == r'\') {
      index += 2;
      continue;
    }
    if (source.startsWith(delimiter, index)) {
      return index + delimiter.length;
    }
    if (!triple && source[index] == '\n') {
      return null;
    }
    index++;
  }
  return null;
}
