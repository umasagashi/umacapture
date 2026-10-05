// Publishing a record to the sharing server: what leaves the device, and that the delete key is never
// lost or leaked on the way.
//
// Entry: a real `record.json`'s bytes decoded the way the app decodes them, the real
// `publishedRecords` store, and the real diagnostic Dio with only its transport replaced. Nothing
// reaches a network. The dialog cases enter through the row menu's real publish submenu and the
// long-press confirms of the publish and withdraw dialogs; the list of publications enters through its
// real privacy-settings row.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/publication_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:logger/logger.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/const.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/publication.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/publish_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/published_records_dialog.dart';
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

/// The fixture's bytes with both parent ids filled in, so every id a record carries is present.
String _recordBytes({String? recordType}) {
  final map = jsonDecode(File('test/fixtures/chara_detail_record.json').readAsStringSync()) as Map<String, dynamic>;
  final metadata = map["metadata"] as Map<String, dynamic>;
  (metadata["record_id"] as Map<String, dynamic>).addAll({"parent1": _parent1Id, "parent2": _parent2Id});
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

  ProviderContainer containerFor(
    List<Object> answers, {
    String? trainerId,
    CharaDetailRecord? shown,
    bool emptied = false,
  }) {
    server = _FakeServer(answers);
    final c = ProviderContainer(
      overrides: [
        trainerIdProvider.overrideWithValue(trainerId ?? record.metadata.trainerId),
        moduleVersionLoader.overrideWith(
          (ref) async => ModuleVersion(
            recognizerVersion: DateTime.utc(2026, 9, 30, 2),
            minimumVersion: DateTime.utc(2021),
            recognizerVersionText: _moduleVersion,
          ),
        ),
        publicationDioProvider.overrideWith(
          (ref) => createDiagnosticDio(operation: "publish_record")..httpClientAdapter = server,
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

  PublishedRecords notes() => container.read(publishedRecordsProvider.notifier);

  /// Holds a ticket as if the confirmation page had been passed, and returns it.
  String confirmed() {
    container.read(publicationTicketProvider.notifier).verificationUrl();
    return container.read(publicationTicketProvider)!;
  }

  setUp(() async {
    await Hive.box(storageBoxNameOf(StorageBoxKey.publishedRecords)).clear();
    record = CharaDetailRecord.fromRecordJson(_recordBytes());
  });

  test('the body that leaves the device carries no trainer id, capture time or record id', () async {
    container = containerFor([_json(201, _located("0123456789"))]);
    confirmed();

    final outcome = await notes().publish(record);

    expect(outcome, isA<Published>());
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
    final sentRecord = (jsonDecode(body) as Map<String, dynamic>)["record"] as Map<String, dynamic>;
    expect(sentRecord["module_version"], _moduleVersion);
    expect(sentRecord["trainee"], {
      "character": record.trainee.character,
      "card": record.trainee.card,
      "rank": record.trainee.rank,
    });
  });

  group('from the row menu', () {
    setUpAll(loadAppTranslations);

    /// Mounts a row whose context menu holds the real publish submenu for [shown], over [container].
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
                          publicationMenu(
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

    Future<void> publishFromMenu(WidgetTester tester, CharaDetailRecord shown) async {
      await openMenu(tester, shown);
      await tester.tap(find.text('公開する…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで公開'));
    }

    testWidgets('publishing shows the URL in the dialog', (tester) async {
      container = containerShowing(record, [_json(201, _located("0123456789"))]);
      confirmed();

      await publishFromMenu(tester, record);
      final url = "${Const.sharingOrigin}/r/0123456789";
      await settleUntil(tester, () => find.text(url).evaluate().isNotEmpty, describe: 'the published URL');

      expect(find.text('公開しました。'), findsOneWidget);
      expect(find.text('URL をコピー'), findsOneWidget);
      expect(server.sent.single.uri.path, "/api/records");
      expect(container.read(publishedRecordsProvider).values.single.url, url);
    });

    testWidgets('a plain tap on the publish button sends nothing; only the long press publishes', (tester) async {
      container = containerShowing(record, [_json(201, _located("0123456789"))]);
      confirmed();
      await openMenu(tester, record);
      await tester.tap(find.text('公開する…'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('長押しで公開'));
      // A press that did publish needs fake time to elapse (as the hold does) and real time for the write
      // before the request, so the window covers both; it cannot be an arrival, there is none to wait for.
      await tester.pump(const Duration(seconds: 1));
      await pumpRealTimeWindow(tester, rounds: 20);
      expect(server.sent, isEmpty);
      expect(find.text('長押しで公開'), findsOneWidget, reason: 'the dialog is still waiting for the hold');

      await tester.longPress(find.text('長押しで公開'));
      await settleUntil(
        tester,
        () => find.text('公開しました。').evaluate().isNotEmpty,
        describe: 'the publication to be confirmed',
      );
      expect(server.sent, hasLength(1));
    });

    testWidgets('while the request is out, neither Cancel, the close button nor the scrim closes the dialog', (
      tester,
    ) async {
      final answer = Completer<Object>();
      container = containerShowing(record, [answer.future]);
      confirmed();

      await publishFromMenu(tester, record);
      await settleUntil(tester, () => server.sent.isNotEmpty, describe: 'the request to reach the server');
      await tester.tap(find.text('キャンセル'), warnIfMissed: false);
      await tester.tap(find.byIcon(Symbols.close_rounded), warnIfMissed: false);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.byType(PublishRecordDialog), findsOneWidget, reason: 'the answer decides whether the key is kept');

      answer.complete(_json(201, _located("0123456789")));
      // Dio reads the late answer on the fake clock, which nothing else here moves.
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.text('公開しました。').evaluate().isNotEmpty,
        describe: 'the publication to be confirmed',
      );
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.byType(PublishRecordDialog), findsNothing);
    });

    testWidgets('without a ticket, the dialog leads to the confirmation page and sends nothing', (tester) async {
      container = containerShowing(record, []);

      await publishFromMenu(tester, record);
      await settleUntil(
        tester,
        () => find.text('確認ページを開く').evaluate().isNotEmpty,
        describe: 'the way to the confirmation page',
      );

      expect(find.textContaining('bot でないことの確認'), findsOneWidget);
      expect(find.text('長押しで公開'), findsOneWidget, reason: 'publishing is pressed again after confirming');
      expect(server.sent, isEmpty);
    });

    testWidgets("a record that is not this trainer's own training sends nothing", (tester) async {
      final friend = CharaDetailRecord.fromRecordJson(_recordBytes(recordType: "FriendStandard"));
      for (final (shown, trainerId) in [(record, "11111111-2222-4333-8444-555555555555"), (friend, null)]) {
        container = containerShowing(shown, [], trainerId: trainerId);
        confirmed();

        await publishFromMenu(tester, shown);
        await settleUntil(
          tester,
          () => find.text('自分で育成したレコードだけ公開できます。').evaluate().isNotEmpty,
          describe: 'the refusal',
        );

        expect(server.sent, isEmpty);
        expect(container.read(publishedRecordsProvider), isEmpty);
        await tester.tap(find.text('閉じる'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('withdrawing from the menu sends the delete and drops the note', (tester) async {
      container = containerShowing(record, [_json(201, _located("0123456789")), _empty(204)]);
      confirmed();
      await tester.runAsync(() => notes().publish(record));

      await openMenu(tester, record);
      await tester.tap(find.text('公開を取り消す…'));
      await tester.pumpAndSettle();
      expect(find.text('公開の取り消し'), findsOneWidget);
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(
        tester,
        () => find.text('公開の取り消し').evaluate().isEmpty,
        describe: 'the withdrawal dialog to close',
      );

      expect(server.sent.last.method, "DELETE");
      expect(server.sent.last.uri.path, "/api/records/0123456789");
      expect(container.read(publishedRecordsProvider), isEmpty);
      expect(StorageBox(StorageBoxKey.publishedRecords).entries(), isEmpty);
    });
  });

  group('from the privacy settings', () {
    setUpAll(loadAppTranslations);

    testWidgets('a publication whose record was deleted is still listed and can be withdrawn', (tester) async {
      container = containerFor([_json(201, _located("0123456789")), _empty(204)], emptied: true);
      confirmed();
      await tester.runAsync(() => notes().publish(record));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DialogLayer(child: Scaffold(body: PublishedRecordsTile())),
          ),
        ),
      );

      await tester.tap(find.text('公開したレコード'));
      await settleUntil(
        tester,
        () => find.text('端末から削除したレコード').evaluate().isNotEmpty,
        describe: 'the row of the deleted record',
      );
      await tester.tap(find.text('取り消す…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(
        tester,
        () => find.text('公開したレコードはありません。').evaluate().isNotEmpty,
        describe: 'the list to empty',
      );

      expect(server.sent.last.method, "DELETE");
      expect(server.sent.last.uri.path, "/api/records/0123456789");
      expect(StorageBox(StorageBoxKey.publishedRecords).entries(), isEmpty);
    });
  });

  group('the delete key and the ticket never reach a log line', () {
    late List<String> sent;
    late BreadcrumbSink realSink;

    setUp(() {
      sent = [];
      realSink = debugBreadcrumbSink;
      debugBreadcrumbSink = (Level level, String message, dynamic error) => sent.add('$message $error');
    });
    tearDown(() => debugBreadcrumbSink = realSink);

    test('through a publication, a refusal, a lost connection and a withdrawal', () async {
      container = containerFor([
        _lostConnection,
        _json(401, {"error": "ticket_required"}),
        _json(201, _located("0123456789")),
        _empty(204),
      ]);
      final firstTicket = confirmed();

      expect(await notes().publish(record), isA<PublishUnreachable>());
      expect(await notes().publish(record), isA<TicketRequired>());
      final secondTicket = confirmed();
      final published = await notes().publish(record) as Published;
      expect(await notes().withdraw(published.entry.keyHash), WithdrawOutcome.withdrawn);

      expect(server.sent, hasLength(4));
      expect(sent, isNotEmpty, reason: 'no line was logged, so the assertions below are vacuous');
      expect(sent.where((line) => line.contains('Network request error')), isNotEmpty);
      for (final secret in [published.entry.deleteKey, firstTicket, secondTicket]) {
        for (final line in sent) {
          expect(line, isNot(contains(secret)));
        }
      }
    });
  });

  test('a reply that never arrived is resent with the same key and then confirmed', () async {
    container = containerFor([_lostConnection, _json(200, _located("0123456789"))]);
    confirmed();

    expect(await notes().publish(record), isA<PublishUnreachable>());
    final pending = container.read(publishedRecordsProvider).values.single;
    expect(pending.state, PublicationState.pending);

    final outcome = await notes().publish(record) as Published;

    final keys = [for (final s in server.sent) (jsonDecode(s.body) as Map<String, dynamic>)["delete_key"]];
    expect(keys, [pending.deleteKey, pending.deleteKey]);
    expect(outcome.entry.keyHash, pending.keyHash);
    expect(container.read(publishedRecordsProvider), {pending.keyHash: outcome.entry});
    final stored = StorageBox(StorageBoxKey.publishedRecords).pull<String>(pending.keyHash);
    expect(PublicationEntryMapper.fromJson(stored!).state, PublicationState.published);
  });

  test('without the record, a publication whose reply was lost is found by its key and withdrawn', () async {
    container = containerFor([_lostConnection, _json(200, _located("0123456789")), _empty(204)]);
    confirmed();
    expect(await notes().publish(record), isA<PublishUnreachable>());
    final keyHash = container.read(publishedRecordsProvider).keys.single;

    // A fresh session: only the store is left, and nothing below is given the record.
    final key = container.read(publishedRecordsProvider)[keyHash]!.deleteKey;
    container = containerFor(server.answers);
    expect(container.read(publishedRecordsProvider)[keyHash]?.state, PublicationState.pending);

    expect(await notes().recover(keyHash), RecoveryOutcome.published);
    expect(await notes().withdraw(keyHash), WithdrawOutcome.withdrawn);

    expect(server.sent.map((s) => "${s.method} ${s.uri.path}"), [
      "POST /api/records/lookup",
      "DELETE /api/records/0123456789",
    ]);
    expect(jsonDecode(server.sent.first.body), {"delete_key": key});
    expect(server.sent.last.headers["Authorization"], "Bearer $key");
    expect(container.read(publishedRecordsProvider), isEmpty);
    expect(StorageBox(StorageBoxKey.publishedRecords).entries(), isEmpty);
  });

  test('a 404 that is not the API saying the row is gone keeps the key; the API\'s 404 drops it', () async {
    container = containerFor([
      _json(201, _located("0123456789")),
      // What the assets-only deployment answers while sharing is switched off.
      ResponseBody.fromString("<!doctype html><title>Not Found</title>", 404),
      _json(404, {"error": "not_found"}),
    ]);
    confirmed();
    final keyHash = (await notes().publish(record) as Published).entry.keyHash;

    expect(await notes().withdraw(keyHash), WithdrawOutcome.failed);
    expect(StorageBox(StorageBoxKey.publishedRecords).pull<String>(keyHash), isNotNull);

    expect(await notes().withdraw(keyHash), WithdrawOutcome.withdrawn);
    expect(StorageBox(StorageBoxKey.publishedRecords).entries(), isEmpty);
  });
}
