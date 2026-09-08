// `origin_storage_estimate_web.dart`: the wrapper around
// `navigator.storage.estimate()` that the storage view's second total is read from.
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/origin_storage_estimate_web_test.dart
//
// What is only checkable here:
//
// * That a real engine answers `estimate()` at all, and with numbers. The app had
//   never called it before this, so "it works" was an assumption about the browser
//   and not a measurement.
// * That the bound behaves. `estimate()` settles in milliseconds on every engine
//   that implements it, so the give-up path cannot be reached through the public
//   entry point; the bounded half takes a promise so a test can supply one that
//   never settles, and the `onTimeout` cast that path runs is a runtime check the
//   analyzer cannot see (see bounded_js_answer_web_test.dart).
// * That an absent dictionary member is reported as absent. `package:web` types
//   `usage` and `quota` as non-nullable `int`, but the IDL marks both optional.
//
// CI runs this in the `Browser tests` job in .github/workflows/ci.yml; a file not
// named on that command line is run by nothing.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

// See the note in record_mutation_lock_web_test.dart: `test` resolves
// transitively through `flutter_test`, so no dev_dependencies entry is added.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:umacapture/src/core/fs/origin_storage_estimate_web.dart';
// ignore: depend_on_referenced_packages
import 'package:web/web.dart' as web;

/// The suite's wedge detector, longer than any bound the subject is handed, so a
/// bound that never fires fails as a named `TimeoutException` instead of hanging
/// the runner.
const _guard = Duration(seconds: 15);

void main() {
  test('a real browser answers with an origin-wide usage figure', () async {
    final estimate = await readOriginStorageEstimate().timeout(_guard);
    expect(estimate, isNotNull, reason: 'this engine answered estimate() with nothing usable');
    expect(estimate?.usageBytes, isNotNull, reason: 'usage is the number the storage view renders');
    expect(estimate?.usageBytes, greaterThanOrEqualTo(0));
    expect(estimate?.quotaBytes, isNotNull, reason: 'quota is reported by every engine that implements estimate()');
    expect(estimate?.quotaBytes, greaterThan(0));
  });

  test('a promise that never settles is given up on as null', () async {
    // The Firefox doorhanger case, and the only route to this branch: a real
    // `estimate()` always settles.
    final pending = Completer<web.StorageEstimate>();
    final estimate = await boundedOriginStorageEstimate(
      pending.future.toJS,
      const Duration(milliseconds: 50),
    ).timeout(_guard);
    expect(estimate, isNull);
  });

  test('a rejected estimate is reported as unknown rather than thrown', () async {
    // The caller renders one "unknown" for every way the browser fails to answer,
    // so the rejection is absorbed here — unlike in the bound itself, which keeps
    // "refused" separate from "never answered".
    final rejected = Future<web.StorageEstimate>.error(StateError('no storage manager')).toJS;
    expect(await boundedOriginStorageEstimate(rejected, const Duration(seconds: 5)).timeout(_guard), isNull);
  });

  test('the reported numbers are the ones the browser put in the dictionary', () async {
    final answer = web.StorageEstimate(usage: 1234, quota: 5678);
    final estimate = await boundedOriginStorageEstimate(
      Future.value(answer).toJS,
      const Duration(seconds: 5),
    ).timeout(_guard);
    expect(estimate?.usageBytes, 1234);
    expect(estimate?.quotaBytes, 5678);
  });

  test('a zero is kept distinct from an absent member', () async {
    final zeroed = await boundedOriginStorageEstimate(
      Future.value(web.StorageEstimate(usage: 0, quota: 0)).toJS,
      const Duration(seconds: 5),
    ).timeout(_guard);
    expect(zeroed?.usageBytes, 0, reason: '"the origin stores nothing" must not be rendered as "unknown"');
    expect(zeroed?.quotaBytes, 0);

    // An engine that omits the members hands back a dictionary without them. The
    // declared `int` getter would convert the `undefined` instead of reporting it,
    // which is why the wrapper reads the properties untyped.
    final absent = await boundedOriginStorageEstimate(
      Future.value(JSObject() as web.StorageEstimate).toJS,
      const Duration(seconds: 5),
    ).timeout(_guard);
    expect(absent, isNotNull, reason: 'an empty dictionary is still an answer');
    expect(absent?.usageBytes, isNull);
    expect(absent?.quotaBytes, isNull);
  });
}
