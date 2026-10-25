// Two devices and a server for the sync tests: each device a data directory of its own, holding real record
// directories and column storages, and the server an in-memory stand-in that refuses what `docs/sync-protocol.md` says
// the Worker refuses — object names that are not the SHA-256 of their bytes, a body without a binding, a row in the
// wrong part or whose image is not its body's binding, a part naming a body the account does not hold, a root
// replaced from a generation that is not current, a root that changes more slots than one replacement may
// ([FakeSyncServer.partsLimit]), and, where a test says so, one that would take too many requests to the bucket
// ([FakeSyncServer.tooManyObjects]).
//
// The devices are seeded through the files the app writes, never through the reader, so what the reader makes of them
// is what it makes of a real data directory. A device runs rounds through the app's own container
// ([SyncTestDevice.open]), which a test closes and opens again to restart the app — or, logged in to
// [syncTestAccount], asks for one as the app does, through its switch of sync ([SyncTestDevice.roundAsAsked]); the
// server answers every endpoint a round calls ([SyncServer]) — directly, or over HTTP through the device's own sync
// server ([SyncTestDevice.overHttp]) and the Worker's face over it (`sync_http_face.dart`) —, and a test turns a
// replacement through [FakeSyncServer.beforeReplace],
// [FakeSyncServer.refuseAsStale] and [FakeSyncServer.loseAnswer], and holds a request for bodies through
// [FakeSyncServer.beforeBodies]; a device's rating and memo writes are held or failed through
// [SyncTestDevice.beforeMetadataWrite]; the work on a record's binding is held through [SyncBindingGateFsBackend]. A
// round the app stops part way is one whose filesystem fails at a write and after it
// ([SyncStopFsBackend], [stoppedRound]). Between rounds a device changes what it holds through the app's own entries: a
// merge ([SyncTestDevice.merge] — every record seeded is the same uma, so any two are a candidate) and a dismissal, an
// export and an import, a re-recognition, and the storage view's delete of the dismissed pairs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/record_archive_state.dart';
import 'package:umacapture/src/chara_detail/record_binding.dart';
import 'package:umacapture/src/chara_detail/record_notes.dart';
import 'package:umacapture/src/chara_detail/record_share_session.dart';
import 'package:umacapture/src/chara_detail/record_sync.dart';
import 'package:umacapture/src/chara_detail/record_sync_list.dart';
import 'package:umacapture/src/chara_detail/record_sync_round.dart';
import 'package:umacapture/src/chara_detail/record_sync_server.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/chara_detail/value_write_time.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/fs_backend_io.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_delete_report.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/preference/settings_state.dart';
import 'package:umacapture/src/preference/storage_box.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';

import 'enhancement_merge_scratch.dart';
import 'long_read_declarations.dart';
import 'record_write_effects_fixture.dart';
import 'records.dart';
import 'settling.dart';

/// The account the devices are logged in to.
const syncTestAccount = 'account-1';

/// The key the switch of sync is kept under in the settings store.
final recordSyncKey = SettingsEntryKey.recordSyncAccount.name;

/// A session of [syncTestAccount].
class _LoggedIn extends RecordShareSession {
  @override
  ShareSession? build() =>
      const ShareSession(token: 'token', expiresAt: 4102444800000, accountId: syncTestAccount, deleting: false);
}

/// The container's own [Ref], which the platform controller takes.
final _refProvider = Provider<Ref>((ref) => ref);

/// One device: a data directory of its own.
class SyncTestDevice {
  SyncTestDevice(String name) : _temp = Directory.systemTemp.createTempSync('uma_sync_$name');

  final Directory _temp;

  /// The data root, as the app's `dataRoot`.
  DirectoryPath get root => DirectoryPath(_temp.path);

  PathInfo get info => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  DirectoryPath get charaDetail => info.charaDetailDir;

  ProviderContainer? _container;

  /// Awaited before each write of a rating or memo storage file the app makes through its controllers — an edit's save
  /// and a sync round's alike — where set before [open]: a test holds a write there, or fails it by throwing.
  Future<void> Function(FilePath path)? beforeMetadataWrite;

  /// The app over this data directory, its stores loaded: opened on first use, and again after [close].
  Future<ProviderContainer> open() async =>
      _container ??= await loadedMergeContainer(info: info, overrides: _overrides);

  /// The app over this data directory as it starts, before its stores have loaded: opened where it is not open.
  ProviderContainer start() => _container ??= makeMergeContainer(info: info, overrides: _overrides);

  /// The sharing server's side of this device's logins, where set before [open]: the device's session is then the
  /// app's own, which [login] and [logout] change as the user does, and none until the first [login]. Where unset, the
  /// device is logged in to [syncTestAccount] for good.
  FakeShareAuth? auth;

  /// The HTTP face of the sync server the device's own sync server ([syncServerProvider], [overHttp]) speaks to, and
  /// the deadline of each of its requests where it is not the app's ([syncRequestTimeoutProvider]); set before [open].
  HttpClientAdapter? syncHttp;
  Duration? syncRequestTimeout;

  /// The time the moments of a round tell ([syncMomentTimeProvider]) where it is not the app's; set before [open].
  SyncMomentTime? syncTime;

  /// The device's own sync server ([syncServerProvider]), under its session, speaking to [syncHttp].
  Future<SyncServer> overHttp() async =>
      (await open()).read<SyncServer?>(syncServerProvider) ?? fail('the device holds no session');

