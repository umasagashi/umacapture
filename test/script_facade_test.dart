// Smoke test for the dart_eval script-column facade.
//
// Compiles a filter+display script against the FacadePlugin and runs it over a
// hand-built enriched map, exercising the public API the user manual promises:
// typed getters, where/whereNot/any/every/map+sum, firstOrNull, $Coded, Cell,
// when/heat/lerpColor, and nullable handling.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/script_facade_test.dart
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/script_facade.dart';

const _scriptUri = 'package:script/script.dart';

Map<String, dynamic> sampleRecord() => {
  'id': 'rec-1',
  'evaluationValue': 12345,
  'fans': 67890,
  'trainedDate': '2026/01/02',
  'capturedDate': '2026-02-01T12:00:00.000Z',
  'charaRank': {'code': 6, 'name': 'B', 'category': 'charaRank'},
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
  'skills': [
    {
      'id': 101,
      'level': 2,
      'name': 'スピードスター',
      'tags': <String>['nige', 'speed'],
    },
    {
      'id': 102,
      'level': null,
      'name': '集中力',
      'tags': <String>['recovery'],
    },
  ],
  'factors': [
    {
      'id': 5,
      'star': 3,
      'name': 'スピード',
      'tags': <String>['status'],
      'subject': {'code': 0, 'name': '本人'},
    },
    {
      'id': 5,
      'star': 1,
      'name': 'スピード',
      'tags': <String>['status'],
      'subject': {'code': 1, 'name': '親1'},
    },
  ],
  'factorGroups': [
    {
      'id': 5,
      'name': 'スピード',
      'tags': <String>['status'],
      'totalStar': 4,
      'selfStar': 3,
      'parent1Star': 1,
      'parent2Star': 0,
    },
  ],
  'races': [
    {
      'place': 3,
      'position': 1,
      'won': true,
      'title': {'code': 12, 'name': '日本ダービー'},
      'ground': {'code': 0, 'name': '芝'},
      'distance': {'code': 2, 'name': '中距離'},
      'strategy': {'code': 1, 'name': '先行'},
      'weather': {'code': 0, 'name': '晴'},
    },
  ],
  'supportCards': [
    {
      'id': 30,
      'level': 50,
      'rank': {'code': 2, 'name': 'SSR'},
    },
  ],
  'scenario': {'id': 7, 'name': 'アオハル杯'},
  'metadata': {
    'recordType': {'code': 0, 'name': '標準'},
    'strategy': {'code': 1, 'name': '先行'},
    'isFriend': false,
  },
};

dynamic Function(String fn) compileScript(String source) {
  final compiler = Compiler()
    ..addPlugin(FacadePlugin())
    ..entrypoints.add(_scriptUri);
  final program = compiler.compile({
    'script': {'script.dart': "import 'package:script/facade.dart';\n$source"},
  });
  final runtime = Runtime.ofProgram(program)..addPlugin(FacadePlugin());
  return (String fn) {
    final result = runtime.executeLib(_scriptUri, fn, [$Record.wrap(sampleRecord())]);
    return result is $Value ? result.$value : result;
  };
}

