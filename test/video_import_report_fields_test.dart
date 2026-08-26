// STRUCTURAL GUARD: no field of an import result may be dropped in silence.
//
// Three hand-written field tables decide what an import-error report actually says, and every one of
// them fails quietly when a field is added and forgotten:
//
//   1. `VideoImportOutcome`'s copy methods — `withSessions`, `withMessage`, and whatever comes next:
//      a copy of every field, all of them defaulted, made on paths every settled import passes
//      through. A forgotten field is not a compile error; it is a zero, and a zero reads as a
//      measurement (`durationMs: 0` means "no duration was measured", which turns the report's
//      correlation into `duration_unknown` and drops the whole import block from every report, with
//      no user-visible symptom whatsoever). The methods themselves are enumerated off the source, so
//      a third one is covered the day it is written rather than the day someone remembers it.
//   2. `buildImportErrorReportScope`'s `import` block — which of those fields reach the developer.
//   3. its `clip` and `frame` blocks — the same question for the clip's axis and for the pixels the
//      report attaches.
//
// So the enumeration is done here BY A MACHINE, off the sources themselves, rather than by a second
// hand-written list that would go stale the same way. Adding a field to any of the three classes
// fails this file until the field is either carried or named in the exclusion list with a reason.
//
// BY A MACHINE MEANS BY THE LANGUAGE'S OWN PARSER. Fields and copies are read off a
// `package:analyzer` parse of the source, never off a pattern: a pattern spells one *shape* of the
// thing it is looking for (an indent, a `final`, a return type written without a `?`), and every
// other shape of it is then absent from the enumeration rather than reported. Absence is the whole
// hazard, because a per-field rule cannot fail for a field it never received — it passes with
// nothing to say, and the count-based vacuity guards below are lower bounds that cannot see a
// subtraction. The extractors therefore have their own cases, and the enumeration is asserted to
// have found something before it is believed.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_report_fields_test.dart
import 'dart:io';

// `analyzer` reaches this package transitively (through the codegen stack). Depended on here rather
// than promoted to a direct dev_dependency because pinning it would freeze the version the codegen
// packages resolve to, and this guard only ever needs the parser. Same arrangement as
// `disabled_tooltip_visibility_test.dart` and `sentry_scrub_event_test.dart`.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

/// The one `class [name]` declared in [source], as a parsed node.
///
/// **Parsed rather than delimited by string search.** The spelling this replaced found the class
/// header with a regex and its end by counting braces in raw text, which meant every rule below was
/// written against a *span of characters* — and a span is only ever as good as the two searches
/// that bound it. A node has an end because the language says so.
///
/// A class that is absent, or declared twice, throws rather than returning an empty body: an empty
/// enumeration satisfies every per-field rule in this file vacuously, which is the exact silence
/// the file exists to remove.
ClassDeclaration _classDeclaration(String source, String name) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final found = unit.declarations.whereType<ClassDeclaration>().where((e) => e.name.lexeme == name).toList();
  if (found.length != 1) {
    throw StateError(
      'expected exactly one `class $name`, found ${found.length}; the enumeration would read '
      'nothing and every rule about $name below would pass vacuously',
    );
  }
  return found.single;
}

/// The names of the instance fields declared on `class [className]` in [source].
///
/// **Enumerated by node kind, so nothing here spells a type or an indent.** The pattern this
/// replaced matched `^[ \t]*final[ \t]+[^;=\n]+?[ \t]+(\w+);[ \t]*$`: single-line, `final`-only,
/// and blind to a field with an initialiser. A declaration it could not read was absent from the
/// returned set, and a field that is absent cannot fail a per-field rule — the rule simply has
/// nothing to say about it and stays green. That silence needed a loud "unparsed declaration"
/// guard bolted on beside it; parsing removes the need for the guard rather than tightening it,
/// because a `FieldDeclaration` is a `FieldDeclaration` however its type is spelled, however it
/// wraps, and whether or not it carries an initialiser.
///
/// Statics are dropped: a `static const` is not per-instance state and has nothing to publish on a
/// report. Getters and methods are not `FieldDeclaration`s at all, so the locals inside them
/// (`final scratch = ...;`, which the old pattern had to exclude by hand) are structurally out of
/// reach rather than excluded by a rule that could be wrong.
///
/// **Stated limit:** fields inherited from a superclass or mixed in are *not* walked — this reads
/// the class's own members. None of the three classes has a supertype today, and a wholesale move
/// into one would go red loudly through the `containsAll` / length guards in
/// `the machine can actually see the fields`, rather than being silently absorbed.
Set<String> _declaredFields(String source, String className) => <String>{
  for (final member in _classDeclaration(source, className).members.whereType<FieldDeclaration>())
    if (!member.isStatic)
      for (final variable in member.fields.variables) variable.name.lexeme,
};

