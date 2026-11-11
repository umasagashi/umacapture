import 'dart:async';
import 'dart:io';

import '/src/core/utils.dart';
import 'login_receiver.dart';

/// Listens on a loopback port for the callback of the login whose secret hashes to [h].
///
/// Bound to `127.0.0.1` only, on a port the OS picks, before the start page is opened. A second
/// app process never reaches Dart (the runner's named mutex in `windows/runner/main.cpp` exits it),
/// so one process holds at most the listeners its own dialogs opened.
///
/// [startTimer] creates the timer for [loginListenSeconds]; a test passes its own to run the clock.
Future<LoginListener?> bindLoginListener({
  required String h,
  Timer Function(Duration, void Function()) startTimer = Timer.new,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final listener = _IoLoginListener(server, h);
  listener._timer = startTimer(const Duration(seconds: loginListenSeconds), listener._timeOut);
  server.listen(listener._handle);
  logger.i('Login listener bound on loopback port ${server.port}.');
  return listener;
}

class _IoLoginListener implements LoginListener {
  _IoLoginListener(this._server, this._h) : port = _server.port {
    // A dialog closed before anything awaited [code] must not surface an unhandled error.
    _callback.future.ignore();
  }

  final HttpServer _server;
  final String _h;
  final _callback = Completer<LoginCallback>();
  Timer? _timer;

  /// Read once at bind: a closed [HttpServer] no longer reports its port.
  @override
  final int port;

  @override
  Future<LoginCallback> get callback => _callback.future;

  @override
  Future<void> close() => _end(const LoginListenClosed(timedOut: false));

  void _timeOut() {
    logger.i('Login listener on port $port timed out.');
    unawaited(_end(const LoginListenClosed(timedOut: true)));
  }

  Future<void> _handle(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final code = query['code'];
    final ours = request.method == 'GET' && request.uri.path == '/cb' && query['h'] == _h;
    if (!ours || code == null || code.isEmpty || _callback.isCompleted) {
      // Another login's redirect, or anything else: refuse it and keep waiting for ours.
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response
      ..persistentConnection = false
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(_doneHtml);
    await request.response.close();
    logger.i('Login listener on port $port received its callback.');
    await _shutdown();
    // The hint rides beside the proof only when the login came back with one; an empty one is none.
    final hint = query['hint'];
    if (!_callback.isCompleted) {
      _callback.complete((code: code, hint: hint == null || hint.isEmpty ? null : hint));
    }
  }

  Future<void> _end(LoginListenClosed reason) async {
    if (!_callback.isCompleted) _callback.completeError(reason);
    await _shutdown();
  }

  Future<void> _shutdown() async {
    _timer?.cancel();
    await _server.close(force: true);
  }
}

const _doneHtml =
    '<!doctype html><meta charset="utf-8"><title>umacapture</title>'
    '<p>ログインしました。アプリに戻ってください。</p>';
