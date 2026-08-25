// The browser half of the OPFS storage-persistence path: the bounded await that
// `WebStoragePersistence.read` / `.request` put around `navigator.storage`.
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/storage_persistence_web_test.dart
//
// It must run in a real browser and it must run under `dart test`, for the same
// two reasons as record_mutation_lock_web_test.dart: `JSPromise.toDart` only
// exists there, and the flutter runner would compile the whole framework first.
// CI runs it in the `Browser tests` job in .github/workflows/ci.yml.
//
// What it pins:
//
// * `Future.timeout` checks `onTimeout` against the **runtime** type argument of
//   its receiver. `JSPromise<JSBoolean>.toDart` hands back a `Future<JSBoolean>`,
//   and assigning that to a `Future<JSBoolean?>` widens only the static type — so
//   `onTimeout: () => null` compiled clean and then threw
//   `type '() => Null' is not a subtype of type '(() => FutureOr<bool>)?'` on
//   every boot, turning the persistence request into a caught error. The analyzer
//   cannot see this and neither can a VM test; only a browser run can.
//
// * A rejection reaches the caller *as a rejection*. Distinguishing that from a
//   bound that never settles takes more than "the await ended with an object",
//   because the suite's own guard produces an object too — see the third test.
//
// This suite deliberately does not import `storage_persistence_web.dart` itself:
// that file pulls in `app_logger.dart` and therefore `package:flutter`, which
// plain `dart test` cannot compile for the browser. `bounded_js_answer.dart` is
// split out so the defect stays reachable from here.
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

/// The bound handed to the subject: the deadline whose behaviour is under test.
const _budget = Duration(seconds: 5);

/// The suite's own wedge detector, and deliberately **longer** than [_budget].
///
/// These two used to be the same constant, which is what let a bound that never
/// settles pass for one that works: with equal deadlines the subject's own
/// give-up and the guard's `TimeoutException` race, and whichever wins puts
/// *something* at the same await. Ordering them means the subject always gets to
/// produce its own outcome first, so the guard firing can only ever mean "the
/// subject produced nothing at all" — a distinct, nameable failure rather than
/// one more object that a loose matcher would accept as success.
const _guard = Duration(seconds: 15);

void main() {
  test('an unanswered promise resolves to null rather than throwing', () async {
    // Firefox's persistence doorhanger leaves the promise pending until the user
    // answers it, which may be never. The give-up must be a value, not a TypeError.
    final pending = Completer<JSBoolean>();
    final answer = await awaitBoundedJsBool(pending.future.toJS, const Duration(milliseconds: 50)).timeout(_guard);
    expect(answer, isNull);
  });

  test('an answered promise is unwrapped to its Dart bool', () async {
    expect(await awaitBoundedJsBool(Future.value(true.toJS).toJS, _budget).timeout(_guard), isTrue);
    expect(await awaitBoundedJsBool(Future.value(false.toJS).toJS, _budget).timeout(_guard), isFalse);
  });

  test('a rejected promise still reaches the caller as an error', () async {
    // `read` / `request` wrap the call in a try/catch and report `unknown`; the
    // bound must not swallow the rejection into a null and hide that path.
    //
    // "Something came out of the await" is not an observation of that. The suite's
    // own guard manufactures an error too, so a matcher that accepts any object
    // accepts the guard's `TimeoutException` as evidence about the subject. Both
    // of the ways the subject can fail to propagate are therefore named below:
    // `null` is what the bound produces when it gives up on the rejection, and a
    // `TimeoutException` from the guard is what remains when the bound does not
    // even do that.
    final thrown = StateError('no storage manager');
    final rejected = Future<JSBoolean>.error(thrown).toJS;

    Object? caught;
    bool? returned;
    var settledWithValue = false;
    try {
      returned = await awaitBoundedJsBool(rejected, _budget).timeout(_guard);
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

    // `Future.toJS` rejects with a JS `Error` placeholder and boxes the Dart error
    // under `.error`, and `JSPromise.toDart` does not unbox it — see the header of
    // record_mutation_lock_web_test.dart. So the caller sees a `JSObject`, not the
    // `StateError`, and the fact worth pinning is that the original error is still
    // in there: that is what `read` / `request` would have to reach for.
    expect(caught, isA<JSObject>(), reason: 'a converted Dart future rejects with a JS Error, not with the error');
    final boxed = (caught as JSObject)['error'];
    expect(boxed, isA<JSBoxedDartObject>(), reason: 'the rejection must still carry the Dart error it was given');
    expect(identical((boxed as JSBoxedDartObject).toDart, thrown), isTrue);
  });
}
