// Sharing a record under the logged-in account: what leaves the device, that each share's note follows its
// own result and its account, and that the client keys and the login secrets never reach a log line.
//
// Entry: a real `record.json`'s bytes decoded the way the app decodes them, the real
// `recordShares` store, and the real diagnostic Dio with only its transport replaced. Nothing
// reaches a network. The dialog cases enter through the row menu's real share submenu and the
// long-press confirms of the share and unshare dialogs; the list of shares enters through its
// real privacy-settings row.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_share_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:logger/logger.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/const.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/record_share.dart';
import 'package:umacapture/src/chara_detail/record_share_session.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/login_receiver.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/record_share_list_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/share_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/settling.dart';

const _parent1Id = "3f0c6b2e-1d4a-4c55-9e0f-6a7b8c9d0e1f";
const _parent2Id = "7e1d2c3b-4a59-4687-b7c8-d9e0f1a2b3c4";
const _moduleVersion = "2026-09-30T11:00:00+0900";

/// One request the app made, as it reached the transport.
typedef _Sent = ({String method, Uri uri, Map<String, dynamic> headers, String body});

/// Answers each request with the next of [answers]; a [SocketException] there is a lost connection, and a
/// future holds the answer back until the test completes it.
class _FakeServer implements HttpClientAdapter {
  final List<Object> answers;
  final sent = <_Sent>[];

  _FakeServer(this.answers);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = requestStream == null ? <int>[] : await requestStream.expand((chunk) => chunk).toList();
    sent.add((method: options.method, uri: options.uri, headers: options.headers, body: utf8.decode(bytes)));
    var answer = answers.removeAt(0);
    if (answer is Future<Object>) {
      answer = await answer;
    }
    if (answer is Exception) {
      throw answer;
    }
    return answer as ResponseBody;
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Map<String, Object?> body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ["application/json"],
  },
);

ResponseBody _empty(int status) => ResponseBody.fromString("", status);

Map<String, Object?> _located(String id) => {
  "id": id,
  "url": "${Const.sharingOrigin}/r/$id",
  "json_url": "${Const.sharingOrigin}/r/$id.json",
};

const _lostConnection = SocketException("connection reset");

/// The answer of `POST /api/shares`: one result per share, in the order they were sent.
ResponseBody _results(List<Map<String, Object?>> results) => _json(200, {"results": results});

Map<String, Object?> _created(String id) => {"status": "created", ..._located(id)};

/// The answer of `GET /api/me/shares`, a JSON array.
ResponseBody _sharesList(List<Map<String, Object?>> shares) => ResponseBody.fromString(
  jsonEncode(shares),
  200,
  headers: {
    Headers.contentTypeHeader: ["application/json"],
  },
);

Map<String, Object?> _listed(String id, String clientKeyHash) => {
  "id": id,
  "url": "${Const.sharingOrigin}/r/$id",
  "shared_on": "2026-10-20",
  "client_key_hash": clientKeyHash,
  "summary": <String, Object?>{},
};

Map<String, Object?> _me(List<String> trainerIds) => {"account_id": _accountId, "trainer_ids": trainerIds};

/// A record id distinct for each [i].
String _uuid(int i) => "9a1e0d66-0654-4416-aa11-${i.toString().padLeft(12, '0')}";

/// The fixture's bytes with both parent ids filled in, so every id a record carries is present.
String _recordBytes({String? recordType, String? recordId, String? trainerId}) {
  final map = jsonDecode(File('test/fixtures/chara_detail_record.json').readAsStringSync()) as Map<String, dynamic>;
  final metadata = map["metadata"] as Map<String, dynamic>;
  (metadata["record_id"] as Map<String, dynamic>).addAll({
    "parent1": _parent1Id,
    "parent2": _parent2Id,
    "self": ?recordId,
  });
  if (trainerId != null) {
    metadata["trainer_id"] = trainerId;
  }
  if (recordType != null) {
    metadata["record_type"] = recordType;
  }
  return jsonEncode(map);
}

/// The record store, holding only the record the row shows.
class _Shown extends CharaDetailRecordStorage {
  final CharaDetailRecord record;

  _Shown(this.record);

  @override
  Future<List<CharaDetailRecord>> build() async => [record];

  @override
  CharaDetailRecord? getBy({required String id}) => id == record.id ? record : null;
}

/// A record store that holds nothing: the record a note was made for has been deleted.
class _Emptied extends CharaDetailRecordStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => [];
}

/// A loopback listener the test hands the callback's proof to.
class _FakeListener implements LoginListener {
  final _code = Completer<String>();
  bool closed = false;

  @override
  int get port => 54321;

