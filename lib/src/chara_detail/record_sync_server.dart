// The sync endpoints of the sharing server over HTTP ([HttpSyncServer]), and the server this device syncs with
// ([syncServerProvider]): the sharing server, under the device's session.
//
// What an answer other than a success means is one decision ([syncAnswerFailure]): a refusal, which changed nothing, or
// an answer that does not tell whether the server acted. A round reads the second as it reads a request whose answer
// did not arrive, and so it reads a request that has not answered by its deadline ([syncRequestTimeoutProvider]): the
// request fails, and the round behind it in [RecordSync.round] runs.
//
// No request waits for a time the server names. A refusal for the day's limit (`429 daily_limit`) carries the seconds
// to the next UTC day (`Retry-After`), and a round asked for before then is refused again; but a refused request
// changes nothing and counts against no limit (`docs/sync-protocol.md`), so asking again costs the account nothing,
// and the round says what waits as it does at the first refusal.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/const.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/record_sync_round.dart';
import '/src/core/sentry_util.dart';

/// The [Dio] every sync request goes through: diagnostics log the method, URL and status only.
final recordSyncDioProvider = Provider<Dio>((ref) => createDiagnosticDio(operation: "record_sync"));

/// How long one sync request may take, from connecting to the last byte of its answer, before it fails as a request
/// whose answer did not arrive: a connection that stopped carrying anything, as one a sleep of the machine cut, answers
/// never. The server counts a sync request still running a quarter of an hour after it began as abandoned
/// (`SYNC_ABANDONED_AFTER`, `server/src/limits.mjs`) and takes over what it left, so an answer later than that is not
/// one the server stands behind; any shorter deadline would be a guess at how fast the user's connection is, which
/// would refuse the largest image put (32 MiB) on a slow one for good. A provider so tests can override it.
final syncRequestTimeoutProvider = Provider<Duration>((_) => const Duration(minutes: 15));

/// The server this device syncs with: the sharing server, under the device's session; null where it holds none, or one
/// that may only continue deleting its account, which every sync endpoint refuses (`409 account_deleting`).
final syncServerProvider = Provider<SyncServer?>((ref) {
  final session = ref.watch(recordShareSessionProvider);
  if (session == null || session.deleting) return null;
  return HttpSyncServer(
    ref.watch(recordSyncDioProvider),
    origin: Const.sharingOrigin,
    token: session.token,
    timeout: ref.watch(syncRequestTimeoutProvider),
    onAnswer: ref.read(recordShareSessionProvider.notifier).answered,
  );
});

/// An answer of a sync endpoint that does not tell whether the server acted on the request: one
/// `docs/sync-protocol.md` does not state — a proxy's, or one the app cannot read —, or one it states may follow a
/// change (`502 storage_unavailable`, `503 temporarily_unavailable`: a replacement stopped after its commit answers
/// either, its new generation current). A round reads it as a request whose answer did not arrive ([SyncServer]).
class SyncAnswerLost implements Exception {
  const SyncAnswerLost(this.status, [this.error]);

  final int status;
  final String? error;

  @override
  String toString() => 'SyncAnswerLost($status $error)';
}

/// The errors `docs/sync-protocol.md` states may answer a request the server acted on.
const _mayHaveActed = {'storage_unavailable', 'temporarily_unavailable'};

/// What an answer of a sync endpoint other than its success is, of [status], its body decoded as JSON ([json]; null
/// where it is not JSON) and its `Retry-After` ([retryAfter]): a refusal, which changed nothing ([SyncRefusal]), with
/// the seconds the `Retry-After` names, or else the one field the answer carries besides `error` (the generation of a
/// `stale_generation`, the names of a `missing_objects` or a `not_found`, the `limit` of a `too_many_parts`, the
/// `field` of an `invalid_payload`), and of a `daily_limit` its `scope` besides ([SyncRefusal.dailyLimit]) — or an
/// answer that does not tell whether the server acted ([SyncAnswerLost]).
Exception syncAnswerFailure(int status, Object? json, {String? retryAfter}) {
  final error = json is Map<String, Object?> ? json['error'] : null;
  if (error is! String || _mayHaveActed.contains(error)) return SyncAnswerLost(status, error is String ? error : null);
  final rest = {...json as Map<String, Object?>}..remove('error');
  if (status == 429 && error == 'daily_limit') {
    final scope = rest['scope'];
    return SyncRefusal.dailyLimit(int.tryParse(retryAfter ?? ''), scope: scope is String ? scope : null);
  }
  final detail = int.tryParse(retryAfter ?? '') ?? (rest.length == 1 ? rest.values.single : null);
  return SyncRefusal(status, error, detail is List ? List<String>.from(detail) : detail);
}

/// The sync endpoints of the server at [origin] (`docs/sync-protocol.md`), under the session [token], each request
/// bounded by [timeout] ([syncRequestTimeoutProvider]). A refusal is thrown as [SyncRefusal]; an answer that does not
/// tell whether the server acted as [SyncAnswerLost]; a request with no answer by its deadline as [TimeoutException];
/// one whose connection failed as Dio's [DioException]. Each answer other than a success is first told to the owner of
/// the session through [onAnswer] ([RecordShareSession.answered]), which drops the session or marks it as deleting as it
/// does for a sharing request.
class HttpSyncServer implements SyncServer {
  HttpSyncServer(this._dio, {required this.origin, required this.token, required this.timeout, required this.onAnswer});

