// Finds the storage view's own sources, and the providers declared in them,
// without naming a file.
//
// WHY THIS EXISTS. Two suites police `storageTabContentProviders`:
// `storage_tab_refresh_test.dart` asserts every provider that needs dropping is
// in it, and `storage_view_reload_test.dart` asserts every watch of a listed
// provider reverts to loading. Both used to read one hard-coded path
// (`lib/src/gui/storage_tree.dart`) with a line-anchored pattern, so a provider
// declared in any other file of the same view — `storage_file_preview.dart`
// already declares two — was outside the scan entirely. A guard that cannot see
// a declaration cannot report it missing.
//
// WHAT "THE VIEW'S OWN SOURCES" MEANS, AS CODE RATHER THAN AS A PATH. Start at
// whichever file declares the roster (found by searching `lib/`, so moving or
// renaming it changes nothing), then take the files it imports, transitively,
// **keeping only those that nothing outside the set imports**. That is the view's
// private sub-library: `storage_file_preview.dart` is in it because only the tree
// imports it, and `providers.dart` is not, because half the app does. The rule is
// about the shape of the import graph, so a new file joins the scan by being
// used, and leaves it by being shared — neither needs a list to be edited.
//
// THE PREDICATE IS ITSELF ASSERTED. "Nothing outside imports it" is a property
// of how the code is written, so importing a view file from one place outside the
// view would drop it out of the scan — silently, with every downstream assertion
// still passing over a smaller view. [providerDeclaringNeighbours] is what makes
// that loud: it is computed from the edges *leaving* the owned set, so a file
// that lost ownership is still on it, and `storage_tab_refresh_test.dart`
// requires every entry to be excused by path with a reason. A view file that
// declares no providers can still fall out unnoticed, and that is intended: the
// roster is a claim about providers, and a file with none takes nothing with it.
//
// Replacing the predicate outright would mean scanning `lib/` whole against a
// place-linked exemption list — 31 non-`autoDispose` `FutureProvider`s live
// outside this view against the 5 inside, so that list would be five times the
// size of what it guards. Ruled out on 2026-09-02.
//
// WHAT DECIDES THE EXEMPTION. `FutureProvider.autoDispose` — read off the
// declaration itself, not off a list of forgiven names. The preview's two are
// exempt because they are `autoDispose`; if either stopped being, the guard would
// start requiring it without anyone remembering to remove an entry.
import 'dart:io';

/// A `FutureProvider` declared in the storage view's own sources.
class StorageViewProvider {
  const StorageViewProvider({required this.name, required this.path, required this.autoDispose});

  /// The variable it is bound to.
  final String name;

  /// The file it is declared in, relative to the repository root.
  final String path;

  /// Whether the declaration is `FutureProvider.autoDispose…`.
  ///
  /// An `autoDispose` provider is dropped by riverpod as soon as the last
  /// listener goes, so nothing has to drop it after a delete; that is the whole
  /// of why the preview's two are outside the roster.
  final bool autoDispose;

  @override
  String toString() => '$name (${autoDispose ? 'autoDispose, ' : ''}$path)';
}

/// The storage view's sources, read off the repository.
class StorageViewSources {
  StorageViewSources._({
    required this.rosterPath,
    required this.rosterNames,
    required this.sources,
    required this.providers,
    required this.providerDeclaringNeighbours,
  });

  /// The file that declares `storageTabContentProviders`.
  final String rosterPath;

  /// The identifiers the roster literal names, in declaration order.
  final List<String> rosterNames;

  /// Path to contents, for every file in the view's private sub-library.
  final Map<String, String> sources;

  /// Every `FutureProvider` declared anywhere in [sources].
  final List<StorageViewProvider> providers;

  /// Files the view imports that declare a `FutureProvider` and are *not* owned.
  ///
  /// This is what turns "the ownership predicate quietly stopped holding" into a
  /// failure. Ownership is computed one way — a file joins only when nothing
  /// outside the set imports it — and this frontier is computed the other way,
  /// from the import edges leaving the set. Import a view file from one place
  /// outside the view and it leaves [sources] silently, but it does not leave
  /// this list, because the view still imports it and it still declares
  /// providers. The suite requires every entry here to be excused in writing.
  final List<String> providerDeclaringNeighbours;

  /// A whole `import` statement, from a line-initial `import` to its semicolon.
  ///
  /// Deliberately not a pattern for one *shape* of import. The repository's 1,751
  /// import statements are written in sixteen combinations of `as`, `show`,
  /// `hide`, conditional `if (dart.library.…)`, `deferred` and line breaks, and
  /// twenty-one of the project-local ones carry at least one of them. A pattern
  /// that ended at `';'` immediately after the URI matched none of those, so
  /// adding ` as x` or ` show Y` to an import was enough to drop the importing
  /// file out of the graph — and the guard with it. So the statement is taken
  /// whole and the URIs are read out of it afterwards.
  static final _importStatement = RegExp(r'^import\b[^;]*;', multiLine: true);
  static final _quoted = RegExp(r"'([^']+)'");
  static final _roster = RegExp(r'storageTabContentProviders = \[(.*?)\];', dotAll: true);
  // Both spellings of a provider declaration, neither anchored to the start of a
  // line: the anchor is what hid the preview's providers from the previous scan.
  //
  //   final foo = FutureProvider…            / … = FutureProvider.autoDispose…
  //   final foo = AutoDisposeFutureProvider… (the generated spelling)
  //   final FutureProvider<X> foo = …        (type-annotated left-hand side)
  static final _valueFirst = RegExp(
    r'\b(?:late\s+)?(?:final|const)\s+(\w+)\s*=\s*(AutoDisposeFutureProvider|FutureProvider(?:\.autoDispose)?)\b',
  );
  static final _typeFirst = RegExp(
    r'\b(?:late\s+)?(?:final|const)\s+(AutoDisposeFutureProvider|FutureProvider)\s*(?:<[^;=]*>)?\s+(\w+)\s*=',
  );

