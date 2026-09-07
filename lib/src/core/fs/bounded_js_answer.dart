import 'dart:js_interop';

/// Awaits [promise] but gives up after [timeout], reporting "no answer" as `null`
/// and the answer itself as the JS value the promise settled with.
///
/// The `then<T?>` hop is load-bearing, not a style choice. `Future.timeout`
/// type-checks `onTimeout` against the **runtime** type argument of the future it
/// is called on, and `JSPromise<T>.toDart` is a `Future<T>` no matter what it is
/// assigned to — widening it through a `Future<T?>` variable changes only the
/// static type, so `onTimeout: () => null` still failed its runtime cast on the
/// web with `type '() => Null' is not a subtype of type '(() => FutureOr<bool>)?'`.
/// The analyzer accepts that code, so nothing but a browser run can catch it.
/// Building a future whose *own* type argument is nullable is what makes `null` a
/// legal answer. Generic instantiation does not exempt this: dart2js reifies `T`,
/// so the receiver's runtime type argument is `T?` only because it is written that
/// way here.
///
/// `null` therefore means "the promise never settled". A rejection is *not*
/// rounded into it: it propagates, so a caller can tell "the browser refused" from
/// "the browser never answered".
///
/// Lives in its own Flutter-free library for the same reason it always did: it is
/// the only part of the `navigator.storage` path a `dart test --platform chrome`
/// suite can import, and this trap is invisible to every other kind of test.
Future<T?> awaitBoundedJsAnswer<T extends JSAny?>(JSPromise<T> promise, Duration timeout) {
  return promise.toDart.then<T?>((value) => value).timeout(timeout, onTimeout: () => null);
}

/// [awaitBoundedJsAnswer] for a promise of a JS boolean, unwrapped to a Dart
/// [bool]. "No answer" stays `null`.
///
/// The unwrap is deliberately outside the bound: `JSBoolean.toDart` is
/// synchronous, so which side of the timeout it sits on cannot change the outcome,
/// and keeping the bounded future's type argument `JSBoolean?` keeps the whole
/// deadline argument above in one place instead of restating it per element type.
Future<bool?> awaitBoundedJsBool(JSPromise<JSBoolean> promise, Duration timeout) {
  return awaitBoundedJsAnswer<JSBoolean>(promise, timeout).then((value) => value?.toDart);
}
