// A loop made only of `pump()`s can hang forever, and no clock in the suite reaches it.
//
// `package:test`'s per-test timeout (30s) and the widget binding's own
// (`AutomatedTestWidgetsFlutterBinding.defaultTestTimeout`, 10 minutes) are both *real* timers.
// Inside `testWidgets` the body runs in `FakeAsync`: `tester.pump()` elapses the *fake* clock and
// returns without ever handing control back to the real event loop. A loop whose only suspension
// point is `pump()` therefore never lets either timer's callback run -- the process spins at 100%
// CPU until something outside kills it. Measured: the two real sites in
// `delete_record_dialog_test.dart` were left spinning and killed by hand at 23 and 11.5 minutes --
// those are how long the observer waited, not a bound the run was heading for, because there is no
// bound. (The commit that capped them quotes 780s for the same shape; that is a third such wait, not
// a different measurement of the same one.) The contrast is the number that means something: the
// same shape written with a `Completer` -- which suspends on something real -- was cut off at 10
// minutes by the binding's own timeout, as designed.
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
    // Per bound, not `isNotEmpty`: the tree has dozens of `for (final x in xs) { await pump(); }`,
    // so one lump canary is satisfied by the sturdiest path alone -- collection bound, literal
    // `pump` -- and stays green with `_Counters`, `_TripConditions` and `_yieldsToRealTime` all
    // broken. Each class of verdict this rule can reach has to still be reachable.
    for (final bound in [PumpLoopBound.collection, PumpLoopBound.counter]) {
      expect(
        loops.where((e) => e.bound == bound),
        isNotEmpty,
        reason: 'no ${bound.name}-bounded pump loop was recognised at all; the scan stopped classifying',
      );
    }

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

  test('no `testWidgets` body waits on the real clock', () {
    final files = Directory('test').listSync(recursive: true).whereType<File>().where((e) => e.path.endsWith('.dart'));

    final waits = <FakeClockWait>[];
    for (final file in files) {
      waits.addAll(scanFakeClockWaits(file.readAsStringSync(), file: file.path.replaceAll(r'\', '/')));
    }

    // The seed name has to still exist where the rule thinks it does, or this observes nothing.
    // Pinned to the file rather than to a count, because the correct count here is zero and a rule
    // that has stopped working reports zero too.
    expect(
      File('test/support/settling.dart').readAsStringSync(),
      contains('Future<void> waitUntil('),
      reason: 'the helper this rule is about was renamed or moved; ${_realClockWaitNames.join(", ")} is stale',
    );

    expect(
      waits.map((e) => e.describe()).toList(),
      isEmpty,
      reason:
          '`waitUntil` polls with `Future.delayed`, which is fake inside a `testWidgets` body and '
          'only advances when something pumps. Nothing does, here, so the poll never runs a second '
          'time: the loop parks, its `Stopwatch` deadline is never re-read, and the `fail()` that '
          'would name the condition is unreachable. Use `settleUntil`, which takes the '
          '`WidgetTester` and steps out to real time every turn -- or, if the wait genuinely has no '
          'tester to pump, put it inside `tester.runAsync(...)`, which this rule allows.',
    );
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

    test('re-deriving the loop condition in the body is not a counter', () {
      // The ordinary spelling of a polling loop, and the one that hung. Nothing counts the turns;
      // the name on the left of the `=` is simply the same name the condition reads.
      final found = scan(
        'var pending = s.hasPending; '
        'while (pending) { s.settle(); await tester.pump(); pending = s.hasPending; }',
      );
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });

    test('an assignment that reads the name it writes still counts', () {
      // The other direction of the same judgement: `i = i + 1` advances, so it must stay a counter.
      final found = scan('for (var i = 0; s.pending; ) { if (i >= 8) fail("x"); await tester.pump(); i = i + 1; }');
      expect(found.single.bound, PumpLoopBound.counter);
    });

    test('a `throw` at the cap counts as loudly as `fail`', () {
      final found = scan('for (var i = 0; s.pending; i++) { if (i >= 8) throw StateError("x"); await tester.pump(); }');
      expect(found.single.bound, PumpLoopBound.counter);
    });

    test('an `expect` at the cap is accepted even though it may pass', () {
      // Documented on `_TripConditions` as a deliberate let-through: a parse cannot know whether an
      // `expect` can fail. Pinned so that tightening it later is a decision and not a side effect.
      final found = scan('for (var i = 0; s.pending; i++) { if (i > 100) expect(w, isEmpty); await tester.pump(); }');
      expect(found.single.bound, PumpLoopBound.counter);
    });

    test('a periodic assertion is not a cap', () {
      // `f` is advanced, and it is read by an `if` that ends the test loudly -- but `f % 10 == 0`
      // does not stop being satisfiable as `f` grows, so no value of `f` ends this loop. The read
      // has to be able to end it, not merely to name it.
      final found = scan('var f = 0; while (!r()) { await tester.pump(); f++; if (f % 10 == 0) expect(x, y); }');
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });

    test('a `+=` whose step comes from the world is not a counter', () {
      // The condition *is* a cap comparison on `s`, and that is not enough: `store.drained()` may
      // answer 0 for ever, so `s` need never reach `n`. Only a step the parse can see is constant
      // makes a compound assignment an advance.
      final found = scan('var s = 0; while (s < n) { await tester.pump(); s += store.drained(); }');
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });

    test('a cap that lives in a nested loop does not bound the outer one', () {
      // The inner `for` is bounded, and says so with a counter and a `fail` -- but it is the inner
      // loop those bound. The outer `while` turns as often as `s.pending` says, and a cap it can
      // only reach by entering a loop that may run zero times is no cap of its own.
      final found = scan(
        'while (s.pending) { for (var i = 0; i < n; i++) { if (i >= 8) fail("x"); } await tester.pump(); }',
      );
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });

    test('a `runAsync` on something that is not a `WidgetTester` exempts the loop anyway', () {
      // No types are resolved, so this is the cost of the exemption, pinned rather than assumed.
      expect(scan('while (s.pending) { await pool.runAsync(f); await tester.pump(); }'), isEmpty);
    });

    test('a loop calling the canonical wait every turn is exempt', () {
      // The failure message recommends `settleUntil`; a loop that takes the advice must not be
      // reported for it. `settleUntil` lives in another file, so it is named, not resolved.
      expect(scan('while (s.pending) { await settleUntil(tester, r, describe: "x"); await tester.pump(); }'), isEmpty);
    });

    test('`await for` is not bounded by its "collection"', () {
      // A stream has no length, and one that never closes parks the loop for good.
      final found = scan('await for (final e in s.stream) { await tester.pump(); }');
      expect(found.single.bound, PumpLoopBound.none);
      expect(found.single.header, startsWith('await for ('));
    });

    test('a synchronous `for-in` is still bounded by its collection', () {
      expect(scan('for (final e in list) { await tester.pump(); }').single.bound, PumpLoopBound.collection);
    });

    test('a report names the file and line it came from', () {
      // The only thing a reader gets when this fails, so it is checked rather than assumed.
      final found = scanPumpLoops('void main() {\n  while (s.pending) { await tester.pump(); }\n}', file: 'a/b.dart');
      expect(found.single.describe(), 'a/b.dart:2  while (s.pending)');
    });
  });

  // A pump reached through a helper is the same pump: this is how the tree actually spells it
  // (`_pumpApp`, `_pumpFor`, `_settlePendingDeletes`), so it is exercised as its own group.
  group('helpers declared in the file', () {
    test('a loop that pumps through a private helper is reported', () {
      final found = scanPumpLoops(
        'void main() { testWidgets("x", (tester) async { while (s.pending) { await _pumpApp(tester); } }); }\n'
        'Future<void> _pumpApp(WidgetTester tester) async { await tester.pump(); }',
      );
      expect(found, hasLength(1));
      expect(found.single.isBounded, isFalse);
    });

    test('a helper calling a helper is reported too', () {
      final found = scanPumpLoops(
        'void main() { testWidgets("x", (tester) async { while (s.pending) { await _outer(tester); } }); }\n'
        'Future<void> _outer(WidgetTester tester) async { await _inner(tester); }\n'
        'Future<void> _inner(WidgetTester tester) async { await tester.pumpAndSettle(); }',
      );
      expect(found, hasLength(1));
    });

    test('a helper that never pumps leaves the loop alone', () {
      final found = scanPumpLoops(
        'void main() { testWidgets("x", (tester) async { while (s.pending) { await _quiet(); } }); }\n'
        'Future<void> _quiet() async { await s.next; }',
      );
      expect(found, isEmpty);
    });

    test('a helper that steps out to real time every turn exempts the loop', () {
      // The direction that would otherwise turn a correct wait red once helpers are resolved: the
      // helper does pump, but it hands control back first.
      final found = scanPumpLoops(
        'void main() { testWidgets("x", (tester) async { while (s.pending) { await _settle(tester); } }); }\n'
        'Future<void> _settle(WidgetTester tester) async { await tester.runAsync(f); await tester.pump(); }',
      );
      expect(found, isEmpty);
    });

    test('a helper in another file is out of reach, and says so by being missed', () {
      // The remaining gap, pinned so it is a known limit rather than a surprise: nothing here
      // declares `_pumpApp`, so the loop is invisible.
      expect(
        scanPumpLoops('void main() { testWidgets("x", (tester) async { while (s.pending) { await _pumpApp(t); } }); }'),
        isEmpty,
      );
    });
  });

  group('the real-clock wait scan', () {
    test('`waitUntil` called straight from a `testWidgets` body is reported', () {
      final found = scanFakeClockWaits(
        'void main() { testWidgets("x", (tester) async { await waitUntil(r, describe: "y"); }); }',
        file: 'a/b.dart',
      );
      expect(found.single.describe(), 'a/b.dart:1  waitUntil(...)');
    });

    test('the same call inside `runAsync` is correct and is not reported', () {
      expect(
        scanFakeClockWaits(
          'void main() { testWidgets("x", (tester) async { '
          'await tester.runAsync(() => waitUntil(r, describe: "y")); }); }',
        ),
        isEmpty,
      );
    });

    test('a plain `test()` is where this helper belongs', () {
      expect(
        scanFakeClockWaits('void main() { test("x", () async { await waitUntil(r, describe: "y"); }); }'),
        isEmpty,
      );
    });

    test('a helper that wraps the wait is reported at the `testWidgets` that reaches it', () {
      final found = scanFakeClockWaits(
        'void main() { testWidgets("x", (tester) async { await _await(env); }); }\n'
        'Future<void> _await(Env env) => waitUntil(env.ready, describe: "y");',
      );
      expect(found, hasLength(1));
    });

    test('a helper that wraps the wait in `runAsync` is not', () {
      // This is the shape `notification_sound_harvest_boundary_test.dart` uses, and it is correct.
      expect(
        scanFakeClockWaits(
          'void main() { testWidgets("x", (tester) async { await _harvest(tester); }); }\n'
          'Future<void> _harvest(WidgetTester tester) async { '
          'await tester.runAsync(() async { await waitUntil(r, describe: "y"); }); }',
        ),
        isEmpty,
      );
    });
  });
}

/// How a fake-advancing pump loop is prevented from running forever, if it is.
enum PumpLoopBound {
  /// Nothing caps the number of iterations.
  none,

  /// The loop walks a collection, so the collection's length caps it.
  collection,

  /// A counter the loop advances by a constant is compared against a bound the loop does not move,
  /// either by the loop condition or by a guard in the body that fails or throws.
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
  final visitor = _PumpLoopVisitor(file, parsed.lineInfo, _Names.resolve(parsed.unit));
  parsed.unit.accept(visitor);
  return visitor.found;
}

/// Every call under a `testWidgets` body that waits on the *real* clock from inside the fake one.
///
/// `waitUntil` (`test/support/settling.dart`) polls with a bare `Future.delayed`, which only a real
/// event loop advances. Called from a `testWidgets` body it is the same hang the loop rule removes,
/// arriving by a different road: nothing turns the fake clock, so the `Stopwatch` it checks is never
/// read a second time and its `fail()` is unreachable by construction. There is no loop at the call
/// site -- the loop is inside the helper, in a file the scan exempts -- so [scanPumpLoops] cannot
/// see it. [file] only labels the results.
List<FakeClockWait> scanFakeClockWaits(String source, {String file = '<source>'}) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final visitor = _FakeClockWaitVisitor(file, parsed.lineInfo, _Names.resolve(parsed.unit));
  parsed.unit.accept(visitor);
  return visitor.found;
}

/// One `waitUntil`-family call reached from a `testWidgets` body.
class FakeClockWait {
  FakeClockWait(this.file, this.line, this.call);

  final String file;
  final int line;
  final String call;

  String describe() => '$file:$line  $call';
}

/// Turning the fake clock. Not a list of "pump" spellings: the property is *drives the loop forward
/// without ever handing control to the real event loop*, so it covers `idle()` (elapse to the next
/// fake timer), `pumpEventQueue` / `flushMicrotasks` (drain the fake microtask queue) and
/// `FakeAsync.elapse` / `elapseBlocking` (advance the fake clock outright) as well as the `pump`
/// family. Anything that suspends on something real -- a `Completer`, a `dart:io` future -- is
/// deliberately absent: those do yield, and the measured 30s / 10-minute timeouts reach them.
///
/// Matched by name, like [_realTimeNames], and with the same limits: no types are resolved, so an
/// unrelated `idle()` on some other object counts, and a `pump` reached through a helper declared in
/// *another* file does not. The second of those was the load-bearing gap -- `_pumpTile`, `_pumpFor`,
/// `_pumpApp`, `_pumpEvent`, `_pump` and `_settlePendingDeletes` all exist in this tree -- so
/// [_Names] closes over the helpers declared in the file being scanned before any loop is judged.
/// Helpers that live in `test/support/` are still out of reach; the canonical one is handled by
/// naming it in [_realTimeNames] instead.
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

/// Stepping outside `FakeAsync`. `WidgetTester.runAsync` is the primitive; a `Future.delayed` inside
/// a `testWidgets` body is fake too, so it does not qualify.
///
/// `settleUntil` is here because it is the wait this rule's own failure message tells people to use,
/// and it calls `runAsync` on every turn. Without it a loop that took that advice was reported --
/// the recommendation and the exemption disagreed. It is named rather than resolved because it lives
/// in `test/support/settling.dart`, outside the file [_Names] can close over; the exemption test
/// above reads that file, so the day `settleUntil` stops calling `runAsync` this stops being true
/// loudly rather than quietly. `waitUntil`, its neighbour, is deliberately **not** here: it polls
/// with `Future.delayed`, which the fake clock does not advance -- see [scanFakeClockWaits].
///
/// Matched by name, which cannot tell a `WidgetTester` from any other object that happens to own a
/// `runAsync` -- no types are resolved here, only a parse. The exemption is narrowed by *position*
/// instead (see [_yieldsToRealTime]), which is the part that was actually load-bearing.
const _realTimeNames = {'runAsync', 'settleUntil'};

/// The names a `testWidgets` body must not call: waits that poll the real clock with a bare
/// `Future.delayed`, which nothing under `FakeAsync` advances.
const _realClockWaitNames = {'waitUntil'};

/// Whether [body] awaits a real-time step on **every** turn of the loop.
///
/// Position matters, not mere presence. A `runAsync` reached only through an `if`, a `switch` or a
/// nested closure leaves turns that never touch real time, and one such turn is enough for the loop
/// to spin forever -- so an exemption granted on presence alone would excuse exactly the loops this
/// rule exists to catch. Only statements the loop cannot skip count, and "cannot skip" is read
/// literally: this descends into nested [Block]s and nothing else, so a `try` body -- which does run
/// every turn -- is not credited either. That is the safe direction (a false report, which is loud)
/// and no site in the tree needs it.
bool _yieldsToRealTime(Statement body, Set<String> realTimeNames) {
  for (final statement in body is Block ? body.statements : [body]) {
    if (statement is Block && _yieldsToRealTime(statement, realTimeNames)) {
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
      if (awaited is MethodInvocation && realTimeNames.contains(awaited.methodName.name)) {
        return true;
      }
    }
  }
  return false;
}

/// Whether [body] -- a whole function body, not a loop body -- always reaches a real-time step.
bool _bodyYieldsToRealTime(FunctionBody body, Set<String> realTimeNames) => switch (body) {
  BlockFunctionBody(:final block) => _yieldsToRealTime(block, realTimeNames),
  ExpressionFunctionBody(:final expression) =>
    expression is MethodInvocation && realTimeNames.contains(expression.methodName.name),
  _ => false,
};

/// The call names that count as turning the fake clock, or as stepping out of it, **in one file**.
///
/// The constant sets above name library calls. A test file routinely wraps those in a private helper
/// (`_pumpApp`, `_settlePendingDeletes`), and a loop that calls the helper is the same loop -- so
/// every function declared in the unit whose body reaches a known name is folded in, to a fixed
/// point, before any loop is classified. One pass would already cover the helpers in this tree; the
/// fixed point is there so that a helper calling a helper does not reopen the gap silently.
///
/// Both directions are closed over, and they have to be: crediting `_pumpApp` as a pump without also
/// crediting a `_settle` that wraps `runAsync` would turn a correct wait into a reported violation.
class _Names {
  _Names(this.fakeClock, this.realTime, this.realClockWait);

  static _Names resolve(CompilationUnit unit) {
    final declarations = _Declarations()..visitNodes([unit]);
    final realTime = _close(declarations.bodies, _realTimeNames, (body, names) => _bodyYieldsToRealTime(body, names));
    bool calls(FunctionBody body, Set<String> names) => (_CallNames()..visitNodes([body])).names.any(names.contains);
    return _Names(
      _close(declarations.bodies, _fakeClockNames, calls),
      realTime,
      // Not `calls`: a helper is only tainted by a real-clock wait it makes *outside* `runAsync`.
      // `notification_sound_harvest_boundary_test.dart` wraps exactly such a wait in `runAsync` and
      // is correct; folding it in by mere presence reported all four of its cases.
      _close(declarations.bodies, _realClockWaitNames, (body, names) {
        final waits = _RealClockWaits(names);
        body.accept(waits);
        return waits.found.isNotEmpty;
      }),
    );
  }

  static Set<String> _close(
    Map<String, List<FunctionBody>> bodies,
    Set<String> seeds,
    bool Function(FunctionBody, Set<String>) reaches,
  ) {
    final names = {...seeds};
    for (var grew = true; grew;) {
      grew = false;
      for (final entry in bodies.entries) {
        if (names.contains(entry.key)) {
          continue;
        }
        if (entry.value.any((body) => reaches(body, names))) {
          names.add(entry.key);
          grew = true;
        }
      }
    }
    return names;
  }

  final Set<String> fakeClock;
  final Set<String> realTime;

  /// Names that reach a real-clock poll ([_realClockWaitNames]) -- banned under `testWidgets`.
  final Set<String> realClockWait;
}

/// Every function and method declared in the unit, by simple name. Names can collide (two classes
/// with a `settle()`); both bodies are kept, and either reaching a known name is enough, which is
/// the safe direction for the real-time set and the reporting direction for the fake-clock set.
class _Declarations extends _Collector {
  final Map<String, List<FunctionBody>> bodies = {};

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    bodies.putIfAbsent(node.name.lexeme, () => []).add(node.functionExpression.body);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    bodies.putIfAbsent(node.name.lexeme, () => []).add(node.body);
    super.visitMethodDeclaration(node);
  }
}

