// The instrument that `storage_tab_refresh_test.dart` and
// `storage_view_reload_test.dart` both aim, tested on its own.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_view_sources_test.dart
//
// WHY THIS FILE EXISTS. `StorageViewSources` decides which files the storage view
// owns and which providers they declare, by reading Dart source as text. Both
// suites that use it assert "nothing is missing" — a claim a scanner satisfies by
// failing to look. So the scanner's two text-facing halves, the import parser and
// the declaration parser, are pinned here against the forms the repository
// actually contains rather than against the form whoever wrote the pattern had in
// mind. The first version parsed `import 'x.dart';` and nothing else; adding
// ` as x` or ` show Y` to one import in the view was enough to make every
// assertion downstream vacuous, and nothing here or there would have said so.
//
// WHAT IT STILL CANNOT READ, stated rather than discovered later:
//   * an `export` that re-exports a provider — the graph follows `import` only;
//   * an import whose URI is not a single-quoted literal (a raw or double-quoted
//     string), which the repository does not contain and `dart format` does not
//     produce;
//   * a provider built by a function call rather than declared
//     (`someHelper<int>(…)` returning a `FutureProvider`);
//   * `.future` suppression in the reload suite is decided per line, so a watch
//     split across two lines with `.future` on the second is counted as a watch
//     needing `unwrapPrevious()`. That direction is fail-safe: it over-reports.
import 'package:flutter_test/flutter_test.dart';

import 'support/storage_view_sources.dart';

void main() {
  group('the import parser reads every form the repository writes', () {
    // The counts are the ones measured over lib/ (1,751 statements): plain,
    // `as`, `show`, `hide`, conditional, multiline and their combinations. Each
    // case below is a form that exists in the tree, not an invented one.
    const cases = <String, List<String>>{
      "import '/src/core/providers.dart';": ['/src/core/providers.dart'],
      "import 'src/core/mapper_init.dart';": ['src/core/mapper_init.dart'],
      "import 'package:flutter/material.dart';": ['package:flutter/material.dart'],
      "import 'dart:async';": ['dart:async'],
      "import 'package:path/path.dart' as path;": ['package:path/path.dart'],
      "import '/src/chara_detail/archive_executor.dart' as archive_executor;": [
        '/src/chara_detail/archive_executor.dart',
      ],
      "import '/src/core/clipboard_image_writer.dart' show ClipboardImageLoader, ClipboardWriter;": [
        '/src/core/clipboard_image_writer.dart',
      ],
      "import 'package:flutter/material.dart' hide Flow;": ['package:flutter/material.dart'],
      "import 'fs_backend_io.dart' if (dart.library.js_interop) 'fs_backend_web.dart';": [
        'fs_backend_io.dart',
        'fs_backend_web.dart',
      ],
      "import 'a.dart'\n    if (dart.library.js_interop) 'b.dart'\n    as writer;": ['a.dart', 'b.dart'],
      "import 'a.dart' deferred as later;": ['a.dart'],
      "import '/src/core/fs/record_directory_transaction.dart'\n    show quarantineDirectoryInto, retireEntryInto;": [
        '/src/core/fs/record_directory_transaction.dart',
      ],
    };

    cases.forEach((source, expected) {
      test('parses ${source.split('\n').first.trim()}', () {
        expect(StorageViewSources.importUris(source), expected);
      });
    });

    test('a conditional import contributes both branches', () {
      final uris = StorageViewSources.importUris("import 'io.dart' if (dart.library.js_interop) 'web.dart';");
      expect(uris, hasLength(2));
    });

    test('an indented occurrence of the word import in a comment is not a statement', () {
      expect(StorageViewSources.importUris("  // import 'ghost.dart';"), isEmpty);
    });
  });

  group('import URIs resolve to repository paths', () {
    test('a rooted URI is the lib-relative path', () {
      expect(
        StorageViewSources.resolveImport('lib/src/gui/storage_tree.dart', '/src/core/providers.dart'),
        'lib/src/core/providers.dart',
      );
    });

    test('a relative URI resolves against the importing file', () {
      expect(
        StorageViewSources.resolveImport('lib/src/core/fs/fs_backend.dart', 'fs_backend_io.dart'),
        'lib/src/core/fs/fs_backend_io.dart',
      );
    });

    test('a relative URI climbs out of its directory', () {
      expect(
        StorageViewSources.resolveImport('lib/src/core/fs/fs_backend.dart', '../providers.dart'),
        'lib/src/core/providers.dart',
      );
    });

    test('package: and dart: URIs name no file in the tree', () {
      expect(StorageViewSources.resolveImport('lib/main.dart', 'package:flutter/material.dart'), '');
      expect(StorageViewSources.resolveImport('lib/main.dart', 'dart:io'), '');
    });
  });

  group('the declaration parser reads every spelling of a FutureProvider', () {
    ({String name, bool autoDispose}) only(String source) {
      final found = StorageViewSources.declarationsIn(source);
      expect(found, hasLength(1), reason: 'expected exactly one declaration in: $source');
      return found.single;
    }

    test('the plain form', () {
      expect(only('final a = FutureProvider<int>((ref) => 0);'), (name: 'a', autoDispose: false));
    });

    test('the family form', () {
      expect(only('final b = FutureProvider.family<int, String>((ref, x) => 0);'), (name: 'b', autoDispose: false));
    });

    test('the autoDispose form is recognised as exempt', () {
      expect(only('final c = FutureProvider.autoDispose.family<int, String>((ref, x) => 0);'), (
        name: 'c',
        autoDispose: true,
      ));
    });

    test('the generated AutoDisposeFutureProvider spelling is recognised as exempt', () {
      expect(only('final d = AutoDisposeFutureProvider<int>((ref) => 0);'), (name: 'd', autoDispose: true));
    });

    test('a type-annotated left-hand side is still a declaration', () {
      expect(only('final FutureProvider<int> e = FutureProvider<int>((ref) => 0);'), (name: 'e', autoDispose: false));
    });

    test('an indented declaration is still a declaration', () {
      expect(only('  final f = FutureProvider<int>((ref) => 0);'), (name: 'f', autoDispose: false));
    });

    test('a Provider that is not a FutureProvider is not a declaration', () {
      expect(StorageViewSources.declarationsIn('final g = Provider<bool>((ref) => true);'), isEmpty);
      expect(StorageViewSources.declarationsIn('final h = NotifierProvider<N, int>(N.new);'), isEmpty);
    });
  });

  group('the instrument, aimed at the repository, still resolves the view', () {
    // A cheap end-to-end check that the parsers above are wired to the walk: if
    // either stopped matching, the closure would collapse to the one file the
    // roster is declared in and this would fail.
    test('the view owns more than the file its roster is declared in', () {
      final view = StorageViewSources.read();
      expect(view.sources.keys, contains(view.rosterPath));
      expect(view.sources, hasLength(greaterThan(1)));
      expect(view.providers.map((provider) => provider.path).toSet(), hasLength(greaterThan(1)));
    });
  });
}