/// One construction of a `VideoImportOutcome` made inside `class VideoImportOutcome` itself, and
/// the named arguments it passes.
typedef _OutcomeCopy = ({String member, Set<String> arguments});

/// Collects every `VideoImportOutcome(...)` construction under [node].
///
/// Both AST shapes, because the parser alone cannot resolve a name: `VideoImportOutcome(...)`
/// parses as a [MethodInvocation] while `const VideoImportOutcome(...)` parses as an
/// [InstanceCreationExpression]. Handling one of the two is the same class of silent loss as
/// spelling one indent.
class _OutcomeConstructions extends RecursiveAstVisitor<void> {
  final List<ArgumentList> found = <ArgumentList>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.toSource() == 'VideoImportOutcome') {
      found.add(node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && node.methodName.name == 'VideoImportOutcome') {
      found.add(node.argumentList);
    }
    super.visitMethodInvocation(node);
  }
}

/// Every copy a `VideoImportOutcome` makes of itself, enumerated off the source.
///
/// **The enumeration is "a construction of this class, inside this class"** — a node kind and a
/// scope, not a signature. The spelling this replaced was
/// `RegExp(r'^\s{2}VideoImportOutcome (\w+)\(')`, which hard-coded a two-space indent *and* an
/// exact return type: a copy returning `VideoImportOutcome?`, a copy written as a getter, or one
/// nested a level deeper was not in the list, and a copy that is not in the list is a copy no rule
/// in this file examines. The only backstop was a `containsAll` of the two known names, which is a
/// lower bound and cannot see a subtraction.
///
/// The hazard is the *construction*, not the method: every parameter of the constructor is
/// defaulted, so a field added to the class and forgotten at any of these call sites is a silent
/// zero rather than a compile error (`durationMs: 0` reads as a measurement, turns the report's
/// correlation into `duration_unknown`, and drops the whole `import` block). Keying on the
/// construction also means a member that builds two of them has both examined.
///
/// A member that *returns* a `VideoImportOutcome` and constructs none fails loudly here rather than
/// being skipped: it is either a copy this reader cannot see (a delegation to a builder elsewhere),
/// or it is not a copy at all — and which of the two it is has to be stated, not assumed.
///
/// **Stated limit:** a copy made *outside* the class is not enumerated. Outside it, building an
/// outcome from scratch is the norm (every producer does it) and carrying every field is not the
/// rule, so the scope is the class's own body.
List<_OutcomeCopy> _outcomeCopies(String source) {
  final copies = <_OutcomeCopy>[];
  for (final member in _classDeclaration(source, 'VideoImportOutcome').members.whereType<MethodDeclaration>()) {
    if (member.isStatic) {
      continue;
    }
    final visitor = _OutcomeConstructions();
    member.accept(visitor);
    final returnsOutcome = member.returnType?.toSource().contains('VideoImportOutcome') ?? false;
    expect(
      visitor.found.isNotEmpty || !returnsOutcome,
      isTrue,
      reason:
          'VideoImportOutcome.${member.name.lexeme} returns an outcome but constructs none where this '
          'reader can see it. If it delegates the copy elsewhere, this enumeration no longer covers '
          'that copy and every "carries every field" rule below is silent about it',
    );
    for (final arguments in visitor.found) {
      copies.add((
        member: member.name.lexeme,
        arguments: arguments.arguments.whereType<NamedExpression>().map((e) => e.name.label.name).toSet(),
      ));
    }
  }
  return copies;
}

