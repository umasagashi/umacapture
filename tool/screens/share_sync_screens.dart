// Draws the sharing and sync screens in every state their sentences appear in, and writes each as a PNG, so the
// wording can be read beside the screen it is shown on. A drawing tool, not a test: it asserts nothing about the
// pictures, and nothing compares them with an earlier run. It lives outside `test/`, so neither `flutter test` with no
// path nor `tool/test_selection.dart` (which scans `test/` alone) ever reaches it.
//
// Each screen is the app's real widget over its real stores, with only the edges replaced: the sharing server is a
// transport that answers what the state needs, and the sync state, the sync server and the memo stores are fakes that
// hold the state shown. The theme is built as the app builds it, over the app's font, M PLUS Rounded 1c, read from a
// file this tool is given; with no file the Japanese text renders as boxes.
//
// Run (from the repository root; the output directory is created if missing):
//   U10_FONT=<path to MPLUSRounded1c regular .ttf> U10_OUT=<output directory> \
//     .fvm/flutter_sdk/bin/flutter test tool/screens/share_sync_screens.dart
// Each PNG is `<screen>-<state>.png`; beside them, `manifest.json` lists per picture every text it shows, and
// `reads.json` every translation key the screen read since it was mounted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
// `Localization` and `Translations` are what `EasyLocalization` drives internally, as in `test/support/localization.dart`.
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// The app reaches it through `easy_localization`, which hands the app its delegates.
// ignore: depend_on_referenced_packages
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/record_share.dart';
import 'package:umacapture/src/chara_detail/record_share_session.dart';
import 'package:umacapture/src/chara_detail/record_sync.dart';
import 'package:umacapture/src/chara_detail/record_sync_round.dart';
import 'package:umacapture/src/chara_detail/record_sync_server.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/account.dart';
import 'package:umacapture/src/gui/app_widget.dart';
import 'package:umacapture/src/gui/chara_detail/account_sync_section.dart';
import 'package:umacapture/src/gui/chara_detail/archive_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/column_preset_bar_widget.dart';
import 'package:umacapture/src/gui/chara_detail/data_table_widget.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/enhancement_merge_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/share_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import '../../test/support/empty_record_stores.dart';
import '../../test/support/factor_classifier.dart';
import '../../test/support/hive.dart';
import '../../test/support/localization.dart';
import '../../test/support/records.dart';
import '../../test/support/settling.dart';

/// The family the app's text is drawn in here; the app's own name for it is google_fonts', which this tool does not
/// load (it would fetch the file at run time).
const _family = 'MPLUSRounded1c';

final _out = Directory(Platform.environment['U10_OUT'] ?? '.notes/analysis/u10-screens');

/// Every picture's texts, written as `manifest.json` once every screen is drawn.
final _manifest = <String, List<String>>{};

/// Every picture's translation keys: those the screen read since it was mounted, written as `reads.json`.
final _reads = <String, List<String>>{};

/// The keys read since the screen on show was mounted.
final _read = <String>{};

/// The app's translations, which record each key a screen reads.
class _RecordingTranslations extends Translations {
  _RecordingTranslations(super.translations);

  @override
  String? get(String key) {
    _read.add(key);
    return super.get(key);
  }
}

final _frame = GlobalKey();

const _accountId = "acct-0001";
const _token = "TOKENtokenTOKENtokenTOKENtokenTOKENtoken123";
const _moduleVersion = "2026-09-30T11:00:00+0900";

final _layout = PathInfo(
  documentDir: DirectoryPath('${Directory.systemTemp.path}/uma_u10_screens/documents'),
  supportDir: DirectoryPath('${Directory.systemTemp.path}/uma_u10_screens/support'),
  executableDir: DirectoryPath('${Directory.systemTemp.path}/uma_u10_screens/exe'),
  downloadDir: DirectoryPath('${Directory.systemTemp.path}/uma_u10_screens/downloads'),
);

// ---------------------------------------------------------------------------------------------------------------
// Fonts and the theme.

