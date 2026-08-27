// A loop made only of `pump()`s can hang forever, and no clock in the suite reaches it.
//
// `package:test`'s per-test timeout (30s) and the widget binding's own
// (`AutomatedTestWidgetsFlutterBinding.defaultTestTimeout`, 10 minutes) are both *real* timers.
// Inside `testWidgets` the body runs in `FakeAsync`: `tester.pump()` elapses the *fake* clock and
// returns without ever handing control back to the real event loop. A loop whose only suspension
// point is `pump()` therefore never lets either timer's callback run -- the process spins at 100%
// CPU until something outside kills it. Measured: two real sites in
// `delete_record_dialog_test.dart` hung for 23 minutes and 11.5 minutes respectively and had to be
// killed by hand, while the same shape written with a `Completer` (which does suspend on something
// real) was cut off at 10 minutes as designed.
//
// So the rule cannot be "every wait has a timeout": a wall-clock bound is exactly what does not
// reach here. The rule is that a loop the fake clock alone drives has to be bounded by its own
// *iteration count*. `test/support/settling.dart` stays the canonical wait and is untouched by this
// -- `settleUntil` calls `runAsync`, which steps back out to real time, which is what makes its
// 20-second bound reachable in the first place.
//
// Scope is `test/` only. `integration_test/` runs on a live binding where `pump` does yield to real
// time, so the mechanism above does not exist there.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/pump_loop_bound_guard_test.dart
import 'dart:io';

