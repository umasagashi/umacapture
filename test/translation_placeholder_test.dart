import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/dashboard.dart';
import 'package:umacapture/src/gui/video_import.dart';

import 'support/localization.dart';

/// Every `{…}` a shipped sentence carries is filled in by whatever names that key.
///
/// **The gap this closes, app-wide.** Renaming `{name}` to `{title}` in
/// `assets/translations/ja.json` puts a raw 「{title}」 on the user's screen, because
/// `.tr()` leaves a placeholder it was given no matching `namedArgs` for standing
/// verbatim. Before this file, one namespace was defended (`storage_wording_test.dart`,
/// which renders `pages.storage.*` through the production functions) and the other
/// fifty-odd placeholder-carrying keys were defended by nothing at all: a suite of
/// 2,362 tests stayed green through such a rename.
///
/// **The axis.** The claim being falsified is *"the sentence and the code that ships
/// it agree on the placeholder names"*. Rendering all of them through production code
/// is not reachable — most of these keys are reached only from inside a widget — so
/// the primary instrument is a source scan of `lib/`: for every `.tr(…)` site whose
/// key expression resolves (a literal, a literal built from `const` prefixes, or a
/// literal with an interpolation treated as a one-segment wildcard), the argument
/// names it passes must cover the placeholder names the locale file gives that key.
///
/// **The residue is enumerated, not waved through.** A key the scan cannot connect to
/// any satisfying site is *unfilled*, and the set of unfilled keys is pinned by set
/// equality against exactly two lists: [_renderers], which renders the key through the
/// app's own function, and [_literalBraceKeys], whose braces are text the user is meant
/// to read. A new brace-carrying sentence that neither list names turns this red, so the
/// exclusion cannot grow in silence.
void main() {
  late _Corpus corpus;

  setUpAll(() {
    corpus = _Corpus.read();
    loadAppTranslations();
  });

  group('the placeholder scan reads what it claims to read', () {
    test('the locale set is the one the renderers below were written for', () {
      // `_renderers` renders under the `ja` locale. A second locale file would be
      // scanned by the checks below but rendered by nothing, so it has to arrive
      // through this line rather than past it.
      expect(appLocaleFiles(), ['assets/translations/ja.json']);
    });

    test('the scan found the sources, the call sites and the sentences', () {
      // Every assertion in this file is "a set difference is empty", and an empty
      // scan satisfies all of them without reading a line of Dart.
      expect(corpus.dartFiles, greaterThan(200), reason: 'lib/ was not walked');
      expect(corpus.sites, hasLength(greaterThan(800)), reason: 'no .tr() sites found');
      expect(corpus.carriers, hasLength(greaterThan(50)), reason: 'no placeholders found');
      expect(corpus.carriers.keys, contains('pages.storage.delete.target'));
      expect(corpus.carriers['pages.storage.delete.target'], {'name'});
    });

    test('the resolver reaches every kind of key expression it claims to', () {
      // The three resolutions the scan performs, each pinned by a site that only
      // that rule can reach. Without these, a resolver that silently stopped
      // resolving would report "nothing to check" and read as a pass.
      //
      //  * a bare literal;
      //  * a literal whose `$tr_…` prefix is a `const` declared in the same file
      //    (`tr_delete_record` in `delete_record_dialog.dart`);
      //  * a literal with a runtime interpolation, matched as one path segment
      //    (`skill.dart`'s `$tr_skill.mode.${…}.description`).
      expect(corpus.reached, contains('pages.storage.delete.target'));
      expect(corpus.reached, contains('pages.chara_detail.delete_record.bulk.message'));
      expect(corpus.reached, contains('pages.chara_detail.column_predicate.skill.mode.sum_of.description'));
    });
  });

  group('every placeholder in a shipped sentence has a name the call site passes', () {
    test('the check fires on a placeholder nobody passes', () {
      // The negative control. Green below has to mean "the names line up", not
      // "the comparison never compares anything" — so a key is fed a site that
      // passes the wrong name and the check is shown to reject it.
      expect(
        corpus.unfilledAmong(
          {
            'pages.storage.delete.target': {'name'},
          },
          const [
            _FakeSite('pages.storage.delete.target', {'title'}),
          ],
        ),
        {'pages.storage.delete.target'},
      );
      expect(
        corpus.unfilledAmong(
          {
            'pages.storage.delete.target': {'name'},
          },
          const [
            _FakeSite('pages.storage.delete.target', {'name'}),
          ],
        ),
        isEmpty,
      );
    });

    test('no shipped sentence carries a placeholder the code leaves unnamed', () {
      // The main assertion. `_unfilled` is every carrier the scan could not connect
      // to a site passing its names — including a carrier no site reaches at all —
      // and the two exclusions are the lists below, each of which owes its own proof.
      expect(
        corpus.unfilled.difference(_renderers.keys.toSet()).difference(_literalBraceKeys),
        isEmpty,
        reason: 'a placeholder in a locale file has a name no call site passes',
      );
    });

    test('the exclusions name no key the scan already covers', () {
      // The other direction of the same set equality: an exclusion that stopped
      // being needed has to be deleted rather than left standing, or the next
      // reader learns a limitation that no longer exists.
      expect(_renderers.keys.toSet().union(_literalBraceKeys).difference(corpus.unfilled), isEmpty);
    });
  });

  group('the keys the scan cannot reach are rendered by the app itself', () {
    // Five sentences are selected by a value the scan cannot fold — a function
    // call, a parameter, a `namedArgs` map built at runtime. Each is rendered here
    // through the production function that ships it, which is the same instrument
    // `storage_wording_test.dart` uses for `pages.storage.*`.

    test('the detector fires on the sentences nobody filled in', () {
      // The negative control for this group: the raw shipped strings are shown to
      // still carry the braces the assertions below look for, so a green run means
      // the substitution ran rather than that the placeholders were removed.
      for (final key in _renderers.keys) {
        expect(appSentenceAt(key), contains('{'), reason: key);
      }
    });

    test('no brace survives into the sentence the user is shown', () {
      for (final entry in _renderers.entries) {
        final shown = entry.value();
        expect(
          shown,
          isNot(contains('{')),
          reason:
              '${entry.key} renders as "$shown": a placeholder in the locale file has a name '
              'the call site does not pass, so the braces reach the screen',
        );
        expect(shown, isNot(contains('}')), reason: entry.key);
        // And the key itself resolved: `.tr()` renders an unresolved key as the
        // key, which carries no braces and would pass the two above.
        expect(shown, isNot(contains(entry.key)), reason: entry.key);
      }
    });
  });

  group('the braces that are not placeholders are text the user reads', () {
    test('each one survives `.tr()` unchanged, which is what makes it legal', () {
      // The proof the exclusion owes. These braces are not `easy_localization`
      // arguments — they are the addon feature's own substitution tokens and a Dart
      // code sample — so the correct behaviour is that `.tr()` leaves them alone and
      // the user sees them. A key that stopped doing that would be a real defect
      // wearing this exclusion as a disguise.
      for (final key in _literalBraceKeys) {
        expect(key.tr(), appSentenceAt(key), reason: key);
        expect(key.tr(), contains('{'), reason: key);
      }
    });
  });

  group('the sites the scan cannot resolve are enumerated', () {
    test('every argument-bearing call site whose key is opaque is one this list names', () {
      // The limit of the instrument, stated as data. A site that passes arguments
      // but whose key the scan cannot fold is a site where a name mismatch could
      // hide; the keys such a site reaches are covered by `_renderers` instead. This
      // is set equality, so a fourth one cannot appear without failing here — which
      // is what stops the residue from growing quietly.
      expect(corpus.opaqueArgumentSites, {
        // `AppUpdaterGroup.describeFailure` picks the outer template per failure
        // kind and calls `.tr()` on the local — covered by `_renderers`.
        'lib/src/gui/dashboard.dart: template',
        // `videoImportResultText` builds both the key and the `namedArgs` map from
        // the outcome — covered by `_renderers`.
        'lib/src/gui/video_import.dart: key',
        r'lib/src/gui/video_import.dart: $tr_video_import.result.${outcome.kind.name}',
      });
    });
  });
}

