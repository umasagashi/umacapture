// Sharing a record under the logged-in account: what leaves the device, that each share's note follows its
// own result and its account, and that the client keys and the login secrets never reach a log line.
//
// Entry: a real `record.json`'s bytes decoded the way the app decodes them, the real
// `recordShares` store, and the real diagnostic Dio with only its transport replaced. Nothing
// reaches a network. The dialog cases enter through the row menu's real share submenu and the
// long-press confirms of the share and unshare dialogs; sharing the checked records enters through the
// table toolbar's real share button and the selection scrim; the list of shares enters through its
// real row on the account tab. The table's share column is read off the real grid build, over the notes a real
// share and a real logout leave.
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
import 'package:image/image.dart' as img;
import 'package:logger/logger.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/const.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/image_converter.dart';
import 'package:umacapture/src/chara_detail/record_share.dart';
import 'package:umacapture/src/chara_detail/record_share_session.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/share_state.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/login_receiver.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/storage/record_write_effects.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/gui/account.dart';
import 'package:umacapture/src/gui/chara_detail/column_preset_bar_widget.dart';
import 'package:umacapture/src/gui/chara_detail/data_table_widget.dart';
import 'package:umacapture/src/gui/chara_detail/record_share_list_card.dart';
import 'package:umacapture/src/gui/chara_detail/share_account_section.dart';
import 'package:umacapture/src/gui/chara_detail/share_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/preference/settings_state.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/settling.dart';

const _parent1Id = "3f0c6b2e-1d4a-4c55-9e0f-6a7b8c9d0e1f";
const _parent2Id = "7e1d2c3b-4a59-4687-b7c8-d9e0f1a2b3c4";
const _moduleVersion = "2026-09-30T11:00:00+0900";

/// One request the app made, as it reached the transport.
typedef _Sent = ({String method, Uri uri, Map<String, dynamic> headers, String body, List<int> bytes});

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
    sent.add((
      method: options.method,
      uri: options.uri,
      headers: options.headers,
      body: utf8.decode(bytes, allowMalformed: true),
      bytes: bytes,
    ));
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

