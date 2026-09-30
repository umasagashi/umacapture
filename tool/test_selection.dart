/// Decides which Dart test files CI runs, and where, from a scan of `test/`.
///
///     dart tool/test_selection.dart vm <shard-index> <shard-count>   # one VM shard's files
///     dart tool/test_selection.dart browser                          # the browser suites
///     dart tool/test_selection.dart summary <shard-count>            # every list, for a human
///
/// Each mode prints one repository-relative path per line on stdout; diagnostics go to stderr.
/// `<shard-index>` is zero-based, matching `strategy.job-index` in `.github/workflows/ci.yml`. Run
/// it as `dart <file>`, not `dart run`: `dart run` would first run the package's native build hooks.
///
/// WHY A SCAN AND NOT A LIST. A test file that is not named on any command line is run by
/// nothing, and a hand-kept list says nothing when a new file is left off it. Every file this
/// prints is derived from what is on disk, with the same rule `flutter test` and `dart test` use
/// when they are given a directory: a file under `test/` whose name ends in `_test.dart`.
///
/// ROUTING. A file whose library carries `@TestOn('browser')` goes to the browser job
/// (`dart test --platform chrome`); every other file goes to the VM shards (`flutter test`). The
/// VM runner skips a browser-only file without compiling it and `dart test` cannot compile a file
/// that reaches `package:flutter`, so each file has exactly one runner that executes it. Any other
/// `@TestOn` selector is refused rather than guessed at: routing it would take a decision about
/// which job owns that platform, and until someone makes it, a silent default could leave the file
/// run by neither.
///
/// The annotation is read the way the test runner reads it (`parseMetadata` in `package:test_core`):
/// parsed, from the metadata of the file's first directive, with a `TestOn` under an import prefix
/// (`@t.TestOn(...)`) counted as `TestOn`. Text that only looks like an annotation, in a comment or
/// a string, is therefore not one, and an annotation the runner honours is never missed.
///
/// WHAT IS CHECKED ON EVERY INVOCATION, before anything is printed, so a broken selection fails
/// the job that asked for it instead of quietly shrinking what runs:
///  * every `*_test.dart` file is routed to exactly one of the two sets;
///  * the VM shards are pairwise disjoint, none is empty, and together they are exactly the VM set;
///  * the browser list is exactly the set of files carrying `@TestOn('browser')`, and is not
///    empty (an empty argument list would make `dart test` fall back to the whole directory).
///
/// ORDER AND BALANCE only affect speed. `flutter test` compiles one file at a time and starts the
/// suites in the order they are named, so a shard's time is roughly its file count times the
/// per-file compile cost, unless a single long suite is still running after the rest have
/// finished. Files are therefore handed out longest-first to the currently lightest shard, and
/// each shard lists its files longest-first, so a long suite runs while the others compile.
library;

import "dart:io";

import "package:analyzer/dart/analysis/utilities.dart";
import "package:analyzer/dart/ast/ast.dart";

/// Serial compile cost of one test file, in seconds: the interval at which new suites started
/// reporting in the CI `Run tests` step (1.2-1.4 s on the 4-vCPU windows-2022 runner).
const double compileSeconds = 1.3;

/// The `-j` the shards pass to `flutter test`; execution overlaps across that many suites.
const int concurrency = 4;

/// Execution seconds assumed for a file absent from [measuredExecutionSeconds]: the median over
/// all VM files in the measurement below.
const double defaultExecutionSeconds = 0.5;

