// The Worker's HTTP face over a [FakeSyncServer], for the sync tests that run a round over the app's own HTTP server
// ([HttpSyncServer]). Each request is read as `docs/sync-protocol.md` states it — its method and path, its session, its
// JSON envelope holding exactly the keys the Worker takes, an image's content type and length — and refused as the
// Worker refuses one that is not (`401 session_required`, `400 invalid_payload`). Each answer is written as the Worker
// writes it: a success's JSON or bytes, a refusal ([SyncRefusal]) as its status and `{error, …}` with the field the
// Worker names, a day's limit and a hidden cap with their `Retry-After`; and a request the fake answers by throwing
// anything else ([FakeSyncAnswerLost], a connection the test drops) as a connection that drops.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:umacapture/src/chara_detail/record_sync_round.dart';

import 'record_sync_harness.dart';

/// The Worker's HTTP face over [server], at [origin], taking the session [token].
class SyncHttpFace implements HttpClientAdapter {
  SyncHttpFace(this.server, {this.origin = 'https://umacapture.com', this.token = 'token'});

  final FakeSyncServer server;
  final String origin;
  final String token;

  /// Awaited as each request arrives, before the server reads it: a gate the test holds, or one it never opens — a
  /// request that never answers.
  Future<void> Function(RequestOptions request)? beforeAnswer;

  /// The endpoints asked, by method and path pattern (`GET /api/sync/roots/<name>`).
  final asked = <String>{};

  /// The requests the face refused as malformed, the way the Worker refuses them: what a test expects none of.
  final malformed = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final chunks = <int>[];
    await requestStream?.forEach(chunks.addAll);
    final bytes = Uint8List.fromList(chunks);
    await beforeAnswer?.call(options);
    final uri = options.uri;
    if (uri.origin != origin) throw StateError('the server of the test answers no ${uri.origin}');
    String? header(String name) {
      for (final MapEntry(:key, :value) in options.headers.entries) {
        if (key.toLowerCase() == name) return '$value';
      }
      return null;
    }