/// Which report key each [VideoImportOutcome] field is published under, or null for a field that is
/// deliberately not published under a key of its own.
///
/// **A field missing from this map fails the test.** That is the point: the decision "does this
/// belong on a bug report?" is a per-field judgement (a new field could be anything, including
/// something a user typed), so a new field must be ruled on rather than defaulted either way.
const Map<String, String?> _outcomeFieldReportKey = <String, String?>{
  'kind': 'outcome',
  'reason': 'reason',
  'blocker': 'blocker',
  'decoded': 'decoded',
  'supplied': 'supplied',
  'rejected': 'rejected',
  'records': 'records',
  'durationMs': 'duration_ms',
  'matrixConverted': 'matrix_converted',
  'message': 'message',
  // Published, but as two keys rather than one: a record type would render on the event as a Dart
  // toString. Checked separately below.
  'sessions': null,
};

/// The same map for the clip's axis. Every field is measured by the decoder, so every one travels.
const Map<String, String?> _timelineFieldReportKey = <String, String?>{
  'firstFrameMs': 'first_frame_ms',
  'durationMs': 'duration_ms',
  'fps': 'fps',
  'width': 'width',
  'height': 'height',
  'hasMediaTimeline': 'has_media_timeline',
};

/// The same map for the grabbed frame.
const Map<String, String?> _frameFieldReportKey = <String, String?>{
  'requestedMs': 'requested_ms',
  'mediaTsMs': 'media_ts_ms',
  'seekBackoffMs': 'seek_backoff_ms',
  'decodedFrames': 'decoded_frames',
  'width': 'width',
  'height': 'height',
  'format': 'format',
  'rotation': 'rotation',
  'matrixConverted': 'matrix_converted',
  // NOT published, and the exclusion is the ruling rather than an omission. `nextMediaTsMs` is the
  // time of the frame AFTER the one attached — it exists so a front end can step forward without
  // guessing a time (`video_frame_grab_ops.dart`), and it describes a frame the report does not
  // contain. Everything a reader needs about the attached pixels is already `media_ts_ms`; adding a
  // neighbour's stamp would invite the reading that the attachment spans a range. Publish it only
  // if some day the report carries more than one frame.
  'nextMediaTsMs': null,
  // The attachment itself. Its path is a temp file this app named, and the file travels as the
  // event's attachment rather than as a string on the event.
  'png': null,
};

/// Every dotted path in [value] whose leaf is null.
///
/// **Walked rather than listed.** A null-valued context key never reaches Sentry (measured on the
/// one real event this feature has filed, 2026-08-21: all five of the frame block's nulls and
/// `import.blocker` were absent from the stored event, while an empty string arrived intact), so a
/// key published as null is a key the reader does not receive — the same silence as forgetting it.
/// Enumerating the built report is what makes that hold for a key nobody has written yet: a leg
/// added later brings its own unstated values, and none of them has to be remembered here.
List<String> _nullPathsIn(dynamic value, [String path = '']) {
  if (value == null) {
    return <String>[path];
  }
  if (value is Map) {
    return <String>[
      for (final entry in value.entries)
        ..._nullPathsIn(entry.value, path.isEmpty ? '${entry.key}' : '$path.${entry.key}'),
    ];
  }
  if (value is List) {
    return <String>[for (var i = 0; i < value.length; i++) ..._nullPathsIn(value[i], '$path[$i]')];
  }
  return const <String>[];
}

/// Every dotted path in [value] that holds a leaf, null or not. Only used to show that
/// [_nullPathsIn] visited a report rather than an empty map.
List<String> _leafPathsIn(dynamic value, [String path = '']) {
  if (value is Map) {
    return <String>[
      for (final entry in value.entries)
        ..._leafPathsIn(entry.value, path.isEmpty ? '${entry.key}' : '$path.${entry.key}'),
    ];
  }
  if (value is List) {
    return <String>[for (var i = 0; i < value.length; i++) ..._leafPathsIn(value[i], '$path[$i]')];
  }
  return <String>[path];
}