/// Execution time of the files that take 8 s or more, in seconds. Measured on 2026-09-30 at
/// `961fe519` with `flutter test -j 4 --reporter json test` on a 24-thread Windows machine: the
/// mean of two full runs of the sum of each file's visible test durations plus its
/// `setUpAll`/`tearDownAll`. A stale or missing entry only makes the shards less even; it never
/// changes which files run. The `web_record_write_protocol_v2*` entries were measured the same way
/// but one file at a time (`flutter test --reporter json <file>`), on the same machine, when that
/// suite was split into them.
const Map<String, double> measuredExecutionSeconds = {
  "test/storage_tree_context_menu_test.dart": 55.4,
  "test/enhancement_merge_test.dart": 31.8,
  "test/storage_row_menu_gate_test.dart": 27.9,
  "test/web_record_write_protocol_v2_update_test.dart": 24.9,
  "test/storage_tree_test.dart": 23.3,
  "test/web_record_write_protocol_v2_same_store_test.dart": 22.9,
  "test/web_record_write_protocol_v2_single_stops_test.dart": 21.9,
  "test/web_record_write_protocol_v2_archive_to_active_test.dart": 21.7,
  "test/web_record_write_protocol_v2_active_to_archive_test.dart": 21.6,
  "test/web_record_write_protocol_v2_test.dart": 16.4,
  "test/enhancement_merge_ui_test.dart": 16.5,
  "test/report_import_controls_test.dart": 15.0,
  "test/storage_file_preview_view_test.dart": 14.6,
  "test/storage_settings_store_menu_test.dart": 13.1,
  "test/storage_long_read_extract_gate_test.dart": 11.3,
  "test/report_import_frame_step_test.dart": 11.1,
  "test/storage_delete_action_test.dart": 10.5,
  "test/storage_dialog_entry_test.dart": 8.8,
  "test/storage_zip_export_test.dart": 8.1,
  "test/storage_extract_capture_gate_test.dart": 8.0,
};

class Selection {
  Selection(this.vm, this.browser);

  final List<String> vm;
  final List<String> browser;
}

void main(List<String> args) {
  final problems = <String>[];
  final selection = _scan(Directory("test"), problems);
  final mode = args.isEmpty ? "" : args.first;
  final shardCount = switch (mode) {
    "vm" when args.length == 3 => int.tryParse(args[2]),
    "summary" when args.length == 2 => int.tryParse(args[1]),
    "browser" when args.length == 1 => 1,
    _ => null,
  };
  if (shardCount == null || shardCount < 1) {
    _fail("usage: dart tool/test_selection.dart (vm <shard-index> <shard-count> | browser | summary <shard-count>)");
  }
  final shards = _assign(selection.vm, shardCount);
  _checkPartition(selection, shards, problems);
  if (problems.isNotEmpty) {
    _fail("test selection is inconsistent; nothing was run:", problems);
  }

  switch (mode) {
    case "vm":
      final index = int.tryParse(args[1]);
      if (index == null || index < 0 || index >= shardCount) {
        _fail("shard index ${args[1]} is outside 0..${shardCount - 1}");
      }
      _report(selection, shards);
      shards[index].forEach(stdout.writeln);
    case "browser":
      _report(selection, null);
      selection.browser.forEach(stdout.writeln);
    case "summary":
      _report(selection, shards);
      for (var i = 0; i < shards.length; i++) {
        stdout.writeln("# vm shard $i (${shards[i].length} files)");
        shards[i].forEach(stdout.writeln);
      }
      stdout.writeln("# browser (${selection.browser.length} files)");
      selection.browser.forEach(stdout.writeln);
  }
}

