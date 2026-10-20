// The session with the record-sharing server: logging in, the requests made under the session, and logging out.
//
// Shared by web and Windows; the one place the two log in differently is [RecordShareSession.beginLogin]. The
// session lives in the `recordShares` store beside the device's share notes, so both go together when the
// store is deleted. Nothing here runs at start-up: the store is read, and the server is reached only from an
// operation the user started.
import 'dart:convert';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '/const.dart';
import '/src/chara_detail/record_share.dart' show newLoginSecret, recordSharesProvider, secretHash;
import '/src/core/login_receiver.dart';
import '/src/core/platform_controller.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/preference/storage_box.dart';

part 'record_share_session.mapper.dart';

/// The key the session is kept under in the `recordShares` store; every other key there is a share note.
const shareSessionKey = "session";

/// What `POST /api/auth/claim` answered, kept as the server named it.
///
/// [deleting] marks a session that can only continue deleting its account.
@MappableClass(caseStyle: CaseStyle.snakeCase)
class ShareSession with ShareSessionMappable {
  final String token;
  final int expiresAt;
  final String accountId;
  final bool deleting;

  const ShareSession({required this.token, required this.expiresAt, required this.accountId, required this.deleting});
}

/// The server's answer: its status, the decoded JSON body when there is one, and [body] when that is an object.
typedef ShareAnswer = ({int status, Map<String, Object?>? body, Object? json, Headers headers});

/// The [Dio] every sharing request goes through: diagnostics log the method, URL and status only.
final recordShareDioProvider = Provider<Dio>((ref) => createDiagnosticDio(operation: "record_share"));

/// Sends one request to the sharing API. A transport failure is thrown as Dio's [DioException].
Future<ShareAnswer> sendShareRequest(Dio dio, String method, String path, {Object? data, String? bearer}) async {
  final response = await dio.request<String>(
    "${Const.sharingOrigin}$path",
    data: data == null ? null : jsonEncode(data),
    options: Options(
      method: method,
      contentType: Headers.jsonContentType,
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      headers: {if (bearer != null) "Authorization": "Bearer $bearer"},
    ),
  );
  Object? json;
  try {
    json = jsonDecode(response.data ?? "");
  } on FormatException {
    json = null;
  }
  final body = json is Map<String, Object?> ? json : null;
  return (status: response.statusCode ?? 0, body: body, json: json, headers: response.headers);
}

/// Opens a login's start page: the default browser on Windows, a new tab on web.
final loginPageOpenerProvider = Provider<Future<bool> Function(Uri)>((ref) => launchUrl);

/// Binds the listener a login's proof comes back to, or answers null where the platform has none.
final loginListenerBinderProvider = Provider<Future<LoginListener?> Function({required String h})>(
  (ref) => bindLoginListener,
);

/// The provider every login names on its start page.
const _loginProvider = "google";

enum LoginOutcome {
  signedIn,

  /// Signed in, but the account already holds as many trainer ids as it may, so this device's was not added.
  trainerLimit,

  /// The login page has not been finished yet. The attempt stays usable: claiming again may succeed.
  incomplete,

  /// The server no longer knows the login. Only starting a new one helps.
  expired,

  /// The server refused the proof.
  refused,

  /// No answer arrived, or not the server's own.
  unreachable,

  /// The user closed the login before it finished.
  cancelled,
}

enum AccountDeletionOutcome {
  /// The server deleted the account; the session and the share notes are gone from the device.
  deleted,

  /// There is no session to continue with. A login onto the account continues its deletion.
  loginRequired,

  /// No answer arrived. The session is kept, and calling again continues where the server left off.
  unreachable,

  /// The server refused or answered something else.
  failed,
}

/// One login, from opening its start page to the session it ends in.
///
/// The secret is held in memory only; the start page receives its hash, and the secret itself first leaves the
/// device in the claim's body.
class LoginAttempt {
  final RecordShareSession _owner;
  final String _secret;
  final LoginListener? _listener;
  Future<LoginOutcome>? _claiming;
  bool _finished = false;

  LoginAttempt._(this._owner, this._secret, this._listener);

  /// Whether the proof arrives by itself through [completion]; otherwise [claim] is what asks for it.
  bool get waitsForCallback => _listener != null;