// `analyzer` reaches this package transitively (through the codegen stack). Depended on here rather
// than promoted to a direct dev_dependency because pinning it would freeze the version the codegen
// packages resolve to, and this guard only ever needs the parser. Same arrangement as
// `module_update_guard_startup_test.dart`.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/visitor.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every fake-advancing pump loop under test/ is capped by an iteration count', () {
    final files = Directory('test').listSync(recursive: true).whereType<File>().where((e) => e.path.endsWith('.dart'));

    final loops = <PumpLoop>[];
    var scanned = 0;
    for (final file in files) {
      scanned++;
      loops.addAll(scanPumpLoops(file.readAsStringSync(), file: file.path.replaceAll(r'\', '/')));
    }

    // Without these the rule passes by having read nothing, or by having stopped recognising the
    // shape it is written to classify -- both of which look exactly like "no violations".
    expect(scanned, greaterThan(100), reason: 'the test tree was not read; this rule observes nothing now');
    expect(loops, isNotEmpty, reason: 'no fake-advancing pump loop was recognised at all');

    expect(
      loops.where((e) => !e.isBounded).map((e) => e.describe()).toList(),
      isEmpty,
      reason:
          'A loop driven only by the fake clock never yields to real time, so neither the 30s nor '
          'the 10-minute timeout can end it -- it hangs until the process is killed, with no '
          'reason printed. Give it a counter and `fail()` when the counter is exceeded, or use '
          '`settleUntil` from test/support/settling.dart, which returns to real time via '
          '`runAsync` on every turn.\n'
          'A cap written as `if (i > n) break;` (or `return`) is deliberately not accepted: it '
          'leaves the loop silently, so the assertions after it fail on unexplained state and the '
          'reader is back to guessing -- exactly the failure mode this rule removes. Say `fail()`.',
    );
  });

  test('the canonical wait itself stays exempt', () {
    // The exemption exists for `settleUntil`, so it is checked against the real source rather than
    // a paraphrase of it: a tightening that reads right on a synthetic sample and rejects the file
    // the rule was written around would be caught here and nowhere else.
    const path = 'test/support/settling.dart';
    final source = File(path).readAsStringSync();
    expect(source, contains('runAsync'), reason: '$path no longer has the shape this exempts');
    expect(scanPumpLoops(source, file: path), isEmpty);
  });

  // The classification is what the case above rests on, so it is exercised on sources of its own --
  // in both directions. A rule that flagged nothing and a rule that flagged every loop would be
  // indistinguishable from the assertion above alone.
  group('the loop scan itself', () {
    List<PumpLoop> scan(String body) => scanPumpLoops('void main() { testWidgets("x", (tester) async {$body}); }');

    test('a `while` driven only by pump is reported', () {
      final found = scan('while (s.pending) { s.settle(); await tester.pump(); }');
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });

    test('a counted `for` is not reported as unbounded', () {
      final found = scan('for (var i = 0; i < 10; i++) { await tester.pump(); }');
      expect(found.single.bound, PumpLoopBound.counter);
    });

    test('a counter tripped by fail() inside the body counts, whatever the loop condition says', () {
      final found = scan('for (var i = 0; s.pending; i++) { if (i >= 8) fail("stuck"); await tester.pump(); }');
      expect(found.single.bound, PumpLoopBound.counter);
    });

    test('a counter with no trip at all is still unbounded', () {
      // The bare `i++` of a `for (;;)` proves nothing on its own; something has to read it.
      final found = scan('for (var i = 0; s.pending; i++) { await tester.pump(); }');
      expect(found.single.isBounded, isFalse);
    });

    test('iterating a collection is bounded by the collection', () {
      final found = scan('for (final id in ids) { await tester.pump(); }');
      expect(found.single.bound, PumpLoopBound.collection);
    });

    test('a cap that breaks out silently is still reported', () {
      // Not an oversight: leaving quietly is the failure mode the rule exists to remove.
      final found = scan('for (var i = 0; s.pending; i++) { if (i >= 8) break; await tester.pump(); }');
      expect(found.single.isBounded, isFalse);
    });

    test('the other ways of turning the fake clock count too', () {
      // The property is "never hands control to the real event loop", not the word "pump".
      for (final turn in ['await tester.idle();', 'await pumpEventQueue();', 'async.elapse(step);']) {
        expect(scan('while (s.pending) { $turn }'), hasLength(1), reason: turn);
      }
    });

    test('a real-time step reached only through a branch does not exempt the loop', () {
      // Presence is not enough: the turns that skip the branch still touch nothing real, and one
      // such turn spinning forever is the whole defect.
      final found = scan('while (s.pending) { if (rare) { await tester.runAsync(f); } await tester.pump(); }');
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });

    test('a loop that steps out to real time is not this shape at all', () {
      // `settleUntil`'s own body. It is unbounded in iteration count *and* correct, because
      // `runAsync` lets the real clock -- and therefore its own stopwatch -- advance.
      final found = scan(
        'while (!ready()) { if (w.elapsed > t) fail("x"); '
        'await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1))); '
        'await tester.pump(); }',
      );
      expect(found, isEmpty);
    });

    test('a loop that never pumps is none of this rule\'s business', () {
      final found = scan('while (s.pending) { await s.next; }');
      expect(found, isEmpty);
    });

    test('`do`/`while` and `pumpAndSettle` are the same shape', () {
      final found = scan('do { await tester.pumpAndSettle(); } while (s.pending);');
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });
  });
}

/// How a fake-advancing pump loop is prevented from running forever, if it is.
enum PumpLoopBound {
  /// Nothing caps the number of iterations.
  none,

  /// The loop walks a collection, so the collection's length caps it.
  collection,

  /// A counter the loop advances is read either by the loop condition or by a guard in the body
  /// that fails or throws.
  counter,
}

/// One loop whose iterations are driven only by the fake clock.
class PumpLoop {
  PumpLoop(this.file, this.line, this.header, this.bound);

  final String file;
  final int line;

  /// The loop header as written, for the failure message.
  final String header;

  final PumpLoopBound bound;

  bool get isBounded => bound != PumpLoopBound.none;

  String describe() => '$file:$line  $header';
}

