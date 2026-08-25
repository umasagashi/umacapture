// The startup sequence must never leave a blank page, whichever step fails.
//
// The branch added `reportFatalStartupError` for exactly that, then wrapped only
// `setupLicense()`. The Hive open and the translation load run before it, so a
// browser with site data blocked (Firefox "Strict", a private window) failed
// `openBox`, the exception escaped `main()`, `runApp` was never called, and the
// visitor got a permanently blank page with only a console entry.
//
// The guard is now a loop over a list of named steps, so what is covered is
// counted by the loop rather than by whoever adds the next step. These tests
// state that: they fail *each* index of a sequence in turn rather than pinning
// the one step the fix happened to be written for.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/module_update_guard_startup_test.dart
import 'dart:io';

// `analyzer` reaches this package transitively (through the codegen stack). Depended on here rather
// than promoted to a direct dev_dependency because pinning it would freeze the version the codegen
// packages resolve to, and this guard only ever needs the parser. Same arrangement as
// `disabled_tooltip_visibility_test.dart`.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/main.dart';

const _names = ['first', 'second', 'third'];

/// Three steps that record that they ran, one of which refuses.
List<StartupStep> _sequence(List<String> ran, {String? failing}) {
  return _names
      .map(
        (name) => (
          name,
          () async {
            ran.add(name);
            if (name == failing) {
              throw Exception('$name blew up');
            }
          },
        ),
      )
      .toList();
}

void main() {
  test('startupSteps names every awaited boot step, not just the licence one', () {
    final names = startupSteps().map((step) => step.$1).toList();

    // S13-06 verbatim: the settings database (Hive) and the translations used to
    // run outside any guard.
    expect(names, contains('opening the settings database'));
    expect(names, contains('loading the translations'));
    expect(names, contains('setting up the license information'));
    // The synchronous initialisers are steps too: one left outside the list is one whose
    // failure is assumed impossible.
    expect(names, contains('registering the data mappers'));
    expect(names, contains('reading the launch flags'));
    // The launch flags are read before anything else awaits, or the browser location has
    // already been rewritten by routing.
    expect(names.first, 'reading the launch flags');
    // The data root has to be resolved before Hive is opened; the settings
    // database cannot store its own location.
    expect(names.indexOf('reading the configured data root'), lessThan(names.indexOf('opening the settings database')));
  });

  group('a failure at any position is reported and stops the boot', () {
    for (final failing in _names) {
      test('the $failing step', () async {
        final ran = <String>[];
        final painted = <String>[];

        final started = await runStartupSequence(_sequence(ran, failing: failing), onFatal: painted.add);

        expect(started, isFalse, reason: 'the app must not start after a refused step');
        expect(painted, hasLength(1), reason: 'the reason has to be painted exactly once');
        expect(painted.single, contains(failing), reason: 'the message has to name the step that broke');
        // Nothing after the failure runs: a later step would be operating on a
        // half-initialised app.
        expect(ran.last, failing);
      });
    }
  });

  test('a sequence that succeeds starts the app and paints nothing', () async {
    // Negative control. Without it, a guard that refuses unconditionally would
    // pass every test above.
    final ran = <String>[];
    final painted = <String>[];

    expect(await runStartupSequence(_sequence(ran), onFatal: painted.add), isTrue);
    expect(ran, _names);
    expect(painted, isEmpty);
  });

  test('a deliberate refusal keeps its own message; anything else names its step', () {
    // `setupLicense` refuses an unverified web disclosure with a StateError whose
    // message is already written for the reader, and that wording must survive.
    expect(
      startupFailureMessage('setting up the license information', StateError('provision web/ first')),
      'provision web/ first',
    );
    expect(
      startupFailureMessage('opening the settings database', Exception('site data blocked')),
      allOf(contains('opening the settings database'), contains('site data blocked')),
    );
  });

  testWidgets('the refusal paints its reason instead of nothing', (tester) async {
    // The claim is an absence ("no blank page"), so this is its positive control:
    // the same measurement, on the same binding, has to be able to see something.
    expect(find.byType(MaterialApp), findsNothing);

    reportFatalStartupError('site data is blocked in this browser');
    await tester.pump();

    // It renders with no translations loaded and no app theme, because it reports
    // the failure of the very steps that would have provided them.
    expect(find.text('umacapture could not start'), findsOneWidget);
    expect(find.text('site data is blocked in this browser'), findsOneWidget);
  });

  test('main() does no awaited startup work outside the sequence', () {
    // The list is only as good as `main()` calling it: a step re-added directly to
    // `main()` would be unguarded again while every test above still passed.
    final scan = scanMainAwaits(File('lib/main.dart').readAsStringSync());

    // Without this the case passes by parsing a `main()` that stopped being recognised, or one
    // whose body the parser read as empty.
    expect(scan.statements, greaterThan(2), reason: 'main() was not read; this rule observes nothing now');

    expect(
      scan.awaited,
      ['runStartupSequence(startupSteps())'],
      reason:
          'every await in main() is listed here as written. A step awaited directly in main() is '
          'outside runStartupSequence, so its failure escapes and the visitor gets a blank page -- '
          'move it into startupSteps() instead of widening this expectation.',
    );
  });

  // The scan is what the case above rests on, so it is exercised on sources of its own. Before
  // this it was `RegExp(r'await [A-Za-z_]+\(')`, which matches a *bare identifier* call only:
  // `await windowManager.ensureInitialized();` -- the repository's own idiom, and the spelling of
  // four of the calls already in this file's own subject -- was invisible to it, so the equality
  // above was satisfied by a `main()` that had grown an unguarded step.
  group('the await scan itself', () {
    test('a dotted receiver is reported, which a bare-identifier pattern cannot see', () {
      final scan = scanMainAwaits('''
FutureOr<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  if (!await runStartupSequence(startupSteps())) {
    return;
  }
  runWithSentry(run);
}
''');

      expect(scan.awaited, ['windowManager.ensureInitialized()', 'runStartupSequence(startupSteps())']);
    });

    test('the other shapes an awaited step can be written in are reported too', () {
      final scan = scanMainAwaits('''
FutureOr<void> main() async {
  await Hive.initFlutter();
  await Future.wait([setupLocalization(), setupLicense()]);
  await (StorageBox.ensureOpened(reset: false));
  await for (final step in stepStream()) {
    await step.run();
  }
  scheduleMicrotask(() async => await rootBundle.loadString('assets/x.json'));
}
''');

      expect(scan.awaited, [
        'Hive.initFlutter()',
        'Future.wait([setupLocalization(), setupLicense()])',
        '(StorageBox.ensureOpened(reset: false))',
        'await for (final step in stepStream())',
        'step.run()',
        "rootBundle.loadString('assets/x.json')",
      ]);
    });

    test('a source with no main() fails loudly rather than reporting nothing awaited', () {
      // The failure mode a text scan has: `indexOf` returning -1 and the scan reading either the
      // whole file or nothing, both of which look like "main() awaits only the sequence".
      expect(() => scanMainAwaits('void notMain() async {}'), throwsStateError);
    });
  });
}

