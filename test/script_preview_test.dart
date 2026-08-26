// Verifies the preview runner: it executes filter/display in a killable isolate
// and rejects scripts that fail to compile, throw, or run too long (the only
// guard that keeps an infinite-loop script from being saved).
//
// The `in-process (web path)` group covers the same runner with `inProcess: true`,
// which is what web gets because `Isolate.spawn` throws `UnsupportedError` there.
// It runs on the VM here, so it exercises the code path, not the platform.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/script_preview_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/script.dart';
import 'package:umacapture/src/chara_detail/spec/script_facade.dart';

Map<String, dynamic> sampleRecord() => {
  'id': 'rec-1',
  'evaluationValue': 12345,
  'fans': 67890,
  'trainedDate': '2026/01/02',
  'ratings': {'main': 4.5},
  'status': {'speed': 1200, 'stamina': 900, 'power': 800, 'guts': 400, 'intelligence': 600},
  'aptitudes': {
    'ground': {
      'turf': {'code': 7, 'name': 'A'},
      'dirt': {'code': 1, 'name': 'G'},
    },
    'distance': {
      'short': {'code': 1, 'name': 'G'},
      'mile': {'code': 4, 'name': 'C'},
      'middle': {'code': 7, 'name': 'A'},
      'long': {'code': 6, 'name': 'B'},
    },
    'style': {
      'leadPace': {'code': 7, 'name': 'A'},
      'withPace': {'code': 5, 'name': 'C'},
      'offPace': {'code': 1, 'name': 'G'},
      'lateCharge': {'code': 1, 'name': 'G'},
    },
  },
  'skills': <Map<String, dynamic>>[],
  'factors': <Map<String, dynamic>>[],
  'factorGroups': <Map<String, dynamic>>[],
  'races': <Map<String, dynamic>>[],
  'supportCards': <Map<String, dynamic>>[],
  'scenario': {'id': 7, 'name': 'アオハル杯'},
  'metadata': {
    'recordType': {'code': 0, 'name': '標準'},
    'strategy': {'code': 1, 'name': '先行'},
    'isFriend': false,
  },
};

// The cases below assert what the runner produces, not how long it is allowed to
// take, so they state both budgets far beyond any scheduling delay instead of
// inheriting the product ones. Under a saturated runner neither the 3 s execution
// budget nor the 30 s spawn/compile budget is a safe assumption even for a trivial
// script, and a functional assertion must not turn into a wall-clock measurement.
// The guard itself is pinned by the infinite-loop case and by the case above it,
// which state the budget they mean to exercise.
const _functionalBudget = Duration(minutes: 5);