/// Every loop in [source] that awaits a pump and never returns to real time.
///
/// Parsed rather than pattern-matched: the shapes a loop and a cap can be written in are open-ended,
/// and a regexp silently reports *nothing* for every shape it does not spell -- which reads as
/// compliance. [file] only labels the results.
List<PumpLoop> scanPumpLoops(String source, {String file = '<source>'}) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final visitor = _PumpLoopVisitor(file, parsed.lineInfo);
  parsed.unit.accept(visitor);
  return visitor.found;
}

/// Turning the fake clock. Not a list of "pump" spellings: the property is *drives the loop forward
/// without ever handing control to the real event loop*, so it covers `idle()` (elapse to the next
/// fake timer), `pumpEventQueue` / `flushMicrotasks` (drain the fake microtask queue) and
/// `FakeAsync.elapse` / `elapseBlocking` (advance the fake clock outright) as well as the `pump`
/// family. Anything that suspends on something real -- a `Completer`, a `dart:io` future -- is
/// deliberately absent: those do yield, and the measured 30s / 10-minute timeouts reach them.
const _fakeClockNames = {
  'pump',
  'pumpAndSettle',
  'pumpWidget',
  'pumpFrames',
  'pumpBenchmark',
  'pumpEventQueue',
  'idle',
  'flushMicrotasks',
  'elapse',
  'elapseBlocking',
};

/// Stepping outside `FakeAsync`. The only one of these that exists is `WidgetTester.runAsync`; a
/// `Future.delayed` inside a `testWidgets` body is fake too, so it does not qualify.
///
/// Matched by name, which cannot tell a `WidgetTester` from any other object that happens to own a
/// `runAsync` -- no types are resolved here, only a parse. The exemption is narrowed by *position*
/// instead (see [_yieldsToRealTime]), which is the part that was actually load-bearing.
const _realTimeNames = {'runAsync'};

/// Whether [body] awaits a real-time step on **every** turn of the loop.
///
/// Position matters, not mere presence. A `runAsync` reached only through an `if`, a `try`, a
/// `switch` or a nested closure leaves turns that never touch real time, and one such turn is
/// enough for the loop to spin forever -- so an exemption granted on presence alone would excuse
/// exactly the loops this rule exists to catch. Only statements the loop cannot skip count.
bool _yieldsToRealTime(Statement body) {
  for (final statement in body is Block ? body.statements : [body]) {
    if (statement is Block && _yieldsToRealTime(statement)) {
      return true;
    }
    final Expression? evaluated = switch (statement) {
      ExpressionStatement(:final expression) => expression,
      VariableDeclarationStatement(:final variables) =>
        variables.variables.length == 1 ? variables.variables.single.initializer : null,
      ReturnStatement(:final expression) => expression,
      _ => null,
    };
    if (evaluated is AwaitExpression) {
      final awaited = evaluated.expression;
      if (awaited is MethodInvocation && _realTimeNames.contains(awaited.methodName.name)) {
        return true;
      }
    }
  }
  return false;
}

class _PumpLoopVisitor extends RecursiveAstVisitor<void> {
  _PumpLoopVisitor(this.file, this.lineInfo);

  final String file;
  final LineInfo lineInfo;
  final List<PumpLoop> found = [];

  @override
  void visitWhileStatement(WhileStatement node) {
    _consider(node, node.body, [node.condition], 'while (${node.condition.toSource()})');
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _consider(node, node.body, [node.condition], 'do { ... } while (${node.condition.toSource()})');
    super.visitDoStatement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    final parts = node.forLoopParts;
    if (parts is ForEachParts) {
      _consider(node, node.body, const [], 'for (${parts.toSource()})', forEach: true);
    } else if (parts is ForParts) {
      _consider(
        node,
        node.body,
        [if (parts.condition != null) parts.condition!],
        'for (${parts.toSource()})',
        updaters: parts.updaters,
      );
    }
    super.visitForStatement(node);
  }

