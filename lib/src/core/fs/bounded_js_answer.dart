import 'dart:js_interop';

/// Awaits [promise] but gives up after [timeout], reporting "no answer" as `null`
/// and the answer itself as a Dart [bool].
///
/// The `then<bool?>` hop is load-bearing, not a style choice. `Future.timeout`
/// type-checks `onTimeout` against the **runtime** type argument of the future it
/// is called on, and `JSPromise<JSBoolean>.toDart` is a `Future<JSBoolean>` no
/// matter what it is assigned to — widening it through a `Future<JSBoolean?>`
/// variable changes only the static type, so `onTimeout: () => null` still failed
/// its runtime cast on the web with
/// `type '() => Null' is not a subtype of type '(() => FutureOr<bool>)?'`. The
/// analyzer accepts that code, so nothing but a browser run can catch it. Building
/// a future whose *own* type argument is nullable is what makes `null` a legal
/// answer.
///
/// Lives in its own Flutter-free library for the same reason: it is the only part
/// of the storage-persistence path a `dart test --platform chrome` suite can
/// import, and this trap is invisible to every other kind of test.
Future<bool?> awaitBoundedJsBool(JSPromise<JSBoolean> promise, Duration timeout) {
  return promise.toDart.then<bool?>((value) => value.toDart).timeout(timeout, onTimeout: () => null);
}