void main() {
  final records = [for (var i = 0; i < 5; i++) sampleRecord()];

  test('a valid script previews ok with timing', () async {
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => r.status.speed >= 1000;\n'
      'dynamic display(CharaRecord r) => r.status.speed;',
      records,
      executionBudget: _functionalBudget,
      startupBudget: _functionalBudget,
    );
    expect(result.ok, isTrue);
    expect(result.timedOut, isFalse);
    expect(result.compileError, isNull);
    expect(result.rows.length, records.length);
    expect(result.rows.every((r) => r.visible), isTrue);
    expect(result.rows.first.display, '1200');
    expect(result.microsPerRecord, greaterThan(0));
  });

  test('a compile error is reported and not ok', () async {
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => r.status.speed >=;\n'
      'dynamic display(CharaRecord r) => 1;',
      records,
      executionBudget: _functionalBudget,
      startupBudget: _functionalBudget,
    );
    expect(result.ok, isFalse);
    expect(result.compileError, isNotNull);
  });

  test('the execution budget is not charged for spawning and compiling', () async {
    // Pins what the budget covers. A compile error is produced before any record
    // runs, so it must still be reported with no execution budget at all; when the
    // budget also covered isolate spawn plus the in-isolate compile, this reported a
    // timeout instead -- and, on a loaded machine, so did a perfectly fast script.
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => r.status.speed >=;\n'
      'dynamic display(CharaRecord r) => 1;',
      records,
      executionBudget: Duration.zero,
      startupBudget: _functionalBudget,
    );
    expect(result.compileError, isNotNull);
    expect(result.timedOut, isFalse);
  });

  test('a runtime exception surfaces on the offending row and is not ok', () async {
    // first on an empty collection throws.
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => r.skills.first.name;',
      records,
      executionBudget: _functionalBudget,
      startupBudget: _functionalBudget,
    );
    expect(result.ok, isFalse);
    expect(result.rows.any((r) => r.error != null), isTrue);
  });

  test('an infinite loop is killed by the timeout and rejected', () async {
    // A short budget, stated here rather than inherited: the mechanism is what is
    // under test, and a script that never returns trips any budget. Overshooting
    // it under load only delays the kill, so this direction cannot flake.
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) { while (true) {} }\n'
      'dynamic display(CharaRecord r) => 1;',
      records,
      executionBudget: const Duration(milliseconds: 200),
      startupBudget: _functionalBudget,
    );
    expect(result.timedOut, isTrue);
    expect(result.ok, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('returning a facade object instead of a value or Cell is an error', () async {
    // `r.scenario` is a Scenario object, not a value; this used to render a silent
    // blank. It must now surface as an error so the save stays gated.
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => r.scenario;',
      records,
      executionBudget: _functionalBudget,
      startupBudget: _functionalBudget,
    );
    expect(result.ok, isFalse);
    expect(result.rows.every((r) => r.error != null), isTrue);
  });

  test('Cell display text is kept with an independent numeric sort key', () async {
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => Cell("fast", sort: r.status.speed);',
      records,
      executionBudget: _functionalBudget,
      startupBudget: _functionalBudget,
    );
    expect(result.ok, isTrue);
    expect(result.rows.first.display, 'fast');
    expect(result.rows.first.sortValue, 1200);
  });

  test('a mapped list still joins (ValueList routes through the List path)', () async {
    final withSkills = sampleRecord();
    withSkills['skills'] = <Map<String, dynamic>>[
      {'id': 1, 'level': 1, 'name': 'A', 'tags': <String>[]},
      {'id': 2, 'level': 1, 'name': 'B', 'tags': <String>[]},
    ];
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => r.skills.map((s) => s.name).join("/");',
      [withSkills],
      executionBudget: _functionalBudget,
      startupBudget: _functionalBudget,
    );
    expect(result.ok, isTrue);
    expect(result.rows.first.display, 'A/B');
  });

  group('in-process (web path)', () {
    // A per-record loop heavy enough that one record costs measurable time, but
    // that always terminates: the in-process path has no way to interrupt a record
    // mid-flight, so a test may never hand it one that does not return.
    const heavy =
        'bool filter(CharaRecord r) { var i = 0; while (i < 20000) { i = i + 1; } return true; }\n'
        'dynamic display(CharaRecord r) => 1;';

    test('a valid script previews ok with timing, without an isolate', () async {
      final result = await runScriptPreview(
        'bool filter(CharaRecord r) => r.status.speed >= 1000;\n'
        'dynamic display(CharaRecord r) => r.status.speed;',
        records,
        inProcess: true,
        executionBudget: _functionalBudget,
      );
      expect(result.ok, isTrue);
      expect(result.timedOut, isFalse);
      expect(result.rows.length, records.length);
      expect(result.rows.first.display, '1200');
      expect(result.microsPerRecord, greaterThan(0));
    });

    test('the pass really runs on the calling isolate', () async {
      // Distinguishes the two paths by an effect only the in-process one can have:
      // the name -> code tables are a library global, so installing them is visible
      // here afterwards, whereas the isolate path installs them in the child. Without
      // this, every case below would also pass if the dispatch quietly kept spawning.
      addTearDown(() => scriptCodeTables = const {});
      scriptCodeTables = const {};
      await runScriptPreview(
        'bool filter(CharaRecord r) => true;\n'
        'dynamic display(CharaRecord r) => 1;',
        records,
        inProcess: true,
        tables: const {
          'trainee': {'name': 3},
        },
        executionBudget: _functionalBudget,
      );
      expect(scriptCodeTables['trainee']?['name'], 3);
    });

    test('the isolate and in-process paths agree on the same script', () async {
      const source =
          'bool filter(CharaRecord r) => r.status.speed >= 1000;\n'
          'dynamic display(CharaRecord r) => Cell("fast", sort: r.status.speed);';
      final spawned = await runScriptPreview(source, records, executionBudget: _functionalBudget);
      final inline = await runScriptPreview(source, records, inProcess: true, executionBudget: _functionalBudget);
      expect(inline.ok, spawned.ok);
      expect(inline.rows.length, spawned.rows.length);
      expect([for (final r in inline.rows) r.display], [for (final r in spawned.rows) r.display]);
      expect([for (final r in inline.rows) r.sortValue], [for (final r in spawned.rows) r.sortValue]);
    });

    test('a compile error is reported and not ok', () async {
      final result = await runScriptPreview(
        'bool filter(CharaRecord r) => r.status.speed >=;\n'
        'dynamic display(CharaRecord r) => 1;',
        records,
        inProcess: true,
        executionBudget: _functionalBudget,
      );
      expect(result.ok, isFalse);
      expect(result.compileError, isNotNull);
    });

    test('the execution budget is not charged for compiling', () async {
      // Same contract as the isolate path: compilation precedes the stopwatch, so a
      // compile error is still reported with no execution budget at all.
      final result = await runScriptPreview(
        'bool filter(CharaRecord r) => r.status.speed >=;\n'
        'dynamic display(CharaRecord r) => 1;',
        records,
        inProcess: true,
        executionBudget: Duration.zero,
      );
      expect(result.compileError, isNotNull);
      expect(result.timedOut, isFalse);
    });

    test('a runtime exception surfaces on the offending row and is not ok', () async {
      final result = await runScriptPreview(
        'bool filter(CharaRecord r) => true;\n'
        'dynamic display(CharaRecord r) => r.skills.first.name;',
        records,
        inProcess: true,
        executionBudget: _functionalBudget,
      );
      expect(result.ok, isFalse);
      expect(result.rows.any((r) => r.error != null), isTrue);
    });

    test('a script that overruns the budget is rejected, with no partial rows', () async {
      // The save gate is what this pins: an over-budget script reports the same
      // timeout a killed isolate does, so it cannot be saved on either platform.
      // Duration.zero makes the direction exact -- any elapsed time trips it after
      // the first record -- rather than racing a wall clock.
      final result = await runScriptPreview(heavy, records, inProcess: true, executionBudget: Duration.zero);
      expect(result.timedOut, isTrue);
      expect(result.ok, isFalse);
      expect(result.rows, isEmpty);
    });

    test('a script too slow across the record set is aborted between records', () async {
      // The realistic shape of the guard that survives on web: cost accumulates over
      // the set and is caught at a record boundary. The budget is derived from this
      // machine's measured per-record cost rather than stated in milliseconds, so a
      // faster interpreter cannot turn the whole set into a pass; overshooting it
      // under load only delays the abort, so this direction cannot flake either.
      final calibration = await runScriptPreview(
        heavy,
        [sampleRecord()],
        inProcess: true,
        executionBudget: _functionalBudget,
      );
      expect(calibration.ok, isTrue);
      expect(calibration.microsPerRecord, greaterThan(0));
      final many = [for (var i = 0; i < 200; i++) sampleRecord()];
      final result = await runScriptPreview(
        heavy,
        many,
        inProcess: true,
        executionBudget: Duration(microseconds: (calibration.microsPerRecord * 10).ceil()),
      );
      expect(result.timedOut, isTrue);
      expect(result.ok, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('ScriptCellResult normalization', () {
    test('primitives and lists map to display/sort', () {
      expect(ScriptCellResult.fromDisplay(42).sortValue, 42);
      expect(ScriptCellResult.fromDisplay(42).display, '42');
      expect(ScriptCellResult.fromDisplay(['a', 'b']).display, 'a, b');
      expect(ScriptCellResult.fromDisplay(null).display, '');
    });

    test('a bare object (Map) is an error, a Cell map is not', () {
      expect(ScriptCellResult.fromDisplay({'code': 7, 'name': 'A'}).error, isNotNull);
      final cell = ScriptCellResult.fromCell({'display': 'x', 'sort': 5});
      expect(cell.error, isNull);
      expect(cell.display, 'x');
      expect(cell.sortValue, 5);
    });
  });
}
