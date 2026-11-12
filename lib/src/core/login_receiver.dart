/// How a login's proof comes back to the app.
///
/// The login page hands its proof to whoever started the login, and the two platforms receive it
/// differently ([LoginReturn]). Windows listens on a loopback port: the app is not a browser, so it
/// cannot read the cookie the login page sets, and a redirect to `127.0.0.1` is the remaining way to
/// hand the proof to this machine only. Web holds no listener: the app is a page of the same origin,
/// so its claim carries the login's cookie.
library;

export 'login_receiver_io.dart' if (dart.library.js_interop) 'login_receiver_web.dart' show platformLoginReturn;

/// The way a login started on this platform comes back to the app.
sealed class LoginReturn {
  const LoginReturn();
}

/// Windows: the app is not a browser, so the start page opens in the default browser and the proof
/// comes back to a loopback listener ([bind]) while the app waits.
final class LoopbackLoginReturn extends LoginReturn {
  const LoopbackLoginReturn(this.bind);

  /// Binds the listener for the login whose secret hashes to `h`.
  final Future<LoginListener> Function({required String h}) bind;
}

/// Web: the app is itself a browser tab, and a login in another tab breaks a password manager's
/// "Sign in with", which follows one tab. So the start page replaces the app in its own tab, the
/// callback sends that tab back to the app, and the app loaded there claims with what [handover]
/// kept across the two page loads.
final class SameTabLoginReturn extends LoginReturn {
  const SameTabLoginReturn(this.handover);

  final LoginHandover handover;
}

/// What carries a web login across the page loads between leaving the app and coming back to it.
abstract interface class LoginHandover {
  /// Keeps [secret] for the app this tab loads next, replacing any kept before.
  void keep(String secret);

  /// The kept secret, removed as it is read, so a login is claimed at most once; null when none is kept.
  String? take();

  /// Replaces the app in this tab with [page].
  void leaveFor(Uri page);
}

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