  void _consider(
    AstNode loop,
    Statement body,
    List<Expression> conditions,
    String header, {
    bool forEach = false,
    List<Expression> updaters = const [],
  }) {
    final calls = _CallNames()..visitNodes([body, ...updaters]);
    if (!calls.names.any(_fakeClockNames.contains)) {
      return;
    }
    if (_yieldsToRealTime(body)) {
      return;
    }

    final PumpLoopBound bound;
    if (forEach) {
      bound = PumpLoopBound.collection;
    } else {
      // A counter is only a cap once something reads it: the loop condition, or a guard in the body
      // that ends the test. `i++` on its own bounds nothing.
      final counters = _Counters()..visitNodes([body, ...updaters]);
      final readers = [...conditions, ..._TripConditions.of(body)].map((e) => _identifiersIn(e)).expand((e) => e);
      bound = counters.names.intersection(readers.toSet()).isEmpty ? PumpLoopBound.none : PumpLoopBound.counter;
    }
    found.add(PumpLoop(file, lineInfo.getLocation(loop.offset).lineNumber, header, bound));
  }
}

Set<String> _identifiersIn(Expression expression) {
  final visitor = _Identifiers();
  expression.accept(visitor);
  return visitor.names;
}

/// Base for the small collectors below, which all walk a handful of nodes rather than a whole unit.
abstract class _Collector extends RecursiveAstVisitor<void> {
  void visitNodes(List<AstNode> nodes) {
    for (final node in nodes) {
      node.accept(this);
    }
  }
}

class _CallNames extends _Collector {
  final Set<String> names = {};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    names.add(node.methodName.name);
    super.visitMethodInvocation(node);
  }
}

class _Identifiers extends RecursiveAstVisitor<void> {
  final Set<String> names = {};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) => names.add(node.name);
}

/// Names the loop advances: `i++`, `++i`, `i += n`, `i = i + n`.
class _Counters extends _Collector {
  final Set<String> names = {};

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _record(node.operand);
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _record(node.operand);
    super.visitPrefixExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _record(node.leftHandSide);
    super.visitAssignmentExpression(node);
  }

  void _record(Expression target) {
    if (target is SimpleIdentifier) {
      names.add(target.name);
    }
  }
}

/// The conditions of `if`s whose taken branch ends the test loudly. Reaching one of these is what
/// turns a counter into a cap.
///
/// "Loudly" is the point, and it is why `break` and `return` are **not** accepted. A loop that
/// slips out silently at its cap leaves the assertions after it to fail on state nobody explained
/// -- the same "stops with no reason printed" this whole rule exists to remove. A cap has to name
/// itself.
///
/// The test for loudness is deliberately loose: any `fail(...)`, any `throw`, or any `expect(...)`
/// in the branch. It is a parse, so it cannot know whether a given `expect` can pass, and it does
/// not try. What that lets through is a branch whose `expect` succeeds --
/// `if (i > 100) expect(warnings, isEmpty);` is read as a cap while the loop actually runs on
/// forever. The alternative was to demand one exact spelling of a cap, which would reject the
/// honest variants people write; a guard rule that is wrong about rare deliberate nonsense is
/// cheaper than one that is wrong about ordinary code.
class _TripConditions extends _Collector {
  final List<Expression> conditions = [];

  static List<Expression> of(Statement body) => (_TripConditions()..visitNodes([body])).conditions;

  @override
  void visitIfStatement(IfStatement node) {
    if (_ends(node.thenStatement) || (node.elseStatement != null && _ends(node.elseStatement!))) {
      conditions.add(node.expression);
    }
    super.visitIfStatement(node);
  }

  bool _ends(Statement branch) {
    final calls = _CallNames()..visitNodes([branch]);
    if (calls.names.contains('fail') || calls.names.contains('expect')) {
      return true;
    }
    final throws = _Throws()..visitNodes([branch]);
    return throws.any;
  }
}

class _Throws extends _Collector {
  bool any = false;

  @override
  void visitThrowExpression(ThrowExpression node) => any = true;
}
