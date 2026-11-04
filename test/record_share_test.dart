// Sharing a record under the logged-in account: what leaves the device, that each share's note follows its
// own result and its account, and that the client keys and the login secrets never reach a log line.
//
// Entry: a real `record.json`'s bytes decoded the way the app decodes them, the real
// `recordShares` store, and the real diagnostic Dio with only its transport replaced. Nothing
// reaches a network. The dialog cases enter through the row menu's real share submenu and the
// long-press confirms of the share and unshare dialogs; sharing the checked records enters through the
// table toolbar's real share button and the selection scrim; the list of shares enters through its
// real row on the account tab.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_share_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/gui/account.dart';
import 'package:umacapture/src/gui/chara_detail/column_preset_bar_widget.dart';
import 'package:umacapture/src/gui/chara_detail/data_table_widget.dart';
import 'package:umacapture/src/gui/chara_detail/record_share_list_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/share_account_section.dart';
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

Map<String, Object?> _listed(String id, String clientKeyHash, {String? cardName}) => {
  "id": id,
  "url": "${Const.sharingOrigin}/r/$id",
  "shared_on": "2026-10-20",
  "client_key_hash": clientKeyHash,
  "summary": <String, Object?>{
    if (cardName != null)
      "trainee": {
        "card": {"gid": 100101, "name": cardName},
      },
  },
};

/// A card's name as the server's name tables label it, which is not the form the app's own rows use.
const _serverCardName = "[スペシャルドリーマー]スペシャルウィーク";

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

/// The record store, holding only the records the rows show.
class _Shown extends CharaDetailRecordStorage {
  final List<CharaDetailRecord> shownRecords;

  _Shown(this.shownRecords);

  @override
  Future<List<CharaDetailRecord>> build() async => shownRecords;

  @override
  CharaDetailRecord? getBy({required String id}) => shownRecords.where((r) => r.id == id).firstOrNull;
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

