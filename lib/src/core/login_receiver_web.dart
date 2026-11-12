import 'package:web/web.dart' as web;

import 'login_receiver.dart';

/// Web's login comes back to this tab: see [SameTabLoginReturn].
LoginReturn platformLoginReturn() => const SameTabLoginReturn(_SessionStorageHandover());

/// The key the kept secret is stored under, named like the app's Web Lock (`umacapture:v1:instance`).
const _pendingLoginKey = 'umacapture:v1:pending_login';

/// Keeps the secret in `sessionStorage`: it survives the page loads of the login in this tab, is
/// not shared with another tab, and goes when the tab closes. Never in the start page's URL, which
/// carries only the secret's hash.
class _SessionStorageHandover implements LoginHandover {
  const _SessionStorageHandover();

  @override
  void keep(String secret) => web.window.sessionStorage.setItem(_pendingLoginKey, secret);

  @override
  String? take() {
    final storage = web.window.sessionStorage;
    final secret = storage.getItem(_pendingLoginKey);
    storage.removeItem(_pendingLoginKey);
    return secret;
  }

  @override
  void leaveFor(Uri page) => web.window.location.assign(page.toString());
}