  /// The device is logged in to [syncTestAccount], or as [auth] says.
  List<Override> get _overrides => [
    pathLayoutLoader.overrideWith((ref) async => info),
    recordSyncDioProvider.overrideWithValue(Dio()..httpClientAdapter = syncHttp ?? const _NoNetwork()),
    if (syncRequestTimeout case final timeout?) syncRequestTimeoutProvider.overrideWithValue(timeout),
    if (syncTime case final time?) syncMomentTimeProvider.overrideWithValue(time),
    if (auth case final auth?) ...[
      recordShareDioProvider.overrideWithValue(Dio()..httpClientAdapter = auth),
      loginPageOpenerProvider.overrideWithValue((_) async => true),
      loginListenerBinderProvider.overrideWithValue(({required String h}) async => null),
    ] else
      recordShareSessionProvider.overrideWith(_LoggedIn.new),
    if (beforeMetadataWrite case final before?)
      metadataFileWriterProvider.overrideWithValue((path, contents) async {
        await before(path);
        await path.writeAsString(contents);
      }),
  ];

  /// Closes the app, as a restart does: what it held in memory is gone, and the next [open] reads the disk.
  void close() {
    _container?.dispose();
    _container = null;
  }

  /// One sync round of this device against [server], as the app runs it; [bindingChunk] as [runSyncRound] takes it.
  Future<SyncRoundOutcome> round(SyncServer server, {int bindingChunk = syncBindingChunk}) async {
    final ref = (await open()).read(containerRefProvider);
    return runSyncRound(
      ref,
      server,
      account: syncTestAccount,
      effects: recordImportEffects(ref),
      bindingChunk: bindingChunk,
    );
  }

  /// Turns this device's sync on or off, as the user does ([RecordSync.setOn]). The switch is kept in the settings
  /// store, which every device of a test shares: a test that turns it on turns it off again when it ends.
  Future<void> setSyncOn(bool on) async {
    if (on) {
      addTearDown(() => StorageEntry<String>(box: StorageBox(StorageBoxKey.settings), key: recordSyncKey).delete());
    }
    await (await open()).read(recordSyncProvider.notifier).setOn(on);
  }

  /// Sets the account's image form to [form] on [server], as the user does on this device ([RecordSync.setImageForm]).
  Future<void> setImageForm(SyncServer server, String form) async =>
      (await open()).read(recordSyncProvider.notifier).setImageForm(server, form);

  /// The app's moments of a round, alive from now on ([recordSyncTriggersProvider]), as the app reads them at its
  /// start — which asks for the round of the start.
  Future<void> startTriggers() async => (await open()).read(recordSyncTriggersProvider);

  /// One sync round against [server], asked for as the app asks for one ([RecordSync.round]); null where none runs.
  Future<SyncRoundOutcome?> roundAsAsked(SyncServer server) async =>
      (await open()).read(recordSyncProvider.notifier).round(server);

  /// The user syncs now against [server] ([RecordSync.syncNow]): the device's mark of being stopped for room comes
  /// down, and a round runs as [roundAsAsked] runs one; with sync on ([setSyncOn]) it is the round's outcome.
  Future<SyncRoundOutcome> syncNow(SyncServer server) async =>
      (await (await open()).read(recordSyncProvider.notifier).syncNow(server)) ??
      (fail('no round ran: is sync on on this device?'));

  /// The user logs in to [account] through the app's login ([RecordShareSession.beginLogin], [LoginAttempt.claim]),
  /// against [auth]. The session is kept in the settings store, which every device of a test shares: the test's end
  /// drops it.
  Future<void> login(String account) async {
    addTearDown(() => StorageBox(StorageBoxKey.recordShares).delete(shareSessionKey));
    auth!.account = account;
    final attempt = await (await open()).read(recordShareSessionProvider.notifier).beginLogin();
    expect(await attempt.claim(), LoginOutcome.signedIn);
  }

  /// The user logs out through the app's logout ([RecordShareSession.logout]), against [auth].
  Future<void> logout() async =>
      expect(await (await open()).read(recordShareSessionProvider.notifier).logout(), isTrue);

  void dispose() {
    close();
    if (_temp.existsSync()) _temp.deleteSync(recursive: true);
  }

  /// Writes the record [id] into [store] as the app stores it: `record.json` from the shared fixture with the given
  /// metadata — [geometry] and [icon] as `metadata.geometry` and `metadata.icon` are, the JSON a body carries —,
  /// `archive.json` where a time or archived state is given, `merged_ids.json` where it absorbed records.
  ///
  /// Every record seeded is the same uma, so any two are a merge candidate ([merge]); [fans] gives one a body of its
  /// own without making it another uma, and [capturedDate] decides which of two is the older. [parentOfTheOthers]
  /// makes it instead the uma every other seeded record names as its first parent — the card and factors the fixture
  /// gives that parent — which an inheritance resolution links them to.
  DirectoryPath seedRecord(
    String id, {
    String store = 'active',
    RecordBinding? binding,
    Map<String, Object?>? geometry,
    String? icon,
    int? bodyWrittenAt,
    String? parent1,
    String? parent2,
    int? relationBonus,
    Set<String> absorbed = const {},
    int? normalWrittenAt,
    ({RecordArchiveState state, int writtenAt})? archived,
    int? fans,
    String capturedDate = '2026-01-01T00:00:00',
    bool parentOfTheOthers = false,
  }) {
    final map = recordFromFixture(id, capturedDate).toMap();
    if (fans != null) map['fans'] = fans;
    if (parentOfTheOthers) {
      (map['trainee'] as Map<String, dynamic>)['card'] = map['family']['parent1']['self']['card'];
      (map['factors'] as Map<String, dynamic>)['self'] = map['factors']['parent1'];
    }
    final metadata = (map['metadata'] as Map<String, dynamic>)
      ..['record_id'] = {'self': id, 'parent1': ?parent1, 'parent2': ?parent2}
      ..['binding'] = binding?.toMap()
      ..['geometry'] = geometry
      ..['icon'] = icon
      ..['body_written_at'] = bodyWrittenAt
      ..['relation_bonus'] = relationBonus;
    metadata.removeWhere((_, value) => value == null);
    final dir = charaDetail / store / id;
    Directory(dir.path).createSync(recursive: true);
    File(dir.filePath('record.json').path).writeAsBytesSync(CharaDetailRecordMapper.fromMap(map).toRecordJsonBytes());
    if (normalWrittenAt != null || archived != null) {
      File(dir.filePath(recordArchiveNoteName).path).writeAsStringSync(
        jsonEncode({
          'normal_written_at': ?normalWrittenAt,
          if (archived != null) 'archived': {'state': archived.state.name, 'written_at': archived.writtenAt},
        }),
      );
    }
    if (absorbed.isNotEmpty) {
      File(dir.filePath(mergedIdsFileName).path).writeAsStringSync(jsonEncode(absorbed.toList()..sort()));
    }
    return dir;
  }