Map<String, Object?> _listed(String id, String clientKeyHash, {String? cardName, int? evaluation}) => {
  "id": id,
  "url": "${Const.sharingOrigin}/r/$id",
  "shared_on": "2026-10-20",
  "client_key_hash": clientKeyHash,
  "summary": <String, Object?>{
    "evaluation": ?evaluation,
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

  /// The ids each delete was asked for. Nothing is erased: no test here has a data directory under it.
  final deleteAsked = <Set<String>>[];

  @override
  Future<RecordDeleteResult> deleteAllAsync(
    Iterable<String> ids, {
    required RecordWriteEffects effects,
    Future<bool> Function(String id)? onlyIf,
  }) async {
    deleteAsked.add(ids.toSet());
    return RecordDeleteResult(succeeded: const {}, failed: ids.toSet());
  }
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
    ({List<CharaDetailRecord> records, List<ColumnSpec>? columns})? table,
    PathInfo? pathInfo,
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
        // The wait after a 429 is the site's rate-limit window; a test does not wait it out in real time.
        shareImagesRetryDelayProvider.overrideWithValue(Duration.zero),
        if (pathInfo != null) pathInfoProvider.overrideWithValue(pathInfo),
        if (table != null) ...[
          displayedRecordsProvider.overrideWithValue(table.records),
          if (table.columns case final columns?) currentColumnSpecsProvider.overrideWithValue(columns),
        ],
        if (held ?? [?shown] case final records when records.isNotEmpty) ...[
          charaDetailRecordStorageLoaderProvider.overrideWith(() => _Shown(records)),
          // The shares' card looks the noted records up in both stores; these records are all in the active one.
          if (!emptied) charaDetailArchiveStorageLoaderProvider.overrideWith(_EmptyArchive.new),
        ],
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
    // A share that ticked "share the images too" keeps that choice; every case starts from none made.
    await StorageBox(StorageBoxKey.settings).delete(SettingsEntryKey.shareImages.name);
    record = CharaDetailRecord.fromRecordJson(_recordBytes());
  });

  test('the body that leaves the device carries no trainer id, capture time or record id, and carries the icons and '
      "the family's ranks and record types", () async {
    await storeSession();
    container = containerFor([
      _results([_created("0123456789")]),
    ]);

    final outcome = (await notes().shareAll([record], source: RecordSource.active))[record.id];

    expect(outcome, isA<Shared>());
    expect(server.sent, hasLength(1));
    final body = server.sent.single.body;
    final bytes = _recordBytes();
    for (final value in [record.metadata.trainerId, record.metadata.capturedDate, record.id, _parent1Id, _parent2Id]) {
      expect(bytes, contains(value), reason: 'the input does not hold $value, so its absence proves nothing');
      expect(body, isNot(contains(value)));
    }
    for (final key in ["trainer_id", "captured_date", "record_id", "format_version", "stage"]) {
      expect(body, isNot(contains('"$key"')));
    }
    final sentRecord = sharesSent(0).single["record"] as Map<String, dynamic>;
    expect(sentRecord["module_version"], _moduleVersion);
    expect(sentRecord["trainee"], {
      "character": record.trainee.character,
      "card": record.trainee.card,
      "rank": record.trainee.rank,
      "icon": record.trainee.icon,
    });
    final family = sentRecord["family"] as Map<String, dynamic>;
    for (final (key, parent) in [("parent1", record.family.parent1), ("parent2", record.family.parent2)]) {
      for (final (member, chara) in [("self", parent.self), ("parent1", parent.parent1), ("parent2", parent.parent2)]) {
        expect((family[key] as Map)[member], {
          "character": chara.character,
          "card": chara.card,
          "icon": chara.icon,
          "rank": chara.rank,
          "record_type": chara.recordType?.toValue(),
        }, reason: '$key.$member');
      }
    }
    expect(
      (family["parent2"] as Map)["self"]["record_type"],
      "InheritanceOnly",
      reason: 'a record type other than the default proves the value is read and not assumed',
    );
    expect(sharesSent(0).single.containsKey("images"), isFalse, reason: 'no images were asked for');
  });

  late Directory dataDir;
  late PathInfo dataInfo;

  /// A data directory of its own, under which [seedImages] writes record directories.
  void useDataDir() {
    dataDir = Directory.systemTemp.createTempSync('record_share_images_');
    addTearDown(() => dataDir.deleteSync(recursive: true));
    final dir = DirectoryPath(dataDir.path);
    dataInfo = PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
  }

  Uint8List solid(int width, int height, int shade, {required bool jpeg}) {
    final image = img.Image(width: width, height: height)..clear(img.ColorRgb8(shade, 255 - shade, shade ~/ 2));
    return jpeg ? img.encodeJpg(image) : img.encodePng(image);
  }

  const anchor = {"h": "ScreenStart", "v": "ScreenStart"};

  /// A geometry file as the native pipeline writes one, with a key beside the rect the declaration must not carry.
  Uint8List geometryFile(int width, int height) => utf8.encode(
    jsonEncode({
      "intersection": {
        "top_left": {"x": 0, "y": 0, "anchor": anchor},
        "bottom_right": {"x": width, "y": height, "anchor": anchor},
        "unrelated": true,
      },
    }),
  );

  /// Writes the active record [id]'s images, coloured by [shade] so no two records' images are alike, and answers its
  /// files by name: the skill image as a PNG wider than an archive keeps, the factor image as its reduced JPEG only,
  /// the campaign image as a PNG an archive keeps at its size, each with its geometry, and the icon.
  Map<String, Uint8List> seedImages(String id, int shade) {
    final files = {
      "skill.png": solid(1000, 400, shade, jpeg: false),
      "skill.json": geometryFile(1000, 400),
      "factor.jpg": solid(300, 200, shade + 1, jpeg: true),
      "factor.json": geometryFile(300, 200),
      "campaign.png": solid(500, 300, shade + 2, jpeg: false),
      "campaign.json": geometryFile(500, 300),
      "trainee.jpg": solid(40, 40, shade + 3, jpeg: true),
      "record.json": utf8.encode(_recordBytes(recordId: id)),
    };
    final dir = Directory(recordDirOfId(dataInfo, RecordSource.active, id).path)..createSync(recursive: true);
    for (final MapEntry(:key, :value) in files.entries) {
      File('${dir.path}/$key').writeAsBytesSync(value);
    }
    return files;
  }

  /// Every file of the active record [id]'s directory, by name.
  Map<String, String> filesOf(String id) => {
    for (final f in Directory(recordDirOfId(dataInfo, RecordSource.active, id).path).listSync().whereType<File>())
      f.uri.pathSegments.last: sha256.convert(f.readAsBytesSync()).toString(),
  };

  Map<String, Object?> pendingImages(String id, {String status = "created"}) => {
    "status": status,
    ..._located(id),
    "images": "pending",
  };

  /// The parts a share of the record holding [files] declares, worked out here by hand: what each part must be.
  List<({String kind, List<int> bytes, Map<String, Object?>? intersection})> expectedParts(
    Map<String, Uint8List> files,
  ) {
    Map<String, Object?> rect(int width, int height) => {
      "top_left": {"x": 0, "y": 0, "anchor": anchor},
      "bottom_right": {"x": width, "y": height, "anchor": anchor},
    };
    return [
      // 1000 px wide, reduced to the archive's 720: the pane's rect scales with it.
      (kind: "skill", bytes: archiveJpegOf(files["skill.png"] ?? Uint8List(0)) ?? [], intersection: rect(720, 288)),
      (kind: "factor", bytes: files["factor.jpg"] ?? [], intersection: rect(300, 200)),
      (
        kind: "campaign",
        bytes: archiveJpegOf(files["campaign.png"] ?? Uint8List(0)) ?? [],
        intersection: rect(500, 300),
      ),
      (kind: "trainee", bytes: files["trainee.jpg"] ?? [], intersection: null),
    ];
  }

  /// Checks the declaration of share [share] and the bundle request [put] against [expected].
  void expectBundle(
    Map<String, dynamic> share,
    _Sent put,
    List<({String kind, List<int> bytes, Map<String, Object?>? intersection})> expected,
  ) {
    final declared = share["images"] as Map<String, dynamic>;
    final parts = (declared["parts"] as List).cast<Map<String, dynamic>>();
    expect(parts.map((p) => p["kind"]), expected.map((e) => e.kind));
    for (final (i, e) in expected.indexed) {
      expect(e.bytes, isNotEmpty, reason: '${e.kind}: the expected bytes were made');
      expect(parts[i]["size"], e.bytes.length, reason: e.kind);
      expect(parts[i]["sha256"], sha256.convert(e.bytes).toString(), reason: e.kind);
      expect(parts[i]["intersection"], e.intersection, reason: e.kind);
    }
    final bundle = [for (final e in expected) ...e.bytes];
    expect(put.method, "PUT");
    expect(put.bytes, bundle, reason: 'the bundle is the parts, one after another, in the declared order');
    expect(declared["size"], bundle.length);
    expect(declared["name"], sha256.convert(bundle).toString());
    expect(put.headers[Headers.contentTypeHeader], "application/octet-stream");
    expect(put.headers[Headers.contentLengthHeader], bundle.length, reason: 'the server requires Content-Length');
  }

  group('images', () {
    setUp(useDataDir);

    test("asked for, each share declares and sends its own record's images, and no file of a record changes", () async {
      await storeSession();
      final ids = [_uuid(1), _uuid(2)];
      final seeded = [seedImages(ids[0], 10), seedImages(ids[1], 120)];
      final before = [for (final id in ids) filesOf(id)];
      final records = [for (final id in ids) CharaDetailRecord.fromRecordJson(_recordBytes(recordId: id))];
      container = containerFor(pathInfo: dataInfo, [
        _results([pendingImages("0000000010"), pendingImages("0000000020")]),
        _json(200, {"status": "stored"}),
        _json(200, {"status": "stored"}),
      ]);

      final outcomes = await notes().shareAll(records, source: RecordSource.active, withImages: true);

      expect(server.sent.map((s) => "${s.method} ${s.uri.path}"), [
        "POST /api/shares",
        "PUT /api/shares/0000000010/images",
        "PUT /api/shares/0000000020/images",
      ]);
      for (final (i, id) in ids.indexed) {
        expectBundle(sharesSent(0)[i], server.sent[i + 1], expectedParts(seeded[i]));
        expect(outcomes[id], isA<Shared>().having((o) => o.imagesLeftOut, 'imagesLeftOut', isFalse));
        expect(notes().entryOf(id)?.state, RecordShareState.shared);
        expect(filesOf(id), before[i], reason: 'sharing reads the images and writes none');
      }
    });

    test('not asked for, nothing is declared or sent; asked for, a record with no complete images is shared without '
        'them and says so', () async {
      await storeSession();
      seedImages(record.id, 10);
      final partial = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(3)));
      seedImages(partial.id, 50);
      File('${recordDirOfId(dataInfo, RecordSource.active, partial.id).path}/campaign.json').deleteSync();
      container = containerFor(pathInfo: dataInfo, [
        _results([_created("0123456789")]),
        _results([
          {..._created("0123456780"), "images": "none"},
        ]),
      ]);

      final plain = (await notes().shareAll([record], source: RecordSource.active))[record.id];
      final leftOut = (await notes().shareAll([partial], source: RecordSource.active, withImages: true))[partial.id];

      expect(server.sent.map((s) => s.method), ["POST", "POST"], reason: 'no bundle is sent for either');
      expect(sharesSent(0).single.containsKey("images"), isFalse);
      expect(plain, isA<Shared>().having((o) => o.imagesLeftOut, 'imagesLeftOut', isFalse));
      expect(sharesSent(1).single.containsKey("images"), isFalse, reason: 'the campaign image has no geometry');
      expect(leftOut, isA<Shared>().having((o) => o.imagesLeftOut, 'imagesLeftOut', isTrue));
    });

    test('a share whose images were not sent stays pending, also against the account list, and sharing it again '
        'sends the images only and confirms it', () async {
      await storeSession();
      final seeded = seedImages(record.id, 10);
      container = containerFor(pathInfo: dataInfo, [
        _results([pendingImages("0123456789")]),
        _lostConnection,
        _results([pendingImages("0123456789", status: "existing")]),
        _json(200, {"status": "stored"}),
      ]);

      final first = (await notes().shareAll([record], source: RecordSource.active, withImages: true))[record.id];

      expect(first, isA<ImagesUnsent>());
      final pending = notes().entryOf(record.id);
      expect(pending?.state, RecordShareState.pending);
      expect(pending?.id, "0123456789");

      server.answers.insert(
        0,
        _sharesList([
          {..._listed("0123456789", pending?.keyHash ?? ""), "images": "pending"},
        ]),
      );
      expect(await notes().refreshFromServer(), isA<SharesListed>());
      expect(notes().entryOf(record.id)?.state, RecordShareState.pending, reason: 'the server still waits for them');

      // The images were declared by the first attempt; the box is no longer ticked, and they are sent all the same.
      final again = (await notes().shareAll([record], source: RecordSource.active))[record.id];

      expect(server.sent.map((s) => "${s.method} ${s.uri.path}"), [
        "POST /api/shares",
        "PUT /api/shares/0123456789/images",
        "GET /api/me/shares",
        "POST /api/shares",
        "PUT /api/shares/0123456789/images",
      ]);
      expect(sharesSent(3).single["client_key"], pending?.clientKey);
      expectBundle(sharesSent(0).single, server.sent[4], expectedParts(seeded));
      expect(again, isA<Shared>());
      expect(notes().entryOf(record.id)?.state, RecordShareState.shared);
    });

    test(
      'after a 429 the bundle is sent once more; a second 429 stops, and the shares not yet sent stay pending',
      () async {
        await storeSession();
        final ids = [_uuid(1), _uuid(2), _uuid(3)];
        for (final (i, id) in ids.indexed) {
          seedImages(id, 10 + 40 * i);
        }
        final records = [for (final id in ids) CharaDetailRecord.fromRecordJson(_recordBytes(recordId: id))];
        container = containerFor(pathInfo: dataInfo, [
          _results([pendingImages("0000000010"), pendingImages("0000000020"), pendingImages("0000000030")]),
          _json(429, {}),
          _json(200, {"status": "stored"}),
          _json(429, {}),
          _json(429, {}),
        ]);

        final outcomes = await notes().shareAll(records, source: RecordSource.active, withImages: true);

        expect(server.sent.map((s) => s.uri.path), [
          "/api/shares",
          "/api/shares/0000000010/images",
          "/api/shares/0000000010/images",
          "/api/shares/0000000020/images",
          "/api/shares/0000000020/images",
        ]);
        expect(outcomes[ids[0]], isA<Shared>());
        expect(outcomes[ids[1]], isA<ImagesUnsent>());
        expect(outcomes[ids[2]], isA<ImagesUnsent>(), reason: 'not sent after the second 429');
        expect(
          [for (final id in ids) notes().entryOf(id)?.state],
          [RecordShareState.shared, RecordShareState.pending, RecordShareState.pending],
        );
      },
    );
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
                            selecting: false,
                            disabledStyle: null,
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

    testWidgets('a share left with "share the images too" untouched sends no images; ticked, it sends them, and the '
        'next confirmation starts ticked', (tester) async {
      await storeSession();
      useDataDir();
      final plain = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(1)));
      final ticked = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(2)));
      final next = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(3)));
      final seeded = await tester.runAsync(() async => [seedImages(plain.id, 10), seedImages(ticked.id, 90)]) ?? [];
      container = containerFor(
        pathInfo: dataInfo,
        held: [plain, ticked, next],
        [
          _results([_created("0000000010")]),
          _results([pendingImages("0000000020")]),
          _json(200, {"status": "stored"}),
        ],
      );

      Future<void> openShare(CharaDetailRecord shown) async {
        await openMenu(tester, shown);
        await tester.tap(find.text('共有する…'));
        await tester.pumpAndSettle();
      }

      bool checked() => tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value ?? false;

      // No choice made yet: the box starts unticked, and the share is left as it is.
      await openShare(plain);
      expect(checked(), isFalse);
      await tester.longPress(find.text('長押しで共有'));
      await settleUntilElapsing(tester, () => server.sent.isNotEmpty, describe: 'the first share');
      await tester.pumpAndSettle();
      expect(server.sent.map((s) => s.method), ["POST"], reason: 'no bundle is sent');
      expect(sharesSent(0).single.containsKey("images"), isFalse, reason: 'no images are declared');
      CardDialog.dismiss(container.read(containerRefProvider));
      await tester.pumpAndSettle();

      await openShare(ticked);
      await tester.tap(find.text('画像も共有する'));
      await tester.pump();
      await tester.longPress(find.text('長押しで共有'));
      await settleUntilElapsing(tester, () => server.sent.length == 3, describe: 'the ticked share and its bundle');
      await tester.pumpAndSettle();
      expectBundle(sharesSent(1).single, server.sent[2], expectedParts(seeded[1]));
      CardDialog.dismiss(container.read(containerRefProvider));
      await tester.pumpAndSettle();

      // The choice of the share just made is where the next confirmation starts.
      await openShare(next);
      expect(checked(), isTrue);
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
      await tester.runAsync(() => notes().shareAll([record], source: RecordSource.active));

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

    /// Mounts the real toolbar under the selection scrim over [container], enters share selection from its button
    /// (or the selection the button [select] names), checks [ids] as the grid's checkboxes would, and opens the
    /// confirmation from the scrim's [confirm].
    Future<void> openBulk(
      WidgetTester tester,
      List<String> ids, {
      String select = '共有するレコードの選択',
      String confirm = '選択を共有',
    }) async {
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
      await tester.tap(find.byTooltip(select));
      await tester.pump();
      container.read(selectedRecordIdsProvider.notifier).set(ids.toSet());
      await tester.pump();
      await tester.tap(find.text(confirm));
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
        // The shares' card asks for each account's list as the account tab shows it.
        _sharesList([]),
        _empty(204),
        _json(200, {..._claimed(), 'account_id': 'acct-0002', 'token': tokenB}),
        _json(200, {'trainer_id': record.metadata.trainerId}),
        _sharesList([]),
        // Answers the last record only if it is wrongly sent under the second account.
        _results([_created('id-8')]),
      ], held: records);
      List<String> sentBesidesListing() => [
        for (final s in server.sent)
          if (s.uri.path != "/api/me/shares") "${s.method} ${s.uri.path}",
      ];
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
      await settleUntilElapsing(tester, () => server.sent.length == 3, describe: "the first account's list");
      await tester.tap(find.text('ログアウト'));
      await settleUntilElapsing(tester, () => find.text('Google でログイン').evaluate().isNotEmpty, describe: 'logout');
      await tester.tap(find.text('Google でログイン'));
      await settleUntil(tester, () => opened.isNotEmpty, describe: "the second account's login page");
      await tester.tap(find.text('Google でログイン'));
      await settleUntilElapsing(tester, () => sentBesidesListing().length == 5, describe: "the second account's login");
      await settleUntilElapsing(
        tester,
        () => find.text('共有したレコードはありません。').evaluate().isNotEmpty,
        describe: "the second account's list",
      );
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
      expect(sentBesidesListing(), hasLength(5), reason: 'the last record is not sent under the second account');
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

    testWidgets('a delete confirmation left open cannot be confirmed once the share notes change under its selection', (
      tester,
    ) async {
      await storeSession();
      final shared = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(0)));
      await storeNote(recordId: shared.id, state: RecordShareState.shared);
      // The one answer is the reply to an unshare whose dialog the user closed before beginning this selection,
      // arriving while the confirmation is open.
      container = containerFor([_empty(204)], held: [shared]);
      const ended = '選択が解除されたため、実行できません。選び直してください。';
      const caution = '選択したレコードを完全に削除します。\n削除すると復元はできません。';

      await openBulk(tester, [shared.id], select: '削除するレコードの選択', confirm: '選択を削除');
      expect(find.text(caution), findsOneWidget, reason: 'opened from a live selection, the confirmation asks');
      expect(find.text(ended), findsNothing);

      await tester.runAsync(() => notes().unshare("0123456789"));
      await tester.pump();
      expect(container.read(recordSharesProvider), isEmpty, reason: 'the reply dropped the note');
      expect(find.text(ended), findsOneWidget);
      expect(find.text(caution), findsNothing);

      await tester.longPress(find.text('長押しで削除'));
      await tester.pump();
      final storage = container.read(charaDetailRecordStorageLoaderProvider.notifier) as _Shown;
      expect(storage.deleteAsked, isEmpty, reason: 'the rows were picked under a share state that no longer holds');
      // The press showed the confirm's tooltip, which says the same.
      expect(find.text(ended), findsNWidgets(2), reason: 'the confirmation stays up to say why');
    });

    testWidgets('a delete confirmed after its selection ended, before the confirm was rebuilt, deletes nothing', (
      tester,
    ) async {
      await storeSession();
      final shared = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(0)));
      await storeNote(recordId: shared.id, state: RecordShareState.shared);
      container = containerFor([_empty(204)], held: [shared]);
      const ended = '選択が解除されたため、実行できません。選び直してください。';

      await openBulk(tester, [shared.id], select: '削除するレコードの選択', confirm: '選択を削除');
      // No pump between the reply and the press: the confirm on screen is still the one built for the live selection.
      await tester.runAsync(() => notes().unshare("0123456789"));
      expect(find.text(ended), findsNothing, reason: 'the confirm has not been rebuilt yet');

      await tester.longPress(find.text('長押しで削除'));
      await tester.pump();
      final storage = container.read(charaDetailRecordStorageLoaderProvider.notifier) as _Shown;
      expect(storage.deleteAsked, isEmpty, reason: 'the press re-reads the selection it was opened under');
      expect(find.text(ended), findsWidgets, reason: 'the rebuild the ended selection scheduled says why');
    });
  });

  group('from the account tab', () {
    setUpAll(loadAppTranslations);

    // S4b: the account tab (N3), mounted as the app routes to it. The view is tall enough for every card at once,
    // because the tab lists its cards lazily and one below the fold would not be found.
    Future<void> mountAccount(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DialogLayer(child: AccountPage())),
        ),
      );
      if (container.read(recordShareSessionProvider) case ShareSession(deleting: false)) {
        await settleUntilElapsing(
          tester,
          () => find.text('共有したレコードを確かめています…').evaluate().isEmpty,
          describe: "the shares' card to list the account's shares",
        );
      }
    }

    /// The requests other than the shares' card asking for the account's list as it comes into view.
    Iterable<String> sentBesidesListing() => [
      for (final s in server.sent)
        if (s.uri.path != "/api/me/shares") "${s.method} ${s.uri.path}",
    ];

    const loggedInActions = ['共有の一覧ページを開く', 'ログアウト', 'アカウントを削除…', '共有したレコード'];

    testWidgets(
      'S4b (C1 i): logged out, the account offers a login; logged in, its list, logout, deletion and shares',
      (tester) async {
        final listener = _FakeListener();
        container = containerFor([
          _json(200, _claimed()),
          _json(200, {"trainer_id": record.metadata.trainerId}),
          // The shares' card asks for the account's list as it appears with the login.
          _sharesList([]),
        ], listener: listener);
        await mountAccount(tester);
        await tester.pumpAndSettle();

        expect(find.text('ログインしていません。'), findsOneWidget);
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
      final note = await storeNote(state: RecordShareState.shared);
      container = containerFor([
        _sharesList([_listed("0123456789", note.keyHash)]),
        _empty(204),
      ]);
      await mountAccount(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('ログアウト'));
      await settleUntilElapsing(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the account to show logged out',
      );
      expect(sentBesidesListing().single, endsWith(" /api/auth/logout"));
      expect(container.read(recordShareSessionProvider), isNull);
      expect(container.read(recordSharesProvider), isEmpty);
      expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
    });

    testWidgets('a logout from the account ends a selection the table began under the share column it filtered', (
      tester,
    ) async {
      await storeSession();
      final shared = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(0)));
      final note = await storeNote(recordId: shared.id, state: RecordShareState.shared);
      final onlyShared = ShareStateColumnSpec(
        id: "only_shared",
        title: "only_shared",
        predicate: ShareColumnPredicate(
          rejects: {ShareColumnState.pending, ShareColumnState.none, ShareColumnState.notShareable},
        ),
      );
      container = containerFor(
        [
          _sharesList([_listed("0123456789", note.keyHash)]),
          _empty(204),
        ],
        table: (records: [shared], columns: [onlyShared]),
      );
      List<String> listed() => [
        for (final row in container.read(currentGridProvider).rows) row.getUserData<CharaDetailRecord>()!.id,
      ];
      container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
      container.read(selectedRecordIdsProvider.notifier).set({shared.id});
      expect(listed(), [shared.id]);
      await mountAccount(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('ログアウト'));
      await settleUntilElapsing(
        tester,
        () => find.text('Google でログイン').evaluate().isNotEmpty,
        describe: 'the account to show logged out',
      );

      expect(container.read(selectionModeProvider), isNull, reason: 'nothing is left to confirm');
      expect(container.read(selectedRecordIdsProvider), isEmpty);
      expect(listed(), isEmpty, reason: 'with nothing known, the filtered column lists no row');
    });

    testWidgets("unsharing from the account's list ends a selection the table began under the share column", (
      tester,
    ) async {
      await storeSession();
      final shared = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(0)));
      final note = await storeNote(recordId: shared.id, state: RecordShareState.shared);
      final onlyShared = ShareStateColumnSpec(
        id: "only_shared",
        title: "only_shared",
        predicate: ShareColumnPredicate(
          rejects: {ShareColumnState.pending, ShareColumnState.none, ShareColumnState.notShareable},
        ),
      );
      // The list names the note as it is, so showing it changes nothing; the unshare is what changes the note.
      container = containerFor(
        [
          _sharesList([_listed("0123456789", note.keyHash)]),
          _empty(204),
          _sharesList([]),
        ],
        held: [shared],
        table: (records: [shared], columns: [onlyShared]),
      );
      List<String> listed() => [
        for (final row in container.read(currentGridProvider).rows) row.getUserData<CharaDetailRecord>()!.id,
      ];
      container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
      container.read(selectedRecordIdsProvider.notifier).set({shared.id});
      final selection = container.read(selectionModeProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DialogLayer(child: Scaffold(body: RecordShareListCard(inView: true))),
          ),
        ),
      );

      // The card asks as it is built; one more fake step reads the answer.
      await settleUntilElapsing(tester, () => server.sent.isNotEmpty, describe: "the account's list to be asked for");
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.byTooltip('共有を取り消す…').evaluate().isNotEmpty,
        describe: 'the row of the shared record',
      );
      expect(
        identical(container.read(selectionModeProvider), selection),
        isTrue,
        reason: 'a list that confirms the notes as they are leaves the selection alone',
      );

      await tester.tap(find.byTooltip('共有を取り消す…'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(
        tester,
        () => container.read(recordSharesProvider).isEmpty,
        describe: 'the unshare to drop the note',
      );
      await settleUntil(
        tester,
        () => find.text('共有したレコードはありません。').evaluate().isNotEmpty,
        describe: 'the list asked for again after the unshare',
      );

      expect(server.sent[1].method, "DELETE");
      expect(container.read(selectionModeProvider), isNull, reason: 'nothing is left to confirm');
      expect(container.read(selectedRecordIdsProvider), isEmpty);
      expect(listed(), isEmpty, reason: 'the share column follows the note again, and filters the row out');
    });

    testWidgets('S4b (C1 iii, iv): only the long press deletes the account, and a deletion cut short is '
        'continued, with nothing else offered meanwhile', (tester) async {
      await storeSession();
      container = containerFor([
        _sharesList([]),
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
      expect(sentBesidesListing(), isEmpty, reason: 'a plain tap deletes nothing');

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
      expect(sentBesidesListing(), List.filled(4, "DELETE /api/me"));
      expect(container.read(recordShareSessionProvider), isNull);
      expect(StorageBox(StorageBoxKey.recordShares).entries(), isEmpty);
    });

    testWidgets("stopped by the server's day, the deletion is left to the server and the device logs out", (
      tester,
    ) async {
      await storeSession();
      final note = await storeNote();
      container = containerFor([
        _sharesList([_listed("0123456789", note.keyHash)]),
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
      final note = await storeNote();
      container = containerFor([
        _sharesList([_listed("0123456789", note.keyHash)]),
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
      final note = await storeNote();
      container = containerFor([
        _sharesList([_listed("0123456789", note.keyHash)]),
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
      // The second share was made on another device: this one holds no note of it.
      final elsewhere = _listed("9876543210", secretHash(newClientKey()), cardName: _serverCardName, evaluation: 12345);
      container = containerFor([
        _sharesList([_listed("0123456789", note.keyHash), elsewhere]),
        _empty(204),
        // Asked again after the unshare, the server lists what is left.
        _sharesList([elsewhere]),
      ], emptied: true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DialogLayer(child: Scaffold(body: RecordShareListCard(inView: true))),
          ),
        ),
      );

      // The card asks as it is built; one more fake step reads the answer.
      await settleUntilElapsing(tester, () => server.sent.isNotEmpty, describe: "the account's list to be asked for");
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.text('端末から削除したレコード').evaluate().isNotEmpty,
        describe: 'the row of the deleted record',
      );
      expect(server.sent.single.uri.path, "/api/me/shares");
      expect(find.text('2026-10-20'), findsNWidgets(2));
      expect(find.text('端末から削除したレコード'), findsOneWidget, reason: 'only the noted share was made here');
      expect(find.text(_serverCardName), findsOneWidget, reason: 'the share with no note takes the listed name');
      expect(find.text('12,345'), findsOneWidget, reason: "the row carries the evaluation value the server listed");
      expect(find.text('-'), findsOneWidget, reason: 'a share listed with no evaluation value shows none');
      await tester.tap(find.byTooltip('共有を取り消す…').first);
      await tester.pumpAndSettle();
      await tester.longPress(find.text('長押しで取り消す'));
      await settleUntil(
        tester,
        () => find.text('2026-10-20').evaluate().length == 1,
        describe: 'the unshared row to leave the list',
      );

      expect(find.text('端末から削除したレコード'), findsNothing);
      expect(find.text(_serverCardName), findsOneWidget);
      expect(server.sent.map((s) => "${s.method} ${s.uri.path}"), [
        "GET /api/me/shares",
        "DELETE /api/shares/0123456789",
        "GET /api/me/shares",
      ], reason: 'the list is asked for again once the share is gone');
      expect(container.read(recordSharesProvider), isEmpty);
    });

    testWidgets("the account's list is asked for each time its tab comes back into view, and on the reload button", (
      tester,
    ) async {
      await storeSession();
      final first = _listed("0123456789", secretHash(newClientKey()), cardName: _serverCardName);
      final second = _listed("9876543210", secretHash(newClientKey()), cardName: "[別の衣装]別のウマ娘");
      container = containerFor([
        _sharesList([first]),
        _sharesList([first, second]),
        _sharesList([second]),
      ]);
      // The account page tells the card whether its tab is the one shown; the inactive tab stays built.
      final inView = ValueNotifier(true);
      addTearDown(inView.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: DialogLayer(
              child: Scaffold(
                body: ValueListenableBuilder(
                  valueListenable: inView,
                  builder: (_, shown, _) => RecordShareListCard(inView: shown),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> settleAsked(int count, String describe) async {
        await settleUntilElapsing(tester, () => server.sent.length == count, describe: "the list's request $count");
        await tester.pump(const Duration(seconds: 1));
        await settleUntil(
          tester,
          () =>
              find.text('共有したレコードを確かめています…').evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
          describe: describe,
        );
      }

      await settleAsked(1, 'the first answer');
      expect(find.text(_serverCardName), findsOneWidget);

      inView.value = false;
      await tester.pumpAndSettle();
      await pumpRealTimeWindow(tester, rounds: 5);
      expect(server.sent, hasLength(1), reason: 'a tab out of view asks nothing');

      inView.value = true;
      await settleAsked(2, 'the answer as the tab comes back');
      await settleUntil(
        tester,
        () => find.text('[別の衣装]別のウマ娘').evaluate().isNotEmpty,
        describe: 'the share made meanwhile to be listed',
      );

      await tester.tap(find.byTooltip('もう一度確かめる'));
      await settleAsked(3, 'the answer to the reload');
      await settleUntil(
        tester,
        () => find.text(_serverCardName).evaluate().isEmpty,
        describe: 'the share unshared elsewhere to leave the list',
      );
      expect(server.sent.map((s) => s.uri.path), everyElement("/api/me/shares"));
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

      final outcomes = await notes().shareAll(records, source: RecordSource.active);

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

  test("a list asked for before a share finished keeps that share's note", () async {
    await storeSession();
    final listing = Completer<Object>();
    container = containerFor([
      listing.future,
      _results([_created("0123456789")]),
    ]);

    final refreshed = notes().refreshFromServer();
    expect((await notes().shareAll([record], source: RecordSource.active))[record.id], isA<Shared>());
    final made = notes().entryOf(record.id);
    listing.complete(_sharesList([]));
    expect(await refreshed, isA<SharesListed>());

    expect(notes().entryOf(record.id), made);
    expect(notes().entryOf(record.id)?.state, RecordShareState.shared);
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(made?.keyHash ?? ""), made?.toJson());
  });

  test("a list that arrives while a share is being sent keeps its note; once the send fails, a list decides", () async {
    await storeSession();
    final posted = Completer<Object>();
    container = containerFor([posted.future, _sharesList([]), _sharesList([])]);

    final sharing = notes().shareAll([record], source: RecordSource.active);
    await waitUntil(() => server.sent.isNotEmpty, describe: 'the share to be sent');
    final note = notes().entryOf(record.id);
    // The server may already hold the share; the list it answered before that is no evidence against it.
    expect(await notes().refreshFromServer(), isA<SharesListed>());
    expect(notes().entryOf(record.id), note);
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(note?.keyHash ?? ""), note?.toJson());

    posted.complete(_lostConnection);
    expect((await sharing)[record.id], isA<ShareUnreachable>());
    expect(notes().entryOf(record.id), note);
    expect(await notes().refreshFromServer(), isA<SharesListed>());
    expect(notes().entryOf(record.id), isNull);
  });

  test("a list asked for while a share was being sent keeps its note when it arrives after the send failed", () async {
    await storeSession();
    final posted = Completer<Object>();
    final listing = Completer<Object>();
    container = containerFor([posted.future, listing.future]);

    final sharing = notes().shareAll([record], source: RecordSource.active);
    await waitUntil(() => server.sent.isNotEmpty, describe: 'the share to be sent');
    final note = notes().entryOf(record.id);
    final refreshed = notes().refreshFromServer();
    await waitUntil(() => server.sent.length == 2, describe: 'the list to be asked for');
    // The server answered the list, then took the share, whose reply was lost.
    posted.complete(_lostConnection);
    expect((await sharing)[record.id], isA<ShareUnreachable>());
    listing.complete(_sharesList([]));
    expect(await refreshed, isA<SharesListed>());

    expect(notes().entryOf(record.id), note);
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(note?.keyHash ?? ""), note?.toJson());
    server.answers.add(_sharesList([_listed("0123456789", note?.keyHash ?? "")]));
    expect(await notes().refreshFromServer(), isA<SharesListed>());
    expect(notes().entryOf(record.id)?.clientKey, note?.clientKey);
    expect(notes().entryOf(record.id)?.state, RecordShareState.shared);
  });

  test("a list asked for before a pending note was sent again keeps the share that send confirmed", () async {
    await storeSession();
    final earlier = await storeNote();
    final listing = Completer<Object>();
    container = containerFor([
      listing.future,
      _results([
        {"status": "existing", ..._located("0123456789")},
      ]),
    ]);

    final refreshed = notes().refreshFromServer();
    await waitUntil(() => server.sent.isNotEmpty, describe: 'the list to be asked for');
    expect((await notes().shareAll([record], source: RecordSource.active))[record.id], isA<Shared>());
    expect(sharesSent(1).single["client_key"], earlier.clientKey);
    final made = notes().entryOf(record.id);
    listing.complete(_sharesList([]));
    expect(await refreshed, isA<SharesListed>());

    expect(made?.state, RecordShareState.shared);
    expect(notes().entryOf(record.id), made);
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(earlier.keyHash), made?.toJson());
  });

  test("a note whose share the server refused is dropped by a list asked for after the refusal", () async {
    await storeSession();
    container = containerFor([
      _results([
        {"status": "refused", "error": "account_limit"},
      ]),
      _sharesList([]),
    ]);

    expect((await notes().shareAll([record], source: RecordSource.active))[record.id], isA<ShareRefused>());
    final note = notes().entryOf(record.id);
    expect(note?.state, RecordShareState.pending);
    expect(await notes().refreshFromServer(), isA<SharesListed>());

    expect(notes().entryOf(record.id), isNull);
    expect(StorageBox(StorageBoxKey.recordShares).pull<String>(note?.keyHash ?? ""), isNull);
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
    expect((await notes().shareAll([record], source: RecordSource.active))[record.id], isA<Shared>());
    expect((await notes().shareAll([synced], source: RecordSource.active))[synced.id], isA<Shared>());

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

        expect((await notes().shareAll([other], source: RecordSource.active))[other.id], isA<LoginRequired>());
        expect(container.read(recordShareSessionProvider), isNull);
        expect(notes().entryOf(record.id), isNotNull, reason: 'a 401 alone keeps the notes');

        final attempt = await container.read(recordShareSessionProvider.notifier).beginLogin();
        expect(await attempt.claim(), LoginOutcome.signedIn);
        final outcomes = await notes().shareAll([record, other], source: RecordSource.active);

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

      expect(
        (await notes().shareAll([record, other], source: RecordSource.active))[record.id],
        isA<ShareUnreachable>(),
      );
      await notes().shareAll([record, other], source: RecordSource.active);
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

    expect((await notes().shareAll([record], source: RecordSource.active))[record.id], isA<ShareUnreachable>());
    final pending = container.read(recordSharesProvider).values.single;
    expect(pending.state, RecordShareState.pending);

    final outcome = (await notes().shareAll([record], source: RecordSource.active))[record.id];

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

    expect((await notes().shareAll([record], source: RecordSource.active))[record.id], isA<ShareUnreachable>());
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

  test(
    "the table's share column, filtered to shared, lists the records shared from here, and none once logged out",
    () async {
      await storeSession();
      final shared = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(0)));
      final pending = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(1)));
      final unnoted = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(2)));
      final friend = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(3), recordType: "FriendStandard"));
      await storeNote(recordId: pending.id);
      final onlyShared = ShareStateColumnSpec(
        id: "only_shared",
        title: "only_shared",
        predicate: ShareColumnPredicate(
          rejects: {ShareColumnState.pending, ShareColumnState.none, ShareColumnState.notShareable},
        ),
      );
      container = containerFor(
        [
          _results([_created("0123456789")]),
          _empty(204),
        ],
        table: (records: [shared, pending, unnoted, friend], columns: [onlyShared]),
      );
      List<String> listed() => [
        for (final row in container.read(currentGridProvider).rows) row.getUserData<CharaDetailRecord>()!.id,
      ];

      expect(listed(), isEmpty, reason: 'a pending share is not listed as shared');
      expect((await notes().shareAll([shared], source: RecordSource.active))[shared.id], isA<Shared>());
      expect(listed(), [shared.id]);

      await container.read(recordShareSessionProvider.notifier).logout();
      expect(listed(), isEmpty, reason: 'with nothing known, a filtered column lists no row');
    },
  );

  test('a share column saved with a filter reads back with it, listing the same rows', () async {
    await storeSession();
    final shared = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(0)));
    final unnoted = CharaDetailRecord.fromRecordJson(_recordBytes(recordId: _uuid(1)));
    await storeNote(recordId: shared.id, state: RecordShareState.shared);
    final table = (records: [shared, unnoted], columns: null);
    List<String> listed() => [
      for (final row in container.read(currentGridProvider).rows) row.getUserData<CharaDetailRecord>()!.id,
    ];

    container = containerFor([], table: table);
    await container.read(currentColumnSpecsLoaderProvider.future);
    final rejects = {ShareColumnState.pending, ShareColumnState.none, ShareColumnState.notShareable};
    container
        .read(currentColumnSpecsLoaderProvider.notifier)
        .add(
          ShareStateColumnSpec(
            id: "only_shared",
            title: "only_shared",
            predicate: ShareColumnPredicate(rejects: rejects),
          ),
        );
    expect(listed(), [shared.id]);

    container = containerFor([], table: table);
    await container.read(currentColumnSpecsLoaderProvider.future);
    final read = container.read(currentColumnSpecsProvider).single;
    expect(read, isA<ShareStateColumnSpec>());
    expect((read as ShareStateColumnSpec).predicate.rejects, rejects);
    expect(listed(), [shared.id]);
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

        final outcome = (await notes().shareAll([other], source: RecordSource.active))[other.id];

        expect(server.sent.single.uri.path, "/api/me");
        expect(outcome, isA<ShareRefused>().having((o) => o.reason, "reason", ShareRefusal.accountDeleting));
        expect(container.read(recordShareSessionProvider)?.deleting, isTrue);
        expect(stored()?.deleting, isTrue);
      });

      test("sharing's account_deleting marks the session as deleting", () async {
        await storeSession();
        container = containerFor([deleting()]);

        final outcome = (await notes().shareAll([record], source: RecordSource.active))[record.id];

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