/// A report whose correlation holds, so the `import` block is populated.
ImportErrorReportScope _matchedScope() {
  return buildImportErrorReportScope(
    clipName: 'clip.mp4',
    frame: GrabbedVideoFrame(
      png: FilePath('/tmp/video_frame_1.png'),
      requestedMs: 6000,
      mediaTsMs: 5963,
      seekBackoffMs: 1000,
      decodedFrames: 31,
      width: 1080,
      height: 1920,
      format: 'I420',
      rotation: 90,
      matrixConverted: 'bt709 -> bt601',
    ),
    timeline: const VideoFrameTimeline(
      firstFrameMs: 50,
      durationMs: 12000,
      fps: 30.0,
      width: 1080,
      height: 1920,
      hasMediaTimeline: true,
    ),
    importState: const VideoImportState(
      phase: VideoImportPhase.finished,
      fileName: 'clip.mp4',
      outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed, durationMs: 12000),
    ),
  );
}

const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30.0,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

const _matchedImport = VideoImportState(
  phase: VideoImportPhase.finished,
  fileName: 'clip.mp4',
  outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed, durationMs: 12000),
);

/// One report of every shape this feature can build, named by what makes it different.
///
/// The shapes are the *producers*, because that is what decides which values are unstated: the
/// Windows grab reply states neither the decoded shape nor a conversion, the web one states no seek
/// ladder, and a report whose clip could not be tied to an import carries no `import` block beyond
/// the correlation.
Map<String, ImportErrorReportScope> _everyShapeOfReport() {
  ImportErrorReportScope scope(GrabbedVideoFrame frame, VideoImportState state) =>
      buildImportErrorReportScope(clipName: 'clip.mp4', frame: frame, timeline: _timeline, importState: state);
  final png = FilePath('/tmp/video_frame_1.png');
  return <String, ImportErrorReportScope>{
    'every value stated': _matchedScope(),
    'the Windows grab producer, which states no shape and no conversion': scope(
      GrabbedVideoFrame(png: png, requestedMs: 6000, mediaTsMs: 5963, seekBackoffMs: 1000, decodedFrames: 31),
      _matchedImport,
    ),
    'the web grab producer, which states no seek ladder': scope(
      GrabbedVideoFrame(
        png: png,
        requestedMs: 6000,
        mediaTsMs: 5963,
        seekBackoffMs: null,
        decodedFrames: null,
        width: 1080,
        height: 1920,
        format: 'I420',
        rotation: 0,
        matrixConverted: '',
      ),
      _matchedImport,
    ),
    'a clip that could not be tied to any import': scope(
      GrabbedVideoFrame(png: png, requestedMs: 6000, mediaTsMs: 5963, seekBackoffMs: 1000, decodedFrames: 31),
      VideoImportState.idle,
    ),
  };
}