/// The sentences whose key the scan cannot fold, rendered the way the app renders them.
///
/// Pinned against the scan by set equality above, so this map cannot fall behind: a
/// sixth such sentence fails the test rather than shipping unwatched.
final Map<String, String Function()> _renderers = {
  // `importRefusalKey(refusal).tr(namedArgs: …)` — key chosen by a function call.
  'pages.chara_detail.import.refused.already_archived': () => _refusalToast(RecordImportRefusal.alreadyArchived),
  'pages.chara_detail.import.refused.not_stored': () => _refusalToast(RecordImportRefusal.notStored),
  // `template.tr(namedArgs: …)` — key chosen by a `switch` into a local.
  'pages.dashboard.app_updater.download_failed.template': () =>
      AppUpdaterGroup.describeFailure(const SocketException('connection reset')),
  'pages.dashboard.app_updater.download_rejected.template': () => AppUpdaterGroup.describeFailure(
    const AppUpdatePayloadException(AppUpdatePayloadKind.installer, 'not a PE image'),
  ),
  // `key.tr(namedArgs: args)` — both the key and the argument map built at runtime.
  'pages.capture.video_import.result.completed_partial': () => videoImportResultText(
    const VideoImportOutcome(
      kind: VideoImportOutcomeKind.completed,
      records: 1,
      sessions: (discarded: 1, unfinished: 0),
    ),
  ),
};