  @override
  Future<String> get code => _code.future;

  void callback(String proof) => _code.complete(proof);

  @override
  Future<void> close() async {
    closed = true;
    if (!_code.isCompleted) {
      _code.completeError(const LoginListenClosed(timedOut: false));
    }
  }
}

const _token = "TOKENtokenTOKENtokenTOKENtokenTOKENtoken123";
const _accountId = "acct-0001";

Map<String, Object?> _claimed() => {
  "token": _token,
  "expires_at": 1792000000,
  "account_id": _accountId,
  "deleting": false,
};

class _EmptyArchive extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);
  useStorageBoxForTest();

  late CharaDetailRecord record;
  late _FakeServer server;
  late ProviderContainer container;
  late List<Uri> opened;

  ProviderContainer containerFor(
    List<Object> answers, {
    String? trainerId,
    CharaDetailRecord? shown,
    bool emptied = false,
    LoginListener? listener,
  }) {
    server = _FakeServer(answers);
    opened = [];
    final c = ProviderContainer(
      overrides: [
        loginPageOpenerProvider.overrideWithValue((uri) async {
          opened.add(uri);
          return true;
        }),
        loginListenerBinderProvider.overrideWithValue(({required String h}) async => listener),
        trainerIdProvider.overrideWithValue(trainerId ?? record.metadata.trainerId),
        moduleVersionLoader.overrideWith(
          (ref) async => ModuleVersion(
            recognizerVersion: DateTime.utc(2026, 9, 30, 2),
            minimumVersion: DateTime.utc(2021),
            recognizerVersionText: _moduleVersion,
          ),
        ),
        recordShareDioProvider.overrideWith(
          (ref) => createDiagnosticDio(operation: "record_share")..httpClientAdapter = server,
        ),
        if (shown != null) charaDetailRecordStorageLoaderProvider.overrideWith(() => _Shown(shown)),
        if (emptied) ...[
          charaDetailRecordStorageLoaderProvider.overrideWith(_Emptied.new),
          charaDetailArchiveStorageLoaderProvider.overrideWith(_EmptyArchive.new),
        ],
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  RecordShares notes() => container.read(recordSharesProvider.notifier);

  Future<void> storeSession({bool deleting = false}) => StorageBox(StorageBoxKey.recordShares).push(
    shareSessionKey,
    ShareSession(token: _token, expiresAt: 1792000000, accountId: _accountId, deleting: deleting).toJson(),
  );

  Future<RecordShare> storeNote({String? recordId, RecordShareState state = RecordShareState.pending}) async {
    final shared = state == RecordShareState.shared;
    final note = RecordShare(
      recordId: recordId ?? record.id,
      accountId: _accountId,
      clientKey: newClientKey(),
      state: state,
      id: shared ? "0123456789" : null,
      url: shared ? "${Const.sharingOrigin}/r/0123456789" : null,
    );
    await StorageBox(StorageBoxKey.recordShares).push(note.keyHash, note.toJson());
    return note;
  }

  List<Map<String, dynamic>> sharesSent(int i) =>
      ((jsonDecode(server.sent[i].body) as Map<String, dynamic>)["shares"] as List).cast<Map<String, dynamic>>();

  setUp(() async {
    await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
    record = CharaDetailRecord.fromRecordJson(_recordBytes());
  });

  test('the body that leaves the device carries no trainer id, capture time or record id', () async {
    await storeSession();
    container = containerFor([
      _results([_created("0123456789")]),
    ]);

    final outcome = (await notes().shareAll([record]))[record.id];

    expect(outcome, isA<Shared>());
    expect(server.sent, hasLength(1));
    final body = server.sent.single.body;
    final bytes = _recordBytes();
    for (final value in [record.metadata.trainerId, record.metadata.capturedDate, record.id, _parent1Id, _parent2Id]) {
      expect(bytes, contains(value), reason: 'the input does not hold $value, so its absence proves nothing');
      expect(body, isNot(contains(value)));
    }
    for (final key in ["trainer_id", "captured_date", "record_id", "format_version", "stage", "icon"]) {
      expect(body, isNot(contains('"$key"')));
    }
    final sentRecord = sharesSent(0).single["record"] as Map<String, dynamic>;
    expect(sentRecord["module_version"], _moduleVersion);
    expect(sentRecord["trainee"], {
      "character": record.trainee.character,
      "card": record.trainee.card,
      "rank": record.trainee.rank,
    });
  });

  group('from the row menu', () {
    setUpAll(loadAppTranslations);

    /// Mounts a row whose context menu holds the real share submenu for [shown], over [container].
    Future<void> openMenu(WidgetTester tester, CharaDetailRecord shown) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: DialogLayer(
              child: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => showContextMenu(
                      context,
                      contextMenu: ContextMenu(
                        entries: [
                          recordShareMenu(
                            ref,
                            record: shown,
                            source: RecordSource.active,
                            constraints: const BoxConstraints(minHeight: 40),
                            style: null,
                          ),
                        ],
                      ),
                    ),
                    child: const Text('row'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('row'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('公開'));
      await tester.pumpAndSettle();
    }

    ProviderContainer containerShowing(CharaDetailRecord shown, List<Object> answers, {String? trainerId}) =>
        containerFor(answers, trainerId: trainerId, shown: shown);

    Future<void> shareFromMenu(WidgetTester tester, CharaDetailRecord shown) async {
      await openMenu(tester, shown);
      await tester.tap(find.text('公開する…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで公開'));
    }

    testWidgets('sharing shows the URL in the dialog', (tester) async {
      await storeSession();
      container = containerShowing(record, [
        _results([_created("0123456789")]),
      ]);

      await shareFromMenu(tester, record);
      final url = "${Const.sharingOrigin}/r/0123456789";
      await settleUntil(tester, () => find.text(url).evaluate().isNotEmpty, describe: 'the shared URL');

      expect(find.text('公開しました。'), findsOneWidget);
      expect(find.text('URL をコピー'), findsOneWidget);
      expect(server.sent.single.uri.path, "/api/shares");
      expect(server.sent.single.headers["Authorization"], "Bearer $_token");
      expect(container.read(recordSharesProvider).values.single.url, url);
    });

    testWidgets('a plain tap on the share button sends nothing; only the long press shares', (tester) async {
      await storeSession();
      container = containerShowing(record, [
        _results([_created("0123456789")]),
      ]);
      await openMenu(tester, record);
      await tester.tap(find.text('公開する…'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('長押しで公開'));
      // A press that did share needs fake time to elapse (as the hold does) and real time for the write
      // before the request, so the window covers both; it cannot be an arrival, there is none to wait for.
      await tester.pump(const Duration(seconds: 1));
      await pumpRealTimeWindow(tester, rounds: 20);
      expect(server.sent, isEmpty);
      expect(find.text('長押しで公開'), findsOneWidget, reason: 'the dialog is still waiting for the hold');

      await tester.longPress(find.text('長押しで公開'));
      await settleUntil(tester, () => find.text('公開しました。').evaluate().isNotEmpty, describe: 'the share');
      expect(server.sent, hasLength(1));
    });

    testWidgets('while the request is out, neither Cancel, the close button nor the scrim closes the dialog', (
      tester,
    ) async {
      await storeSession();
      final answer = Completer<Object>();
      container = containerShowing(record, [answer.future]);

      await shareFromMenu(tester, record);
      await settleUntil(tester, () => server.sent.isNotEmpty, describe: 'the request to reach the server');
      await tester.tap(find.text('キャンセル'), warnIfMissed: false);
      await tester.tap(find.byIcon(Symbols.close_rounded), warnIfMissed: false);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.byType(ShareRecordDialog), findsOneWidget, reason: 'the answer decides whether the share was made');

      answer.complete(_results([_created("0123456789")]));
      // Dio reads the late answer on the fake clock, which nothing else here moves.
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(tester, () => find.text('公開しました。').evaluate().isNotEmpty, describe: 'the share');
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.byType(ShareRecordDialog), findsNothing);
    });

    testWidgets('with no session, sharing asks for a login and sends nothing; after the login it shares', (
      tester,
    ) async {
      final listener = _FakeListener();
      container = containerFor(
        [
          _json(200, _claimed()),
          _json(200, {"trainer_id": record.metadata.trainerId}),
          _results([_created("0123456789")]),
        ],
        shown: record,
        listener: listener,
      );

      await shareFromMenu(tester, record);
      await settleUntil(tester, () => find.text('確認ページを開く').evaluate().isNotEmpty, describe: 'the way to the login');
      expect(server.sent, isEmpty);
      expect(container.read(recordSharesProvider), isEmpty, reason: 'no note is made before there is an account');

      await tester.tap(find.text('確認ページを開く'));
      await settleUntil(tester, () => opened.isNotEmpty, describe: 'the login page to open');
      listener.callback("proof-from-the-callback");
      // Dio reads each answer on the fake clock: one step for the claim, one for the trainer registration.
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(tester, () => server.sent.length == 2, describe: 'the trainer registration');
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => container.read(recordShareSessionProvider) != null && find.text('確認ページを開く').evaluate().isEmpty,
        describe: 'the login to finish',
      );
      expect(server.sent.map((s) => s.uri.path), ["/api/auth/claim", "/api/me/trainers"]);

      await tester.longPress(find.text('長押しで公開'));
      await settleUntil(tester, () => find.text('公開しました。').evaluate().isNotEmpty, describe: 'the share');
      expect(server.sent.last.uri.path, "/api/shares");
    });

    testWidgets("a record that is not a training of the account's trainers sends nothing", (tester) async {
      final friend = CharaDetailRecord.fromRecordJson(_recordBytes(recordType: "FriendStandard"));
      // Another trainer's record asks the account which trainers it holds; a friend's record asks nothing.
      final cases = [
        (record, "11111111-2222-4333-8444-555555555555", <Object>[_json(200, _me([]))], ["/api/me"]),
        (friend, null, <Object>[], <String>[]),
      ];
      for (final (shown, trainerId, answers, paths) in cases) {
        await storeSession();
        container = containerShowing(shown, answers, trainerId: trainerId);

        await shareFromMenu(tester, shown);
        await settleUntil(
          tester,
          () => find.text('自分で育成したレコードだけ公開できます。').evaluate().isNotEmpty,
          describe: 'the refusal',
        );

        expect(server.sent.map((s) => s.uri.path), paths);
        expect(container.read(recordSharesProvider), isEmpty);
        await tester.tap(find.text('閉じる'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('unsharing from the menu sends the delete and drops the note', (tester) async {
      await storeSession();
      container = containerShowing(record, [
        _results([_created("0123456789")]),
        _empty(204),
      ]);
      await tester.runAsync(() => notes().shareAll([record]));

      await openMenu(tester, record);
      await tester.tap(find.text('公開を取り消す…'));
      await tester.pumpAndSettle();
      expect(find.text('公開の取り消し'), findsOneWidget);
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(tester, () => find.text('公開の取り消し').evaluate().isEmpty, describe: 'the unshare dialog to close');

      expect(server.sent.last.method, "DELETE");
      expect(server.sent.last.uri.path, "/api/shares/0123456789");
      expect(server.sent.last.headers["Authorization"], "Bearer $_token");
      expect(container.read(recordSharesProvider), isEmpty);
      expect(StorageBox(StorageBoxKey.recordShares).entries().map((e) => e.key), [shareSessionKey]);
    });
  });

  group('from the privacy settings', () {
    setUpAll(loadAppTranslations);

    testWidgets("a share whose record was deleted is listed from the account's list and can be unshared", (
      tester,
    ) async {
      await storeSession();
      final note = await storeNote(state: RecordShareState.shared);
      container = containerFor([
        _sharesList([_listed("0123456789", note.keyHash)]),
        _empty(204),
      ], emptied: true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DialogLayer(child: Scaffold(body: RecordShareListTile())),
          ),
        ),
      );

      await tester.tap(find.text('公開したレコード'));
      // The dialog asks as it opens; one more fake step reads the answer.
      await settleUntilElapsing(tester, () => server.sent.isNotEmpty, describe: "the account's list to be asked for");
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.text('端末から削除したレコード').evaluate().isNotEmpty,
        describe: 'the row of the deleted record',
      );
      expect(server.sent.single.uri.path, "/api/me/shares");
      await tester.tap(find.text('取り消す…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(
        tester,
        () => find.text('公開したレコードはありません。').evaluate().isNotEmpty,
        describe: 'the list to empty',
      );

      expect(server.sent.last.method, "DELETE");
      expect(server.sent.last.uri.path, "/api/shares/0123456789");
      expect(container.read(recordSharesProvider), isEmpty);
    });
  });

  test(
    'a selection of more than eight is sent eight at a time, and one refused share leaves the others clean',
    () async {
      await storeSession();
      final records = [for (var i = 0; i < 10; i++) CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(i)))];
      container = containerFor([
        _results([
          for (var i = 0; i < 8; i++)
            i == 2 ? {"status": "refused", "error": "account_limit"} : _created("00000000${i}0"),
        ]),
        _results([_created("0000000080"), _created("0000000090")]),
      ]);

      final outcomes = await notes().shareAll(records);

      expect(
        [
          for (final i in [0, 1]) sharesSent(i).length,
        ],
        [8, 2],
      );
      final keys = [
        for (final i in [0, 1]) ...sharesSent(i).map((s) => s["client_key"] as String),
      ];
      expect(keys.toSet(), hasLength(10), reason: 'every share carries its own key');
      for (final (i, r) in records.indexed) {
        final note = notes().entryOf(r.id);
        expect(note?.clientKey, keys[i]);
        if (i == 2) {
          expect(outcomes[r.id], isA<ShareRefused>().having((o) => o.reason, 'reason', ShareRefusal.accountLimit));
          expect(note?.state, RecordShareState.pending);
          expect(note?.id, isNull);
        } else {
          expect(outcomes[r.id], isA<Shared>());
          expect(note?.state, RecordShareState.shared);
          expect(note?.id, "00000000${i}0");
        }
      }
    },
  );

  test("the account's list confirms a pending note whose key hash it names, and drops one it does not", () async {
    await storeSession();
    final kept = await storeNote();
    final lost = await storeNote(recordId: _uuid(1));
    container = containerFor([
      _sharesList([_listed("0123456789", sha256.convert(utf8.encode(kept.clientKey)).toString())]),
    ]);

    expect(await notes().refreshFromServer(), isA<SharesListed>());

    final notesNow = container.read(recordSharesProvider);
    expect(notesNow.keys, [kept.keyHash]);
    expect(notesNow[kept.keyHash]?.state, RecordShareState.shared);
    expect(notesNow[kept.keyHash]?.id, "0123456789");
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(lost.keyHash), isNull);
  });

  test("a record of this device's trainer is shared without asking the account; another trainer's asks it", () async {
    await storeSession();
    const otherTrainer = "11111111-2222-4333-8444-555555555555";
    final synced = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(1), trainerId: otherTrainer));
    container = containerFor([
      _results([_created("0123456789")]),
      _json(200, _me([otherTrainer])),
      _results([_created("0123456780")]),
    ]);

    // As after a login whose trainer registration got no answer: the account does not hold this device's id.
    expect((await notes().shareAll([record]))[record.id], isA<Shared>());
    expect((await notes().shareAll([synced]))[synced.id], isA<Shared>());

    expect(server.sent.map((s) => s.uri.path), ["/api/shares", "/api/me", "/api/shares"]);
  });

  group('after a 401', () {
    final cases = [
      ('a claim to another account drops the old notes before sharing', "acct-0002", false),
      ('a claim to the same account keeps them', _accountId, true),
    ];
    for (final (name, nextAccount, keeps) in cases) {
      test(name, () async {
        await storeSession();
        final old = await storeNote(state: RecordShareState.shared);
        final other = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(1)));
        container = containerFor([
          _json(401, {"error": "session_required"}),
          _json(200, {..._claimed(), "account_id": nextAccount}),
          _json(200, {"trainer_id": record.metadata.trainerId}),
          _results([_created("0123456780"), if (!keeps) _created("0123456781")]),
        ]);

        expect((await notes().shareAll([other]))[other.id], isA<LoginRequired>());
        expect(container.read(recordShareSessionProvider), isNull);
        expect(notes().entryOf(record.id), isNotNull, reason: 'a 401 alone keeps the notes');

        final attempt = await container.read(recordShareSessionProvider.notifier).beginLogin();
        expect(await attempt.claim(), LoginOutcome.signedIn);
        final outcomes = await notes().shareAll([record, other]);

        final sentKeys = sharesSent(3).map((s) => s["client_key"]).toList();
        if (keeps) {
          expect(outcomes[record.id], isA<AlreadyShared>());
          expect(sentKeys, hasLength(1));
          expect(notes().entryOf(record.id)?.clientKey, old.clientKey);
        } else {
          expect(outcomes[record.id], isA<Shared>());
          expect(sentKeys, hasLength(2));
          expect(sentKeys, isNot(contains(old.clientKey)));
          expect(StorageBox(StorageBoxKey.recordShares).pull<String>(old.keyHash), isNull);
          expect(container.read(recordSharesProvider).values.map((n) => n.accountId).toSet(), {nextAccount});
        }
      });
    }
  });

  group('the client keys never reach a log line', () {
    late List<String> logged;
    late BreadcrumbSink realSink;

    setUp(() {
      logged = [];
      realSink = debugBreadcrumbSink;
      debugBreadcrumbSink = (Level level, String message, dynamic error) => logged.add('$message $error');
    });
    tearDown(() => debugBreadcrumbSink = realSink);

    test('through a share, a lost connection, a refusal, a listing and an unshare', () async {
      await storeSession();
      final other = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(1)));
      final listing = Completer<Object>();
      container = containerFor([
        _lostConnection,
        _results([
          _created("0123456789"),
          {"status": "refused", "error": "invalid_payload"},
        ]),
        listing.future,
        _empty(204),
      ]);

      expect((await notes().shareAll([record, other]))[record.id], isA<ShareUnreachable>());
      await notes().shareAll([record, other]);
      final keys = [
        for (final r in [record, other]) notes().entryOf(r.id)?.clientKey ?? "",
      ];
      listing.complete(_sharesList([_listed("0123456789", secretHash(keys[0]))]));
      expect(await notes().refreshFromServer(), isA<SharesListed>());
      expect(await notes().unshare("0123456789"), UnshareOutcome.unshared);

      expect(server.sent, hasLength(4));
      expect(logged.where((line) => line.contains('Network request error')), isNotEmpty);
      for (final key in keys) {
        expect(
          server.sent[1].body,
          contains(key),
          reason: 'the key was sent, so its absence from the log says something',
        );
        for (final line in logged) {
          expect(line, isNot(contains(key)));
        }
      }
    });
  });

  test('a reply that never arrived is resent with the same key and then confirmed', () async {
    await storeSession();
    container = containerFor([
      _lostConnection,
      _results([
        {"status": "existing", ..._located("0123456789")},
      ]),
    ]);

    expect((await notes().shareAll([record]))[record.id], isA<ShareUnreachable>());
    final pending = container.read(recordSharesProvider).values.single;
    expect(pending.state, RecordShareState.pending);

    final outcome = (await notes().shareAll([record]))[record.id];

    expect(
      [
        for (final i in [0, 1]) sharesSent(i).single["client_key"],
      ],
      [pending.clientKey, pending.clientKey],
    );
    expect(outcome, isA<Shared>().having((o) => o.entry.keyHash, 'keyHash', pending.keyHash));
    final stored = StorageBox(StorageBoxKey.recordShares).pull<String>(pending.keyHash);
    expect(RecordShareMapper.fromJson(stored ?? "").state, RecordShareState.shared);
  });

  test("a 404 that is not the API saying the share is gone keeps the note; the API's 404 drops it", () async {
    await storeSession();
    final note = await storeNote(state: RecordShareState.shared);
    container = containerFor([
      // What the assets-only deployment answers while sharing is switched off.
      ResponseBody.fromString("<!doctype html><title>Not Found</title>", 404),
      _json(404, {"error": "not_found"}),
    ]);

    expect(await notes().unshare("0123456789"), UnshareOutcome.failed);
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(note.keyHash), isNotNull);

    expect(await notes().unshare("0123456789"), UnshareOutcome.unshared);
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(note.keyHash), isNull);
  });

  group('the sharing session', () {
    RecordShareSession session() => container.read(recordShareSessionProvider.notifier);
    Map<String, dynamic> bodyOf(int i) => jsonDecode(server.sent[i].body) as Map<String, dynamic>;

    test('building the session reads the store and calls no server', () async {
      await storeSession();
      final note = await storeNote();
      container = containerFor([]);

      expect(container.read(recordShareSessionProvider)?.token, _token);
      expect(container.read(recordSharesProvider).keys, [note.keyHash]);
      // A request reaches the transport only asynchronously, so let one that build() started arrive first.
      await pumpEventQueue();
      expect(server.sent, isEmpty);
    });

    test('after a claim, the requests under the session carry its bearer token', () async {
      container = containerFor([
        _json(200, _claimed()),
        _json(200, {"trainer_id": record.metadata.trainerId}),
        _json(200, {"account_id": _accountId}),
      ]);

      final attempt = await session().beginLogin();
      expect(await attempt.claim(), LoginOutcome.signedIn);
      await session().send("GET", "/api/me");

      expect(server.sent.map((r) => r.uri.path), ["/api/auth/claim", "/api/me/trainers", "/api/me"]);
      expect(server.sent[0].headers["Authorization"], isNull);
      for (final request in server.sent.skip(1)) {
        expect(request.headers["Authorization"], "Bearer $_token");
      }
      expect(bodyOf(1), {"trainer_id": record.metadata.trainerId});
      final stored = StorageBox(StorageBoxKey.recordShares).pull<String>(shareSessionKey);
      expect(ShareSessionMapper.fromJson(stored!).accountId, _accountId);
    });

    test("the server's 401 drops the session and keeps the share notes", () async {
      await storeSession();
      final note = await storeNote();
      container = containerFor([
        _json(401, {"error": "session_required"}),
      ]);

      final answer = await session().send("GET", "/api/me");

      expect(answer.status, 401);
      expect(container.read(recordShareSessionProvider), isNull);
      final box = StorageBox(StorageBoxKey.recordShares);
      expect(box.pull<String>(shareSessionKey), isNull);
      expect(box.pull<String>(note.keyHash), isNotNull);
      expect(container.read(recordSharesProvider).keys, [note.keyHash]);
    });

    test('logging out drops the session and the share notes', () async {
      await storeSession();
      await storeNote();
      container = containerFor([_empty(204)]);
      expect(container.read(recordSharesProvider), isNotEmpty);

      expect(await session().logout(), isTrue);

      expect(server.sent.single.uri.path, "/api/auth/logout");
      expect(server.sent.single.headers["Authorization"], "Bearer $_token");
      expect(container.read(recordShareSessionProvider), isNull);
      expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
      expect(container.read(recordSharesProvider), isEmpty);
    });

    test('a login with a listener names its port on the start page and claims with exactly s and code', () async {
      final listener = _FakeListener();
      container = containerFor([
        _json(200, _claimed()),
        _json(200, {"trainer_id": record.metadata.trainerId}),
      ], listener: listener);

      final attempt = await session().beginLogin();
      expect(attempt.waitsForCallback, isTrue);
      expect(server.sent, isEmpty, reason: 'nothing is claimed before the callback');
      listener.callback("proof-from-the-callback");

      expect(await attempt.completion, LoginOutcome.signedIn);
      final page = opened.single;
      expect(page.path, "/api/auth/start");
      expect(page.queryParameters["port"], "${listener.port}");
      expect(page.queryParameters["p"], "google");
      final claim = bodyOf(0);
      expect(claim.keys.toSet(), {"s", "code"});
      expect(claim["code"], "proof-from-the-callback");
      expect(page.queryParameters["h"], sha256.convert(utf8.encode(claim["s"] as String)).toString());
    });

    test('closing a login with a listener closes the listener and claims nothing', () async {
      final listener = _FakeListener();
      container = containerFor([], listener: listener);

      final attempt = await session().beginLogin();
      final completion = attempt.completion;
      await attempt.cancel();

      expect(await completion, LoginOutcome.cancelled);
      expect(listener.closed, isTrue);
      expect(server.sent, isEmpty);
    });

    test(
      'a login without a listener names no port, claims with exactly s, and succeeds after login_incomplete',
      () async {
        container = containerFor([
          _json(409, {"error": "login_incomplete"}),
          _json(200, _claimed()),
          _json(200, {"trainer_id": record.metadata.trainerId}),
        ]);

        final attempt = await session().beginLogin();
        expect(attempt.waitsForCallback, isFalse);
        expect(opened.single.queryParameters.containsKey("port"), isFalse);

        expect(await attempt.claim(), LoginOutcome.incomplete);
        expect(container.read(recordShareSessionProvider), isNull);
        expect(await attempt.claim(), LoginOutcome.signedIn);

        for (final i in [0, 1]) {
          expect(bodyOf(i).keys.toSet(), {"s"});
        }
        expect(bodyOf(0)["s"], bodyOf(1)["s"]);
        expect(opened.single.queryParameters["h"], sha256.convert(utf8.encode(bodyOf(1)["s"] as String)).toString());
        expect(container.read(recordShareSessionProvider)?.token, _token);
      },
    );

    test('an account already holding as many trainers as it may still logs in', () async {
      container = containerFor([
        _json(200, _claimed()),
        _json(409, {"error": "trainer_limit"}),
      ]);

      final attempt = await session().beginLogin();

      expect(await attempt.claim(), LoginOutcome.trainerLimit);
      expect(container.read(recordShareSessionProvider)?.token, _token);
      expect(StorageBox(StorageBoxKey.recordShares).pull<String>(shareSessionKey), isNotNull);
    });

    group('deleting the account', () {
      ShareSession? stored() => switch (StorageBox(StorageBoxKey.recordShares).pull<String>(shareSessionKey)) {
        final json? => ShareSessionMapper.fromJson(json),
        null => null,
      };
      ResponseBody remaining(Map<String, int> kinds) => _json(200, {"remaining": kinds});
      ResponseBody deleting() => _json(409, {"error": "account_deleting"});

      test('repeats the delete while any kind remains, then drops the session and the share notes', () async {
        await storeSession();
        await storeNote();
        container = containerFor([
          remaining({"shares": 3, "sync": 2}),
          remaining({"shares": 0, "sync": 1}),
          _empty(204),
        ]);
        final progress = <int>[];

        expect(await session().deleteAccount(onProgress: progress.add), AccountDeletionOutcome.deleted);

        expect(progress, [5, 1]);
        expect(server.sent.map((r) => "${r.method} ${r.uri.path}"), List.filled(3, "DELETE /api/me"));
        for (final request in server.sent) {
          expect(request.headers["Authorization"], "Bearer $_token");
        }
        expect(container.read(recordShareSessionProvider), isNull);
        expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
        expect(container.read(recordSharesProvider), isEmpty);
      });

      test('cut off after its first 200, it continues after a restart with the same token', () async {
        await storeSession();
        await storeNote();
        container = containerFor([
          remaining({"shares": 2, "sync": 1}),
          _lostConnection,
        ]);

        expect(await session().deleteAccount(), AccountDeletionOutcome.unreachable);
        expect(stored()?.deleting, isTrue);
        expect(stored()?.token, _token);

        container = containerFor([
          remaining({"shares": 0, "sync": 1}),
          _empty(204),
        ]);
        expect(container.read(recordShareSessionProvider)?.deleting, isTrue);
        expect(await session().deleteAccount(), AccountDeletionOutcome.deleted);

        expect(server.sent.map((r) => r.headers["Authorization"]), List.filled(2, "Bearer $_token"));
        expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
      });

      test("GET /api/me's account_deleting marks the session as deleting", () async {
        await storeSession();
        const otherTrainer = "11111111-2222-4333-8444-555555555555";
        final other = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(1), trainerId: otherTrainer));
        container = containerFor([deleting()]);

        final outcome = (await notes().shareAll([other]))[other.id];

        expect(server.sent.single.uri.path, "/api/me");
        expect(outcome, isA<ShareRefused>().having((o) => o.reason, "reason", ShareRefusal.accountDeleting));
        expect(container.read(recordShareSessionProvider)?.deleting, isTrue);
        expect(stored()?.deleting, isTrue);
      });

      test("sharing's account_deleting marks the session as deleting", () async {
        await storeSession();
        container = containerFor([deleting()]);

        final outcome = (await notes().shareAll([record]))[record.id];

        expect(server.sent.single.uri.path, "/api/shares");
        expect(outcome, isA<ShareRefused>().having((o) => o.reason, "reason", ShareRefusal.accountDeleting));
        expect(stored()?.deleting, isTrue);
      });

      test("the list of shares' account_deleting marks the session as deleting", () async {
        await storeSession();
        final note = await storeNote(state: RecordShareState.shared);
        container = containerFor([deleting()]);

        expect(await notes().refreshFromServer(), isA<SharesAccountDeleting>());

        expect(server.sent.single.uri.path, "/api/me/shares");
        expect(stored()?.deleting, isTrue);
        expect(container.read(recordSharesProvider).keys, [note.keyHash]);
      });

      test(
        'a session lost on the way is regained by a login that answers deleting, and the deletion finishes',
        () async {
          await storeSession(deleting: true);
          await storeNote();
          container = containerFor([
            _json(401, {"error": "session_required"}),
            _json(200, {..._claimed(), "deleting": true}),
            remaining({"shares": 1, "sync": 0}),
            _empty(204),
          ]);

          expect(await session().deleteAccount(), AccountDeletionOutcome.loginRequired);
          expect(stored(), isNull);

          final attempt = await session().beginLogin();
          expect(await attempt.claim(), LoginOutcome.signedIn);
          expect(stored()?.deleting, isTrue);
          expect(await session().deleteAccount(), AccountDeletionOutcome.deleted);

          // A deletion-only session registers no trainer id: every later request is the deletion's.
          expect(server.sent.map((r) => "${r.method} ${r.uri.path}"), [
            "DELETE /api/me",
            "POST /api/auth/claim",
            "DELETE /api/me",
            "DELETE /api/me",
          ]);
          expect(container.read(recordShareSessionProvider), isNull);
          expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
        },
      );
    });

    group('the login secrets and the session token never reach a log line', () {
      late List<String> logged;
      late BreadcrumbSink realSink;

      setUp(() {
        logged = [];
        realSink = debugBreadcrumbSink;
        debugBreadcrumbSink = (Level level, String message, dynamic error) => logged.add('$message $error');
      });
      tearDown(() => debugBreadcrumbSink = realSink);

      test('through a login, a request under the session, a lost connection and a logout', () async {
        final listener = _FakeListener();
        container = containerFor([
          _json(200, _claimed()),
          _json(200, {"trainer_id": record.metadata.trainerId}),
          _lostConnection,
          _empty(204),
        ], listener: listener);

        final attempt = await session().beginLogin();
        listener.callback("proof-from-the-callback");
        expect(await attempt.completion, LoginOutcome.signedIn);
        await expectLater(session().send("GET", "/api/me"), throwsA(isA<DioException>()));
        expect(await session().logout(), isTrue);

        expect(server.sent, hasLength(4));
        expect(logged.where((line) => line.contains('Network request error')), isNotEmpty);
        final secret = bodyOf(0)["s"] as String;
        for (final value in [_token, secret, "proof-from-the-callback"]) {
          for (final line in logged) {
            expect(line, isNot(contains(value)));
          }
        }
      });
    });
  });
}