  /// Writes the rating or memo column storage [key] of [storage] as its controller does.
  void seedColumn(
    String storage,
    String key, {
    required String title,
    int? titleWrittenAt,
    bool titleCleared = false,
    Map<String, Object> data = const {},
    Map<String, int> writtenAt = const {},
  }) {
    final dir = storage == 'rating' ? info.charaDetailRatingDir : info.charaDetailMemoDir;
    final contents = storage == 'rating'
        ? RatingData(
            title: title,
            data: data.cast<String, double>(),
            writtenAt: {...writtenAt},
            titleWrittenAt: titleWrittenAt,
            titleCleared: titleCleared,
          ).toJson()
        : MemoData(
            title: title,
            data: data.cast<String, String>(),
            writtenAt: {...writtenAt},
            titleWrittenAt: titleWrittenAt,
            titleCleared: titleCleared,
          ).toJson();
    File(dir.filePath('$key.json').path)
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  /// Writes the dismissed pairs as the merge's dismissal does.
  void seedDismissed(Iterable<(String, String)> pairs) {
    File(info.charaDetailEnhancementDismissedFile.path)
      ..createSync(recursive: true)
      ..writeAsStringSync(dismissedPairsJson([for (final (a, b) in pairs) RecordIdPair(a, b)]));
  }

  /// What the reader reads of this device: everything, or given what it read before, those [records] again.
  Future<LocalSyncRead> read({LocalSyncRead? previous, Set<String>? records, RecordRecoveryGate? gate}) =>
      readLocalSyncList(info, gate: gate ?? platformRecordRecoveryGate, previous: previous, records: records);

  /// The body object of the record [id] in [store], as the device sends it.
  String bodyOf(String id, {String store = 'active'}) =>
      utf8.decode(syncBodyBytes(File((charaDetail / store / id).filePath('record.json').path).readAsBytesSync()));

  Future<ProviderContainer> _loaded() async {
    final container = await open();
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    return container;
  }

  /// The merge of [newer] into [older] the merge dialog makes, keeping [keep]'s body (the two are the same uma, so the
  /// dialog offers the choice) and [choices]; what it writes is at [valueWriteClock]'s time.
  Future<void> merge(
    String older,
    String newer, {
    required String keep,
    EnhancementMergeChoices choices = const EnhancementMergeChoices(),
  }) async {
    final container = await _loaded();
    final candidates = candidatesIn(container);
    final candidate = candidates.singleWhere(
      (c) => c.olderId == older && c.newerId == newer,
      orElse: () => fail('no candidate $older/$newer in ${[for (final c in candidates) '${c.olderId}/${c.newerId}']}'),
    );
    final merged = await container
        .read(enhancementMergeProvider)
        .merge(candidate, keptContentId: keep, choices: choices, effects: mergeEffects(container));
    expect(merged.outcome, EnhancementMergeOutcome.merged, reason: 'the merge of $newer into $older');
  }

  /// Takes the candidate pair [a] and [b] out of the candidates, as the merge dialog's dismissal does.
  Future<void> dismiss(String a, String b) async {
    final container = await _loaded();
    final candidate = candidatesIn(container).singleWhere((c) => {c.olderId, c.newerId}.containsAll({a, b}));
    expect(
      await container.read(enhancementDismissalStoreProvider).dismiss(candidate),
      EnhancementDismissOutcome.dismissed,
    );
  }

  /// The zip the export makes of the record [id] in [store].
  Future<Uint8List> exportZip(String id, {String store = 'active'}) async {
    final container = await _loaded();
    return RecordZipService.export(
      [charaDetail / store / id],
      ref: container.read(containerRefProvider),
      declaration: undeclaredInTest,
    );
  }

  /// Imports [zip] as the import button does, but for the button's duplicate rule: that rule refuses a record that is
  /// the same uma as one stored under another id, which every record [seedRecord] writes is.
  Future<void> importZip(Uint8List zip) async {
    final container = await _loaded();
    final ref = container.read(containerRefProvider);
    final imported = await RecordZipService.import(zip, info.storageDir);
    expect(imported.refusals, isEmpty);
    applyRecordsPublished(ref, info, writtenIds: imported.recordIds, effects: recordImportEffects(ref));
    await _loaded();
  }

  /// Recognises the record [id] again as the desktop app takes the result in: the recognizer's result — the shared
  /// recognized fixture, with [edit] applied — left beside the record, and announced with `onCharaDetailUpdated`
  /// through the real dispatch.
  Future<void> recognizeAgain(String id, void Function(Map<String, dynamic> result) edit) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PlatformChannel.channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(PlatformChannel.channel, null));
    final container = await _loaded();
    final result = (jsonDecode(File('test/fixtures/recognized.json').readAsStringSync()) as Map)
        .cast<String, dynamic>();
    // The recognizer reads the record's own directory, and names the record by it.
    (result['metadata'] as Map)['record_id'] = {'self': id};
    edit(result);
    File((charaDetail / 'active' / id).filePath('recognized.json').path).writeAsStringSync(jsonEncode(result));
    final regeneration = container.read(charaDetailRecordRegenerationControllerProvider.notifier)..beginBatch(1);
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
    controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailUpdated', 'id': id}));
    await waitUntil(
      () => regeneration.successCount + regeneration.failureCount == 1,
      describe: 'the re-recognition of $id to be counted',
    );
    expect(regeneration.successCount, 1, reason: 'the re-recognition of $id');
    await _loaded();
  }

  /// Deletes the dismissed pairs' file in the storage view.
  Future<void> deleteDismissedFile() async {
    await deleteMetadata(StorageDeletePathsRequest([info.charaDetailEnhancementDismissedFile]));
  }

  /// Deletes what [request] names from the metadata group in the storage view — the group row's request when null.
  Future<StorageDeleteReport> deleteMetadata([StorageDeleteRequest? request]) {
    final group = storageGroupOf(StorageGroupId.metadata);
    return deleteInStorageView(
      StorageGroupId.metadata,
      request ?? storageGroupDeleteRequest(info, group, onWeb: false)!,
    );
  }

  /// Deletes what [request] names from the group [group] in the storage view.
  Future<StorageDeleteReport> deleteInStorageView(StorageGroupId group, StorageDeleteRequest request) async {
    final container = await _loaded();
    return runStorageDelete(
      container.read(containerRefProvider),
      effects: storageDeleteEffects(container),
      group: storageGroupOf(group),
      request: request,
      silent: true,
    );
  }

  /// The quarantine shelf's directory.
  DirectoryPath get shelf => info.charaDetailQuarantineDir;

  /// The `record.json` of the record [id] is torn, as a save cut short leaves it, and the app starts again: its scan
  /// moves the record onto the quarantine shelf. Answers the bytes it held, to repair it with ([repairQuarantined]).
  Future<Uint8List> breakRecord(String id, {String store = 'active'}) async {
    close();
    final file = File((charaDetail / store / id).filePath('record.json').path);
    final bytes = file.readAsBytesSync();
    file.writeAsStringSync('{"id": "$id", "cut short');
    await open();
    return bytes;
  }

  /// The `record.json` of the record [id] on the quarantine shelf is written back from outside the app as [bytes], and
  /// the app starts again: its scan puts the record back.
  Future<void> repairQuarantined(String id, Uint8List bytes) async {
    close();
    File((shelf / id).filePath('record.json').path).writeAsBytesSync(bytes);
    await open();
  }
}

