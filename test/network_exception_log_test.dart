// Tests for the network-failure diagnostic helper in version_check.dart.
//
// Every caller treats a failed request as recoverable -- the web module bootstrap turns it into "no module",
// the desktop version check into a warning toast -- so the reporting helper must never raise a second
// exception out of the caller's catch block. It used to be able to: the context it builds reads
// `Platform.operatingSystem` and friends, which throw `UnsupportedError` on web, turning a missing module
// into a hard error out of `moduleVersionLoader` and taking the capture gate and every spec loader with it.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/network_exception_log_test.dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/version_check.dart';

/// Stands in for anything in the context map that can misbehave while it is being described.
class _UndescribableError {
  @override
  String toString() => throw StateError('toString exploded');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reporting a failure whose context cannot be built does not raise a second one', () async {
    // The path is relative, so the derived URI has no https host and the TLS probe is skipped -- the context
    // map is built before the probe anyway, which is exactly where the platform reads live.
    final exception = DioException(
      requestOptions: RequestOptions(path: '/modules.zip'),
      error: _UndescribableError(),
    );

    await logNetworkException(operation: 'bootstrap_web_module', exception: exception, stackTrace: StackTrace.current);
  });

  test('a plain failure still reports without throwing', () async {
    await logNetworkException(
      operation: 'bootstrap_web_module',
      exception: StateError('offline'),
      stackTrace: StackTrace.current,
    );
  });
}