  /// The listener's login: resolves once its callback has arrived and been claimed, or the attempt has ended.
  ///
  /// Only an attempt that [waitsForCallback] has one.
  Future<LoginOutcome> get completion async {
    final listener = _listener;
    if (listener == null) {
      throw StateError("a login with no listener completes through claim()");
    }
    final String code;
    try {
      code = await listener.code;
    } on LoginListenClosed {
      _finished = true;
      return LoginOutcome.cancelled;
    }
    if (_finished) {
      return LoginOutcome.cancelled;
    }
    return _claim(code: code);
  }

  /// Claims the login with the cookie the login page left in this browser. Called from the dialog's check button
  /// and when the page becomes visible again; a claim already on its way is shared rather than sent twice.
  Future<LoginOutcome> claim() {
    if (_listener != null) {
      throw StateError("a login with a listener completes through completion");
    }
    return _claim();
  }

  Future<LoginOutcome> _claim({String? code}) {
    if (_finished) {
      return Future.value(LoginOutcome.cancelled);
    }
    return _claiming ??= _owner._claim(_secret, code: code).then((outcome) {
      _claiming = null;
      if (outcome != LoginOutcome.incomplete && outcome != LoginOutcome.unreachable) {
        _finished = true;
      }
      return outcome;
    });
  }

  /// Ends the attempt when its dialog closes: the listener lets go of its port and nothing more is claimed.
  Future<void> cancel() async {
    _finished = true;
    await _listener?.close();
  }
}

/// The device's session with the sharing server, or null when it holds none.
class RecordShareSession extends Notifier<ShareSession?> {
  StorageBox get _box => StorageBox(StorageBoxKey.recordShares);

  @override
  ShareSession? build() {
    final stored = _box.pull<String>(shareSessionKey);
    if (stored == null) {
      return null;
    }
    try {
      return ShareSessionMapper.fromJson(stored);
    } on Exception catch (e) {
      // An unreadable session is one the user logs in again for; nothing else depends on it.
      logger.w("The stored sharing session could not be read: ${e.runtimeType}");
      return null;
    }
  }

  Future<void> _keep(ShareSession? session) async {
    state = session;
    if (session == null) {
      await _box.delete(shareSessionKey);
    } else {
      await _box.push(shareSessionKey, session.toJson());
    }
  }

  /// Starts a login and opens its start page.
  Future<LoginAttempt> beginLogin() async {
    final secret = newLoginSecret();
    final h = secretHash(secret);
    // Windows listens for the proof on a loopback port: the app is not a browser, so it cannot read the cookie
    // the login page sets. Web has no listener, and its claim carries that cookie instead.
    final listener = await ref.read(loginListenerBinderProvider)(h: h);
    final page = Uri.parse(
      "${Const.sharingOrigin}/api/auth/start",
    ).replace(queryParameters: {"p": _loginProvider, "h": h, if (listener != null) "port": "${listener.port}"});
    await ref.read(loginPageOpenerProvider)(page);
    return LoginAttempt._(this, secret, listener);
  }

  Future<LoginOutcome> _claim(String secret, {String? code}) async {
    final ShareAnswer answer;
    try {
      answer = await sendShareRequest(
        ref.read(recordShareDioProvider),
        "POST",
        "/api/auth/claim",
        data: {"s": secret, "code": ?code},
      );
    } on DioException {
      return LoginOutcome.unreachable;
    }
    final error = answer.body?["error"];
    switch (answer.status) {
      case 200:
        final session = _sessionOf(answer.body);
        if (session == null) {
          return LoginOutcome.unreachable;
        }
        await _keep(session);
        await ref.read(recordSharesProvider.notifier).keepOnlyAccount(session.accountId);
        logger.i("Logged in to the sharing server. deleting=${session.deleting}");
        return session.deleting ? LoginOutcome.signedIn : _registerTrainer(session);
      case 409 when error == "login_incomplete":
        return LoginOutcome.incomplete;
      case 410 when error == "login_expired":
        return LoginOutcome.expired;
      case 403 when error == "forbidden":
        return LoginOutcome.refused;
      default:
        return LoginOutcome.unreachable;
    }
  }

  ShareSession? _sessionOf(Map<String, Object?>? body) {
    final token = body?["token"];
    final expiresAt = body?["expires_at"];
    final accountId = body?["account_id"];
    final deleting = body?["deleting"];
    if (token is! String || expiresAt is! int || accountId is! String || deleting is! bool) {
      return null;
    }
    return ShareSession(token: token, expiresAt: expiresAt, accountId: accountId, deleting: deleting);
  }