String _refusalToast(RecordImportRefusal refusal) =>
    importRefusalToasts({'record-id': refusal}).single.description ?? '';

/// Sentences whose `{…}` is text rather than an `easy_localization` argument.
///
/// The addon feature substitutes `{record_id}` itself, after `.tr()` has returned, and
/// names that token in its own help text; the script column's hint is a Dart snippet
/// whose braces are Dart's. Each is proved above to reach `.tr()`'s output unchanged.
const Set<String> _literalBraceKeys = {
  'pages.addon.dialog.arguments.helper',
  'pages.addon.dialog.copy_placeholder_hint',
  'pages.addon.dialog.webhook.body_helper',
  'pages.addon.dialog.webhook.url_helper',
  'pages.chara_detail.column_predicate.script.code.hint',
};

// ---------------------------------------------------------------------------
// The scan
// ---------------------------------------------------------------------------

/// One `.tr(` call site, with whatever the scan could work out about it.
class _Site {
  /// The file it sits in, with forward slashes.
  final String file;

  /// The key expression as written, before any `const` was folded into it.
  final String raw;

  /// The folded key, with `\u0000` standing for a segment decided at runtime,
  /// or null when the key expression is opaque (an identifier that is not a
  /// `const` string, a function call, a parameter).
  final String? key;

  /// The `namedArgs` names it passes, or null when the map itself is a variable.
  final Set<String>? named;

  /// The number of positional `args:` it passes, or null when it passes none.
  final int? positional;

  const _Site({required this.file, required this.raw, this.key, this.named, this.positional});

  bool get carriesArguments => named == null || named!.isNotEmpty || positional != null;
}

/// A site with a fixed key and a fixed argument list, for the negative control.
class _FakeSite implements _Site {
  @override
  final String key;
  @override
  final Set<String> named;

  const _FakeSite(this.key, this.named);

  @override
  String get file => '<control>';
  @override
  String get raw => key;
  @override
  int? get positional => null;
  @override
  bool get carriesArguments => true;
}

/// What one pass over `lib/` and the locale files found.
class _Corpus {
  final int dartFiles;
  final List<_Site> sites;

  /// `key -> placeholder names`, unioned over every locale file. The empty string
  /// is the positional form, `{}`.
  final Map<String, Set<String>> carriers;

  /// Every locale key some site resolves to, placeholder-carrying or not.
  final Set<String> reached;

  _Corpus._(this.dartFiles, this.sites, this.carriers, this.reached);