/// The network a device of the tests reaches where its sync server is not given one ([SyncTestDevice.syncHttp]):
/// none.
class _NoNetwork implements HttpClientAdapter {
  const _NoNetwork();

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw StateError('a device of the tests reaches no network: ${options.method} ${options.uri}');

  @override
  void close({bool force = false}) {}
}

/// The time the moments of a round tell ([SyncMomentTime]), held by the test: the clock it sets ([now]), and each
/// timer started ([timers]), which it fires ([HeldTimer.fire]).
class HeldSyncTime {
  DateTime now = DateTime.utc(2030);

  /// Every timer started, the first first.
  final timers = <HeldTimer>[];

  SyncMomentTime get time => SyncMomentTime(
    now: () => now,
    timer: (duration, callback) {
      final timer = HeldTimer(duration, callback);
      timers.add(timer);
      return timer;
    },
  );
}

/// A timer of [HeldSyncTime]: it runs [_callback] when the test fires it, where it was not cancelled.
class HeldTimer implements Timer {
  HeldTimer(this.duration, this._callback);

  /// The time it was started for.
  final Duration duration;
  final void Function() _callback;
  var _active = true;

  /// Runs it, as its time coming does.
  void fire() {
    expect(_active, isTrue, reason: 'a timer that was cancelled, or has run, does not run');
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}

/// The sharing server's answers to a device's logins and logouts, as the Worker gives them: a claim signs in to
/// [account], a trainer id is registered, a logout ends the session.
class FakeShareAuth implements HttpClientAdapter {
  /// The account the next claim signs in to.
  String account = syncTestAccount;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    ResponseBody json(Map<String, Object?> body) => ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
    return switch (options.uri.path) {
      '/api/auth/claim' => json({
        'token': 'token-$account',
        'expires_at': 4102444800000,
        'account_id': account,
        'deleting': false,
      }),
      '/api/me/trainers' => json({}),
      '/api/auth/logout' => ResponseBody.fromString('', 204),
      final path => throw StateError('the sharing server of the test answers no $path'),
    };
  }

  @override
  void close({bool force = false}) {}
}

/// A request whose answer did not arrive.
class FakeSyncAnswerLost implements Exception {
  @override
  String toString() => 'FakeSyncAnswerLost';
}

/// One account's sync on the server.
class FakeSyncServer implements SyncServer {
  int generation = 0;
  String? rootName;

  /// Runs as a replacement arrives, before the server weighs it: another device's round, or a gate the test holds.
  Future<void> Function()? beforeReplace;

  /// Runs as a request for bodies arrives, before the server answers it, with the names asked for: a gate the test
  /// holds. Answers the names the server is to say it does not hold.
  Future<Set<String>> Function(List<String> names)? beforeBodies;

  /// The names whose body the server answers with another object than the one the name names: a bucket that holds a
  /// stored object wrong, which a device tells by the name it computes.
  Set<String> answeredWrong = {};

  /// How many replacements still to come the server refuses as stale, changing nothing.
  int refuseAsStale = 0;

  /// Whether the next replacement the server makes loses its answer: made, and the device told nothing.
  bool loseAnswer = false;

  /// Every replacement asked of the server, made or not.
  int replacementsAsked = 0;

  /// The slots of the root one replacement may change: more is refused as `too_many_parts`, as the Worker refuses it.
  int partsLimit = 4;

  /// Whether the server refuses a replacement that changes [slots] slots as `too_many_objects`: the requests to the
  /// bucket it would take, which depend on what the bucket holds, not on the replacement alone.
  bool Function(int slots)? tooManyObjects;

  /// The slots each replacement made changed, in order.
  final slotsChanged = <int>[];

  /// The `error` the server refuses a put of new bytes with for want of room (`507`), as the Worker refuses it: a put of
  /// bodies that names one the server does not hold is refused whole, and stores none of them. Null where it has room.
  String? noRoom;