  /// Every URI a single import statement names.
  ///
  /// A conditional import names two, and the importing file depends on both as
  /// far as this graph is concerned: which one a build picks is a platform
  /// decision, and a guard that followed only the default branch would stop
  /// seeing a file the moment someone gave it a web variant.
  static List<String> importUris(String source) {
    return [
      for (final statement in _importStatement.allMatches(source))
        for (final uri in _quoted.allMatches(statement.group(0)!)) uri.group(1)!,
    ];
  }

  /// Every `FutureProvider` [source] declares, in either spelling.
  ///
  /// A form this cannot read is a provider it reports as absent, so the shapes it
  /// covers are pinned by `storage_view_sources_test.dart` rather than assumed.
  static List<({String name, bool autoDispose})> declarationsIn(String source) {
    final found = <({String name, bool autoDispose})>[];
    for (final match in _valueFirst.allMatches(source)) {
      found.add((name: match.group(1)!, autoDispose: match.group(2)!.contains('utoDispose')));
    }
    for (final match in _typeFirst.allMatches(source)) {
      found.add((name: match.group(2)!, autoDispose: match.group(1)!.contains('utoDispose')));
    }
    return found;
  }

  /// Resolves an import URI written in [from] to a repository-relative path.
  ///
  /// Returns an empty string for a `package:` or `dart:` URI, which names no file
  /// inside `lib/`.
  static String resolveImport(String from, String spec) => _resolve(from, spec);

  static String _resolve(String from, String spec) {
    if (spec.startsWith('package:') || spec.startsWith('dart:')) {
      return '';
    }
    if (spec.startsWith('/src/')) {
      return 'lib$spec';
    }
    final segments = <String>[];
    for (final part in [...from.substring(0, from.lastIndexOf('/')).split('/'), ...spec.split('/')]) {
      if (part.isEmpty || part == '.') {
        continue;
      } else if (part == '..') {
        if (segments.isNotEmpty) {
          segments.removeLast();
        }
      } else {
        segments.add(part);
      }
    }
    return segments.join('/');
  }

  /// Walks `lib/` and works out which of it the storage view privately owns.
  static StorageViewSources read() {
    final all = <String, String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        all[entity.path.replaceAll('\\', '/')] = entity.readAsStringSync();
      }
    }

    final importsOf = <String, Set<String>>{};
    final importersOf = {for (final path in all.keys) path: <String>{}};
    for (final entry in all.entries) {
      final targets = <String>{};
      for (final uri in importUris(entry.value)) {
        final target = _resolve(entry.key, uri);
        if (all.containsKey(target)) {
          targets.add(target);
          importersOf[target]!.add(entry.key);
        }
      }
      importsOf[entry.key] = targets;
    }

    final roster = all.entries.where((entry) => _roster.hasMatch(entry.value)).toList();
    if (roster.length != 1) {
      throw StateError('expected exactly one declaration of storageTabContentProviders, found ${roster.length}');
    }

    // Grow the private sub-library: a dependency joins only once every file that
    // imports it is already inside.
    final owned = <String>{roster.single.key};
    for (var changed = true; changed;) {
      changed = false;
      for (final path in owned.toList()) {
        for (final target in importsOf[path]!) {
          if (!owned.contains(target) && importersOf[target]!.every(owned.contains)) {
            owned.add(target);
            changed = true;
          }
        }
      }
    }

    final sources = {for (final path in owned) path: all[path]!};
    final providers = <StorageViewProvider>[];
    for (final path in owned.toList()..sort()) {
      for (final declaration in declarationsIn(sources[path]!)) {
        providers.add(StorageViewProvider(name: declaration.name, path: path, autoDispose: declaration.autoDispose));
      }
    }

    // Computed from the edges *leaving* the set, so it does not restate how the
    // set was built: a file that fell out of ownership because someone outside
    // imported it is still on this frontier.
    final neighbours = <String>{};
    for (final path in owned) {
      for (final target in importsOf[path]!) {
        if (!owned.contains(target) && declarationsIn(all[target]!).isNotEmpty) {
          neighbours.add(target);
        }
      }
    }

    final listed = _roster.firstMatch(roster.single.value)!.group(1)!;
    return StorageViewSources._(
      rosterPath: roster.single.key,
      rosterNames: RegExp(r'\w+').allMatches(listed).map((match) => match[0]!).toList(),
      sources: sources,
      providers: providers,
      providerDeclaringNeighbours: neighbours.toList()..sort(),
    );
  }

  /// Whether the roster literal names [name].
  bool rosterContains(String name) => rosterNames.contains(name);
}