class _PumpLoopVisitor extends RecursiveAstVisitor<void> {
  _PumpLoopVisitor(this.file, this.lineInfo, this.names);

  final String file;
  final LineInfo lineInfo;
  final _Names names;
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
      // `await for` is a `ForEachParts` too, and there the "collection" is a stream: its length is
      // not known, may be infinite, and a stream that simply never closes leaves the loop parked
      // forever. Measured, not assumed -- before this line an `await for` scanned as `collection`.
      // So only a synchronous `for-in` gets the collection bound; an `await for` is judged like any
      // other loop and needs a counter. Nothing in this tree pumps inside an `await for`.
      final isAwait = node.awaitKeyword != null;
      _consider(node, node.body, const [], '${isAwait ? 'await ' : ''}for (${parts.toSource()})', forEach: !isAwait);
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
    if (!calls.names.any(names.fakeClock.contains)) {
      return;
    }
    if (_yieldsToRealTime(body, names.realTime)) {
      return;
    }

    final PumpLoopBound bound;
    if (forEach) {
      bound = PumpLoopBound.collection;
    } else {
      // A counter is only a cap once something reads it *in a way that can end the loop*: the loop
      // condition, or a guard in the body that ends the test. `i++` on its own bounds nothing, and
      // neither does a read that no value of the counter can falsify -- see [_CapComparison].
      final counters = _Counters()..visitNodes([body, ...updaters]);
      final caps = _CapComparison.of([...conditions, ..._TripConditions.of(body)]);
      // The far side must not itself be something the loop advances: `while (i < limit) { i++;
      // limit++; }` compares a counter against a moving target and never closes.
      final capped = caps.any((e) => counters.names.contains(e.counter) && !e.against.any(counters.names.contains));
      bound = capped ? PumpLoopBound.counter : PumpLoopBound.none;
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

/// Stops the walk at a nested loop, so that only *this* loop's own text is judged.
///
/// Both halves of the counter verdict need this, and for the same reason: an inner loop carries its
/// own counter and often its own `fail()`, and neither of them says anything about how long the
/// outer loop turns. `while (s.pending) { for (var i = 0; i < n; i++) { if (i >= 8) fail(...); }
/// await tester.pump(); }` reads as capped if the walk descends -- `i` is advanced and `i >= 8` is
/// loud -- while the outer `while` runs for ever, and an inner loop may not even execute once.
/// [_CallNames] deliberately does *not* mix this in: a pump anywhere inside the outer body, nested
/// or not, still makes the outer loop this rule's business, and that is the reporting direction.
mixin _OwnLoopOnly on RecursiveAstVisitor<void> {
  @override
  void visitWhileStatement(WhileStatement node) {}

  @override
  void visitDoStatement(DoStatement node) {}

  @override
  void visitForStatement(ForStatement node) {}
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

/// Names the loop *advances*: `i++`, `++i`, `i += n`, `i = i + n`.
///
/// The distinction between advancing a name and merely writing to it is the whole content of this
/// class, and getting it wrong is not a near miss. Any assignment used to count would make
///
/// ```dart
/// var pending = store.hasPendingDelete;
/// while (pending) { store.settle(); await tester.pump(); pending = store.hasPendingDelete; }
/// ```
///
/// "bounded by a counter" -- the ordinary spelling of a polling loop, re-deriving its condition from
/// the world each turn with nothing capping the turns. That is the exact loop this rule was written
/// after, and it passed. Measured, not reasoned: renaming the assignment target was enough to flip
/// the verdict, which is what showed the name, not the arithmetic, was carrying the judgement.
///
/// So: `++`/`--` in either position, `i += 1` / `i -= 1`, and a plain `=` only in the shape
/// `i = i + 1` -- the target, plus or minus a fixed amount. `pending = f()` replaces.
///
/// The *amount* has to be a literal the parse can read, and that is the second half of the same
/// judgement. `settled += store.drainedCount` differs from `settled = store.drainedCount` by one
/// keystroke, and the operator alone was carrying the whole difference: credited on `+=` alone, a
/// step the world may answer `0` to for ever counts as an advance, and the loop is declared bounded
/// while running exactly as long as the polling loop above. So `+=` is credited only for a constant
/// non-zero amount. The cost is that `i += step` for a genuinely fixed `step` held in a variable is
/// not credited -- a parse cannot see that it is fixed, and being reported (loudly) is the safe
/// direction. `*=` and friends are not credited at all: `i *= 2` from `0` never leaves `0`.
///
/// A counter still has to be *read* by something that can end the test before it caps anything; that
/// part is [_CapComparison], used from [_PumpLoopVisitor._consider].
class _Counters extends _Collector with _OwnLoopOnly {
  final Set<String> names = {};

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (const {'++', '--'}.contains(node.operator.lexeme)) {
      _record(node.operand);
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (const {'++', '--'}.contains(node.operator.lexeme)) {
      _record(node.operand);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final target = node.leftHandSide;
    final advances = switch (node.operator.lexeme) {
      '=' => target is SimpleIdentifier && _isConstantStepFrom(node.rightHandSide, target.name),
      '+=' || '-=' => _isConstantAmount(node.rightHandSide),
      _ => false,
    };
    if (advances) {
      _record(target);
    }
    super.visitAssignmentExpression(node);
  }

  void _record(Expression target) {
    if (target is SimpleIdentifier) {
      names.add(target.name);
    }
  }
}

/// A fixed, non-zero amount written out in the source: `1`, `-1`, `2`. `0` is excluded because a
/// step of zero is the very thing that makes a loop spin.
bool _isConstantAmount(Expression expression) {
  final operand = expression is PrefixExpression && const {'-', '+'}.contains(expression.operator.lexeme)
      ? expression.operand
      : expression;
  return operand is IntegerLiteral && operand.value != null && operand.value != 0;
}

/// Whether [expression] is [target] displaced by a constant: `i + 1`, `i - 1`, `1 + i`.
///
/// `1 - i` is deliberately not accepted -- it oscillates rather than advances -- and neither is
/// `i + step`, for the reason given on [_Counters].
bool _isConstantStepFrom(Expression expression, String target) {
  if (expression is! BinaryExpression || !const {'+', '-'}.contains(expression.operator.lexeme)) {
    return false;
  }
  final left = expression.leftOperand;
  final right = expression.rightOperand;
  if (left is SimpleIdentifier && left.name == target) {
    return _isConstantAmount(right);
  }
  return expression.operator.lexeme == '+' &&
      right is SimpleIdentifier &&
      right.name == target &&
      _isConstantAmount(left);
}

/// A relational comparison of a name against something else: `i < 10`, `turns >= issued`, `n > i`.
///
/// This is what turns a counter into a cap, and the reason it is a shape rather than a name is
/// U2-01's spelling `if (frames % 10 == 0) expect(...)`: `frames` is advanced, and it is read by an
/// `if` that ends the test loudly, so co-occurrence of the *name* between the two says "bounded"
/// while the loop runs for ever. What separates the two is that `i >= 8` stops being false once and
/// stays that way, whereas `frames % 10 == 0` is re-entered every tenth turn.
///
/// So the counter has to be a **direct operand** of a `<`/`<=`/`>`/`>=`, not a term inside one.
/// `==` and `!=` are excluded on the same ground: `while (i != 10)` closes only if the step happens
/// to land on 10, which a parse cannot know.
///
/// Two things this still does not check, both strictly narrower let-throughs than what it replaced:
/// the *direction* of the comparison against the sign of the step (`if (i < 8) fail(...)` reads as a
/// cap and trips immediately instead), and whether the comparison sits under a `!`. Neither shape
/// occurs in this tree.
class _CapComparison {
  _CapComparison(this.counter, this.against);

  /// The name being compared.
  final String counter;

  /// The identifiers on the other side of the comparison.
  final Set<String> against;

  static List<_CapComparison> of(List<Expression> expressions) => (_CapComparisons()..visitNodes(expressions)).found;
}

class _CapComparisons extends _Collector {
  final List<_CapComparison> found = [];

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (const {'<', '<=', '>', '>='}.contains(node.operator.lexeme)) {
      _record(node.leftOperand, node.rightOperand);
      _record(node.rightOperand, node.leftOperand);
    }
    super.visitBinaryExpression(node);
  }

  void _record(Expression side, Expression other) {
    if (side is SimpleIdentifier) {
      found.add(_CapComparison(side.name, _identifiersIn(other)));
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
class _TripConditions extends _Collector with _OwnLoopOnly {
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

/// Finds `testWidgets` bodies and reports the real-clock waits reached from inside them.
class _FakeClockWaitVisitor extends RecursiveAstVisitor<void> {
  _FakeClockWaitVisitor(this.file, this.lineInfo, this.names);

  final String file;
  final LineInfo lineInfo;
  final _Names names;
  final List<FakeClockWait> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // Prefix rather than equality: `testWidgetsWithLeakTracking` and friends are the same body.
    if (!node.methodName.name.startsWith('testWidgets')) {
      super.visitMethodInvocation(node);
      return;
    }
    final waits = _RealClockWaits(names.realClockWait);
    node.argumentList.accept(waits);
    for (final call in waits.found) {
      found.add(FakeClockWait(file, lineInfo.getLocation(call.offset).lineNumber, '${call.methodName.name}(...)'));
    }
  }
}

class _RealClockWaits extends RecursiveAstVisitor<void> {
  _RealClockWaits(this.banned);

  final Set<String> banned;
  final List<MethodInvocation> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'runAsync') {
      // Whatever is passed to `runAsync` runs on the real event loop, so a real-clock poll there is
      // the correct thing rather than the defect -- do not descend into it.
      return;
    }
    if (banned.contains(node.methodName.name)) {
      found.add(node);
    }
    super.visitMethodInvocation(node);
  }
}