/// The root of [package] as `.dart_tool/package_config.json` resolves it.
String _packageRoot(String package) {
  final config = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map<String, dynamic>;
  final entry = (config['packages'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['name'] == package);
  return Uri.parse(entry['rootUri'] as String).toFilePath();
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

Future<void> _loadFonts() async {
  final font = Platform.environment['U10_FONT'] ?? '.notes/t3-img/fonts/MPLUSRounded1c-Regular.ttf';
  if (!File(font).existsSync()) {
    throw StateError('no font at $font: give the M PLUS Rounded 1c regular .ttf as U10_FONT');
  }
  await _loadFont(_family, font);
  final symbols = _packageRoot('material_symbols_icons');
  await _loadFont(
    'packages/material_symbols_icons/MaterialSymbolsRounded',
    '$symbols/lib/fonts/MaterialSymbolsRounded.ttf',
  );
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '.fvm/flutter_sdk';
  await _loadFont('MaterialIcons', '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
}

/// The app's light theme: `ApplicationWidgetState.build`'s FlexColorScheme base, over the app's font, through the
/// app's own [ApplicationWidgetState.modifyTheme].
ThemeData _theme(WidgetRef ref) => ApplicationWidgetState().modifyTheme(
  ref,
  FlexThemeData.light(
    scheme: FlexScheme.blue,
    surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
    blendLevel: 20,
    subThemesData: const FlexSubThemesData(outlinedButtonOutlineSchemeColor: SchemeColor.primary),
    visualDensity: FlexColorScheme.comfortablePlatformDensity,
    useMaterial3: true,
    fontFamily: _family,
  ),
);

// ---------------------------------------------------------------------------------------------------------------
// Drawing.

/// Mounts [home] in the app's frame over [container]: its theme, a dialog layer and a scaffold.
Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  Widget home, {
  Size size = const Size(900, 1000),
}) async {
  _read.clear();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _frame,
      child: UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            // The app's locale, as `EasyLocalization` hands it to the app's `MaterialApp`.
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [appTestLocale],
            locale: appTestLocale,
            theme: _theme(ref),
            home: DialogLayer(child: Scaffold(body: home)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// A button with no text, which opens a dialog from a widget's own ref, as the app's entries do.
class _Opener extends ConsumerWidget {
  const _Opener(this.open);

  final void Function(WidgetRef ref) open;

  static const openKey = Key('u10-open');

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
    alignment: Alignment.topLeft,
    child: IconButton(key: openKey, onPressed: () => open(ref), icon: const SizedBox.square(dimension: 8)),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_Opener.openKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

bool _isIconOnly(String s) => s.runes.every((r) => r >= 0xE000 && r <= 0xF8FF || r >= 0xF0000);

/// Writes the frame as `<name>.png`, and the texts it shows into the manifest.
Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  final texts = <String>[
    for (final e in find.byType(RichText).evaluate())
      (e.widget as RichText).text.toPlainText(includeSemanticsLabels: false),
    for (final e in find.byType(EditableText).evaluate()) (e.widget as EditableText).controller.text,
  ].where((s) => s.trim().isNotEmpty && !_isIconOnly(s)).toList();
  _manifest[name] = texts;
  _reads[name] = _read.toList()..sort();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_frame));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    _out.createSync(recursive: true);
    File('${_out.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Sharing: the transport, the records and the session.

class _FakeServer implements HttpClientAdapter {
  _FakeServer(this.answers);

  final List<Object> answers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final answer = answers.removeAt(0);
    if (answer is Exception) throw answer;
    return answer as ResponseBody;
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ["application/json"],
  },
);

const _lostConnection = SocketException("connection reset");

Map<String, Object?> _created(String id) => {
  "status": "created",
  "id": id,
  "url": "https://umacapture.com/r/$id",
  "json_url": "https://umacapture.com/r/$id.json",
};

ResponseBody _results(List<Map<String, Object?>> results) => _json(200, {"results": results});

Map<String, Object?> _claimed() => {
  "token": _token,
  "expires_at": 1792000000,
  "account_id": _accountId,
  "deleting": false,
};

String _uuid(int i) => "9a1e0d66-0654-4416-aa11-${i.toString().padLeft(12, '0')}";

CharaDetailRecord _record({int i = 0, String? recordType}) {
  final map = jsonDecode(File('test/fixtures/chara_detail_record.json').readAsStringSync()) as Map<String, dynamic>;
  final metadata = map["metadata"] as Map<String, dynamic>;
  (metadata["record_id"] as Map<String, dynamic>)["self"] = _uuid(i);
  if (recordType != null) metadata["record_type"] = recordType;
  return CharaDetailRecord.fromRecordJson(jsonEncode(map));
}

class _Shown extends CharaDetailRecordStorage {
  _Shown(this.shown);

  final List<CharaDetailRecord> shown;

  @override
  Future<List<CharaDetailRecord>> build() async => shown;

  @override
  CharaDetailRecord? getBy({required String id}) => shown.where((r) => r.id == id).firstOrNull;
}

Future<void> _storeSession({bool deleting = false}) => StorageBox(StorageBoxKey.recordShares).push(
  shareSessionKey,
  ShareSession(token: _token, expiresAt: 1792000000, accountId: _accountId, deleting: deleting).toJson(),
);

Future<void> _storeShared(String recordId) async {
  final note = RecordShare(
    recordId: recordId,
    accountId: _accountId,
    clientKey: newClientKey(),
    state: RecordShareState.shared,
    id: "0123456789",
    url: "https://umacapture.com/r/0123456789",
  );
  await StorageBox(StorageBoxKey.recordShares).push(note.keyHash, note.toJson());
}

// ---------------------------------------------------------------------------------------------------------------
// Sync: the state, the server and the session.

/// Holds the sync state a screen shows; turns sync on and sets the image form without a round.
class _Sync extends RecordSync {
  _Sync(this.initial, {this.countsUnread = false, this.longMemoCount = 0});

  final RecordSyncState initial;
  final ({int toSend, int toReceive}) counts = (toSend: 12, toReceive: 30);
  final bool countsUnread;
  final int longMemoCount;

  @override
  RecordSyncState build() => initial;

  void show(RecordSyncState shown) => state = shown;

  /// Unread counts are null, as [RecordSync.beforeOn] gives them when the server's list could not be read.
  @override
  Future<SyncBeforeOn?> beforeOn([SyncServer? server]) async =>
      (longMemos: longMemoCount, counts: countsUnread ? null : counts);

  @override
  Future<void> setOn(bool on) async {}

  @override
  Future<void> setImageForm(SyncServer server, String form) async {
    await server.putImageForm(form);
    ref.invalidate(syncImageFormProvider);
  }
}

/// A sync server that holds the account's image form, and answers nothing else.
class _SyncServer implements SyncServer {
  _SyncServer({this.unread = false});

  String form = 'none';
  final bool unread;

  @override
  Future<String> imageForm() async => unread ? throw StateError('the server did not answer') : form;

  @override
  Future<void> putImageForm(String form) async => this.form = form;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Dropped extends RecordShareSessionDropped {
  @override
  bool build() => true;
}

final _synced = DateTime(2030, 1, 1, 9, 30);

RecordSyncState _on({SyncRoundOutcome? told, SyncToldCounts? counts, bool running = false, bool synced = true}) =>
    RecordSyncState(
      account: _accountId,
      ranAs: told == null ? null : _accountId,
      told: told,
      counts: counts,
      lastSynced: synced ? _synced : null,
      running: running,
    );

// ---------------------------------------------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useStorageBoxForTest();
  setUpAll(() async {
    initializeMappers();
    final json = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
    Localization.load(appTestLocale, translations: _RecordingTranslations(json));
    await _loadFonts();
  });
  setUp(() async {
    await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDownAll(() {
    _out.createSync(recursive: true);
    File('${_out.path}/manifest.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_manifest));
    File('${_out.path}/reads.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_reads));
  });

  /// A container for the sharing screens over [answers], with [shown] in the record store.
  ProviderContainer sharing(List<Object> answers, {List<CharaDetailRecord> shown = const [], String? trainerId}) {
    final c = ProviderContainer(
      overrides: [
        loginPageOpenerProvider.overrideWithValue((uri) async => true),
        loginListenerBinderProvider.overrideWithValue(({required String h}) async => null),
        trainerIdProvider.overrideWithValue(trainerId ?? _record().metadata.trainerId),
        moduleVersionLoader.overrideWith(
          (ref) async => ModuleVersion(
            recognizerVersion: DateTime.utc(2026, 9, 30, 2),
            minimumVersion: DateTime.utc(2021),
            recognizerVersionText: _moduleVersion,
          ),
        ),
        recordShareDioProvider.overrideWith(
          (ref) => createDiagnosticDio(operation: "record_share")..httpClientAdapter = _FakeServer(answers),
        ),
        if (shown.isNotEmpty) charaDetailRecordStorageLoaderProvider.overrideWith(() => _Shown(shown)),
        syncServerProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// A container for the account and sync screens: [sync] holds the state, [server] the account's image form.
  ProviderContainer syncing(
    _Sync sync, {
    SyncServer? server,
    bool dropped = false,
    List<Object> answers = const [],
    List<CharaDetailRecord> shown = const [],
  }) {
    final c = ProviderContainer(
      overrides: [
        if (shown.isNotEmpty) charaDetailRecordStorageLoaderProvider.overrideWith(() => _Shown(shown)),
        recordSyncProvider.overrideWith(() => sync),
        syncServerProvider.overrideWithValue(server),
        if (dropped) recordShareSessionDroppedProvider.overrideWith(_Dropped.new),
        recordShareDioProvider.overrideWith(
          (ref) => createDiagnosticDio(operation: "record_share")..httpClientAdapter = _FakeServer([...answers]),
        ),
        loginPageOpenerProvider.overrideWithValue((uri) async => true),
        loginListenerBinderProvider.overrideWithValue(({required String h}) async => null),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Ends a screen: unmounts it, lets the timers it left (tooltips, toasts) run out, and drops the platform.
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    debugDefaultTargetPlatformOverride = null;
  }

  group('N1 — the share dialog', () {
    final record = _record();

    Future<void> openShare(WidgetTester tester, ProviderContainer c) async {
      await _mount(
        tester,
        c,
        _Opener((ref) => ShareRecordDialog.show(ref.base, recordId: record.id, source: RecordSource.active)),
      );
      await tester.runAsync(() => c.read(charaDetailRecordStorageLoaderProvider.future));
      await _open(tester);
    }

    testWidgets('logged out, and each login that does not simply succeed', (tester) async {
      final cases = [
        (
          'incomplete',
          <Object>[
            _json(409, {"error": "login_incomplete"}),
          ],
        ),
        (
          'expired',
          <Object>[
            _json(410, {"error": "login_expired"}),
          ],
        ),
        (
          'refused',
          <Object>[
            _json(403, {"error": "forbidden"}),
          ],
        ),
        ('unreachable', <Object>[_lostConnection]),
        (
          'trainer-limit',
          <Object>[
            _json(200, _claimed()),
            _json(409, {"error": "trainer_limit"}),
          ],
        ),
      ];
      for (final (i, (name, answers)) in cases.indexed) {
        await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
        final c = sharing(answers, shown: [record]);
        await openShare(tester, c);
        await tester.longPress(find.text(appSentenceAt('pages.chara_detail.share_record.dialog.ok_button.label')));
        final login = appSentenceAt('pages.chara_detail.record_share.log_in');
        await settleUntil(tester, () => find.text(login).evaluate().isNotEmpty, describe: 'the way to the login');
        if (i == 0) await _shoot(tester, 'N1-logged-out');
        await tester.tap(find.text(login));
        await tester.pump();
        await tester.tap(find.text(login));
        await tester.pump(const Duration(seconds: 1));
        final key = name == 'trainer-limit' ? 'trainer_limit' : name;
        final sentence = appSentenceAt('pages.chara_detail.record_share.login.$key');
        await settleUntil(tester, () => find.text(sentence).evaluate().isNotEmpty, describe: 'the $name sentence');
        await _shoot(tester, 'N1-login-$name');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await done(tester);
    });

    testWidgets('shared, refused and not shareable', (tester) async {
      final cases = [
        (
          'shared',
          <Object>[
            _results([_created("0123456789")]),
          ],
          null,
          'pages.chara_detail.share_record.dialog.shared',
        ),
        (
          'refused-account-limit',
          <Object>[
            _results([
              {"status": "refused", "error": "account_limit"},
            ]),
          ],
          null,
          'pages.chara_detail.share_record.failure.account_limit',
        ),
        (
          'refused-daily-limit',
          <Object>[
            _results([
              {"status": "refused", "error": "daily_limit"},
            ]),
          ],
          null,
          'pages.chara_detail.share_record.failure.daily_limit',
        ),
        (
          'not-shareable',
          <Object>[
            _json(200, {"account_id": _accountId, "trainer_ids": <String>[]}),
          ],
          "11111111-2222-4333-8444-555555555555",
          'pages.chara_detail.share_record.failure.not_shareable',
        ),
      ];
      for (final (name, answers, trainerId, key) in cases) {
        await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
        await _storeSession();
        final c = sharing(answers, shown: [record], trainerId: trainerId);
        await openShare(tester, c);
        await tester.longPress(find.text(appSentenceAt('pages.chara_detail.share_record.dialog.ok_button.label')));
        await tester.pump(const Duration(seconds: 1));
        await settleUntil(tester, () => find.text(appSentenceAt(key)).evaluate().isNotEmpty, describe: name);
        await _shoot(tester, 'N1-$name');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await done(tester);
    });
  });

  group('N2 — sharing the checked records', () {
    Future<void> openBulk(WidgetTester tester, ProviderContainer c, List<String> ids) async {
      await _mount(
        tester,
        c,
        _Opener((ref) => BulkShareRecordDialog.show(ref.base, recordIds: ids, source: RecordSource.active)),
      );
      await tester.runAsync(() => c.read(charaDetailRecordStorageLoaderProvider.future));
      await _open(tester);
    }

    testWidgets('the confirmation, a partial result, the left out and all shared', (tester) async {
      final ok = appSentenceAt('pages.chara_detail.share_record.dialog.ok_button.label');

      await _storeSession();
      final own = _record(i: 1);
      final shared = _record(i: 2);
      final friend = _record(i: 3, recordType: "FriendStandard");
      await _storeShared(shared.id);
      var c = sharing(
        [
          _results([_created("id-own")]),
        ],
        shown: [own, shared, friend],
      );
      await openBulk(tester, c, [own.id, shared.id, friend.id]);
      await tester.pump(const Duration(seconds: 1));
      await _shoot(tester, 'N2-confirm');
      await tester.longPress(find.text(ok));
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.textContaining('件を共有しました。').evaluate().isNotEmpty,
        describe: 'the left-out result',
      );
      await _shoot(tester, 'N2-excluded');
      await tester.pumpWidget(const SizedBox.shrink());

      await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
      await _storeSession();
      final nine = [for (var i = 0; i < 9; i++) _record(i: 10 + i)];
      c = sharing([
        _results([for (var i = 0; i < 8; i++) _created("id-$i")]),
        _lostConnection,
        _results([_created("id-8")]),
      ], shown: nine);
      await openBulk(tester, c, [for (final r in nine) r.id]);
      await tester.longPress(find.text(ok));
      final retry = appSentenceAt('pages.chara_detail.share_record.bulk.retry');
      await settleUntil(tester, () => find.text(retry).evaluate().isNotEmpty, describe: 'the partial result');
      await _shoot(tester, 'N2-partial');
      await tester.tap(find.text(retry));
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.textContaining('https://').evaluate().isNotEmpty || find.textContaining('/u/').evaluate().isNotEmpty,
        describe: 'the list URL',
      );
      await _shoot(tester, 'N2-all-shared');
      await tester.pumpWidget(const SizedBox.shrink());

      await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
      final two = [_record(i: 30), _record(i: 31)];
      c = sharing([], shown: two);
      await openBulk(tester, c, [for (final r in two) r.id]);
      await tester.longPress(find.text(ok));
      final login = appSentenceAt('pages.chara_detail.record_share.log_in');
      await settleUntil(tester, () => find.text(login).evaluate().isNotEmpty, describe: 'the login');
      await _shoot(tester, 'N2-logged-out');
      await done(tester);
    });
  });

  group('N3, N8, P2 — the account tab', () {
    Widget section() => const AccountPage();

    testWidgets('logged out, logged in, deleting, and the deletion dialog', (tester) async {
      var c = syncing(_Sync(const RecordSyncState()), server: _SyncServer());
      await _mount(tester, c, section());
      await _shoot(tester, 'N3-logged-out');
      await tester.pumpWidget(const SizedBox.shrink());

      await _storeSession();
      c = syncing(
        _Sync(const RecordSyncState()),
        server: _SyncServer(),
        answers: [
          _json(200, {
            "remaining": {"shares": 3, "sync": 2},
          }),
          _lostConnection,
        ],
      );
      await _mount(tester, c, section());
      await _shoot(tester, 'N3-logged-in');
      await tester.tap(find.text(appSentenceAt('pages.account.delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await _shoot(tester, 'N3-delete-confirm');
      await tester.longPress(find.text(appSentenceAt('pages.account.deletion.ok_button.label')));
      await tester.pump(const Duration(seconds: 1));
      await settleUntil(
        tester,
        () => find.text(appSentenceAt('pages.account.deletion.failure.unreachable')).evaluate().isNotEmpty,
        describe: 'the deletion to stop',
      );
      await _shoot(tester, 'N3-deleting-stopped');
      await tester.pumpWidget(const SizedBox.shrink());

      await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
      await _storeSession(deleting: true);
      c = syncing(_Sync(_on()));
      await _mount(tester, c, section());
      await _shoot(tester, 'N3-deleting');
      await done(tester);
    });

    testWidgets('P2: unsharing with no session asks for a login', (tester) async {
      final c = sharing([]);
      await _mount(tester, c, _Opener((ref) => UnshareRecordDialog.show(ref.base, shareId: "0123456789")));
      await _open(tester);
      await tester.longPress(find.text(appSentenceAt('pages.chara_detail.unshare_record.dialog.ok_button.label')));
      final login = appSentenceAt('pages.chara_detail.record_share.log_in');
      await settleUntil(tester, () => find.text(login).evaluate().isNotEmpty, describe: 'the login');
      await _shoot(tester, 'P2-login-required');
      await done(tester);
    });

    testWidgets('N8: every state of the sync card', (tester) async {
      const counts = SyncToldCounts(account: _accountId, restored: 1, splitOff: 2, added: 3);
      final undone = (records: 2, stops: <SyncImagesStop>{});
      final cases = <(String, RecordSyncState, SyncServer?)>[
        ('off', const RecordSyncState(), _SyncServer()),
        ('on', _on(), _SyncServer()),
        ('not-synced-yet', _on(synced: false), _SyncServer()),
        ('running', _on(running: true), _SyncServer()),
        ('counts', _on(told: const SyncRoundOutcome(SyncRoundEnd.done), counts: counts), _SyncServer()),
        ('long-memos', _on(told: const SyncRoundOutcome(SyncRoundEnd.heldByLongMemos, longMemos: 2)), _SyncServer()),
        ('withheld', _on(told: const SyncRoundOutcome(SyncRoundEnd.done, withheld: 3)), _SyncServer()),
        (
          'halt-account-room-waits',
          _on(
            told: SyncRoundOutcome(
              SyncRoundEnd.done,
              waitingForRoom: 3,
              imagesUndone: undone,
              serverStop: SyncServerStop.accountRoom,
            ),
          ),
          _SyncServer(),
        ),
        (
          'halt-account-room-stopped',
          _on(told: const SyncRoundOutcome(SyncRoundEnd.failed, serverStop: SyncServerStop.accountRoom)),
          _SyncServer(),
        ),
        (
          'halt-service-room-waits',
          _on(told: const SyncRoundOutcome(SyncRoundEnd.done, waitingForRoom: 2, serverStop: SyncServerStop.service)),
          _SyncServer(),
        ),
        (
          'halt-service-stopped',
          _on(told: const SyncRoundOutcome(SyncRoundEnd.failed, serverStop: SyncServerStop.service)),
          _SyncServer(),
        ),
        (
          'halt-account-day',
          _on(
            told: const SyncRoundOutcome(SyncRoundEnd.done, waitingForTheDay: 4, serverStop: SyncServerStop.accountDay),
          ),
          _SyncServer(),
        ),
        (
          'halt-service-day',
          _on(
            told: const SyncRoundOutcome(SyncRoundEnd.done, waitingForTheDay: 4, serverStop: SyncServerStop.serviceDay),
          ),
          _SyncServer(),
        ),
        ('image-form-unread', _on(), _SyncServer(unread: true)),
      ];
      await _storeSession();
      for (final (name, state, server) in cases) {
        final c = syncing(_Sync(state), server: server);
        await _mount(tester, c, const SingleChildScrollView(child: AccountSyncCard()));
        await tester.runAsync(() async {
          try {
            await c.read(syncImageFormProvider.future);
          } catch (_) {}
        });
        await _shoot(tester, 'N8-$name');
        await tester.pumpWidget(const SizedBox.shrink());
      }

      // D6-1: setting a form that sends images from none tells that the held images go, with no count.
      final c = syncing(_Sync(_on()), server: _SyncServer());
      await _mount(tester, c, const SingleChildScrollView(child: AccountSyncCard()));
      await tester.runAsync(() => c.read(syncImageFormProvider.future));
      await tester.pump();
      await tester.tap(find.text(appSentenceAt('$tr_account_sync.image_form.option.png.label')));
      await tester.pump();
      await tester.runAsync(() => c.read(syncImageFormProvider.future));
      await settleUntil(
        tester,
        () => find.text(appSentenceAt('$tr_account_sync.image_form.sends_held')).evaluate().isNotEmpty,
        describe: 'the note of the held images',
      );
      await _shoot(tester, 'N8-image-form-sends-held');
      await tester.pumpWidget(const SizedBox.shrink());

      // The session the server dropped: logged out, the sync card tells only that.
      await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
      final dropped = syncing(_Sync(const RecordSyncState()), server: null, dropped: true);
      await _mount(tester, dropped, const AccountPage());
      await _shoot(tester, 'N8-session-dropped');
      await done(tester);
    });

    testWidgets('N11: the dialog that turns sync on', (tester) async {
      await _storeSession();
      final cases = [
        ('counts', _Sync(const RecordSyncState())),
        ('long-memos', _Sync(const RecordSyncState(), longMemoCount: 2)),
        ('counts-unread', _Sync(const RecordSyncState(), countsUnread: true)),
      ];
      for (final (name, sync) in cases) {
        final c = syncing(sync, server: _SyncServer());
        await _mount(tester, c, _Opener((ref) => SyncTurnOnDialog.show(ref.base)), size: const Size(900, 1100));
        await _open(tester);
        await tester.runAsync(() => c.read(syncImageFormProvider.future));
        await tester.pump(const Duration(milliseconds: 500));
        await _shoot(tester, 'N11-$name');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await done(tester);
    });
  });

  group('N9, N10 — the toolbar icon and the toast', () {
    testWidgets('N9: the hover of each colour, on the real toolbar', (tester) async {
      await _storeSession();
      final cases = [
        ('synced', _on()),
        (
          'warning',
          _on(
            told: const SyncRoundOutcome(SyncRoundEnd.done, waitingForRoom: 3, serverStop: SyncServerStop.accountRoom),
          ),
        ),
        ('error', _on(told: const SyncRoundOutcome(SyncRoundEnd.heldByLongMemos, longMemos: 2))),
      ];
      for (final (name, state) in cases) {
        final c = syncing(_Sync(state), server: _SyncServer(), shown: [_record()]);
        await tester.runAsync(() => c.read(charaDetailRecordStorageLoaderProvider.future));
        await _mount(
          tester,
          c,
          const TopControlsLayer(
            controls: Column(mainAxisSize: MainAxisSize.min, children: [ColumnPresetBarWidget(), SizedBox(height: 80)]),
          ),
          size: const Size(1400, 320),
        );
        final icon = find.byType(SyncStatusIcon);
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(icon));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        await _shoot(tester, 'N9-hover-$name');
        await gesture.removePointer();
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await done(tester);
    });

    testWidgets('N10: the toast of a stop the server makes', (tester) async {
      await _storeSession();
      final sync = _Sync(_on());
      final c = syncing(sync, server: _SyncServer());
      final toasts = <ToastData>[];
      final subscription = c.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
      addTearDown(subscription.close);
      final toaster = c.listen(syncHaltToastsProvider, (_, _) {});
      addTearDown(toaster.close);
      const host = Key('u10-toast-host');
      await _mount(tester, c, const SizedBox.expand(key: host), size: const Size(900, 400));
      BuildContext context() => tester.element(find.byKey(host));
      final halts = [
        ('account-room-waits', const SyncRoundOutcome(SyncRoundEnd.done, serverStop: SyncServerStop.accountRoom)),
        ('account-room-stopped', const SyncRoundOutcome(SyncRoundEnd.failed, serverStop: SyncServerStop.accountRoom)),
        ('service-room-waits', const SyncRoundOutcome(SyncRoundEnd.done, serverStop: SyncServerStop.service)),
        ('service-stopped', const SyncRoundOutcome(SyncRoundEnd.failed, serverStop: SyncServerStop.service)),
        ('account-day', const SyncRoundOutcome(SyncRoundEnd.done, serverStop: SyncServerStop.accountDay)),
        ('service-day', const SyncRoundOutcome(SyncRoundEnd.done, serverStop: SyncServerStop.serviceDay)),
      ];
      for (final (name, told) in halts) {
        sync.show(_on());
        await tester.pump();
        final before = toasts.length;
        sync.show(_on(told: told));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (toasts.length != before + 1) throw StateError('the $name stop told no toast');
        ScaffoldMessenger.of(context()).clearSnackBars();
        await tester.pump(const Duration(seconds: 1));
        Toaster().showToast(context(), toasts.last);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await _shoot(tester, 'N10-toast-$name');
      }
      ScaffoldMessenger.of(context()).clearSnackBars();
      await tester.pump(const Duration(seconds: 2));
      await done(tester);
    });
  });

  group('N15, N16 and the changed sentences', () {
    testWidgets('N15: the memo dialog counts, within the limit and past it', (tester) async {
      for (final (name, held) in [('count', '良い因子。'), ('over', 'メモ' * 125)]) {
        final memos = _Memos(held);
        final c = ProviderContainer(
          overrides: [
            charaDetailRecordMemoProvider(_memoKey).overrideWith(() => memos),
            displayedRecordsProvider.overrideWithValue([makeRecord(id: 'R1', card: 1)]),
            pathInfoProvider.overrideWithValue(_layout),
          ],
        );
        addTearDown(c.dispose);
        await _mount(tester, c, const _MemoCellTap(), size: const Size(900, 600));
        await settleUntil(
          tester,
          () => c.read(charaDetailRecordMemoProvider(_memoKey)).hasValue,
          describe: 'the memos to load',
        );
        await tester.tap(find.byKey(_MemoCellTap.tapKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await _shoot(tester, 'N15-$name');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await done(tester);
    });

    testWidgets('N16: the merge dialog with sync on', (tester) async {
      List<Factor> self({required bool enhanced}) => [...coloured(enhanced ? 3 : 1, 1, 1), ...whites(enhanced ? 6 : 5)];
      final older = makeRecord(id: 'older', card: 1, self: self(enhanced: false), evaluationValue: 12000);
      final newer = makeRecord(
        id: 'newer',
        card: 1,
        self: self(enhanced: true),
        capturedDate: '2026-02-01T00:00:00+0900',
        evaluationValue: 12000,
      );
      final candidate = EnhancementCandidate(olderId: 'older', newerId: 'newer', enhancedId: 'newer');
      final c = ProviderContainer(
        overrides: [
          charaDetailRecordRatingStorageDataLoader.overrideWith((ref) => const <RatingStorageData>[]),
          charaDetailRecordMemoStorageDataLoader.overrideWith((ref) => const <MemoStorageData>[]),
          pathInfoProvider.overrideWithValue(_layout),
          pathLayoutProvider.overrideWithValue(_layout),
          enhancementMergeActionsProvider.overrideWithValue((
            merge: (candidate, {keptContentId, choices = const EnhancementMergeChoices()}) async =>
                const EnhancementMergeResult(outcome: EnhancementMergeOutcome.merged, needsReload: false),
            dismiss: (candidate) async => EnhancementDismissOutcome.dismissed,
            resolveInheritance: () async {},
            readMergesInProgress: (recordId) async => const <String, MergeDefaults>{},
          )),
          pendingEnhancementCandidatesProvider.overrideWithValue(const []),
          factorInfoLoader.overrideWith((ref) async => testFactorInfo),
          charaDetailRecordStorageLoaderProvider.overrideWith(() => _Shown([older, newer])),
          ...emptyRecordStoreOverrides.skip(1),
          imageSizeContainerProvider.overrideWith((ref, path) async => null),
          previewImagePathsProvider.overrideWith((ref, path) async => const PreviewImagePaths()),
          predictionAvailableProvider.overrideWith((ref, path) async => false),
          syncOnProvider.overrideWithValue(true),
        ],
      );
      addTearDown(c.dispose);
      await _mount(
        tester,
        c,
        EnhancementMergeDialog(candidate: candidate, route: EnhancementMergeRoute.settings),
        size: const Size(1100, 1000),
      );
      await tester.runAsync(() => c.read(charaDetailRecordStorageLoaderProvider.future));
      await tester.pump(const Duration(seconds: 1));
      await _shoot(tester, 'N16-merge-synced');
      await done(tester);
    });

    testWidgets('the delete confirmations with sync on, the archive and the storage warning', (tester) async {
      ProviderContainer container() {
        final c = ProviderContainer(
          overrides: [
            syncOnProvider.overrideWithValue(true),
            charaDetailRecordStorageLoaderProvider.overrideWith(
              () => _Shown([makeRecord(id: 'a', card: 1), makeRecord(id: 'b', card: 1)]),
            ),
            pathInfoProvider.overrideWithValue(_layout),
            pathLayoutProvider.overrideWithValue(_layout),
          ],
        );
        addTearDown(c.dispose);
        return c;
      }

      final shows = <(String, void Function(WidgetRef))>[
        ('delete-synced', (ref) => DeleteRecordDialog.show(ref.base, recordId: 'a')),
        (
          'bulk-delete-synced',
          (ref) {
            ref.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
            ref.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
            BulkDeleteRecordDialog.show(ref.base, recordIds: const ['a', 'b'], source: RecordSource.active);
          },
        ),
        ('archive', (ref) => ArchiveRecordDialog.show(ref.base, recordId: 'a')),
        (
          'storage-settings-warning',
          (ref) => CardDialog.show(
            ref.base,
            (_) => StorageDeleteConfirmDialog(
              group: storageGroupOf(StorageGroupId.settings),
              request: StorageDeleteSettingsRequest(storeDirectories: [_layout.settingsDir]),
              subject: 'settings',
            ),
          ),
        ),
      ];
      for (final (name, show) in shows) {
        final c = container();
        await _mount(tester, c, _Opener(show));
        await tester.runAsync(() => c.read(charaDetailRecordStorageLoaderProvider.future));
        await _open(tester);
        await _shoot(tester, 'changed-$name');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await done(tester);
    });
  });
}

// ---------------------------------------------------------------------------------------------------------------
// N15: the memo dialog, opened through a memo cell's own handler as the records table opens it.

const _memoKey = 'memo';

class _Memos extends CharaDetailRecordMemoController {
  _Memos(this.held) : super(_memoKey);

  final String held;

  @override
  Future<MemoData> build() async => MemoData(title: 'メモ', data: {'R1': held});
}

class _MemoCellTap extends ConsumerWidget {
  const _MemoCellTap();

  static const tapKey = Key('u10-memo');

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
    alignment: Alignment.topLeft,
    child: IconButton(
      key: tapKey,
      icon: const SizedBox.square(dimension: 8),
      onPressed: () {
        final spec = MemoColumnSpec(
          id: 'm',
          title: 'メモ',
          parser: EvaluationValueParser(),
          predicate: RegExpPredicate(),
          storageKey: _memoKey,
        );
        final cell = spec.cellBuilder(ref.base)(null);
        final row = TrinaRow(cells: {'m': cell})..setUserData(makeRecord(id: 'R1', card: 1));
        cell.getUserData<MemoCellData>()!.onSelected!(ref.base, TrinaGridOnSelectedEvent(row: row, cell: cell));
      },
    ),
  );
}
