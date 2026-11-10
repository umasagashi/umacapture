// Importing a record another person shared, from its link (N1 → N2), as a friend's record.
//
// Driven from the toolbar's link button and the dialog it opens, against a fake sharing server that answers the
// import endpoint (`GET /api/shares/<id>`) and the bundle (`GET /api/shares/<id>/images`) in the shapes the server
// answers them; the record store is the real one on a temporary directory, read back from disk.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_link_import_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/const.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/image_converter.dart';
import 'package:umacapture/src/chara_detail/record_binding.dart';
import 'package:umacapture/src/chara_detail/record_link_import.dart';
import 'package:umacapture/src/chara_detail/record_share.dart';
import 'package:umacapture/src/chara_detail/record_share_session.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/chara_detail/link_import_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/records.dart';
import 'support/riverpod.dart';
import 'support/settling.dart';

ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

/// One share as the fake server holds it: the import endpoint's answer (or a bare status), and the bundle's.
class _Share {
  Object answer;
  Object? bundle;

  _Share(this.answer, [this.bundle]);
}

/// The sharing server: the two GETs an import makes, answered from [shares] by the public id in the path; 404 for an
/// id it does not hold. Every request is recorded in [sent].
class _FakeServer implements HttpClientAdapter {
  final shares = <String, _Share>{};
  final sent = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add('${options.method} ${options.uri.path}');
    final match = RegExp(r'^/api/shares/([^/]+)(/images)?$').firstMatch(options.uri.path);
    final share = match == null ? null : shares[match[1]];
    var answer = share == null ? 404 : (match![2] == null ? share.answer : share.bundle ?? 404);
    if (answer is Future<Object>) answer = await answer;
    return switch (answer) {
      final int status => ResponseBody.fromString(jsonEncode({"error": "x"}), status),
      final Uint8List bytes => ResponseBody.fromBytes(bytes, 200),
      final Map<String, Object?> json => ResponseBody.fromString(
        jsonEncode(json),
        200,
        headers: {
          Headers.contentTypeHeader: ["application/json"],
        },
      ),
      _ => throw StateError('no answer of $answer'),
    };
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _jpeg(int shade, {int width = 24, int height = 16}) =>
    img.encodeJpg(img.Image(width: width, height: height)..clear(img.ColorRgb8(shade, 255 - shade, shade ~/ 2)));

Map<String, Object?> _rect(int x, int y, int x2, int y2) => {
  "top_left": {
    "x": x,
    "y": y,
    "anchor": {"h": "ScreenStart", "v": "ScreenStart"},
  },
  "bottom_right": {
    "x": x2,
    "y": y2,
    "anchor": {"h": "ScreenStart", "v": "ScreenStart"},
  },
};

/// A share's images as the server states and serves them: the parts in the bundle's order, the bundle, and the
/// `stored` state with its parts' sizes and SHA-256s.
({Map<String, Uint8List> parts, Map<String, Map<String, Object?>> rects, Uint8List bundle, Map<String, Object?> stored})
_images() {
  final parts = {'skill': _jpeg(10), 'factor': _jpeg(90), 'campaign': _jpeg(170), 'trainee': _jpeg(250, width: 8)};
  final rects = {'skill': _rect(1, 2, 20, 14), 'factor': _rect(3, 1, 22, 15), 'campaign': _rect(0, 0, 24, 16)};
  final bundle = Uint8List.fromList([for (final bytes in parts.values) ...bytes]);
  return (
    parts: parts,
    rects: rects,
    bundle: bundle,
    stored: {
      "state": "stored",
      "name": sha256.convert(bundle).toString(),
      "size": bundle.length,
      "parts": [
        for (final MapEntry(key: kind, value: bytes) in parts.entries)
          {
            "kind": kind,
            "size": bytes.length,
            "sha256": sha256.convert(bytes).toString(),
            "intersection": ?rects[kind],
          },
      ],
    },
  );
}

/// The import endpoint's answer for the share [id] of [record]: its posted form without `module_version`, as the
/// server stores and returns it, shared on [sharedOn], with [images].
Map<String, Object?> _answer(String id, CharaDetailRecord record, {Object? images, String sharedOn = '2026-11-08'}) {
  final form = postedForm(record, moduleVersion: '2026-09-30T11:00:00+0900')..remove('module_version');
  return {"schema": 1, "id": id, "shared_on": sharedOn, "record": form, "images": images};
}

void main() {
  setUpAll(initializeMappers);
  setUpAll(loadAppTranslations);
  useStorageBoxForTest();

  late Directory tempRoot;
  late _FakeServer server;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('uma_link_import');
    server = _FakeServer();
    await Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).clear();
  });
  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  DirectoryPath root() => DirectoryPath(tempRoot.path);
  PathInfo pathInfo() => PathInfo(
    documentDir: root(),
    supportDir: root(),
    executableDir: root() / 'exe',
    downloadDir: root() / 'dl',
    dataRoot: root(),
  );
  Directory activeDir() => Directory(pathInfo().charaDetailActiveDir.path);

  /// The record directories of the active store, by name.
  List<Directory> stored() => activeDir().existsSync()
      ? (activeDir().listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path)))
      : <Directory>[];

  /// Pumps the toolbar's link button under a built record store, and returns the container and the toasts.
  Future<({ProviderContainer container, List<ToastData> toasts})> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfo()),
        moduleVersionLoader.overrideWith((ref) async => null),
        recordShareDioProvider.overrideWith((ref) => Dio()..httpClientAdapter = server),
        linkImportRetryDelayProvider.overrideWithValue(Duration.zero),
      ],
    );
    // Built inside `runAsync`, and only then listened to: a provider first read in the fake-async zone builds there,
    // and its file reads never complete.
    await tester.runAsync(() async {
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
    });
    addTearDown(container.listen(charaDetailRecordStorageLoaderProvider, (_, _) {}).close);
    addTearDown(container.listen(charaDetailArchiveStorageLoaderProvider, (_, _) {}).close);
    final toasts = <ToastData>[];
    addTearDown(
      container
          .listen<AsyncValue<ToastData>>(plainToastEventProvider, (_, current) => current.whenData(toasts.add))
          .close,
    );
    await pumpWithContainer(
      tester,
      container,
      MaterialApp(
        theme: _theme(),
        home: DialogLayer(child: const Scaffold(body: CharaDetailLinkImportButton())),
      ),
    );
    return (container: container, toasts: toasts);
  }

  /// Opens the dialog where it is not open, pastes [link], presses the import button, and waits for the toast it
  /// ends with — every outcome ends with one — and for the dialog to stop importing.
  Future<ToastData> importLink(WidgetTester tester, List<ToastData> toasts, String link) async {
    if (find.byType(LinkImportDialog).evaluate().isEmpty) {
      await tester.tap(find.byType(CharaDetailLinkImportButton));
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), link);
    final before = toasts.length;
    await tester.tap(find.text(appSentenceAt('$tr_link_import.dialog.ok_button.label')));
    await settleUntilElapsing(
      tester,
      () => toasts.length > before && find.byType(LinearProgressIndicator).evaluate().isEmpty,
      describe: 'the link import to end with a toast',
      fakeStep: const Duration(milliseconds: 100),
    );
    return toasts[before];
  }

  String link(String id) => '${Const.sharingOrigin}/r/$id';

  testWidgets('a share imports as a friend record of no trainer, captured on its share day, read back unquarantined, '
      'with its images and their geometry where it carries them', (tester) async {
    final standard = recordFromFixture('a-source', '2026-01-02T03:04:05+0900');
    final inheritance = makeRecord(id: 'b-source', card: 777, recordType: RecordType.inheritanceOnly);
    final images = _images();
    server.shares['aaaaaaaaaa'] = _Share(_answer('aaaaaaaaaa', standard, images: images.stored), images.bundle);
    server.shares['bbbbbbbbbb'] = _Share(_answer('bbbbbbbbbb', inheritance, sharedOn: '2026-02-03'));
    final (:container, :toasts) = await pump(tester);

    final first = await importLink(tester, toasts, link('aaaaaaaaaa'));
    expect(first.type, ToastType.success);
    final second = await importLink(tester, toasts, '  ${link('bbbbbbbbbb')}.json  ');
    expect(second.type, ToastType.success);

    final dirs = stored();
    expect(dirs, hasLength(2));
    Map<String, Object?> rawOf(Directory dir) =>
        jsonDecode(File('${dir.path}/record.json').readAsStringSync()) as Map<String, Object?>;
    final byType = {for (final dir in dirs) (rawOf(dir)['metadata'] as Map)['record_type']: dir};
    // Written as the friend's types in record.json itself: a re-recognition reads the type from there.
    expect(byType.keys.toSet(), {'FriendStandard', 'FriendInheritance'});

    for (final (dir, source, sharedOn) in [
      (byType['FriendStandard']!, standard, '2026-11-08'),
      (byType['FriendInheritance']!, inheritance, '2026-02-03'),
    ]) {
      final record = CharaDetailRecord.fromRecordJson(File('${dir.path}/record.json').readAsStringSync());
      final id = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      expect(record.id, id);
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(record.metadata.trainerId, unknownTrainerId);
      expect(record.metadata.capturedDate, capturedDateOfSharedDay(sharedOn));
      expect(record.metadata.stage, RecordStage.active);
      expect(record.metadata.formatVersion, recordFormatVersion);
      expect(record.metadata.relationBonus, isNull);
      expect(record.metadata.region, source.metadata.region);
      expect(record.metadata.recognizerVersion, source.metadata.recognizerVersion);
      expect(record.isFriend, isTrue);
      // The body is the shared one: trainee and family with their icons, ranks and record types.
      expect(record.trainee, source.trainee);
      expect(record.family, source.family);
      expect(record.factors, source.factors);
      expect(record.skills, source.skills);
      expect(record.races, source.races);
      expect(record.trainedDate, source.trainedDate);
    }
    final day = DateTime(2026, 11, 8).timeZoneOffset;
    expect(capturedDateOfSharedDay('2026-11-08'), startsWith('2026-11-08T00:00:00${day.isNegative ? '-' : '+'}'));

    final withImages = byType['FriendStandard']!;
    final withImagesRecord = CharaDetailRecord.fromRecordJson(
      File('${withImages.path}/record.json').readAsStringSync(),
    );
    for (final kind in ['skill', 'factor', 'campaign']) {
      expect(File('${withImages.path}/$kind.jpg').readAsBytesSync(), images.parts[kind]);
      expect(
        File('${withImages.path}/$kind.json').readAsBytesSync(),
        geometryFileBytesOf(images.rects[kind]! as Map<String, dynamic>),
      );
      expect(File('${withImages.path}/$kind.png').existsSync(), isFalse);
    }
    expect(File('${withImages.path}/trainee.jpg').readAsBytesSync(), images.parts['trainee']);
    // The binding knows the JPEGs it was given and no PNG: the record cannot be re-recognized from them.
    final binding = withImagesRecord.metadata.binding!;
    expect(binding.skillJpeg, sha256.convert(images.parts['skill']!).toString());
    expect([binding.skillPng, binding.factorPng, binding.campaignPng], [null, null, null]);
    expect(withImagesRecord.metadata.icon, sha256.convert(images.parts['trainee']!).toString());
    final plain = byType['FriendInheritance']!;
    expect(plain.listSync().map((e) => e.uri.pathSegments.last).where(isRecordImageFile), isEmpty);

    // Read back by the store, not quarantined.
    final loaded = await tester.runAsync(() => container.read(charaDetailRecordStorageLoaderProvider.future));
    expect(loaded!.map((r) => r.id).toSet(), {
      for (final dir in dirs) dir.uri.pathSegments.where((s) => s.isNotEmpty).last,
    });
    expect(Directory(pathInfo().charaDetailQuarantineDir.path).existsSync(), isFalse);
  });

  testWidgets('a share declaring images saves nothing until its bundle is stored, fetched and matches, '
      'and the same link then brings the record with its images', (tester) async {
    final record = recordFromFixture('source', '2026-01-02T03:04:05+0900');
    final images = _images();
    final share = _Share(_answer('cccccccccc', record, images: {"state": "pending"}));
    server.shares['cccccccccc'] = share;
    final (:container, :toasts) = await pump(tester);

    Future<void> refusedWith(LinkImportRefusal reason) async {
      final toast = await importLink(tester, toasts, link('cccccccccc'));
      expect(toast.description, appSentenceAt(linkImportRefusalKey(reason)), reason: reason.name);
      expect(stored(), isEmpty, reason: '${reason.name} saved something');
      expect(find.byType(LinkImportDialog), findsOneWidget, reason: 'the link stays to try again');
    }

    // While the import runs, nothing closes the dialog: not the cancel button, nor a tap on the barrier.
    final held = Completer<Object>();
    share.answer = held.future;
    await tester.tap(find.byType(CharaDetailLinkImportButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), link('cccccccccc'));
    final before = toasts.length;
    await tester.tap(find.text(appSentenceAt('$tr_link_import.dialog.ok_button.label')));
    await settleUntilElapsing(
      tester,
      () => server.sent.isNotEmpty,
      describe: 'the import endpoint to be asked',
      fakeStep: const Duration(milliseconds: 100),
    );
    await tester.tap(find.text(appSentenceAt('$tr_link_import.dialog.cancel_button.label')), warnIfMissed: false);
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    expect(find.byType(LinkImportDialog), findsOneWidget, reason: 'the dialog was closed while the import ran');
    held.complete(_answer('cccccccccc', record, images: {"state": "pending"}));
    await settleUntilElapsing(
      tester,
      () => toasts.length > before && find.byType(LinearProgressIndicator).evaluate().isEmpty,
      describe: 'the held import to end',
      fakeStep: const Duration(milliseconds: 100),
    );
    expect(toasts[before].description, appSentenceAt(linkImportRefusalKey(LinkImportRefusal.imagesPending)));
    expect(stored(), isEmpty);

    await refusedWith(LinkImportRefusal.imagesPending);
    share.answer = _answer('cccccccccc', record, images: {"state": "unavailable"});
    await refusedWith(LinkImportRefusal.imagesUnavailable);
    share.answer = _answer('cccccccccc', record, images: images.stored);
    share.bundle = 502;
    await refusedWith(LinkImportRefusal.imagesUnreachable);
    final altered = Uint8List.fromList(images.bundle)..[images.parts['skill']!.length + 40] ^= 0xff;
    share.bundle = altered;
    await refusedWith(LinkImportRefusal.imagesUnreachable);

    share.bundle = images.bundle;
    final done = await importLink(tester, toasts, link('cccccccccc'));
    expect(done.type, ToastType.success);
    final dir = stored().single;
    expect(File('${dir.path}/factor.jpg').readAsBytesSync(), images.parts['factor']);
    expect(find.byType(LinkImportDialog), findsNothing, reason: 'an import that reached the store closes the dialog');
    expect(container.read(recordSharesProvider), isEmpty);
  });

  testWidgets('goes through the import zips take: the second import of the same share is refused as a duplicate '
      'with the zip import sentence', (tester) async {
    final record = recordFromFixture('source', '2026-01-02T03:04:05+0900');
    server.shares['dddddddddd'] = _Share(_answer('dddddddddd', record));
    final (container: _, :toasts) = await pump(tester);

    expect((await importLink(tester, toasts, link('dddddddddd'))).type, ToastType.success);
    final refused = await importLink(tester, toasts, link('dddddddddd'));
    expect(refused.type, ToastType.warning);
    expect(refused.description, appSentenceAt('$tr_import.refused.duplicate_of_existing').replaceAll('{count}', '1'));
    expect(stored(), hasLength(1));
    expect(find.byType(LinkImportDialog), findsOneWidget, reason: 'a refused record leaves the link to correct');
  });

  testWidgets('refuses, saving nothing, a link of another shape, an old share, the device\'s own share and a share '
      'the server does not hold', (tester) async {
    final record = recordFromFixture('source', '2026-01-02T03:04:05+0900');
    final old = _answer('eeeeeeeeee', record);
    (old['record'] as Map<String, Object?>)['trainee'] = {
      ...((old['record'] as Map)['trainee'] as Map)..remove('icon'),
    };
    server.shares['eeeeeeeeee'] = _Share(old);
    server.shares['ffffffffff'] = _Share(_answer('ffffffffff', record));
    final (:container, :toasts) = await pump(tester);
    await tester.runAsync(
      () => Hive.box(storageBoxNameOf(StorageBoxKey.recordShares)).put(
        'k',
        const RecordShare(
          recordId: 'mine',
          accountId: 'acct',
          clientKey: 'key',
          state: RecordShareState.shared,
          id: 'ffffffffff',
        ).toJson(),
      ),
    );
    container.invalidate(recordSharesProvider);

    for (final (text, reason) in [
      ('${Const.sharingOrigin}/u/aaaaaaaaaaaaaaaa', LinkImportRefusal.notALink),
      ('https://example.com/r/eeeeeeeeee', LinkImportRefusal.notALink),
      ('mailto:a@example.com', LinkImportRefusal.notALink),
      ('https:/r/eeeeeeeeee', LinkImportRefusal.notALink),
      ('${Const.sharingOrigin}/r/ILLEGALIDX', LinkImportRefusal.notALink),
      (link('eeeeeeeeee'), LinkImportRefusal.oldFormat),
      (link('ffffffffff'), LinkImportRefusal.ownShare),
      (link('gggggggggg'), LinkImportRefusal.notFound),
    ]) {
      final toast = await importLink(tester, toasts, text);
      expect(toast.description, appSentenceAt(linkImportRefusalKey(reason)), reason: text);
    }
    expect(stored(), isEmpty);
    // Nothing is fetched for a link of another shape, nor for the device's own share.
    expect(server.sent, ['GET /api/shares/eeeeeeeeee', 'GET /api/shares/gggggggggg']);
  });
}