  static _Corpus read() {
    final files = Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
    final sources = {
      for (final file in files) file.path.replaceAll(r'\', '/'): _withoutWholeLineComments(file.readAsStringSync()),
    };
    // A `tr_…` prefix is often declared in one file and imported by another
    // (`capture.dart` names `tr_video_import`), so a file-local table alone leaves
    // those keys unresolved and silently unchecked. Names that more than one file
    // declares differently — `tr_preview`, `tr_chara_detail` — are dropped from the
    // shared table and resolve from the declaring file only.
    final byName = <String, Set<String>>{};
    final perFile = {for (final entry in sources.entries) entry.key: _constStringsIn(entry.value)};
    for (final table in perFile.values) {
      table.forEach((name, value) => byName.putIfAbsent(name, () => <String>{}).add(value));
    }
    final shared = {
      for (final entry in byName.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
    final sites = <_Site>[];
    for (final entry in sources.entries) {
      sites.addAll(_sitesIn(entry.key, entry.value, {...shared, ...perFile[entry.key]!}));
    }
    final carriers = <String, Set<String>>{};
    final known = <String>{};
    for (final path in appLocaleFiles()) {
      final leaves = <String, String>{};
      _walk(localeJson(path), '', leaves);
      known.addAll(leaves.keys);
      for (final entry in leaves.entries) {
        final names = _placeholder.allMatches(entry.value).map((m) => m.group(1) ?? '').toSet();
        if (names.isNotEmpty) {
          carriers.update(entry.key, (existing) => existing..addAll(names), ifAbsent: () => names);
        }
      }
    }
    final reached = <String>{};
    for (final site in sites) {
      reached.addAll(_matches(site, known));
    }
    return _Corpus._(files.length, sites, carriers, reached);
  }

  /// Every carrier whose placeholder names no site that can reach it passes.
  Set<String> get unfilled => unfilledAmong(carriers, sites);

  /// [wanted], restricted to the keys [among] leaves unfilled.
  ///
  /// A key is filled when **some** site that can resolve to it passes every name it
  /// carries. Any-site rather than every-site because an interpolated key resolves
  /// to a whole family of keys and a sibling's placeholders are not that site's to
  /// pass; the cost is that a key served by two sites is excused by the more
  /// generous one, which is why a rename — which breaks every site at once — is
  /// still caught.
  Set<String> unfilledAmong(Map<String, Set<String>> wanted, List<_Site> among) {
    final result = <String>{};
    for (final entry in wanted.entries) {
      var filled = false;
      for (final site in among) {
        if (!_matches(site, {entry.key}).contains(entry.key)) {
          continue;
        }
        final passed = {...?site.named};
        if (site.positional != null && site.positional == _positionalCount(entry.key)) {
          passed.add('');
        }
        if (entry.value.difference(passed).isEmpty) {
          filled = true;
          break;
        }
      }
      if (!filled) {
        result.add(entry.key);
      }
    }
    return result;
  }

  int _positionalCount(String key) => carriers[key]?.contains('') == true
      ? _placeholder.allMatches(appSentenceAt(key)).where((m) => (m.group(1) ?? '').isEmpty).length
      : 0;

  /// `file: expression` for every site that passes arguments but whose key is opaque.
  Set<String> get opaqueArgumentSites => {
    for (final site in sites)
      if (site.carriesArguments && (site.key == null || site.named == null)) '${site.file}: ${site.raw}',
  };
}

final _placeholder = RegExp(r'\{([^{}]*)\}');
final _constDouble = RegExp(r'^[ \t]*const (?:String )?(\w+) = "([^"]*)";', multiLine: true);
final _constSingle = RegExp(r"^[ \t]*const (?:String )?(\w+) = '([^']*)';", multiLine: true);
final _call = RegExp(r'''(?:"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'|([A-Za-z_]\w*))\s*\.tr\(''');
final _namedArgs = RegExp(r'namedArgs\s*:');
final _namedArgsMap = RegExp(r'namedArgs\s*:\s*(?:const\s*)?(?:<[^>]*>\s*)?\{');
final _positionalList = RegExp(r'\bargs\s*:\s*(?:const\s*)?(?:<[^>]*>\s*)?\[');
final _argName = RegExp(r'''["']([A-Za-z_]\w*)["']\s*:''');
final _interpolation = RegExp(r'\$\{[^{}]*\}|\$\w+');

/// A key the runtime decides, standing for exactly one path segment.
const _wildcard = '\u0000';

void _walk(Object? node, String path, Map<String, String> out) {
  if (node is Map<String, dynamic>) {
    node.forEach((key, value) => _walk(value, path.isEmpty ? key : '$path.$key', out));
  } else if (node is String) {
    out[path] = node;
  }
}

/// [source] with its whole-line comments removed.
///
/// A key quoted in prose is not a use of it. Whole-line comments only: a trailing
/// comment can at worst invent a site, which the checks read as one more chance for a
/// key to be filled, never as a missing one.
String _withoutWholeLineComments(String source) =>
    source.split('\n').where((line) => !line.trimLeft().startsWith('//')).join('\n');

/// The `const <name> = '<literal>';` declarations in [body], at any indentation.
Map<String, String> _constStringsIn(String body) => {
  for (final match in [..._constDouble.allMatches(body), ..._constSingle.allMatches(body)])
    match.group(1)!: match.group(2)!,
};

/// Every `.tr(` site in [source], with its key folded as far as [consts] allows.
List<_Site> _sitesIn(String file, String body, Map<String, String> consts) {
  final result = <_Site>[];
  for (final match in _call.allMatches(body)) {
    final literal = match.group(1) ?? match.group(2);
    final identifier = match.group(3);
    final close = _balanced(body, match.end - 1);
    final arguments = body.substring(match.end, close);

    Set<String>? named;
    if (_namedArgs.hasMatch(arguments)) {
      final map = _namedArgsMap.firstMatch(arguments);
      if (map != null) {
        final end = _balanced(arguments, map.end - 1);
        named = _argName.allMatches(arguments.substring(map.end, end)).map((m) => m.group(1)!).toSet();
      }
    } else {
      named = const {};
    }

    int? positional;
    final list = _positionalList.firstMatch(arguments);
    if (list != null) {
      positional = _topLevelItems(arguments.substring(list.end, _balanced(arguments, list.end - 1)));
    }

    final String raw = literal ?? identifier!;
    final String? folded = literal != null
        ? _fold(literal, consts)
        : (consts.containsKey(identifier) ? _fold(consts[identifier]!, consts) : null);
    result.add(_Site(file: file, raw: raw, key: folded, named: named, positional: positional));
  }
  return result;
}

/// [text] with every `$…` replaced by the `const` it names, or by [_wildcard].
String _fold(String text, Map<String, String> consts, [int depth = 0]) {
  if (depth > 4 || !text.contains(r'$')) {
    return text;
  }
  return text.replaceAllMapped(_interpolation, (match) {
    final token = match.group(0)!;
    final name = token.startsWith(r'${') ? token.substring(2, token.length - 1) : token.substring(1);
    final value = consts[name];
    return value == null ? _wildcard : _fold(value, consts, depth + 1);
  });
}

/// The keys in [known] that [site] can name at runtime.
Set<String> _matches(_Site site, Set<String> known) {
  final key = site.key;
  // An identifier with no dot is not a key; an opaque expression names nothing the
  // scan can check.
  if (key == null || !key.contains('.')) {
    return const {};
  }
  if (!key.contains(_wildcard)) {
    return known.contains(key) ? {key} : const {};
  }
  final pattern = RegExp('^${key.split(_wildcard).map(RegExp.escape).join('[^.]*')}\$');
  return known.where(pattern.hasMatch).toSet();
}

/// The index of the bracket closing the one at [open].
int _balanced(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if ('([{'.contains(source[i])) {
      depth++;
    } else if (')]}'.contains(source[i])) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  return source.length;
}

/// How many comma-separated items [body] holds at bracket depth zero.
int _topLevelItems(String body) {
  if (body.trim().isEmpty) {
    return 0;
  }
  var depth = 0;
  var count = 1;
  for (var i = 0; i < body.length; i++) {
    if ('([{'.contains(body[i])) {
      depth++;
    } else if (')]}'.contains(body[i])) {
      depth--;
    } else if (body[i] == ',' && depth == 0) {
      count++;
    }
  }
  return body.trimRight().endsWith(',') ? count - 1 : count;
}