void main() {
  late String importOps;
  late String grabOps;

  setUpAll(() {
    importOps = File('lib/src/core/video_import_ops.dart').readAsStringSync();
    grabOps = File('lib/src/core/video_frame_grab_ops.dart').readAsStringSync();
  });

  // The enumeration above is only as good as the parser doing it, and a parser that quietly skips a
  // declaration produces the same silence as a hand-written list that forgot one -- with the extra
  // twist that the count-based vacuity guard cannot see it (a lower bound stays satisfied while the
  // twelfth field goes missing). So the parser is fed sources whose answer is known, including the
  // shapes the pattern it replaced used to skip.
  group('the field parser itself', () {
    // Every shape that has to be enumerated, and several that must not be. Written here rather than
    // read off `lib/` on purpose: a source file cannot state the expected answer, and these shapes
    // are legal Dart that the real classes may grow at any time.
    const sample = '''
class Sample {
  /// A doc comment naming `final int notAField;`, which must not be counted.
  final int plain;
  final Map<String, List<int>> generic;
  final ({int a, int b}) record;
  final void Function(int value, {String? tag}) callback;
  final List<({String name, int at})> recordList;
  final String? optional;
  final void Function(
    int value,
  ) wrapped;
  final int initialised = 3;
  int mutable = 0;
  static const int notPerInstance = 7;

  const Sample({required this.plain});

  int get derived => plain + 1;

  Map<String, int> get derivedMap => <String, int>{};

  Sample copy() {
    final scratch = plain;
    return Sample(plain: scratch);
  }
}

class Decoy {
  final int mustNotAppear;
}
''';

    test('enumerates every field whatever its type is spelled like, and nothing else', () {
      final fields = _declaredFields(sample, 'Sample');

      // Exact equality, not `containsAll`: a parser that over-matched -- pulling a name out of the
      // doc comment, the getters, the local, the static or the second class -- would satisfy any
      // subset assertion. The three shapes after `optional` are the ones the previous pattern lost:
      // a declaration that wraps across lines, one carrying an initialiser, and one that is not
      // `final`.
      expect(fields, <String>{
        'plain',
        'generic',
        'record',
        'callback',
        'recordList',
        'optional',
        'wrapped',
        'initialised',
        'mutable',
      });
    });

    test('keeps adjacent declarations separate rather than reporting one', () {
      const adjacent = '''
class Adjacent {
  final Map<String, int> first;
  final Map<String, int> second;
}
''';

      expect(_declaredFields(adjacent, 'Adjacent'), <String>{'first', 'second'});
    });

    test('fails loudly when the class it was asked for is not there exactly once', () {
      // The failure mode the string search had: `indexOf` returning -1 (or resolving a duplicate to
      // the first one) produced a body, and a body produced a set, and an empty or wrong set makes
      // every per-field rule in this file pass with nothing to say.
      expect(() => _declaredFields(sample, 'NotHere'), throwsStateError);
      expect(() => _declaredFields('class Twice {}\nclass Twice {}', 'Twice'), throwsStateError);
    });

    test('does not mistake a local variable for a field', () {
      // The real `VideoFrameTimeline` getters hold `final end = ...;` locals inside the class body,
      // so this is not hypothetical: counting them would demand report keys for names that are not
      // fields, and the guard would become unfixable rather than informative.
      const withLocals = '''
class WithLocals {
  final int only;

  int get doubled {
    final scratch = only;
    return scratch * 2;
  }
}
''';

      expect(_declaredFields(withLocals, 'WithLocals'), <String>{'only'});
    });
  });

  // The copy enumeration, fed the shapes its predecessor lost. Each of these is legal Dart the real
  // class may grow at any time, and each was invisible to a pattern that spelled `^\s{2}` and an
  // exact return type.
  group('the copy enumeration itself', () {
    test('finds a copy whatever its return type, indent, or member kind', () {
      const source = '''
class VideoImportOutcome {
  const VideoImportOutcome({this.kind, this.durationMs = 0, this.message = ''});

  final int kind;
  final int durationMs;
  final String message;

  /// The shape the old pattern matched.
  VideoImportOutcome withMessage(String message) =>
      VideoImportOutcome(kind: kind, durationMs: durationMs, message: message);

  /// A nullable return type: `VideoImportOutcome?` did not match `VideoImportOutcome `.
      VideoImportOutcome? maybeCleared() =>
          VideoImportOutcome(kind: kind, durationMs: durationMs, message: '');

  /// A getter, which has no `(` after the name at all.
  VideoImportOutcome get silenced => const VideoImportOutcome(kind: 0, durationMs: 0, message: '');

  /// Two constructions in one member: both are copies, and both must be examined.
  VideoImportOutcome pick(bool first) => first
      ? VideoImportOutcome(kind: kind, durationMs: durationMs, message: message)
      : VideoImportOutcome(kind: kind, message: message);

  /// Not a copy, and not enumerated: it returns something else.
  String describe() => 'kind=\$kind';
}
''';

      final copies = _outcomeCopies(source);
      expect(copies.map((e) => e.member).toList(), <String>['withMessage', 'maybeCleared', 'silenced', 'pick', 'pick']);
      // And the arguments are read off the construction, not off the parameter list -- reading the
      // parameter list instead returns an empty set, which makes "nothing was dropped" true of any
      // implementation at all. That is not hypothetical: it is what the first spelling of the
      // argument reader did.
      final fields = _declaredFields(source, 'VideoImportOutcome');
      final dropped = copies.map((copy) => fields.difference(copy.arguments)).toList();
      expect(dropped, <Set<String>>[
        <String>{},
        <String>{},
        <String>{},
        <String>{},
        <String>{'durationMs'}, // the second construction inside `pick`
      ]);
    });

    test('fails loudly on a member that returns an outcome it does not construct here', () {
      // The one shape this reader cannot follow. It must be a failure rather than an omission: a
      // copy made behind a call is a copy no rule in this file examines.
      const delegating = '''
class VideoImportOutcome {
  final int kind;

  VideoImportOutcome withSessions(int sessions) => _build(sessions);
}
''';

      expect(() => _outcomeCopies(delegating), throwsA(isA<TestFailure>()));
    });
  });

  group('the machine can actually see the fields', () {
    // Without this, every assertion below would be vacuously true for an empty set.
    test('the enumeration finds each class and a plausible number of fields', () {
      final outcome = _declaredFields(importOps, 'VideoImportOutcome');
      final timeline = _declaredFields(grabOps, 'VideoFrameTimeline');
      final frame = _declaredFields(grabOps, 'GrabbedVideoFrame');
      expect(outcome, containsAll(<String>['kind', 'decoded', 'sessions', 'durationMs']));
      expect(outcome.length, greaterThanOrEqualTo(11));
      expect(timeline, containsAll(<String>['firstFrameMs', 'hasMediaTimeline']));
      expect(timeline.length, greaterThanOrEqualTo(6));
      expect(frame, containsAll(<String>['png', 'mediaTsMs', 'matrixConverted']));
      expect(frame.length, greaterThanOrEqualTo(10));
      // Getters must not be counted as fields, or the report tables would be asked to publish
      // derived values and the guard would be unfixable rather than informative.
      expect(timeline, isNot(contains('selectableStartMs')));
      expect(outcome, isNot(contains('sessionsWithoutRecord')));
      // And the argument reader has to be reading the constructor call, not the parameter list:
      // an empty set here would make "nothing was dropped" true for any implementation at all.
      final copies = _outcomeCopies(importOps);
      expect(
        copies.map((copy) => copy.member).toSet(),
        containsAll(<String>['withSessions', 'withMessage']),
        reason: 'the copy enumeration missed one; every assertion about them would be vacuous',
      );
      for (final copy in copies) {
        expect(copy.arguments.length, greaterThanOrEqualTo(11));
      }
    });
  });

  group('no report key may be published in a form the reader never receives', () {
    test('nothing anywhere in the context is null, whichever producer built the report', () {
      for (final entry in _everyShapeOfReport().entries) {
        expect(
          _nullPathsIn(entry.value.context),
          isEmpty,
          reason:
              'a null-valued context key is dropped before the reader sees it, so ${entry.key} would '
              'report those keys as silently as forgetting them. Publish $reportValueNotStated '
              'instead — lib/src/core/video_import_ops.dart, statedReportContext.',
        );
      }
    });

    test('every unstated value is the one string chosen for it, and not a plausible measurement', () {
      // The other direction: "no nulls" is also satisfied by publishing a 0, an '' or the word
      // "unknown" per key, and each of those reads as something a producer said.
      final windows = _everyShapeOfReport()['the Windows grab producer, which states no shape and no conversion'];
      final frame = windows!.context['frame'] as Map<String, dynamic>;
      for (final key in <String>['width', 'height', 'format', 'rotation', 'matrix_converted']) {
        expect(frame[key], reportValueNotStated, reason: 'frame.$key');
      }
      expect(frame['seek_backoff_ms'], 1000, reason: 'and what the producer DID state is its own number');
    });

    test('the walker would find a null if the report published one', () {
      // Vacuity, in both of the ways this guard can die: a walker that returns nothing for any input,
      // and a walker that never reaches the leaves of a real report.
      expect(
        _nullPathsIn(<String, dynamic>{
          'clip': <String, dynamic>{'container': 'mp4', 'width': null},
          'frame': <String, dynamic>{'rotation': null},
          'list': <dynamic>[1, null],
        }),
        <String>['clip.width', 'frame.rotation', 'list[1]'],
      );
      for (final entry in _everyShapeOfReport().entries) {
        expect(
          _leafPathsIn(entry.value.context).length,
          greaterThanOrEqualTo(16),
          reason: 'the walker reached only ${_leafPathsIn(entry.value.context)} on ${entry.key}',
        );
        expect(_leafPathsIn(entry.value.context), contains('frame.matrix_converted'));
      }
    });
  });

  group('every VideoImportOutcome copy carries every field there is', () {
    test('no field of the class is missing from any of the hand-written copies', () {
      final fields = _declaredFields(importOps, 'VideoImportOutcome');
      for (final copy in _outcomeCopies(importOps)) {
        final dropped = fields.difference(copy.arguments);
        expect(
          dropped,
          isEmpty,
          reason:
              'VideoImportOutcome.${copy.member} does not carry $dropped. Every parameter has a '
              'default, so the field is silently zeroed on a copy every settled import passes '
              'through. Add it to the argument list in lib/src/core/video_import_ops.dart.',
        );
      }
    });

    test('no copy invents an argument that is not a field', () {
      // The other direction, and it is not symmetry for its own sake: an argument that no longer
      // names a field is a rename that half happened, which is how a value starts being copied into
      // the wrong place.
      final fields = _declaredFields(importOps, 'VideoImportOutcome');
      for (final copy in _outcomeCopies(importOps)) {
        expect(copy.arguments.difference(fields), isEmpty, reason: 'in ${copy.member}');
      }
    });
  });

  group('every field is ruled on before it can go missing from a report', () {
    test('VideoImportOutcome: each field is either published or named as an exclusion', () {
      final fields = _declaredFields(importOps, 'VideoImportOutcome');
      expect(
        fields.difference(_outcomeFieldReportKey.keys.toSet()),
        isEmpty,
        reason:
            'a new field of VideoImportOutcome has to be given a report key in this test, or the '
            'value null with a comment saying why it does not belong on a bug report.',
      );
      final import = _matchedScope().context['import'] as Map<String, dynamic>;
      for (final entry in _outcomeFieldReportKey.entries) {
        final key = entry.value;
        if (key == null) {
          continue;
        }
        expect(import.containsKey(key), isTrue, reason: 'import.$key is missing for field ${entry.key}');
      }
      // The one field published under two keys.
      expect(import.containsKey('sessions_discarded'), isTrue);
      expect(import.containsKey('sessions_unfinished'), isTrue);
    });

    test('VideoFrameTimeline: each field reaches the clip block', () {
      final fields = _declaredFields(grabOps, 'VideoFrameTimeline');
      expect(fields.difference(_timelineFieldReportKey.keys.toSet()), isEmpty);
      final clip = _matchedScope().context['clip'] as Map<String, dynamic>;
      for (final entry in _timelineFieldReportKey.entries) {
        final key = entry.value;
        if (key == null) {
          continue;
        }
        expect(clip.containsKey(key), isTrue, reason: 'clip.$key is missing for field ${entry.key}');
      }
    });

    test('GrabbedVideoFrame: each field reaches the frame block', () {
      // The condition this file was written for: these five (width, height, format, rotation,
      // matrixConverted) were parsed off the wire by nobody, and they describe the very pixels the
      // report attaches.
      final fields = _declaredFields(grabOps, 'GrabbedVideoFrame');
      expect(fields.difference(_frameFieldReportKey.keys.toSet()), isEmpty);
      final frame = _matchedScope().context['frame'] as Map<String, dynamic>;
      for (final entry in _frameFieldReportKey.entries) {
        final key = entry.value;
        if (key == null) {
          continue;
        }
        expect(frame.containsKey(key), isTrue, reason: 'frame.$key is missing for field ${entry.key}');
      }
    });
  });
}