  /// How many puts of bodies the server refused for room ([noRoom]).
  int refusedForRoom = 0;

  /// The UTC day of the clock the app writes by ([valueWriteClock]) whose daily limit is all but used up
  /// ([limitTheDay]), and how many puts of new bytes it takes still; none where no day is limited.
  ({int day, int left, String scope})? _limited;

  /// How many puts the server refused for the day ([limitTheDay]).
  int refusedForTheDay = 0;

  /// Of the UTC day the clock is in now, the server takes [puts] more puts of new bytes — a put of bodies that names
  /// one it does not hold, a put of an image it does not hold —, and refuses each after them `429 daily_limit` of the
  /// limit [scope] names (`account` or `service`), with the seconds to the next UTC day, as the Worker refuses them once
  /// what is left of a daily limit is the reserve. A refused put counts against none; the next day has room.
  void limitTheDay(int puts, {String scope = 'account'}) =>
      _limited = (day: valueWriteClock() ~/ Duration.millisecondsPerDay, left: puts, scope: scope);

  /// Counts a put of new bytes against the day's limit ([limitTheDay]), or refuses it.
  void _countPut() {
    final now = valueWriteClock();
    final day = now ~/ Duration.millisecondsPerDay;
    final limited = _limited;
    if (limited == null || limited.day != day) return;
    if (limited.left <= 0) {
      refusedForTheDay++;
      throw SyncRefusal.dailyLimit(((day + 1) * Duration.millisecondsPerDay - now) ~/ 1000, scope: limited.scope);
    }
    _limited = (day: day, left: limited.left - 1, scope: limited.scope);
  }

  final _bodies = <String, String>{};
  final _bodyBindings = <String, Map<String, Object?>>{};
  final _bodyIcons = <String, String?>{};

  /// Every body the server holds, by name.
  Map<String, String> get storedBodies => Map.unmodifiable(_bodies);

  /// The icon a body or a row names, as the Worker reads it: an image name, null where it names none, and not one
  /// ([_notAnIcon]) where the value is neither.
  static Object? _icon(Object? json) =>
      json == null || (json is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(json)) ? json : _notAnIcon;
  static const _notAnIcon = Object();
  final _parts = <String, String>{};
  final _roots = <String, String>{};

  static const _bindingKeys = {'campaign_png', 'campaign_jpeg', 'factor_png', 'factor_jpeg', 'skill_png', 'skill_jpeg'};

  static String _nameOf(String text) => syncObjectName(utf8.encode(text));

