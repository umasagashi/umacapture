import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'bounded_js_answer.dart';

/// How long `navigator.storage.estimate()` may stay unanswered before this gives
/// up on it.
///
/// The value and the reasoning are `_storageManagerTimeout` in
/// `storage_persistence_web.dart`, which records the measurement behind it:
/// Firefox answers `navigator.storage` calls through a permission doorhanger that
/// may never be answered (measured: >20 min on a fresh profile), so every promise
/// under that namespace needs a bound. `estimate()` is not supposed to prompt
/// anywhere, and it is bounded for the same reason `persisted()` is: the row that
/// shows it must reach a state on every engine, and "unknown" is already a state
/// it can render.
///
/// It is a copy rather than a reference because `storage_persistence_web.dart`
/// imports `app_logger.dart` and therefore `package:flutter`, which `dart test
/// --platform chrome` cannot compile — importing it here would put this wrapper
/// out of reach of the only kind of test that can run it. If that file ever loses
/// its Flutter dependency, the two constants should become one.
const Duration originStorageEstimateTimeout = Duration(seconds: 5);

/// What the browser reports for the **whole origin**, not for this app's files.
///
/// `navigator.storage.estimate()` answers for everything the origin has stored:
/// OPFS (this app's files) *plus* IndexedDB — where Hive keeps the settings boxes
/// — *plus* CacheStorage, which holds `coi-serviceworker.js` and Flutter's own
/// service-worker cache. So [usageBytes] is always at least the app's own total
/// and normally larger, and the two numbers must never share a row in the UI: one
/// is "what this app stores", the other is "what this site costs the browser".
///
/// Both fields are optional in the spec's dictionary, so either may be `null` on
/// an engine that declines to report it. There is no Windows counterpart: the
/// platform has no notion of "what this origin costs the browser", which is why
/// this file is web-only rather than a conditional-import pair.
typedef OriginStorageEstimate = ({int? usageBytes, int? quotaBytes});

/// Reads the origin-wide estimate, or `null` when the browser gave no usable
/// answer.
///
/// `null` covers all three ways that can happen — no storage manager at all (an
/// insecure context), a rejected call, and a promise that never settled within
/// [originStorageEstimateTimeout] — because the caller renders the same "unknown"
/// for each. Nothing is thrown and nothing is logged here: this library is kept
/// free of `package:flutter` (see [originStorageEstimateTimeout]), and
/// `app_logger` is where a log line would have to come from, so the caller does
/// the reporting.
Future<OriginStorageEstimate?> readOriginStorageEstimate({Duration timeout = originStorageEstimateTimeout}) async {
  final JSPromise<web.StorageEstimate> promise;
  try {
    // Reaching `navigator.storage` at all throws in an insecure context, and so
    // does calling a member the engine does not implement, so the call itself is
    // inside the guard and not only the await.
    promise = web.window.navigator.storage.estimate();
  } catch (_) {
    return null;
  }
  return boundedOriginStorageEstimate(promise, timeout);
}

/// The bounded half of [readOriginStorageEstimate], split out so a test can hand
/// it a promise it controls — a browser's own `estimate()` always settles at once,
/// so the give-up path is unreachable through the public entry point.
Future<OriginStorageEstimate?> boundedOriginStorageEstimate(
  JSPromise<web.StorageEstimate> promise,
  Duration timeout,
) async {
  final web.StorageEstimate? estimate;
  try {
    estimate = await awaitBoundedJsAnswer<web.StorageEstimate>(promise, timeout);
  } catch (_) {
    return null;
  }
  if (estimate == null) {
    return null;
  }
  return (usageBytes: _byteCount(estimate, 'usage'), quotaBytes: _byteCount(estimate, 'quota'));
}

/// Reads [name] off [estimate] as a byte count, or `null` when it is absent.
///
/// `package:web` declares `usage` and `quota` as non-nullable `int` getters, but
/// the IDL dictionary marks both optional: an engine that omits one hands back
/// `undefined`, and the declared getter would convert that rather than report it.
/// Reading the property untyped and checking what arrived keeps "the engine did
/// not say" distinct from "the engine said zero".
int? _byteCount(web.StorageEstimate estimate, String name) {
  final value = estimate[name];
  return value.isA<JSNumber>() ? (value as JSNumber).toDartInt : null;
}
