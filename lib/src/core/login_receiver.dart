/// Where a login's proof comes back to the app.
///
/// The login page sends its proof to whoever started the login, and the two platforms receive it
/// differently. Windows listens on a loopback port: the app is not a browser, so it cannot read the
/// cookie the login page sets, and a redirect to `127.0.0.1` is the remaining way to hand the proof
/// to this machine only. Web holds no listener: the app is a page of the same origin, so its claim
/// carries the login's cookie, and there is nothing to receive here.
library;

export 'login_receiver_io.dart' if (dart.library.js_interop) 'login_receiver_web.dart' show bindLoginListener;

/// How long a listener waits before closing by itself.
///
/// It covers the whole login in the browser, Turnstile on the start page included, so it is longer
/// than the server's login lifetime, which counts from `begin`. Being long does not widen what is
/// accepted: the listener ignores every callback but its own login's.
const loginListenSeconds = 600;

/// A listener waiting for one login's callback.
abstract interface class LoginListener {
  /// The loopback port, known before the start page is opened, so it can be named there.
  int get port;

  /// The proof from the login's callback.
  ///
  /// Fails with [LoginListenClosed] when the listener closes without one.
  Future<String> get code;

  /// Stops waiting and releases the port. [code] fails with [LoginListenClosed] unless it is done.
  Future<void> close();
}

/// The listener closed before its login's callback arrived.
class LoginListenClosed implements Exception {
  const LoginListenClosed({required this.timedOut});

  /// True when [loginListenSeconds] ran out, false when [LoginListener.close] was called.
  final bool timedOut;

  @override
  String toString() => 'LoginListenClosed(timedOut: $timedOut)';
}