  static Map<String, Object?>? _binding(Object? json) {
    if (json is! Map<String, Object?> || json.keys.any((key) => !_bindingKeys.contains(key))) return null;
    if (json.values.any((value) => value != null && (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)))) {
      return null;
    }
    return {for (final key in _bindingKeys) key: json[key]};
  }

  /// Whether the operator switched sync off (`SYNC_ENABLED=false`): the Worker then refuses every sync request
  /// `503 sync_paused`, and the fake refuses the one a round asks first, the generation.
  bool paused = false;

  @override
  Future<({int generation, String? root})> readGeneration() async {
    if (paused) throw const SyncRefusal(503, 'sync_paused');
    return (generation: generation, root: rootName);
  }

  /// How many times a root was read: a round reads the list only where the generation moved from its base's.
  int rootsRead = 0;

  @override
  Future<String> root(String name) async {
    rootsRead++;
    return _roots[name] ?? (throw const SyncRefusal(404, 'not_found'));
  }

  @override
  Future<String> part(String name) async => _parts[name] ?? (throw const SyncRefusal(404, 'not_found'));

  @override
  Future<List<({String name, String body})>> bodies(List<String> names) async {
    final withheld = await beforeBodies?.call(names) ?? const <String>{};
    final missing = [
      for (final name in names)
        if (!_bodies.containsKey(name) || withheld.contains(name)) name,
    ];
    if (missing.isNotEmpty) throw SyncRefusal(404, 'not_found', missing);
    return [
      for (final name in names) (name: name, body: answeredWrong.contains(name) ? '${_bodies[name]} ' : _bodies[name]!),
    ];
  }

  /// `POST /api/sync/bodies`.
  @override
  Future<List<String>> putBodies(List<({String name, String body})> bodies) async {
    if (bodies.isEmpty || bodies.length > 10) throw const SyncRefusal(400, 'invalid_payload', 'bodies');
    for (final (i, body) in bodies.indexed) {
      if (body.name != _nameOf(body.body)) throw SyncRefusal(400, 'invalid_payload', 'bodies[$i].name');
      final decoded = jsonDecode(body.body);
      final binding = decoded is Map<String, Object?> ? _binding((decoded['metadata'] as Map?)?['binding']) : null;
      if (binding == null) throw SyncRefusal(400, 'invalid_payload', 'bodies[$i].body');
      if (identical(_icon((decoded as Map)['metadata']['icon']), _notAnIcon)) {
        throw SyncRefusal(400, 'invalid_payload', 'bodies[$i].body');
      }
    }
    if (bodies.any((body) => !_bodies.containsKey(body.name))) {
      if (noRoom case final error?) {
        refusedForRoom++;
        throw SyncRefusal(507, error);
      }
      _countPut();
    }
    return [for (final body in bodies) _storeBody(body.name, body.body)];
  }

  String _storeBody(String name, String body) {
    final status = _bodies.containsKey(name) ? 'exists' : 'stored';
    _bodies[name] = body;
    _bodyBindings[name] = _binding((jsonDecode(body) as Map)['metadata']['binding'])!;
    _bodyIcons[name] = (jsonDecode(body) as Map)['metadata']['icon'] as String?;
    return status;
  }

  /// `POST /api/sync/parts`.
  @override
  Future<String> putPart(String name, String text) async {
    if (name != _nameOf(text)) throw const SyncRefusal(400, 'invalid_payload', 'name');
    final part = jsonDecode(text) as Map<String, Object?>;
    if (part['format'] != 1) throw const SyncRefusal(400, 'invalid_payload', 'part.format');
    final number = part['part'];
    if (number == 'columns' || number == 'dismissed') {
      if (part.keys.toSet().difference({'format', 'part', 'content'}).isNotEmpty || !part.containsKey('content')) {
        throw const SyncRefusal(400, 'invalid_payload', 'part');
      }
    } else {
      if (number is! int || number < 0 || number > 127) {
        throw const SyncRefusal(400, 'invalid_payload', 'part.part');
      }
      final records = part['records'];
      if (records is! List ||
          records.isEmpty ||
          part.keys.toSet().difference({'format', 'part', 'records'}).isNotEmpty) {
        throw const SyncRefusal(400, 'invalid_payload', 'part.records');
      }
      final ids = <String>{};
      final missing = <String>[];
      for (final (i, row) in records.indexed) {
        if (row is! Map<String, Object?>) throw SyncRefusal(400, 'invalid_payload', 'part.records[$i]');
        final id = row['id'];
        if (id is! String || id.isEmpty || id.length > 128 || syncRecordPartOf(id) != number || !ids.add(id)) {
          throw SyncRefusal(400, 'invalid_payload', 'part.records[$i].id');
        }
        final bodyName = (row['body'] as Map?)?['name'];
        if (bodyName is! String) throw SyncRefusal(400, 'invalid_payload', 'part.records[$i].body');
        if (!{'normal', 'jpeg', 'none'}.contains((row['archive'] as Map?)?['state'])) {
          throw SyncRefusal(400, 'invalid_payload', 'part.records[$i].archive');
        }
        final image = _binding(row['image']);
        final bodyBinding = _bodyBindings[bodyName];
        if (bodyBinding == null) {
          missing.add(bodyName);
        } else if (image == null || image.toString() != bodyBinding.toString()) {
          throw SyncRefusal(400, 'invalid_payload', 'part.records[$i].image');
        } else if (_icon(row['icon']) != _bodyIcons[bodyName]) {
          throw SyncRefusal(400, 'invalid_payload', 'part.records[$i].icon');
        }
      }
      if (missing.isNotEmpty) throw SyncRefusal(409, 'missing_objects', missing);
    }
    final status = _parts.containsKey(name) ? 'exists' : 'stored';
    _parts[name] = text;
    return status;
  }

  /// `POST /api/sync/root`; answers the new generation.
  @override
  Future<int> replaceRoot(int from, String name, String text) async {
    replacementsAsked++;
    await beforeReplace?.call();
    if (refuseAsStale > 0) {
      refuseAsStale--;
      throw SyncRefusal(409, 'stale_generation', generation);
    }
    if (name != _nameOf(text)) throw const SyncRefusal(400, 'invalid_payload', 'name');
    final root = jsonDecode(text) as Map<String, Object?>;
    if (root['format'] != 1 || root.keys.toSet().difference({'format', 'parts'}).isNotEmpty) {
      throw const SyncRefusal(400, 'invalid_payload', 'root');
    }
    final missing = <String>[];
    for (final MapEntry(key: slot, :value) in (root['parts'] as Map<String, Object?>).entries) {
      final number = int.tryParse(slot);
      if ((number == null || number < 0 || number > 127) && slot != 'columns' && slot != 'dismissed') {
        throw SyncRefusal(400, 'invalid_payload', 'root.parts.$slot');
      }
      final part = _parts[value];
      if (part == null) {
        missing.add(value as String);
      } else if ((jsonDecode(part) as Map)['part'].toString() != slot) {
        throw SyncRefusal(400, 'invalid_payload', 'root.parts.$slot');
      }
    }
    if (missing.isNotEmpty) throw SyncRefusal(409, 'missing_objects', missing);
    if (from != generation) throw SyncRefusal(409, 'stale_generation', generation);
    final old = rootName == null ? const <String, Object?>{} : (jsonDecode(_roots[rootName]!) as Map)['parts'] as Map;
    final slots = root['parts'] as Map<String, Object?>;
    final changed = {...old.keys, ...slots.keys}.where((slot) => old[slot] != slots[slot]).length;
    if (changed > partsLimit) throw SyncRefusal(400, 'too_many_parts', partsLimit);
    if (tooManyObjects?.call(changed) ?? false) throw const SyncRefusal(409, 'too_many_objects');
    slotsChanged.add(changed);
    _roots[name] = text;
    rootName = name;
    ++generation;
    if (loseAnswer) {
      loseAnswer = false;
      throw FakeSyncAnswerLost();
    }
    return generation;
  }

  /// The text of every part the current root names.
  List<String> currentParts() => rootName == null
      ? const []
      : [for (final name in (jsonDecode(_roots[rootName]!)['parts'] as Map).values) _parts[name]!];

  /// The account's image form (`GET /api/sync/settings`): `png`, `jpeg` or `none`, which it is until the test sets one.
  String form = 'none';

  /// The images the account holds, by name.
  final images = <String, Uint8List>{};

  /// Runs as an image put arrives, before the server weighs it, with the image's name: a gate the test holds, or a
  /// connection that drops (it throws).
  Future<void> Function(String name)? beforeImagePut;

  /// The names asked of `POST /api/sync/held`, each request's.
  final heldAsked = <List<String>>[];

  @override
  Future<String> imageForm() async => form;

  /// `PUT /api/sync/settings`: the account's image form, from now on.
  @override
  Future<void> putImageForm(String form) async => this.form = form;

  /// Runs once an image put the server stored, or held already, answers, with the image's name.
  Future<void> Function(String name)? afterImagePut;

  /// `POST /api/sync/held`: the names of [names] the account holds.
  @override
  Future<Set<String>> held(List<String> names) async {
    if (names.isEmpty || names.length > 1000) throw const SyncRefusal(400, 'invalid_payload', 'names');
    heldAsked.add([...names]);
    return {
      for (final name in names)
        if (images.containsKey(name)) name,
    };
  }

  /// `PUT /api/sync/images/<name>`: an image whose bytes do not hash to its name is refused as the bucket refuses it,
  /// one the account holds is there already, and under the form `none` a new one is refused but the reduced JPEG an
  /// archive puts in place of a PNG the account holds, which a row of the current root archived as reduced JPEG names
  /// with that PNG (`docs/sync-protocol.md`).
  @override
  Future<void> putImage(String name, Uint8List bytes, {required bool jpeg}) async {
    await beforeImagePut?.call(name);
    if (syncObjectName(bytes) != name) throw const SyncRefusal(502, 'storage_refused');
    if (!images.containsKey(name)) {
      if (form == 'none' && !(jpeg && _replacements().contains(name))) {
        throw const SyncRefusal(409, 'images_not_synced');
      }
      _countPut();
      images[name] = bytes;
    }
    await afterImagePut?.call(name);
  }

  /// `GET /api/sync/images/<name>`: the bytes of an image the account holds and its current root references; null,
  /// for `404 not_found`, otherwise.
  @override
  Future<Uint8List?> image(String name) async => _referenced().contains(name) ? images[name] : null;

  /// The rows of the current root's record parts.
  Iterable<Map<String, Object?>> _rows() sync* {
    for (final text in currentParts()) {
      final part = jsonDecode(text) as Map<String, Object?>;
      if (part['records'] case final List<Object?> records) yield* records.cast<Map<String, Object?>>();
    }
  }

  /// Of a row's binding, each image's PNG and reduced JPEG name.
  static Iterable<({String? png, String? jpeg})> _imagesOf(Map<String, Object?> row) {
    final binding = (row['image'] as Map<String, Object?>?) ?? const {};
    return [
      for (final image in recordBindingImages)
        (png: binding['${image}_png'] as String?, jpeg: binding['${image}_jpeg'] as String?),
    ];
  }

  static String? _stateOf(Map<String, Object?> row) => (row['archive'] as Map<String, Object?>?)?['state'] as String?;

  /// What the current root references of images: every image a normal row names; of a row archived as reduced JPEG,
  /// each image's JPEG, and its PNG only while the account holds no JPEG of it; and the icon either names (`icon`); none
  /// of a row archived without images.
  Set<String> _referenced() => {
    for (final row in _rows()) ...[
      for (final (:png, :jpeg) in _imagesOf(row))
        ...switch (_stateOf(row)) {
          'normal' => [?png, ?jpeg],
          'jpeg' => [?jpeg, if (jpeg == null || !images.containsKey(jpeg)) ?png],
          _ => const <String>[],
        },
      if (_stateOf(row) case 'normal' || 'jpeg') ?(row['icon'] as String?),
    ],
  };

  /// The reduced JPEGs the account takes under the form `none`: of each row of the current root archived as reduced
  /// JPEG, the JPEG of an image whose PNG the account holds.
  Set<String> _replacements() => {
    for (final row in _rows())
      if (_stateOf(row) == 'jpeg')
        for (final (:png, :jpeg) in _imagesOf(row))
          if (png != null && images.containsKey(png)) ?jpeg,
  };

  /// `POST /api/sync/bodies/get`, for one body.
  String? body(String name) => _bodies[name];
}

