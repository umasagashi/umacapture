// The generic half of `bounded_js_answer.dart`: `awaitBoundedJsAnswer`, the bound
// every `navigator.storage` promise goes through when its answer is not a bool.
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/bounded_js_answer_web_test.dart
//
// storage_persistence_web_test.dart already pins the `bool` wrapper. This suite
// exists because the trap the wrapper was written around is a **runtime** type
// check, and a generic function passes or fails it once per instantiation:
// `Future.timeout` checks `onTimeout` against the runtime type argument of its
// receiver, dart2js reifies `T`, and the analyzer sees none of it. So the object
// and number instantiations are exercised here rather than argued from the bool
// one having worked.
//
// It must run in a real browser and under `dart test` for the same reasons as its
// siblings: `JSPromise.toDart` exists nowhere else, and the flutter runner would
// compile the whole framework first. CI runs it in the `Browser tests` job in
// .github/workflows/ci.yml; a file not named on that command line is run by
// nothing.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// See the note in record_mutation_lock_web_test.dart: `test` resolves
// transitively through `flutter_test`, so no dev_dependencies entry is added.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:umacapture/src/core/fs/bounded_js_answer.dart';

/// The bound handed to the subject, when the subject is meant to answer.
const _budget = Duration(seconds: 5);

/// The suite's own wedge detector, deliberately **longer** than every bound the
/// subject is given — see storage_persistence_web_test.dart for why equal
/// deadlines would make "the bound works" and "the bound never fires"
/// indistinguishable.
const _guard = Duration(seconds: 15);

void main() {
  test('an unanswered object promise gives up as null rather than throwing', () async {
    // The `onTimeout: () => null` cast is checked against the receiver's runtime
    // type argument, so this is the assertion that the generic version builds a
    // `Future<T?>` and not a `Future<T>`. A regression here throws
    // `type '() => Null' is not a subtype of type '(() => FutureOr<JSObject>)?'`.
    final pending = Completer<JSObject>();
    final answer = await awaitBoundedJsAnswer<JSObject>(
      pending.future.toJS,
      const Duration(milliseconds: 50),
    ).timeout(_guard);
    expect(answer, isNull);
  });

  test('an unanswered promise gives up as null at a second instantiation too', () async {
    // Same check with a different `T`. The cast is per-instantiation, so one
    // passing instantiation is not evidence about another.
    final pending = Completer<JSNumber>();
    final answer = await awaitBoundedJsAnswer<JSNumber>(
      pending.future.toJS,
      const Duration(milliseconds: 50),
    ).timeout(_guard);
    expect(answer, isNull);
  });

  test('an answered promise hands back the very object it resolved with', () async {
    final resolved = JSObject();
    final answer = await awaitBoundedJsAnswer<JSObject>(Future.value(resolved).toJS, _budget).timeout(_guard);
    expect(answer, isNotNull);
    expect(identical(answer, resolved), isTrue, reason: 'the bound must pass the answer through unchanged');
  });

  test('the bool wrapper still unwraps to a Dart bool through the generic bound', () async {
    // `awaitBoundedJsBool` is now a thin layer over the generic one; its callers
    // (`WebStoragePersistence.read` / `.request`) must keep seeing true/false/null
    // and never a `JSBoolean`.
    expect(await awaitBoundedJsBool(Future.value(true.toJS).toJS, _budget).timeout(_guard), isTrue);
    expect(await awaitBoundedJsBool(Future.value(false.toJS).toJS, _budget).timeout(_guard), isFalse);
    final pending = Completer<JSBoolean>();
    expect(await awaitBoundedJsBool(pending.future.toJS, const Duration(milliseconds: 50)).timeout(_guard), isNull);
  });

  test('a rejected promise still reaches the caller as an error', () async {
    // "No answer" and "refused" are different outcomes and the bound must not
    // merge them: a caller that wants to log the refusal has nothing left if the
    // rejection is rounded into the same null the give-up produces.
    //
    // "Something came out of the await" is not an observation of that — the
    // suite's own guard manufactures an error too — so both failure modes are
    // named separately below.
    final thrown = StateError('no storage manager');
    final rejected = Future<JSObject>.error(thrown).toJS;

    Object? caught;
    JSObject? returned;
    var settledWithValue = false;
    try {
      returned = await awaitBoundedJsAnswer<JSObject>(rejected, _budget).timeout(_guard);
      settledWithValue = true;
    } catch (error) {
      caught = error;
    }

    expect(settledWithValue, isFalse, reason: 'the bound rounded the rejection into $returned instead of raising it');
    expect(
      caught,
      isNot(isA<TimeoutException>()),
      reason: 'nothing settled within $_guard, so the rejection wedged the bound rather than reaching the caller',
    );
    expect(caught, isA<JSObject>(), reason: 'a converted Dart future rejects with a JS Error, not with the error');
    final boxed = (caught as JSObject)['error'];
    expect(boxed, isA<JSBoxedDartObject>(), reason: 'the rejection must still carry the Dart error it was given');
    expect(identical((boxed as JSBoxedDartObject).toDart, thrown), isTrue);
  });
}
