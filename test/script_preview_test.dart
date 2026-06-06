// Verifies the preview runner: it executes filter/display in a killable isolate
// and rejects scripts that fail to compile, throw, or run too long (the only
// guard that keeps an infinite-loop script from being saved).
//
// Run: .fvm/flutter_sdk/bin/flutter test test/script_preview_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/script.dart';

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

void main() {
  final records = [for (var i = 0; i < 5; i++) sampleRecord()];

  test('a valid script previews ok with timing', () async {
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => r.status.speed >= 1000;\n'
      'dynamic display(CharaRecord r) => r.status.speed;',
      records,
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
    );
    expect(result.ok, isFalse);
    expect(result.compileError, isNotNull);
  });

  test('a runtime exception surfaces on the offending row and is not ok', () async {
    // first on an empty collection throws.
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => r.skills.first.name;',
      records,
    );
    expect(result.ok, isFalse);
    expect(result.rows.any((r) => r.error != null), isTrue);
  });

  test('an infinite loop is killed by the timeout and rejected', () async {
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) { while (true) {} }\n'
      'dynamic display(CharaRecord r) => 1;',
      records,
    );
    expect(result.timedOut, isTrue);
    expect(result.ok, isFalse);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('returning a facade object instead of a value or Cell is an error', () async {
    // `r.scenario` is a Scenario object, not a value; this used to render a silent
    // blank. It must now surface as an error so the save stays gated.
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => r.scenario;',
      records,
    );
    expect(result.ok, isFalse);
    expect(result.rows.every((r) => r.error != null), isTrue);
  });

  test('Cell display text is kept with an independent numeric sort key', () async {
    final result = await runScriptPreview(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => Cell("fast", sort: r.status.speed);',
      records,
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
    );
    expect(result.ok, isTrue);
    expect(result.rows.first.display, 'A/B');
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