/// The filesystem as the app writes through it, stopping the app at one write: the first write that reaches the
/// [stopAt]th of the marks [markOf] names is held until the test lets it go ([stop]), and then fails, as does every write
/// after it — the app stops there, as a crash stops it, and nothing after it reaches the disk. Reads go through. Let go
/// with [go] instead, the held write and every one after it land: a write held as long as the test wants.
class SyncStopFsBackend implements FsBackend {
  SyncStopFsBackend(this.inner, {required this.markOf, this.stopAt = 1});

  /// Marks the record directories of [ids] in either store, by id.
  static String? Function(String path) recordsOf(Set<String> ids) => (path) {
    final id = RegExp(r'[/\\]chara_detail[/\\](?:active|archive)[/\\]([^/\\]+)').firstMatch(path)?.group(1);
    return ids.contains(id) ? id : null;
  };

  /// Marks the base the round keeps ([syncBaseFile]), as `base`.
  static String? baseOf(String path) => RegExp(r'[/\\]sync[/\\]base\.json').hasMatch(path) ? 'base' : null;

  final FsBackend inner;
  final String? Function(String path) markOf;
  final int stopAt;

  final _reached = <String>{};
  final _held = Completer<String>();
  final _go = Completer<void>();
  var _stopped = false;

  /// The mark of the write held, once one is.
  Future<String> get held => _held.future;

  /// Lets the held write go, failing.
  void stop() => _go.complete();

  /// Lets the held write go on, landing, and every write after it.
  void go() {
    _through = true;
    _go.complete();
  }

  var _through = false;

  bool _stops(List<String> paths) {
    if (_through) return false;
    if (_stopped) return true;
    final marks = {for (final path in paths) ?markOf(path)};
    _reached.addAll(marks);
    if (marks.isEmpty || _reached.length < stopAt) return false;
    _stopped = true;
    _held.complete(marks.first);
    return true;
  }

  Future<void> _write(List<String> paths) async {
    if (!_stops(paths)) return;
    await _go.future;
    if (_through) return;
    throw const FileSystemException('the app stopped');
  }

  void _writeSync(List<String> paths) {
    if (_stops(paths)) throw const FileSystemException('the app stopped');
  }

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<String> readString(String path) => inner.readString(path);

  @override
  Future<Uint8List> readBytes(String path) => inner.readBytes(path);

  @override
  Future<Uint8List?> readBytesIfPresent(String path) => inner.readBytesIfPresent(path);

  @override
  Future<FsDirectory> openDirectory(String path) async => PassThroughFsDirectory(this, path);

  @override
  Future<Uint8List> readHead(String path, int maxBytes) => inner.readHead(path, maxBytes);