    if (header('authorization') != 'Bearer $token') return _fail(401, 'session_required');
    try {
      return await _answer(options.method, uri.path, bytes, header);
    } on SyncRefusal catch (refusal) {
      return _refused(refusal);
    } on _Malformed catch (malformed) {
      this.malformed.add('${options.method} ${uri.path}: ${malformed.field}');
      return _fail(400, 'invalid_payload', {'field': malformed.field});
    }
  }

  Future<ResponseBody> _answer(String method, String path, Uint8List bytes, String? Function(String) header) async {
    final name = RegExp(r'^/api/sync/(roots|parts|images)/([0-9a-f]{64})$').firstMatch(path);
    final route = name == null ? '$method $path' : '$method /api/sync/${name[1]}/<name>';
    asked.add(route);
    Map<String, Object?> body(List<String> keys) => _envelope(bytes, keys);
    switch (route) {
      case 'GET /api/sync/generation':
        final head = await server.readGeneration();
        return _json({'generation': head.generation, 'root': head.root});
      case 'GET /api/sync/roots/<name>':
        return _text(await server.root(name![2]!));
      case 'GET /api/sync/parts/<name>':
        return _text(await server.part(name![2]!));
      case 'POST /api/sync/bodies/get':
        final got = await server.bodies(_names(body(['names'])['names']));
        return _json({
          'bodies': [
            for (final b in got) {'name': b.name, 'body': b.body},
          ],
        });
      case 'POST /api/sync/bodies':
        final items = body(['bodies'])['bodies'];
        if (items is! List) throw const _Malformed('bodies');
        final bodies = [
          for (final (i, item) in items.indexed)
            if (_envelopeOf(item, ['name', 'body'], 'bodies[$i]') case {'name': String name, 'body': String text})
              (name: name, body: text)
            else
              throw _Malformed('bodies[$i]'),
        ];
        final statuses = await server.putBodies(bodies);
        return _json({
          'results': [
            for (final (i, b) in bodies.indexed) {'name': b.name, 'status': statuses[i]},
          ],
        });
      case 'POST /api/sync/parts':
        final part = body(['name', 'part']);
        if (part case {'name': String name, 'part': String text}) {
          return _json({'name': name, 'status': await server.putPart(name, text)});
        }
        throw const _Malformed('part');
      case 'POST /api/sync/root':
        final root = body(['generation', 'name', 'root']);
        if (root case {'generation': int generation, 'name': String name, 'root': String text}) {
          return _json({'generation': await server.replaceRoot(generation, name, text), 'root': name});
        }
        throw const _Malformed('root');
      case 'GET /api/sync/settings':
        return _json({'image_form': await server.imageForm()});
      case 'PUT /api/sync/settings':
        final form = body(['image_form'])['image_form'];
        if (form is! String || !{'png', 'jpeg', 'none'}.contains(form)) throw const _Malformed('image_form');
        await server.putImageForm(form);
        return _json({'image_form': form});
      case 'POST /api/sync/held':
        final names = _names(body(['names'])['names']);
        final held = await server.held(names);
        return _json({'held': names.where(held.contains).toList()});
      case 'PUT /api/sync/images/<name>':
        final type = header('content-type');
        if (type != 'image/png' && type != 'image/jpeg') throw const _Malformed('content-type');
        if (int.tryParse(header('content-length') ?? '') != bytes.length) throw const _Malformed('content-length');
        final held = server.images.containsKey(name![2]);
        await server.putImage(name[2]!, bytes, jpeg: type == 'image/jpeg');
        return _json({'name': name[2], 'status': held ? 'exists' : 'stored'});
      case 'GET /api/sync/images/<name>':
        final image = await server.image(name![2]!);
        if (image == null) return _fail(404, 'not_found');
        return ResponseBody.fromBytes(image, 200);
    }
    throw StateError('the server of the test answers no $route');
  }

  static List<String> _names(Object? names) =>
      names is List && names.every((name) => name is String) ? names.cast<String>() : throw const _Malformed('names');

  /// The request body as a JSON object holding exactly [keys], as the Worker's `envelope` takes it.
  static Map<String, Object?> _envelope(Uint8List bytes, List<String> keys) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const _Malformed('body');
    }
    return _envelopeOf(decoded, keys, 'body');
  }

  static Map<String, Object?> _envelopeOf(Object? value, List<String> keys, String field) {
    if (value is! Map<String, Object?>) throw _Malformed(field);
    for (final key in {...value.keys, ...keys}) {
      if (!keys.contains(key) || !value.containsKey(key)) throw _Malformed(key);
    }
    return value;
  }

  static ResponseBody _json(Map<String, Object?> body, [int status = 200, Map<String, String> headers = const {}]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          for (final MapEntry(:key, :value) in headers.entries) key: [value],
        },
      );

  static ResponseBody _text(String text) => ResponseBody.fromBytes(
    utf8.encode(text),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );

  static ResponseBody _fail(int status, String error, [Map<String, Object?> extra = const {}]) =>
      _json({'error': error, ...extra}, status);

  /// [refusal] as the Worker writes it: the field each error carries (`server/src/sync*.mjs`), and the `Retry-After`
  /// of a day's limit and of a hidden cap, which the fake holds in [SyncRefusal.detail].
  static ResponseBody _refused(SyncRefusal refusal) {
    final detail = refusal.detail;
    return switch (refusal.error) {
      'stale_generation' => _fail(refusal.status, refusal.error, {'generation': detail}),
      'missing_objects' => _fail(refusal.status, refusal.error, {'names': detail}),
      'not_found' => _fail(refusal.status, refusal.error, {'names': ?detail}),
      'too_many_parts' || 'too_many_pngs_per_jpeg' => _fail(refusal.status, refusal.error, {'limit': detail}),
      'invalid_payload' => _fail(refusal.status, refusal.error, {'field': detail}),
      'account_limit' => _fail(refusal.status, refusal.error, {'limit': detail}),
      'daily_limit' => _json(
        {'error': refusal.error, 'scope': refusal.scope ?? 'account'},
        refusal.status,
        {'retry-after': '$detail'},
      ),
      'hidden_limit' => _json({'error': refusal.error}, refusal.status, {'retry-after': '$detail'}),
      _ => _fail(refusal.status, refusal.error),
    };
  }

  @override
  void close({bool force = false}) {}
}

/// A request the Worker refuses as malformed, naming the field.
class _Malformed implements Exception {
  const _Malformed(this.field);

  final String field;
}