void main() {
  test('typed getter chains resolve statically', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => r.status.speed >= 1000;\n'
      'dynamic display(CharaRecord r) => r.status.speed;',
    );
    expect(run('filter'), isTrue);
    expect(run('display'), 1200);
  });

  test('collections: where/whereNot/any/map+sum/firstOrNull', () {
    final run = compileScript(
      'num speedStars(CharaRecord r) =>\n'
      '  r.factorGroups.where((g) => g.name == "スピード").map((g) => g.totalStar).sum;\n'
      'bool filter(CharaRecord r) =>\n'
      '  speedStars(r) >= 4 &&\n'
      '  r.skills.whereNot((s) => s.level == null).any((s) => s.name.contains("スピード")) &&\n'
      '  r.races.any((e) => e.ground.name == "芝" && e.won) &&\n'
      '  (r.ratings.get("main") ?? 0.0) >= 4.0;\n'
      'dynamic display(CharaRecord r) => speedStars(r).toInt();',
    );
    expect(run('filter'), isTrue);
    expect(run('display'), 4);
  });

  test('coded fields: name and ordered code comparison', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => r.aptitudes.distance.middle.code >= 5;\n'
      'dynamic display(CharaRecord r) => r.aptitudes.distance.middle.name;',
    );
    expect(run('filter'), isTrue);
    expect(run('display'), 'A');
  });

  test('hasTag and firstOrNull null-safety', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => r.skills.any((s) => s.hasTag("nige"));\n'
      'dynamic display(CharaRecord r) =>\n'
      '  (r.factorGroups.where((g) => g.name == "存在しない").firstOrNull?.totalStar ?? 0);',
    );
    expect(run('filter'), isTrue);
    expect(run('display'), 0);
  });

  test('heat returns a hex string', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => heat(4, min: 0, max: 8);',
    );
    expect((run('display') as String).startsWith('#'), isTrue);
  });

  test('when() returns the value when the condition holds', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => Cell("x", color: when(r.status.speed >= 1000, "green"));',
    );
    expect((run('display') as Map)['color'], 'green');
  });

  // Canonical conditional-styling recipe: precompute the boolean condition into
  // a `final` before using the same numeric in a Cell call. dart_eval 0.8.5
  // mis-boxes an int local that is both inline-compared and passed to a bridge
  // arg in the same expression, so the manual steers users to this shape.
  test('Cell with heat background and when-based color/icon', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) {\n'
      '  final n = r.factorGroups.map((g) => g.totalStar).sum.toInt();\n'
      '  final hot = n >= 6;\n'
      '  return Cell("speed(\$n)", sort: n,\n'
      '      background: heat(n, min: 0, max: 8), color: when(hot, "white"), icon: when(hot, "star"));\n'
      '}',
    );
    final cell = run('display') as Map;
    expect(cell['display'], 'speed(4)');
    expect(cell['sort'], 4);
    expect(cell['color'], isNull);
    expect(cell['icon'], isNull);
    expect((cell['background'] as String).startsWith('#'), isTrue);
  });

  test('numeric display, sort, and heat on one value (no inline compare)', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) {\n'
      '  final s = r.status.speed;\n'
      '  return Cell("\$s", sort: s, background: heat(s, min: 1000, max: 1800));\n'
      '}',
    );
    final cell = run('display') as Map;
    expect(cell['sort'], 1200);
    expect((cell['background'] as String).startsWith('#'), isTrue);
  });

  test('lerpColor and string sort', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) =>\n'
      '  Cell(r.aptitudes.distance.middle.name, sort: r.aptitudes.distance.middle.code,\n'
      '       background: lerpColor("blue", "red", 0.5));',
    );
    final cell = run('display') as Map;
    expect(cell['display'], 'A');
    expect(cell['sort'], 7);
    expect((cell['background'] as String).startsWith('#'), isTrue);
  });

  group('codeOf / atLeast / atMost', () {
    test('resolve a target name to its code within the field category', () {
      scriptCodeTables = {
        'charaRank': {'C': 5, 'B': 6, 'A': 7, 'S': 8},
      };
      bool boolOf(String expr) {
        final run = compileScript('bool filter(CharaRecord r) => $expr;\ndynamic display(CharaRecord r) => 0;');
        return run('filter') as bool;
      }

      // r.charaRank.code == 6 ("B" in the sample record).
      expect(boolOf('r.charaRank.atMost("B")'), isTrue); // 6 <= 6
      expect(boolOf('r.charaRank.atMost("C")'), isFalse); // 6 <= 5
      expect(boolOf('r.charaRank.atLeast("B")'), isTrue); // 6 >= 6
      expect(boolOf('r.charaRank.atLeast("A")'), isFalse); // 6 >= 7

      final run = compileScript(
        'bool filter(CharaRecord r) => true;\ndynamic display(CharaRecord r) => r.charaRank.codeOf("S");',
      );
      expect(run('display'), 8);
    });

    test('throw a ScriptLookupError on an unknown name', () {
      scriptCodeTables = {
        'charaRank': {'B': 6},
      };
      final run = compileScript(
        'bool filter(CharaRecord r) => r.charaRank.atMost("ZZ");\ndynamic display(CharaRecord r) => 0;',
      );
      expect(
        () => run('filter'),
        throwsA(isA<ScriptLookupError>().having((e) => e.toString(), 'message', 'unknown charaRank name: ZZ')),
      );
    });

    test('throw when the field has no category (no comparable order)', () {
      scriptCodeTables = const {};
      // The sample's aptitude coded maps carry no `category` tag.
      final run = compileScript(
        'bool filter(CharaRecord r) => r.aptitudes.distance.middle.atMost("A");\ndynamic display(CharaRecord r) => 0;',
      );
      expect(() => run('filter'), throwsA(isA<ScriptLookupError>()));
    });
  });

  test('days() converts date strings to epoch-day integers', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => days("2026/02/01") - days(r.trainedDate);',
    );
    // 2026-02-01 minus 2026-01-02 = 30 whole days (date-only, timezone-stable).
    expect(run('display'), 30);
  });

  test('days() parses the ISO capturedDate without throwing', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\ndynamic display(CharaRecord r) => days(r.capturedDate);',
    );
    expect(run('display'), isA<int>());
  });

  test('days() throws with a clear message on an unparseable string', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\ndynamic display(CharaRecord r) => days("not a date");',
    );
    // A registered top-level bridge function's throw is wrapped in dart_eval's
    // RuntimeException, whose toString embeds the original message; the
    // production catch surfaces that same text. Assert on the message, not type.
    expect(() => run('display'), throwsA(predicate((e) => e.toString().contains('cannot parse date: not a date'))));
  });

  // The `sep` param is typed `String?`, so a non-string literal is a compile
  // error — but a `dynamic` value slips past the static check and would hit the
  // runtime cast. It must coerce, not throw a ClassCastError.
  test('join coerces a dynamic non-string separator instead of throwing', () {
    final run = compileScript(
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) {\n'
      '  dynamic sep = 0;\n'
      '  return r.skills.map((s) => s.name).join(sep);\n'
      '}',
    );
    expect(run('display'), 'スピードスター0集中力');
  });
}