  @override
  Future<void> writeString(String path, String contents) async {
    await _write([path]);
    await inner.writeString(path, contents);
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes, {bool flush = false}) async {
    await _write([path]);
    await inner.writeBytes(path, bytes, flush: flush);
  }

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) => inner.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    await _write([path]);
    await inner.delete(path, recursive: recursive);
  }

  @override
  Future<void> rename(String source, String destination) async {
    await _write([source, destination]);
    await inner.rename(source, destination);
  }

  @override
  bool get renameReplacesFileAtomically => inner.renameReplacesFileAtomically;

  @override
  Future<void> createDir(String path, {bool recursive = false}) async {
    await _write([path]);
    await inner.createDir(path, recursive: recursive);
  }

  @override
  Future<void> copyFile(String source, String destination) async {
    await _write([destination]);
    await inner.copyFile(source, destination);
  }

  @override
  Future<int> length(String path) => inner.length(path);

  @override
  Future<DateTime> modified(String path) => inner.modified(path);

  @override
  Future<bool> sameFileBytes(String a, String b) => inner.sameFileBytes(a, b);

  @override
  Future<bool> isFile(String path) => inner.isFile(path);

  @override
  bool existsSync(String path) => inner.existsSync(path);

  @override
  String readStringSync(String path) => inner.readStringSync(path);

  @override
  Uint8List readBytesSync(String path) => inner.readBytesSync(path);

  @override
  Uint8List? readBytesIfPresentSync(String path) => inner.readBytesIfPresentSync(path);

  @override
  void writeStringSync(String path, String contents) {
    _writeSync([path]);
    inner.writeStringSync(path, contents);
  }

  @override
  void writeBytesSync(String path, List<int> bytes, {bool flush = false}) {
    _writeSync([path]);
    inner.writeBytesSync(path, bytes, flush: flush);
  }

  @override
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false, bool withMetadata = false}) =>
      inner.listSync(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);

  @override
  void deleteSync(String path, {bool recursive = false}) {
    _writeSync([path]);
    inner.deleteSync(path, recursive: recursive);
  }

  @override
  void renameSync(String source, String destination) {
    _writeSync([source, destination]);
    inner.renameSync(source, destination);
  }

  @override
  bool isFileSync(String path) => inner.isFileSync(path);
}

/// The filesystem as the app reads and writes through it, holding the work on the bindings of the records [ids]: the
/// first look for the skill image of each, in either store, which the work on its binding starts with
/// ([computeRecordBodyImages]), waits until the test lets it go ([go]) — a binding worked out as slowly as the test wants.
/// Everything else goes through.
class SyncBindingGateFsBackend extends IoFsBackend {
  SyncBindingGateFsBackend(Set<String> ids)
    : _gates = {for (final id in ids) id: (Completer<void>(), Completer<void>())};

  static final _image = RegExp(r'[/\\]chara_detail[/\\](?:active|archive)[/\\]([^/\\]+)[/\\]skill\.png$');

  final Map<String, (Completer<void>, Completer<void>)> _gates;

  /// Completes once the work on the binding of [id] is held.
  Future<void> entered(String id) => _gates[id]!.$1.future;

  /// Lets the work on the binding of [id] go on.
  void go(String id) {
    if (!_gates[id]!.$2.isCompleted) _gates[id]!.$2.complete();
  }

  /// Lets the work on every binding go on.
  void goAll() => _gates.keys.forEach(go);

  @override
  Future<bool> exists(String path) async {
    if (_gates[_image.firstMatch(path)?.group(1)] case (final entered, final go) when !entered.isCompleted) {
      entered.complete();
      await go.future;
    }
    return super.exists(path);
  }
}

/// Runs a round of [device] against [server] that the app stops at the write [stop] holds: [whileHeld] runs while the
/// write is held, then the app stops, and a restart opens it again on the filesystem as it was before. [bindingChunk]
/// as [runSyncRound] takes it.
Future<void> stoppedRound(
  SyncTestDevice device,
  FakeSyncServer server,
  SyncStopFsBackend stop, {
  Future<void> Function()? whileHeld,
  int bindingChunk = syncBindingChunk,
}) async {
  final original = fsBackend;
  fsBackend = stop;
  try {
    final round = device
        .round(server, bindingChunk: bindingChunk)
        .then<SyncRoundEnd?>((o) => o.end, onError: (Object _) => null);
    final reached = await Future.any([stop.held.then((_) => true), round.then((_) => false)]);
    expect(reached, isTrue, reason: 'the round reached the write it is stopped at');
    try {
      await whileHeld?.call();
    } finally {
      // Let go even where a check failed: a write held for good keeps its record's lock, and every test after waits.
      stop.stop();
    }
    expect(await round, anyOf(isNull, isNot(SyncRoundEnd.done)), reason: 'a stopped round does not end as done');
  } finally {
    fsBackend = original;
  }
  device.close();
}

/// Puts what [device] holds on [server] as one replacement: its bodies, its parts, and a root naming them. The tests'
/// own upload, so the shapes the reader writes are checked against what the server refuses; a sync round is not this.
Future<void> putDeviceList(SyncTestDevice device, FakeSyncServer server) async {
  final read = await device.read();
  final bodies = [
    for (final row in read.list.rows.values)
      (
        name: row.bodyName,
        body: device.bodyOf(row.record.id, store: row.record.stage.value == null ? 'active' : 'archive'),
      ),
  ];
  for (var i = 0; i < bodies.length; i += 10) {
    await server.putBodies(bodies.sublist(i, i + 10 > bodies.length ? bodies.length : i + 10));
  }
  final parts = syncListParts(read.list);
  final names = <String, String>{};
  for (final MapEntry(key: slot, value: text) in parts.entries) {
    final name = syncObjectName(utf8.encode(text));
    await server.putPart(name, text);
    names[slot] = name;
  }
  final root = jsonEncode({'format': 1, 'parts': names});
  await server.replaceRoot(server.generation, syncObjectName(utf8.encode(root)), root);
}