  /// The listener's own deadline passing with no callback.
  void timeOut() => _code.completeError(const LoginListenClosed(timedOut: true));

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
    List<CharaDetailRecord>? held,
    bool emptied = false,
    LoginListener? listener,
    Duration? requestTimeout,
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
        if (requestTimeout != null) shareRequestTimeoutProvider.overrideWithValue(requestTimeout),
        if (held ?? [?shown] case final records when records.isNotEmpty)
          charaDetailRecordStorageLoaderProvider.overrideWith(() => _Shown(records)),
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
      await tester.tap(find.text('共有'));
      await tester.pumpAndSettle();
    }

    ProviderContainer containerShowing(CharaDetailRecord shown, List<Object> answers, {String? trainerId}) =>
        containerFor(answers, trainerId: trainerId, shown: shown);

    Future<void> shareFromMenu(WidgetTester tester, CharaDetailRecord shown) async {
      await openMenu(tester, shown);
      await tester.tap(find.text('共有する…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで共有'));
    }

    testWidgets('sharing shows the URL in the dialog', (tester) async {
      await storeSession();
      container = containerShowing(record, [
        _results([_created("0123456789")]),
      ]);

      await shareFromMenu(tester, record);
      final url = "${Const.sharingOrigin}/r/0123456789";
      await settleUntil(tester, () => find.text(url).evaluate().isNotEmpty, describe: 'the shared URL');

      expect(find.text('共有しました。'), findsOneWidget);
      expect(find.text('URL をコピー'), findsOneWidget);
      expect(server.sent.single.uri.path, "/api/shares");
      expect(server.sent.single.headers["Authorization"], "Bearer $_token");
      expect(container.read(recordSharesProvider).values.single.url, url);
    });

    testWidgets("the confirmation's link opens the privacy policy next to the shared pages", (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final opened = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        opened.add((call.arguments as Map)['url']);
        return true;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      container = containerShowing(record, []);

      await openMenu(tester, record);
      await tester.tap(find.text('共有する…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('プライバシーポリシー'));
      await tester.pumpAndSettle();

      expect(opened, ["${Const.sharingOrigin}/privacy/"]);
      expect(server.sent, isEmpty);
    });

    testWidgets('a plain tap on the share button sends nothing; only the long press shares', (tester) async {
      await storeSession();
      container = containerShowing(record, [
        _results([_created("0123456789")]),
      ]);
      await openMenu(tester, record);
      await tester.tap(find.text('共有する…'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('長押しで共有'));
      // A press that did share needs fake time to elapse (as the hold does) and real time for the write
      // before the request, so the window covers both; it cannot be an arrival, there is none to wait for.
      await tester.pump(const Duration(seconds: 1));
      await pumpRealTimeWindow(tester, rounds: 20);
      expect(server.sent, isEmpty);
      expect(find.text('長押しで共有'), findsOneWidget, reason: 'the dialog is still waiting for the hold');

      await tester.longPress(find.text('長押しで共有'));
      await settleUntil(tester, () => find.text('共有しました。').evaluate().isNotEmpty, describe: 'the share');
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
      await settleUntil(tester, () => find.text('共有しました。').evaluate().isNotEmpty, describe: 'the share');
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
      await settleUntil(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the way to the login',
      );
      expect(server.sent, isEmpty);
      expect(container.read(recordSharesProvider), isEmpty, reason: 'no note is made before there is an account');

      await tester.tap(find.text('Google でログイン'));
      await settleUntil(tester, () => opened.isNotEmpty, describe: 'the login page to open');
      listener.callback("proof-from-the-callback");
      // Dio reads each answer on the fake clock: one step for the claim, one for the trainer registration.
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(tester, () => server.sent.length == 2, describe: 'the trainer registration');
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => container.read(recordShareSessionProvider) != null && find.text('Google でログイン').evaluate().isEmpty,
        describe: 'the login to finish',
      );
      expect(server.sent.map((s) => s.uri.path), ["/api/auth/claim", "/api/me/trainers"]);

      await tester.longPress(find.text('長押しで共有'));
      await settleUntil(tester, () => find.text('共有しました。').evaluate().isNotEmpty, describe: 'the share');
      expect(server.sent.last.uri.path, "/api/shares");
    });

    testWidgets('a login whose listener timed out says the login expired, and claims nothing', (tester) async {
      final listener = _FakeListener();
      container = containerFor([], shown: record, listener: listener);

      await shareFromMenu(tester, record);
      await settleUntil(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the way to the login',
      );
      await tester.tap(find.text('Google でログイン'));
      await settleUntil(tester, () => opened.isNotEmpty, describe: 'the login page to open');
      listener.timeOut();
      await settleUntil(
        tester,
        () => find.text('ログインの有効期限が切れました。もう一度ログインしてください。').evaluate().isNotEmpty,
        describe: 'the expired sentence',
      );
      expect(server.sent, isEmpty);
      expect(container.read(recordShareSessionProvider), isNull);
    });

    testWidgets('with no listener, the login is claimed each time the page is shown again, with no second press', (
      tester,
    ) async {
      container = containerFor([
        _json(409, {"error": "login_incomplete"}),
        _json(200, _claimed()),
        _json(200, {"trainer_id": record.metadata.trainerId}),
      ], shown: record);
      // The login page opens in another tab; coming back to this one is the page being shown again.
      void leaveAndReturn() {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }

      await shareFromMenu(tester, record);
      await settleUntil(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the way to the login',
      );
      await tester.tap(find.text('Google でログイン'));
      await settleUntil(tester, () => opened.isNotEmpty, describe: 'the login page to open');
      expect(server.sent, isEmpty, reason: 'nothing is claimed before the page is shown again');

      leaveAndReturn();
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(tester, () => server.sent.length == 1, describe: 'the claim of the first return');
      expect(find.text('Google でログイン'), findsOneWidget, reason: 'an unfinished login waits for the next return');

      leaveAndReturn();
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(tester, () => server.sent.length == 3, describe: 'the trainer registration');
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => container.read(recordShareSessionProvider) != null && find.text('長押しで共有').evaluate().isNotEmpty,
        describe: 'the login to finish',
      );
      expect(server.sent.map((s) => s.uri.path), ["/api/auth/claim", "/api/auth/claim", "/api/me/trainers"]);
      expect(opened, hasLength(1));
    });

    testWidgets('a login that does not simply succeed says why, next to what to do about it', (tester) async {
      const login = 'Google でログイン';
      final cases = [
        (
          'incomplete',
          <Object>[
            _json(409, {"error": "login_incomplete"}),
          ],
          'ログインがまだ終わっていません。開いたログインのタブで続けてから、もう一度押してください。',
        ),
        (
          'expired',
          <Object>[
            _json(410, {"error": "login_expired"}),
          ],
          'ログインの有効期限が切れました。もう一度ログインしてください。',
        ),
        (
          'refused',
          <Object>[
            _json(403, {"error": "forbidden"}),
          ],
          'ログインを確認できませんでした。もう一度ログインしてください。',
        ),
        ('unreachable', <Object>[_lostConnection], 'サーバーに接続できなかったため、ログインを確認できませんでした。もう一度お試しください。'),
        (
          'trainer limit',
          <Object>[
            _json(200, _claimed()),
            _json(409, {"error": "trainer_limit"}),
          ],
          'ログインしました。ただし、このアカウントに登録できるトレーナー ID の数が上限に達しているため、'
              'この端末のトレーナー ID は登録されませんでした。この端末で育成したレコードは共有できます。',
        ),
      ];
      for (final (name, answers, sentence) in cases) {
        // No listener: the proof is claimed by pressing the login button a second time.
        container = containerFor(answers, shown: record);
        opened = [];

        await shareFromMenu(tester, record);
        await settleUntil(tester, () => find.text(login).evaluate().isNotEmpty, describe: 'the way to the login');
        expect(find.text('共有にはログインが必要です。'), findsOneWidget, reason: name);
        await tester.tap(find.text(login));
        await settleUntil(tester, () => opened.isNotEmpty, describe: 'the login page to open');
        await tester.tap(find.text(login));
        await tester.pump(const Duration(seconds: 1));
        await settleUntil(tester, () => find.text(sentence).evaluate().isNotEmpty, describe: 'the $name sentence');

        if (name == 'trainer limit') {
          expect(container.read(recordShareSessionProvider), isNotNull);
          expect(find.text('長押しで共有'), findsOneWidget, reason: 'signed in, the share can be confirmed');
          expect(find.text(login), findsNothing);
        } else {
          expect(container.read(recordShareSessionProvider), isNull, reason: name);
          expect(find.text('共有にはログインが必要です。'), findsNothing, reason: 'the login sentence takes its place');
        }
        if (name == 'expired' || name == 'refused') {
          // An ended attempt cannot be claimed again; the next press starts a new login.
          await tester.tap(find.text(login));
          await settleUntil(tester, () => opened.length == 2, describe: 'a new login page to open');
          expect(server.sent, hasLength(1), reason: 'nothing is claimed with the ended attempt');
        }
        await tester.tap(find.byIcon(Symbols.close_rounded).last);
        await tester.pumpAndSettle();
      }
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
          () => find.text('自分で育成したレコードだけ共有できます。').evaluate().isNotEmpty,
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
      await tester.tap(find.text('共有を取り消す…'));
      await tester.pumpAndSettle();
      expect(find.text('共有を取り消す'), findsOneWidget);
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(tester, () => find.text('共有を取り消す').evaluate().isEmpty, describe: 'the unshare dialog to close');

      expect(server.sent.last.method, "DELETE");
      expect(server.sent.last.uri.path, "/api/shares/0123456789");
      expect(server.sent.last.headers["Authorization"], "Bearer $_token");
      expect(container.read(recordSharesProvider), isEmpty);
      expect(StorageBox(StorageBoxKey.recordShares).entries().map((e) => e.key), [shareSessionKey]);
    });

    // S4b G398: P2 leads a lost session to a login, as P1 does, instead of reading it as a refusal.
    testWidgets('unsharing with no session asks for a login there, and after it the long press unshares', (
      tester,
    ) async {
      await storeNote(state: RecordShareState.shared);
      final listener = _FakeListener();
      container = containerFor(
        [
          _json(200, _claimed()),
          _json(200, {"trainer_id": record.metadata.trainerId}),
          _empty(204),
        ],
        shown: record,
        listener: listener,
      );

      await openMenu(tester, record);
      await tester.tap(find.text('共有を取り消す…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(
        tester,
        () => find.text('共有を取り消すにはログインが必要です。').evaluate().isNotEmpty,
        describe: 'the way to the login',
      );
      expect(server.sent, isEmpty);

      await tester.tap(find.text('Google でログイン'));
      await settleUntil(tester, () => opened.isNotEmpty, describe: 'the login page to open');
      listener.callback("proof-from-the-callback");
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(tester, () => server.sent.length == 2, describe: 'the trainer registration');
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.text('長押しで取り消す').evaluate().isNotEmpty,
        describe: 'the long press to come back after the login',
      );

      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(tester, () => find.text('共有を取り消す').evaluate().isEmpty, describe: 'the unshare dialog to close');
      expect(server.sent.last.method, "DELETE");
      expect(server.sent.last.uri.path, "/api/shares/0123456789");
      expect(container.read(recordSharesProvider), isEmpty);
    });

    // S4b G396: the account's limit holds a count that only unsharing lowers, as well as a daily charge.
    testWidgets("the account's limit is not told as the day's limit", (tester) async {
      await storeSession();
      container = containerShowing(record, [
        _results([
          {"status": "refused", "error": "account_limit"},
        ]),
      ]);

      await shareFromMenu(tester, record);
      await settleUntil(
        tester,
        () => find.textContaining('このアカウントで共有できる上限').evaluate().isNotEmpty,
        describe: "the account's limit",
      );
      expect(find.textContaining('今日の共有の上限'), findsNothing);
    });
  });

  // S4c: sharing the checked records (N2), from the table toolbar's share button through the selection scrim.
  group('from the table toolbar', () {
    setUpAll(loadAppTranslations);

    /// Mounts the real toolbar under the selection scrim over [container], enters share selection from its button,
    /// checks [ids] as the grid's checkboxes would, and opens the confirmation from the scrim.
    Future<void> openBulk(WidgetTester tester, List<String> ids) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => container.read(charaDetailRecordStorageLoaderProvider.future));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DialogLayer(
              child: Scaffold(
                // The box stands in for the column chips the layer also covers, which the scrim's buttons sit over.
                body: TopControlsLayer(
                  controls: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [ColumnPresetBarWidget(), SizedBox(height: 80)],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('共有するレコードの選択'));
      await tester.pump();
      container.read(selectedRecordIdsProvider.notifier).set(ids.toSet());
      await tester.pump();
      await tester.tap(find.text('選択を共有'));
      await tester.pumpAndSettle();
    }

    List<CharaDetailRecord> ownRecords(int n) => [
      for (var i = 0; i < n; i++) CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(i))),
    ];

    testWidgets(
      'S4c (C1 i): nine records go as eight and one; the one that failed is told and the rest is sent again',
      (tester) async {
        await storeSession();
        final records = ownRecords(9);
        container = containerFor([
          _results([for (var i = 0; i < 8; i++) _created("id-$i")]),
          _lostConnection,
          _results([_created("id-8")]),
        ], held: records);

        await openBulk(tester, [for (final r in records) r.id]);
        expect(find.text('9 件のレコードを共有します。'), findsOneWidget);
        await tester.longPress(find.text('長押しで共有'));
        await settleUntil(tester, () => find.text('残りを再試行').evaluate().isNotEmpty, describe: 'the partial result');

        expect([sharesSent(0).length, sharesSent(1).length], [8, 1]);
        expect(find.text('8 件を共有しました。\n1 件は共有できませんでした。'), findsOneWidget);
        expect(find.text('サーバーに接続できませんでした。もう一度お試しください。'), findsOneWidget);
        expect(
          container.read(selectionModeProvider),
          isNull,
          reason: 'the checked rows are the dialog\'s to tell about',
        );

        await tester.tap(find.text('残りを再試行'));
        // Dio reads the answer on the fake clock, which nothing else here moves.
        await tester.pump(const Duration(seconds: 1));
        await settleUntil(tester, () => find.text('9 件を共有しました。').evaluate().isNotEmpty, describe: 'the retry');
        expect(
          sharesSent(2).single["client_key"],
          sharesSent(1).single["client_key"],
          reason: 'the kept key is resent',
        );
        expect(find.text("${Const.sharingOrigin}/u/$_accountId"), findsOneWidget, reason: 'all shared: the list URL');
        expect(find.text('残りを再試行'), findsNothing);
      },
    );

    testWidgets('S4d (C1): a share begun under one account sends nothing more once another account has logged in', (
      tester,
    ) async {
      await storeSession();
      final records = ownRecords(9);
      final heldAnswer = Completer<Object>();
      const tokenB = 'second-account-token';
      container = containerFor([
        _lostConnection,
        heldAnswer.future,
        _empty(204),
        _json(200, {..._claimed(), 'account_id': 'acct-0002', 'token': tokenB}),
        _json(200, {'trainer_id': record.metadata.trainerId}),
        // Answers the last record only if it is wrongly sent under the second account.
        _results([_created('id-8')]),
      ], held: records);
      await openBulk(tester, [for (final r in records) r.id]);
      await tester.longPress(find.text('長押しで共有'));
      await settleUntil(tester, () => find.text('残りを再試行').evaluate().isNotEmpty, describe: 'the partial result');
      await tester.tap(find.text('残りを再試行'));
      await settleUntilElapsing(tester, () => server.sent.length == 2, describe: "the retry's first chunk");
      // The dialog closes while the retry is still waiting for its answer.
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DialogLayer(child: AccountPage())),
        ),
      );
      await tester.tap(find.text('ログアウト'));
      await settleUntilElapsing(tester, () => find.text('Google でログイン').evaluate().isNotEmpty, describe: 'logout');
      await tester.tap(find.text('Google でログイン'));
      await settleUntil(tester, () => opened.isNotEmpty, describe: "the second account's login page");
      await tester.tap(find.text('Google でログイン'));
      await settleUntilElapsing(tester, () => server.sent.length == 5, describe: "the second account's login");
      expect(container.read(recordShareSessionProvider)?.accountId, 'acct-0002');

      heldAnswer.complete(_results([for (var i = 0; i < 8; i++) _created('id-$i')]));
      await settleUntilElapsing(
        tester,
        () => notes().entryOf(records[7].id)?.state == RecordShareState.shared,
        describe: "the first account's answer",
      );
      // Nothing signals that the share has given up on the last record, so it gets a window.
      await pumpRealTimeWindow(tester, rounds: 20);

      expect(server.sent[1].headers['Authorization'], 'Bearer $_token');
      expect(server.sent, hasLength(5), reason: 'the last record is not sent under the second account');
      expect(notes().entryOf(records.last.id), isNull, reason: 'no note names the first account for it');
    });

    testWidgets('S4c (C1 ii): before the press the confirmation counts a shared record and a friend\'s one; neither '
        'is sent, and each is counted', (tester) async {
      await storeSession();
      final [own, shared] = ownRecords(2);
      final friend = CharaDetailRecord.fromRecordJson(_recordBytes(recordType: "FriendStandard", recordId: _uuid(7)));
      await storeNote(recordId: shared.id, state: RecordShareState.shared);
      container = containerFor(
        [
          _results([_created("id-own")]),
        ],
        held: [own, shared, friend],
      );

      await openBulk(tester, [own.id, shared.id, friend.id]);
      expect(
        find.text('1 件はすでに共有しているため、送りません。\n1 件は自分で育成したレコードではないため、除外します。'),
        findsOneWidget,
        reason: 'what the share leaves out is told before the press',
      );
      expect(server.sent, isEmpty);
      await tester.longPress(find.text('長押しで共有'));
      await settleUntil(tester, () => find.textContaining('1 件を共有しました。').evaluate().isNotEmpty, describe: 'the result');

      expect(server.sent, hasLength(1));
      expect(sharesSent(0), hasLength(1));
      expect(find.text('1 件を共有しました。\n1 件はすでに共有しています。\n1 件は自分で育成したレコードではないため、除外しました。'), findsOneWidget);
      expect(find.text("${Const.sharingOrigin}/u/$_accountId"), findsNothing, reason: 'not every record is listed');
    });

    testWidgets('S4c (C1 iii): a plain tap on the confirm sends nothing; only the long press shares', (tester) async {
      await storeSession();
      final records = ownRecords(2);
      container = containerFor([
        _results([_created("id-0"), _created("id-1")]),
      ], held: records);

      await openBulk(tester, [for (final r in records) r.id]);
      await tester.tap(find.text('長押しで共有'));
      // As in P1's case: the window covers the fake time a hold needs and the real time of the write before a send.
      await tester.pump(const Duration(seconds: 1));
      await pumpRealTimeWindow(tester, rounds: 20);
      expect(server.sent, isEmpty);

      await tester.longPress(find.text('長押しで共有'));
      await settleUntil(tester, () => find.text('2 件を共有しました。').evaluate().isNotEmpty, describe: 'the share');
      expect(server.sent, hasLength(1));
    });

    testWidgets('S4c (C1 iv): with no session, the result asks for a login and nothing is sent', (tester) async {
      final records = ownRecords(2);
      container = containerFor([], held: records);

      await openBulk(tester, [for (final r in records) r.id]);
      await tester.longPress(find.text('長押しで共有'));
      await settleUntil(tester, () => find.text('Google でログイン').evaluate().isNotEmpty, describe: 'the login');

      expect(find.text('共有にはログインが必要です。'), findsOneWidget);
      expect(find.text('0 件を共有しました。\n2 件は共有できませんでした。'), findsOneWidget);
      expect(find.text('残りを再試行'), findsNothing, reason: 'logging in comes first');
      expect(server.sent, isEmpty);
    });
  });

  group('from the account tab', () {
    setUpAll(loadAppTranslations);

    // S4b: the account tab (N3), mounted as the app routes to it. The view is tall enough for every card at once,
    // because the tab lists its cards lazily and one below the fold would not be found.
    Future<void> mountAccount(WidgetTester tester) {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DialogLayer(child: AccountPage())),
        ),
      );
    }

    const loggedInActions = ['共有の一覧ページを開く', 'ログアウト', 'アカウントを削除…', '共有したレコード'];

    testWidgets(
      'S4b (C1 i): logged out, the account offers a login; logged in, its list, logout, deletion and shares',
      (tester) async {
        final listener = _FakeListener();
        container = containerFor([
          _json(200, _claimed()),
          _json(200, {"trainer_id": record.metadata.trainerId}),
        ], listener: listener);
        await mountAccount(tester);
        await tester.pumpAndSettle();

        expect(find.text('ログインしていません。ログインすると、レコードを共有できます。'), findsOneWidget);
        for (final action in loggedInActions) {
          expect(find.text(action), findsNothing, reason: action);
        }
        expect(server.sent, isEmpty, reason: 'showing the account asks no server');

        await tester.tap(find.text('Google でログイン'));
        await settleUntil(tester, () => opened.isNotEmpty, describe: 'the login page to open');
        listener.callback("proof-from-the-callback");
        await tester.pump(const Duration(seconds: 1));
        await settleUntil(tester, () => server.sent.length == 2, describe: 'the trainer registration');
        await tester.pump(const Duration(seconds: 1));
        await settleUntil(tester, () => find.text('ログアウト').evaluate().isNotEmpty, describe: 'the logged-in account');

        for (final action in loggedInActions) {
          expect(find.text(action), findsOneWidget, reason: action);
        }
        expect(find.text('Google でログイン'), findsNothing);
        expect(accountListUrl(_accountId), "${Const.sharingOrigin}/u/$_accountId");
      },
    );

    testWidgets('S4b (C1 ii): logging out from the account drops the session and the share notes', (tester) async {
      await storeSession();
      await storeNote(state: RecordShareState.shared);
      container = containerFor([_empty(204)]);
      await mountAccount(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('ログアウト'));
      await settleUntilElapsing(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the account to show logged out',
      );
      expect(server.sent.single.uri.path, "/api/auth/logout");
      expect(container.read(recordShareSessionProvider), isNull);
      expect(container.read(recordSharesProvider), isEmpty);
      expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
    });

    testWidgets('S4b (C1 iii, iv): only the long press deletes the account, and a deletion cut short is '
        'continued, with nothing else offered meanwhile', (tester) async {
      await storeSession();
      container = containerFor([
        _json(200, {
          "remaining": {"shares": 3, "sync": 2},
        }),
        _lostConnection,
        _json(200, {
          "remaining": {"shares": 1},
        }),
        _empty(204),
      ]);
      await mountAccount(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('アカウントを削除…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('長押しで削除'));
      await tester.pump(const Duration(seconds: 1));
      await pumpRealTimeWindow(tester, rounds: 20);
      expect(server.sent, isEmpty, reason: 'a plain tap deletes nothing');

      await tester.longPress(find.text('長押しで削除'));
      await settleUntil(
        tester,
        () => find.text('サーバーに接続できませんでした。もう一度お試しください。').evaluate().isNotEmpty,
        describe: 'the deletion to stop at the lost connection',
      );
      expect(find.textContaining('残り'), findsNothing, reason: 'the server counts no unit the user knows');
      expect(container.read(recordShareSessionProvider)?.deleting, isTrue);

      await tester.tap(find.byTooltip('削除せずに閉じる'));
      await tester.pumpAndSettle();
      expect(find.text('アカウントを削除しています。'), findsOneWidget);
      expect(find.text('削除を再開'), findsOneWidget);
      for (final action in [...loggedInActions, 'Google でログイン']) {
        expect(find.text(action), findsNothing, reason: action);
      }

      await tester.tap(find.text('削除を再開'));
      await settleUntilElapsing(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the account to be deleted',
      );
      expect(server.sent.map((s) => "${s.method} ${s.uri.path}"), List.filled(4, "DELETE /api/me"));
      expect(container.read(recordShareSessionProvider), isNull);
      expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
    });

    testWidgets("stopped by the server's day, the deletion is left to the server and the device logs out", (
      tester,
    ) async {
      await storeSession();
      await storeNote();
      container = containerFor([
        _json(200, {
          "remaining": {"shares": 0, "sync": 1},
        }),
        _json(429, {
          "error": "sync_paused_today",
          "remaining": {"shares": 0, "sync": 1},
        }),
      ]);
      final toasts = <String?>[];
      container.listen(plainToastEventProvider, (_, next) => next.whenData((toast) => toasts.add(toast.description)));
      await mountAccount(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('アカウントを削除…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで削除'));
      await settleUntilElapsing(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the device to let go of the account',
      );

      expect(toasts, ['残りは、サーバーが自動で削除します。']);
      expect(container.read(recordShareSessionProvider), isNull);
      expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
    });

    testWidgets('a deleting session lost on the way leaves the deletion to the server and the device logs out', (
      tester,
    ) async {
      await storeSession();
      await storeNote();
      container = containerFor([
        _json(200, {
          "remaining": {"shares": 0, "sync": 1},
        }),
        _json(401, {"error": "session_required"}),
      ]);
      final toasts = <String?>[];
      container.listen(plainToastEventProvider, (_, next) => next.whenData((toast) => toasts.add(toast.description)));
      await mountAccount(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('アカウントを削除…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで削除'));
      await settleUntilElapsing(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the device to let go of the account',
      );

      expect(toasts, ['残りは、サーバーが自動で削除します。']);
      expect(find.text('ログインが切れています。もう一度ログインしてください。'), findsNothing);
      expect(container.read(recordShareSessionProvider), isNull);
      expect(container.read(recordShareSessionDroppedProvider), isFalse);
      expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
    });

    testWidgets('a session lost before the deletion started asks for a login and does not leave it to the server', (
      tester,
    ) async {
      await storeSession();
      await storeNote();
      container = containerFor([
        _json(401, {"error": "session_required"}),
      ]);
      final toasts = <String?>[];
      container.listen(plainToastEventProvider, (_, next) => next.whenData((toast) => toasts.add(toast.description)));
      await mountAccount(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('アカウントを削除…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで削除'));
      await settleUntilElapsing(
        tester,
        () => find.text('ログインが切れています。もう一度ログインしてください。').evaluate().isNotEmpty,
        describe: 'the deletion to ask for a login',
      );

      expect(toasts, isEmpty);
    });

    testWidgets("a share whose record was deleted is listed from the account's list and can be unshared; one with no "
        'note is not called deleted', (tester) async {
      await storeSession();
      final note = await storeNote(state: RecordShareState.shared);
      container = containerFor([
        // The second share was made on another device: this one holds no note of it.
        _sharesList([
          _listed("0123456789", note.keyHash),
          _listed("9876543210", secretHash(newClientKey()), cardName: _serverCardName),
        ]),
        _empty(204),
      ], emptied: true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DialogLayer(child: Scaffold(body: RecordShareListCard())),
          ),
        ),
      );

      await tester.tap(find.text('ログインしたアカウントで共有したレコードの確認と、共有を取り消すことができます。'));
      // The dialog asks as it opens; one more fake step reads the answer.
      await settleUntilElapsing(tester, () => server.sent.isNotEmpty, describe: "the account's list to be asked for");
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.text('端末から削除したレコード').evaluate().isNotEmpty,
        describe: 'the row of the deleted record',
      );
      expect(server.sent.single.uri.path, "/api/me/shares");
      expect(find.text('共有日 2026-10-20'), findsNWidgets(2));
      expect(find.text('端末から削除したレコード'), findsOneWidget, reason: 'only the noted share was made here');
      expect(find.text(_serverCardName), findsOneWidget, reason: 'the share with no note takes the listed name');
      await tester.tap(find.text('共有を取り消す…').first);
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(
        tester,
        () => find.text('共有日 2026-10-20').evaluate().length == 1,
        describe: 'the unshared row to leave the list',
      );

      expect(find.text('端末から削除したレコード'), findsNothing);
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

  test('a request the server never answers fails at its deadline and keeps the note to resend', () async {
    await storeSession();
    container = containerFor([Completer<Object>().future], requestTimeout: const Duration(milliseconds: 10));

    expect((await notes().shareAll([record]))[record.id], isA<ShareUnreachable>());
    expect(container.read(recordSharesProvider).values.single.state, RecordShareState.pending);
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

    // T3a2 (L-5): the screen tells a session the server dropped apart from the user's logout.
    test("T3a2 (C1 ii): a 401 tells the device the server dropped the session, a logout does not — not even one the "
        'server answers 401 —, and the next login lowers it', () async {
      await storeSession();
      container = containerFor([
        _json(401, {"error": "session_required"}),
        _json(200, _claimed()),
        _json(200, {"trainer_id": record.metadata.trainerId}),
        _json(401, {"error": "session_required"}),
      ]);
      bool dropped() => container.read(recordShareSessionDroppedProvider);
      expect(dropped(), isFalse);

      await session().send("GET", "/api/me");
      expect((container.read(recordShareSessionProvider), dropped()), (null, true));

      final attempt = await session().beginLogin();
      expect(await attempt.claim(), LoginOutcome.signedIn);
      expect(dropped(), isFalse, reason: 'logged in again');

      expect(await session().logout(), isTrue);
      expect((container.read(recordShareSessionProvider), dropped()), (null, false), reason: 'the user logged out');
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

        expect(await session().deleteAccount(), AccountDeletionOutcome.deleted);

        expect(server.sent.map((r) => "${r.method} ${r.uri.path}"), List.filled(3, "DELETE /api/me"));
        for (final request in server.sent) {
          expect(request.headers["Authorization"], "Bearer $_token");
        }
        expect(container.read(recordShareSessionProvider), isNull);
        expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
        expect(container.read(recordSharesProvider), isEmpty);
      });

      test("a 429 that is not the server's day, as a firewall's, keeps the session", () async {
        await storeSession();
        container = containerFor([
          remaining({"shares": 0, "sync": 1}),
          _json(429, {"error": "rate_limited"}),
        ]);

        expect(await session().deleteAccount(), AccountDeletionOutcome.failed);

        expect(stored()?.deleting, isTrue);
        expect(stored()?.token, _token);
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
        'a login onto an account the server marks deleting continues its deletion, and the deletion finishes',
        () async {
          await storeNote();
          container = containerFor([
            _json(200, {..._claimed(), "deleting": true}),
            remaining({"shares": 1, "sync": 0}),
            _empty(204),
          ]);

          final attempt = await session().beginLogin();
          expect(await attempt.claim(), LoginOutcome.signedIn);
          expect(stored()?.deleting, isTrue);
          expect(await session().deleteAccount(), AccountDeletionOutcome.deleted);

          // A deletion-only session registers no trainer id: every later request is the deletion's.
          expect(server.sent.map((r) => "${r.method} ${r.uri.path}"), [
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