/// What one parse of a `main()` found: how much body there was, and every expression it awaits.
class MainAwaitScan {
  MainAwaitScan(this.statements, this.awaited);

  /// Statements directly in `main()`'s block, for the vacuity guard.
  final int statements;

  /// Each awaited expression as written, in source order. `await for` is included as the loop
  /// header, because a stream of startup work is awaited startup work too.
  final List<String> awaited;
}

/// Every await in the top-level `main()` of [source].
///
/// Parsed rather than pattern-matched. A pattern has to spell the shape of the call it is looking
/// for, and every shape it does not spell is silently *absent* from the result -- so an equality
/// assertion against the result keeps passing while the thing it was written to catch is added.
/// The parser enumerates instead: an `await` is an `AwaitExpression` whatever its receiver, its
/// arguments or its nesting, so nothing here names a function, a receiver or a call shape.
MainAwaitScan scanMainAwaits(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final mains = unit.declarations.whereType<FunctionDeclaration>().where((d) => d.name.lexeme == 'main').toList();
  if (mains.length != 1) {
    throw StateError('expected exactly one top-level main(), found ${mains.length}; this rule reads nothing');
  }

  final body = mains.single.functionExpression.body;
  final visitor = _AwaitVisitor();
  body.accept(visitor);
  return MainAwaitScan(body is BlockFunctionBody ? body.block.statements.length : 0, visitor.awaited);
}

/// Every `await` under one function body, including the ones inside closures it creates: a step
/// awaited in a callback that `main()` installs is just as unguarded as one awaited inline.
class _AwaitVisitor extends RecursiveAstVisitor<void> {
  final List<String> awaited = [];

  @override
  void visitAwaitExpression(AwaitExpression node) {
    awaited.add(node.expression.toSource());
    super.visitAwaitExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    // `await for (...)` carries no `AwaitExpression`; the await is a token on the loop.
    if (node.awaitKeyword != null) {
      awaited.add('await for (${node.forLoopParts.toSource()})');
    }
    super.visitForStatement(node);
  }
}