Selection _scan(Directory root, List<String> problems) {
  if (!root.existsSync()) {
    _fail("run from the repository root: ${root.path}/ not found");
  }
  final files =
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((file) => file.path.replaceAll(r"\", "/"))
          .where((path) => path.endsWith("_test.dart"))
          .toList()
        ..sort();
  final vm = <String>[];
  final browser = <String>[];
  for (final path in files) {
    final testOn = _testOnAnnotations(File(path).readAsStringSync(), path);
    if (testOn.isEmpty) {
      vm.add(path);
    } else if (testOn.length > 1) {
      problems.add("$path: more than one @TestOn annotation");
    } else if (_singleStringArgument(testOn.single) == "browser") {
      browser.add(path);
    } else {
      problems.add(
        "$path: ${testOn.single.toSource()} is not routed to any job; only 'browser' is "
        "(extend tool/test_selection.dart and the workflow together)",
      );
    }
  }
  return Selection(vm, browser);
}

/// The `TestOn` annotations on the file's library, found where the test runner looks: on the first
/// directive. `p.TestOn` counts when `p` is an import prefix; otherwise the runner reads `p.TestOn`
/// as the named constructor `TestOn` of a class `p`, which does not count.
List<Annotation> _testOnAnnotations(String source, String path) {
  final directives = parseString(content: source, path: path, throwIfDiagnostics: false).unit.directives;
  if (directives.isEmpty) return const [];
  final prefixes = {
    for (final directive in directives.whereType<ImportDirective>())
      if (directive.prefix case final prefix?) prefix.name,
  };
  return [
    for (final annotation in directives.first.metadata)
      if (_className(annotation, prefixes) == "TestOn") annotation,
  ];
}

String _className(Annotation annotation, Set<String> prefixes) => switch (annotation.name) {
  PrefixedIdentifier(:final prefix, :final identifier)
      when prefixes.contains(prefix.name) || annotation.constructorName != null =>
    identifier.name,
  PrefixedIdentifier(:final prefix) => prefix.name,
  final name => name.name,
};

/// The value of the annotation's only argument when it is a string literal without interpolation;
/// null otherwise, which the caller refuses.
String? _singleStringArgument(Annotation annotation) => switch (annotation.arguments?.arguments) {
  [StringLiteral(:final stringValue)] => stringValue,
  _ => null,
};

double _weight(String path) =>
    compileSeconds + (measuredExecutionSeconds[path] ?? defaultExecutionSeconds) / concurrency;

/// Longest-processing-time-first assignment; ties break on the path so every job computes the
/// same shards from the same checkout.
List<List<String>> _assign(List<String> files, int shardCount) {
  final ordered = [...files]
    ..sort((a, b) {
      final byWeight = _weight(b).compareTo(_weight(a));
      return byWeight != 0 ? byWeight : a.compareTo(b);
    });
  final shards = List.generate(shardCount, (_) => <String>[]);
  final loads = List.filled(shardCount, 0.0);
  for (final path in ordered) {
    var lightest = 0;
    for (var i = 1; i < shardCount; i++) {
      if (loads[i] < loads[lightest]) lightest = i;
    }
    shards[lightest].add(path);
    loads[lightest] += _weight(path);
  }
  return shards;
}

void _checkPartition(Selection selection, List<List<String>> shards, List<String> problems) {
  final vmSet = selection.vm.toSet();
  final browserSet = selection.browser.toSet();
  for (final path in vmSet.intersection(browserSet)) {
    problems.add("$path: routed to both the VM shards and the browser job");
  }
  final seen = <String, int>{};
  for (var i = 0; i < shards.length; i++) {
    if (shards[i].isEmpty) problems.add("vm shard $i is empty");
    for (final path in shards[i]) {
      final previous = seen[path];
      if (previous != null) problems.add("$path: in vm shards $previous and $i");
      seen[path] = i;
    }
  }
  for (final path in vmSet.difference(seen.keys.toSet())) {
    problems.add("$path: a VM test file in no shard");
  }
  for (final path in seen.keys.toSet().difference(vmSet)) {
    problems.add("$path: in a shard but not a VM test file");
  }
  if (browserSet.isEmpty) {
    problems.add("no @TestOn('browser') file found; the browser job would run the whole test/ directory");
  }
  for (final path in selection.browser) {
    if (path.contains(RegExp(r"\s"))) problems.add("$path: whitespace in a path the workflow word-splits");
  }
}

/// [shards] is null for the browser job, which has no use for the VM shard sizes.
void _report(Selection selection, List<List<String>>? shards) {
  final sizes = [
    for (final shard in shards ?? const <List<String>>[])
      "${shard.length} (~${shard.fold(0.0, (s, p) => s + _weight(p)).round()} s)",
  ];
  stderr.writeln(
    "test selection: ${selection.vm.length + selection.browser.length} test files = "
    "${selection.vm.length} VM + ${selection.browser.length} browser"
    "${shards == null ? "" : "; VM shards: ${sizes.join(", ")}"}",
  );
  for (final path in measuredExecutionSeconds.keys) {
    if (!selection.vm.contains(path)) {
      stderr.writeln("note: the execution-time table names $path, which is not a VM test file (balance only)");
    }
  }
}

Never _fail(String headline, [List<String> problems = const []]) {
  stderr.writeln(headline);
  for (final problem in problems) {
    stderr.writeln("  $problem");
  }
  exit(1);
}