  /// Adds this device's trainer id to the account. The login stands whatever the answer.
  Future<LoginOutcome> _registerTrainer(ShareSession session) async {
    try {
      final answer = await send("POST", "/api/me/trainers", data: {"trainer_id": ref.read(trainerIdProvider)});
      if (answer.status == 409 && answer.body?["error"] == "trainer_limit") {
        return LoginOutcome.trainerLimit;
      }
      if (answer.status != 200) {
        logger.w("The trainer id was not registered. status=${answer.status}");
      }
    } on DioException {
      logger.w("The trainer id was not registered: no answer");
    } on StateError {
      // The session was dropped in between; the login itself is what the caller already holds.
    }
    return LoginOutcome.signedIn;
  }

  /// Sends a request under the session. The server's 401 means it no longer knows the session, which is dropped;
  /// the share notes stay, since each names its account and a later login decides whether they still apply.
  ///
  /// Throws [StateError] when there is no session, and Dio's [DioException] when no answer arrives.
  Future<ShareAnswer> send(String method, String path, {Object? data}) async {
    final session = state;
    if (session == null) {
      throw StateError("no sharing session");
    }
    final answer = await sendShareRequest(
      ref.read(recordShareDioProvider),
      method,
      path,
      data: data,
      bearer: session.token,
    );
    if (answer.status == 401 && state?.token == session.token) {
      logger.i("The sharing server no longer knows the session; it is dropped");
      await _keep(null);
    } else if (answer.status == 409 && answer.body?["error"] == "account_deleting") {
      await _markDeleting(session);
    }
    return answer;
  }

  /// Records that [session]'s account is being deleted, so a restart continues the deletion with the same token.
  Future<void> _markDeleting(ShareSession session) async {
    final current = state;
    if (current == null || current.token != session.token || current.deleting) {
      return;
    }
    logger.i("The sharing account is being deleted");
    await _keep(
      ShareSession(token: current.token, expiresAt: current.expiresAt, accountId: current.accountId, deleting: true),
    );
  }

  /// Deletes the account: repeats `DELETE /api/me` until the server answers 204, then drops the session and the
  /// share notes. Each 200 reports through [onProgress] how much is left, summed over every kind the server
  /// names, since the kinds are the server's to add.
  ///
  /// The session is marked as deleting from the first 200 on, so a deletion cut short continues with the same
  /// token. A session lost on the way (401) is regained by logging in again: the claim then answers `deleting`.
  Future<AccountDeletionOutcome> deleteAccount({void Function(int remaining)? onProgress}) async {
    while (true) {
      final session = state;
      if (session == null) {
        return AccountDeletionOutcome.loginRequired;
      }
      final ShareAnswer answer;
      try {
        answer = await send("DELETE", "/api/me");
      } on DioException {
        return AccountDeletionOutcome.unreachable;
      }
      switch (answer.status) {
        case 204:
          logger.i("The sharing account was deleted");
          await _forgetAll();
          return AccountDeletionOutcome.deleted;
        case 401:
          return AccountDeletionOutcome.loginRequired;
        case 200:
          final remaining = _remainingOf(answer.body);
          if (remaining == null) {
            return AccountDeletionOutcome.failed;
          }
          await _markDeleting(session);
          onProgress?.call(remaining);
        default:
          logger.w("The sharing account was not deleted. status=${answer.status}");
          return AccountDeletionOutcome.failed;
      }
    }
  }

  /// The sum of a 200's `remaining`, whatever kinds it names, or null when the body is not that map.
  int? _remainingOf(Map<String, Object?>? body) {
    final remaining = body?["remaining"];
    if (remaining is! Map) {
      return null;
    }
    var sum = 0;
    for (final count in remaining.values) {
      if (count is! int) {
        return null;
      }
      sum += count;
    }
    return sum;
  }

  /// Ends the session on the server and drops it with the share notes. Returns false when the server did not
  /// answer, which leaves both as they were.
  Future<bool> logout() async {
    if (state == null) {
      await _forgetAll();
      return true;
    }
    final ShareAnswer answer;
    try {
      answer = await send("POST", "/api/auth/logout");
    } on DioException {
      return false;
    }
    if (answer.status != 204 && answer.status != 401) {
      return false;
    }
    await _forgetAll();
    return true;
  }

  /// Drops the session and every share note: the notes index this account's shares, and another account logging
  /// in next must not see them as its own.
  Future<void> _forgetAll() async {
    state = null;
    for (final (:key, value: _) in _box.entries().toList()) {
      await _box.delete(key);
    }
    ref.invalidate(recordSharesProvider);
  }
}

final recordShareSessionProvider = NotifierProvider<RecordShareSession, ShareSession?>(RecordShareSession.new);