  final Dio _dio;
  final String origin;
  final String token;
  final Duration timeout;
  final Future<void> Function(String token, int status, Object? error) onAnswer;

  /// Sends one request — [json] encoded as JSON, or [bytes] of [contentType] — and answers its status, body and
  /// `Retry-After`. The deadline covers the whole request, from connecting to the last byte of the answer: Dio's own
  /// receive timeout restarts on every chunk, and a request still waiting for its answer receives none.
  Future<({int status, Uint8List body, String? retryAfter})> _send(
    String method,
    String path, {
    Object? json,
    Uint8List? bytes,
    String? contentType,
  }) async {
    final cancel = CancelToken();
    var timedOut = false;
    final deadline = Timer(timeout, () {
      timedOut = true;
      cancel.cancel();
    });
    try {
      final response = await _dio.request<List<int>>(
        '$origin$path',
        data: json == null ? bytes : utf8.encode(jsonEncode(json)),
        cancelToken: cancel,
        options: Options(
          method: method,
          contentType: json == null ? contentType : Headers.jsonContentType,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
      final body = response.data;
      return (
        status: response.statusCode ?? 0,
        body: body is Uint8List ? body : Uint8List.fromList(body ?? const []),
        retryAfter: response.headers.value('retry-after'),
      );
    } on DioException {
      if (timedOut) throw TimeoutException('sync request $method $path', timeout);
      rethrow;
    } finally {
      deadline.cancel();
    }
  }

  static Object? _decode(Uint8List body) {
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
  }

  /// The body of a success, as sent; else what the answer is ([syncAnswerFailure]), thrown.
  Future<Uint8List> _ok(String method, String path, {Object? json, Uint8List? bytes, String? contentType}) async {
    final answer = await _send(method, path, json: json, bytes: bytes, contentType: contentType);
    if (answer.status == 200) return answer.body;
    final decoded = _decode(answer.body);
    await onAnswer(token, answer.status, decoded is Map<String, Object?> ? decoded['error'] : null);
    throw syncAnswerFailure(answer.status, decoded, retryAfter: answer.retryAfter);
  }

  /// The JSON object of a success; an answer that is not one does not tell what the server did.
  Future<Map<String, Object?>> _object(String method, String path, {Object? json}) async {
    final decoded = _decode(await _ok(method, path, json: json));
    if (decoded is Map<String, Object?>) return decoded;
    throw const SyncAnswerLost(200);
  }

  /// The text of a success, as stored.
  Future<String> _text(String path) async {
    try {
      return utf8.decode(await _ok('GET', path));
    } on FormatException {
      throw const SyncAnswerLost(200);
    }
  }

  static T _field<T>(Map<String, Object?> answer, String key) =>
      answer[key] is T ? answer[key] as T : throw const SyncAnswerLost(200);

  @override
  Future<({int generation, String? root})> readGeneration() async {
    final answer = await _object('GET', '/api/sync/generation');
    return (generation: _field<int>(answer, 'generation'), root: _field<String?>(answer, 'root'));
  }

  @override
  Future<String> root(String name) => _text('/api/sync/roots/$name');

  @override
  Future<String> part(String name) => _text('/api/sync/parts/$name');

  @override
  Future<List<({String name, String body})>> bodies(List<String> names) async {
    final answer = await _object('POST', '/api/sync/bodies/get', json: {'names': names});
    return [
      for (final item in _field<List<Object?>>(answer, 'bodies'))
        if (item is Map<String, Object?>)
          (name: _field<String>(item, 'name'), body: _field<String>(item, 'body'))
        else
          throw const SyncAnswerLost(200),
    ];
  }

  @override
  Future<void> putBodies(List<({String name, String body})> bodies) => _object(
    'POST',
    '/api/sync/bodies',
    json: {
      'bodies': [
        for (final body in bodies) {'name': body.name, 'body': body.body},
      ],
    },
  );

  @override
  Future<void> putPart(String name, String text) =>
      _object('POST', '/api/sync/parts', json: {'name': name, 'part': text});

  @override
  Future<int> replaceRoot(int generation, String name, String text) async => _field<int>(
    await _object('POST', '/api/sync/root', json: {'generation': generation, 'name': name, 'root': text}),
    'generation',
  );

  @override
  Future<String> imageForm() async => _field<String>(await _object('GET', '/api/sync/settings'), 'image_form');

  @override
  Future<void> putImageForm(String form) => _object('PUT', '/api/sync/settings', json: {'image_form': form});

  @override
  Future<Set<String>> held(List<String> names) async {
    final answer = await _object('POST', '/api/sync/held', json: {'names': names});
    return {
      for (final name in _field<List<Object?>>(answer, 'held'))
        if (name is String) name else throw const SyncAnswerLost(200),
    };
  }

  @override
  Future<void> putImage(String name, Uint8List bytes, {required bool jpeg}) =>
      _ok('PUT', '/api/sync/images/$name', bytes: bytes, contentType: jpeg ? 'image/jpeg' : 'image/png');

  @override
  Future<Uint8List?> image(String name) async {
    try {
      return await _ok('GET', '/api/sync/images/$name');
    } on SyncRefusal catch (refusal) {
      if (refusal.status == 404 && refusal.error == 'not_found') return null;
      rethrow;
    }
  }
}
