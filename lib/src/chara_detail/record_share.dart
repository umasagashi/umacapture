// Sharing a record under the logged-in account, unsharing it, and listing the account's shares.
//
// Shared by web and Windows. The record leaves the device as the posted form below, and its images only
// when the sharer chooses to share them, as one bundle of reduced JPEGs ([shareImageBundleOf]) put after
// the share; the server names the values, so the app sends sids. Each share carries a client key made here and kept in the
// `recordShares` store before anything is sent, so a share whose reply never arrived is found again:
// a resend with the same key answers the id the first send created, and the account's list names each
// share by the hash of its key.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_binding.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

part 'record_share.mapper.dart';

/// Whether [record] may be shared: only a training of a trainer the account holds, or of this device's own.
///
/// A device-side policy and not a defence: the server never receives `trainer_id`, so it can refuse a
/// friend's record type and nothing more.
bool canShare(CharaDetailRecord record, Iterable<String> trainerIds) =>
    !isNeverShareable(record) && trainerIds.contains(record.metadata.trainerId);

/// Whether [record] can never be shared, whatever the account holds: a friend's record. The part of [canShare] the
/// device decides without asking the account's trainers.
bool isNeverShareable(CharaDetailRecord record) => record.isFriend;

/// A family member: who it is, its face icon's class number, its rank, and its record type where the recognizer read
/// one, so a device importing the share holds the fields a captured record holds.
Map<String, Object?> _chara(Character c) => {
  "character": c.character,
  "card": c.card,
  "icon": c.icon,
  "rank": c.rank,
  if (c.recordType case final type?) "record_type": type.toValue(),
};

Map<String, Object?> _parent(Parent p) => {
  "self": _chara(p.self),
  "parent1": _chara(p.parent1),
  "parent2": _chara(p.parent2),
  if (p.rental != null) "rental": p.rental,
};

List<Map<String, Object?>> _factors(List<Factor> factors) => [
  for (final f in factors) {"id": f.id, "star": f.star},
];

Map<String, Object?> _race(Race r) => {
  "title": r.title,
  "place": r.place,
  "ground": r.ground,
  "distance": r.distance,
  "variation": r.variation,
  "weather": r.weather,
  "strategy": r.strategy,
  "turn": r.turn,
  "position": r.position,
};

/// The posted form v1 of [record]: what each share of `POST /api/shares` carries as `record`.
///
/// Every value is picked out by name. A field added to the record does not leave the device until it
/// is listed here, which is what keeps `trainer_id`, the capture time and the record ids out.
/// [moduleVersion] is the installed module's recognizer version as the module states it.
Map<String, Object?> postedForm(CharaDetailRecord record, {required String moduleVersion}) {
  final m = record.metadata;
  final s = record.status;
  final a = record.aptitudes;
  return {
    "schema": 1,
    "region": m.region,
    "module_version": moduleVersion,
    "recognizer_version": m.recognizerVersion,
    "record_type": (m.recordType ?? RecordType.standard).toValue(),
    "strategy": m.strategy,
    if (m.relationBonus != null) "relation_bonus": m.relationBonus,
    "trainee": {
      "character": record.trainee.character,
      "card": record.trainee.card,
      "rank": record.trainee.rank,
      "icon": record.trainee.icon,
    },
    "evaluation_value": record.evaluationValue,
    "status": {
      "speed": s.speed,
      "stamina": s.stamina,
      "power": s.power,
      "guts": s.guts,
      "intelligence": s.intelligence,
    },
    "aptitudes": {
      "ground": {"turf": a.ground.turf, "dirt": a.ground.dirt},
      "distance": {
        "short_range": a.distance.shortRange,
        "mile_range": a.distance.mileRange,
        "middle_range": a.distance.middleRange,
        "long_range": a.distance.longRange,
      },
      "style": {
        "lead_pace": a.style.leadPace,
        "with_pace": a.style.withPace,
        "off_pace": a.style.offPace,
        "late_charge": a.style.lateCharge,
      },
    },
    "skills": [
      for (final skill in record.skills) {"id": skill.id, if (skill.level != null) "level": skill.level},
    ],
    "factors": {
      "self": _factors(record.factors.self),
      "parent1": _factors(record.factors.parent1),
      "parent2": _factors(record.factors.parent2),
    },
    "support_cards": [
      for (final c in record.supportCards) {"id": c.id, "rank": c.rank, "level": c.level},
    ],
    "family": {"parent1": _parent(record.family.parent1), "parent2": _parent(record.family.parent2)},
    "fans": record.fans,
    "scenario": {"id": record.scenario.id},
    "trained_date": record.trainedDate,
    "races": [for (final r in record.races) _race(r)],
  };
}

/// Unpadded base64url of [bytes] random bytes from the platform's cryptographic generator.
String _randomToken(int bytes) {
  final random = Random.secure();
  final values = List<int>.generate(bytes, (_) => random.nextInt(256));
  return base64Url.encode(values).replaceAll("=", "");
}

/// A new client key: 128 random bits, 22 characters, the form the server accepts.
String newClientKey() => _randomToken(16);

/// A new login secret: 256 random bits, 43 characters.
String newLoginSecret() => _randomToken(32);

/// SHA-256 of [secret]'s UTF-8 text in lowercase hex: what the server stores, and the store's key.
String secretHash(String secret) => sha256.convert(utf8.encode(secret)).toString();

/// How many shares one `POST /api/shares` may carry; the server refuses a larger request whole.
const maxSharesPerRequest = 8;

@MappableEnum()
enum RecordShareState { pending, shared }

/// One share this device made under [accountId], kept until it is unshared, the account's list no longer
/// holds it, or the session ends.
///
/// Keyed in the store by [secretHash] of [clientKey], which is the `client_key_hash` the account's list
/// names each share by, and which does not change when a pending share is confirmed.
@MappableClass(caseStyle: CaseStyle.snakeCase, ignoreNull: true)
class RecordShare with RecordShareMappable {
  final String recordId;
  final String accountId;
  final String clientKey;
  final RecordShareState state;
  final String? id;
  final String? url;
  final String? sharedOn;

  const RecordShare({
    required this.recordId,
    required this.accountId,
    required this.clientKey,
    required this.state,
    this.id,
    this.url,
    this.sharedOn,
  });

  String get keyHash => secretHash(clientKey);

  /// This note once the server has the share as [id], under the same key, and holds every image it declared.
  RecordShare confirmedAs({required String id, required String url, required String sharedOn}) =>
      _at(RecordShareState.shared, id: id, url: url, sharedOn: sharedOn);

  /// This note once the server has the share as [id] but not yet the images it declared: still pending, so sharing the
  /// record again sends them.
  RecordShare locatedAs({required String id, required String url, required String sharedOn}) =>
      _at(RecordShareState.pending, id: id, url: url, sharedOn: sharedOn);

  RecordShare _at(RecordShareState state, {required String id, required String url, required String sharedOn}) =>
      RecordShare(
        recordId: recordId,
        accountId: accountId,
        clientKey: clientKey,
        state: state,
        id: id,
        url: url,
        sharedOn: sharedOn,
      );
}

/// The images of one share as one unit: [bytes], the parts' bytes one after another, and [declaration], what a share
/// of `POST /api/shares` declares of them — the bundle's SHA-256 as its name, its size, and each part's kind, size,
/// SHA-256 and geometry, in the order the bundle holds them.
typedef ShareImageBundle = ({Uint8List bytes, Map<String, Object?> declaration});

/// The bundle of [images] ([recordShareImagesOf]), or null where an image's geometry is not one a declaration can state
/// ([_declaredRect]). Pure.
ShareImageBundle? shareImageBundleOf(List<RecordShareImage> images) {
  final parts = <Map<String, Object?>>[];
  final builder = BytesBuilder(copy: false);
  for (final image in images) {
    final Map<String, Object?>? rect;
    if (image.intersection case final intersection?) {
      rect = _declaredRect(intersection);
      if (rect == null) return null;
    } else {
      rect = null;
    }
    builder.add(image.bytes);
    parts.add({
      "kind": image.kind,
      "size": image.bytes.length,
      "sha256": sha256.convert(image.bytes).toString(),
      "intersection": ?rect,
    });
  }
  final bytes = builder.takeBytes();
  return (bytes: bytes, declaration: {"name": sha256.convert(bytes).toString(), "size": bytes.length, "parts": parts});
}

/// The rect a declaration states of the geometry [intersection]: its two corners with their integer `x` and `y` and
/// their `anchor` where it has one, picked out by name as the posted form's values are, since the server refuses any
/// other key. Null where a corner has no integer coordinates.
Map<String, Object?>? _declaredRect(Map<String, dynamic> intersection) {
  Map<String, Object?>? corner(Object? point) => switch (point) {
    {"x": final int x, "y": final int y} => {
      "x": x,
      "y": y,
      if (point["anchor"] case {"h": final String h, "v": final String v}) "anchor": {"h": h, "v": v},
    },
    _ => null,
  };
  final topLeft = corner(intersection["top_left"]);
  final bottomRight = corner(intersection["bottom_right"]);
  return topLeft == null || bottomRight == null ? null : {"top_left": topLeft, "bottom_right": bottomRight};
}

/// What the server says of a share's images, in a share's result and in the account's list: whether it still waits
/// for the bundle the share declared. A share that declared none, or whose bundle is stored, waits for nothing.
bool _imagesPending(Object? item) => item is Map && item["images"] == "pending";

/// Why the server refused a share, past the cases the app answers by itself.
enum ShareRefusal {
  dailyLimit,
  storageFull,
  accountLimit,
  serverTablesOlder,
  rejected,
  sharingPaused,

  /// The account is being deleted; nothing more can be shared under it.
  accountDeleting,
  temporarilyUnavailable,

  /// A 429 or 5xx that is not the server's own JSON: Cloudflare's rate limit or its daily quota.
  busy,

  /// The share declared images and the server takes no more images, today or at all. The whole share is refused;
  /// without images it could be shared.
  imageLimit,

  /// The share declared images and the server has stopped taking images. The whole share is refused; without images it
  /// could be shared.
  imageSharingPaused,
}

sealed class ShareOutcome {
  const ShareOutcome();
}

final class Shared extends ShareOutcome {
  final RecordShare entry;

  /// Images were asked for and the record has none a share can carry ([recordShareImagesOf]), so it was shared
  /// without them.
  final bool imagesLeftOut;

  const Shared(this.entry, {this.imagesLeftOut = false});
}

/// The server holds the share but not the images it declared, which were not sent. The note stays pending with the
/// share's id, and sharing the record again sends the images only.
final class ImagesUnsent extends ShareOutcome {
  final RecordShare entry;

  const ImagesUnsent(this.entry);
}

/// The record is already shared; it is unshared and shared again to change what it holds.
final class AlreadyShared extends ShareOutcome {
  final RecordShare entry;

  const AlreadyShared(this.entry);
}

/// Not a training of a trainer the account holds ([canShare]). Nothing was sent for it.
final class NotShareable extends ShareOutcome {
  const NotShareable();
}

/// No installed module states its version, so the posted form cannot be made. Nothing was sent.
final class ModuleUnavailable extends ShareOutcome {
  const ModuleUnavailable();
}

/// There is no session, or the server no longer knows it: logging in comes first. Nothing was shared.
final class LoginRequired extends ShareOutcome {
  const LoginRequired();
}

final class ShareRefused extends ShareOutcome {
  final ShareRefusal reason;
  final Duration? retryAfter;

  const ShareRefused(this.reason, {this.retryAfter});
}

/// The server stopped before this share, which was not tried; sending it again may succeed.
final class ShareSkipped extends ShareOutcome {
  const ShareSkipped();
}

/// No answer arrived. The pending note keeps the key, and sharing again resends with it.
final class ShareUnreachable extends ShareOutcome {
  const ShareUnreachable();
}

enum UnshareOutcome { unshared, forbidden, loginRequired, unreachable, failed }

/// One share of the account, as `GET /api/me/shares` lists it. [cardName] is the trainee's card as the server's name
/// tables label it (its own form, not the app's), or null when the listing names none. [evaluation] is the game's
/// evaluation value the listing carries, or null when it carries none (an inheritance-only record has none).
/// [imagesPending] is whether the server still waits for the images the share declared ([_imagesPending]).
typedef AccountShare = ({
  String id,
  String url,
  String sharedOn,
  String clientKeyHash,
  String? cardName,
  int? evaluation,
  bool imagesPending,
});

/// What listing the account's shares answered.
sealed class ShareListing {
  const ShareListing();
}

final class SharesListed extends ShareListing {
  final List<AccountShare> shares;

  const SharesListed(this.shares);
}

final class SharesLoginRequired extends ShareListing {
  const SharesLoginRequired();
}

final class SharesUnreachable extends ShareListing {
  const SharesUnreachable();
}

/// The account is being deleted, so it lists nothing; the session now continues the deletion only.
final class SharesAccountDeleting extends ShareListing {
  const SharesAccountDeleting();
}

/// Whether the sharing API itself answered that the row does not exist.
///
/// A bare 404 is not enough: with sharing switched off, the assets-only deployment answers 404 for every API path
/// while the row is still stored.
bool _apiSaysNotFound(ShareAnswer answer) => answer.status == 404 && answer.body?["error"] == "not_found";

ShareRefusal? _refusalOf(Object? error) => switch (error) {
  "daily_limit" => ShareRefusal.dailyLimit,
  "storage_full" => ShareRefusal.storageFull,
  "account_limit" => ShareRefusal.accountLimit,
  "server_tables_older" => ShareRefusal.serverTablesOlder,
  "invalid_payload" || "payload_too_large" => ShareRefusal.rejected,
  "sharing_paused" => ShareRefusal.sharingPaused,
  "account_deleting" => ShareRefusal.accountDeleting,
  "temporarily_unavailable" => ShareRefusal.temporarilyUnavailable,
  "image_daily_limit" || "image_storage_full" || "image_account_limit" => ShareRefusal.imageLimit,
  "image_sharing_paused" => ShareRefusal.imageSharingPaused,
  _ => null,
};

Duration? _retryAfter(Headers headers) {
  final seconds = int.tryParse(headers.value("retry-after") ?? "");
  return seconds == null ? null : Duration(seconds: seconds);
}

String _today() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

/// The shares this device made, by [RecordShare.keyHash], mirrored in the store.
class RecordShares extends Notifier<Map<String, RecordShare>> {
  StorageBox get _box => StorageBox(StorageBoxKey.recordShares);

  RecordShareSession get _session => ref.read(recordShareSessionProvider.notifier);

  /// The requests this device sent that can make the server hold a note's share or change what it holds, by the
  /// note's key hash; [refreshFromServer] reads from them which notes a list may decide.
  final _sends = _Sends();

  @override
  Map<String, RecordShare> build() {
    final entries = <String, RecordShare>{};
    for (final (:key, :value) in _box.entries()) {
      if (shareLoginKeys.contains(key) || value is! String) {
        continue;
      }
      try {
        entries[key] = RecordShareMapper.fromJson(value);
      } on Exception catch (e) {
        // The account's list names the share again, so an unreadable note costs nothing but this line.
        logger.w("A share note could not be read: ${e.runtimeType}");
      }
    }
    return entries;
  }

  Future<void> _put(RecordShare entry) async {
    state = {...state, entry.keyHash: entry};
    await _box.push(entry.keyHash, entry.toJson());
  }

  Future<void> _drop(Iterable<String> keyHashes) async {
    final dropped = keyHashes.toList();
    if (dropped.isEmpty) {
      return;
    }
    state = {...state}..removeWhere((key, _) => dropped.contains(key));
    for (final key in dropped) {
      await _box.delete(key);
    }
  }

  /// Drops every note made under an account other than [accountId]: they index that account's shares, which
  /// this session cannot act on. Called once, right after a claim.
  Future<void> keepOnlyAccount(String accountId) => _drop([
    for (final e in state.entries)
      if (e.value.accountId != accountId) e.key,
  ]);

  RecordShare? entryOf(String recordId) => state.values.where((e) => e.recordId == recordId).firstOrNull;

  /// Shares [records], held in [source], under the session, [maxSharesPerRequest] to a request, and answers each
  /// record's outcome by its id. Each share's note is written from its own result only.
  ///
  /// With [withImages], each share declares its record's images ([recordShareImagesOf]) and their bundle is sent once
  /// the server holds the share; a record with none a share can carry is shared without them. Whatever
  /// [withImages] says, a share the server holds and still waits for images of (one an earlier attempt declared)
  /// is sent its bundle, and its note becomes shared only once the bundle is sent.
  Future<Map<String, ShareOutcome>> shareAll(
    List<CharaDetailRecord> records, {
    required RecordSource source,
    bool withImages = false,
  }) async {
    final session = ref.read(recordShareSessionProvider);
    if (session == null) {
      return {for (final r in records) r.id: const LoginRequired()};
    }
    final moduleVersion = (await ref.read(moduleVersionLoader.future))?.recognizerVersionText;
    if (moduleVersion == null) {
      return {for (final r in records) r.id: const ModuleUnavailable()};
    }
    final (:toSend, :settled) = await sortForSharing(records, under: session);
    final outcomes = {...settled};
    final images = _ShareImages(ref, source);
    for (var start = 0; start < toSend.length; start += maxSharesPerRequest) {
      final chunk = toSend.sublist(start, min(start + maxSharesPerRequest, toSend.length));
      final answered = await _shareChunk(chunk, session, moduleVersion, withImages ? images : null);
      final unsent = await _sendBundles(answered, session, images);
      outcomes.addAll(answered);
      final stop = answered.values.any(
        (o) => o is LoginRequired || o is ShareUnreachable || o is ShareRefused && o.reason == ShareRefusal.busy,
      );
      if (stop || unsent.stopped) {
        for (final record in toSend.skip(start + chunk.length)) {
          outcomes[record.id] = stop ? answered.values.first : const ShareSkipped();
        }
        break;
      }
    }
    return outcomes;
  }

  /// Sends the bundle of each share of [answered] the server holds and waits for images of ([ImagesUnsent]), one at a
  /// time, and replaces its outcome with [Shared] once the bundle is sent. A 429 is waited out once
  /// ([shareImagesRetryDelayProvider]); a second stops the sending, and every share not yet sent stays [ImagesUnsent].
  /// Answers whether it stopped so.
  Future<({bool stopped})> _sendBundles(
    Map<String, ShareOutcome> answered,
    ShareSession session,
    _ShareImages images,
  ) async {
    for (final MapEntry(key: recordId, value: outcome) in answered.entries.toList()) {
      if (outcome is! ImagesUnsent) {
        continue;
      }
      final bundle = await images.of(recordId);
      final RecordShare(:id, :url, :sharedOn) = outcome.entry;
      if (bundle == null || id == null || url == null || sharedOn == null) {
        continue;
      }
      final keys = [outcome.entry.keyHash];
      _sends.begin(keys);
      try {
        final answer = await _sendBundle(id, bundle, session);
        if (answer?.status == 429) {
          return (stopped: true);
        }
        if (answer case ShareAnswer(:final status) when status >= 200 && status < 300) {
          final shared = outcome.entry.confirmedAs(id: id, url: url, sharedOn: sharedOn);
          await _put(shared);
          answered[recordId] = Shared(shared);
        } else {
          logger.w("A share's images were not sent: ${answer?.status ?? 'no answer'}");
        }
      } finally {
        _sends.end(keys);
      }
    }
    return (stopped: false);
  }

  /// Sends [bundle] as the images of the share [id], once more after a 429, and answers the last answer, or null where
  /// none arrived.
  Future<ShareAnswer?> _sendBundle(String id, ShareImageBundle bundle, ShareSession session) async {
    ShareAnswer? answer;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(ref.read(shareImagesRetryDelayProvider));
      }
      try {
        answer = await _session.send(
          "PUT",
          "/api/shares/$id/images",
          data: bundle.bytes,
          under: session,
          timeout: ref.read(shareImagesRequestTimeoutProvider),
        );
      } on DioException {
        answer = null;
      } on StateError {
        answer = null;
      }
      if (answer?.status != 429) {
        break;
      }
    }
    return answer;
  }

  /// Sorts [records] without sending anything: those [shareAll] would send, and the outcome of each it would not —
  /// already shared, not shareable, or the failure that kept the account's trainers from being known. A
  /// confirmation counts from this what a share would leave out. A share passes its session as [under], so the
  /// account's trainers are asked of that account only.
  Future<({List<CharaDetailRecord> toSend, Map<String, ShareOutcome> settled})> sortForSharing(
    List<CharaDetailRecord> records, {
    ShareSession? under,
  }) async {
    final outcomes = <String, ShareOutcome>{};
    final toSend = <CharaDetailRecord>[];
    final ownTrainerId = ref.read(trainerIdProvider);
    ({Set<String> ids, ShareOutcome? failure})? account;
    for (final record in records) {
      final earlier = entryOf(record.id);
      if (earlier != null && earlier.state == RecordShareState.shared) {
        outcomes[record.id] = AlreadyShared(earlier);
        continue;
      }
      // This device's own trainings never depend on the account's list, so a trainer id that failed to register
      // at login cannot keep them from being shared.
      if (isNeverShareable(record)) {
        outcomes[record.id] = const NotShareable();
        continue;
      }
      if (!canShare(record, [ownTrainerId])) {
        account ??= await _accountTrainerIds(under);
        if (account.failure case final failure?) {
          outcomes[record.id] = failure;
          continue;
        }
        if (!canShare(record, account.ids)) {
          outcomes[record.id] = const NotShareable();
          continue;
        }
      }
      toSend.add(record);
    }
    return (toSend: toSend, settled: outcomes);
  }

  /// The trainer ids the account holds, or the outcome that stands for every record needing them when the server
  /// did not tell. Asked only for a record that is not this device's own training.
  Future<({Set<String> ids, ShareOutcome? failure})> _accountTrainerIds(ShareSession? under) async {
    ({Set<String> ids, ShareOutcome? failure}) failed(ShareOutcome o) => (ids: const {}, failure: o);
    final ShareAnswer answer;
    try {
      answer = await _session.send("GET", "/api/me", under: under);
    } on DioException {
      return failed(const ShareUnreachable());
    } on StateError {
      return failed(const LoginRequired());
    }
    final ids = answer.body?["trainer_ids"];
    if (answer.status == 401) {
      return failed(const LoginRequired());
    }
    if (answer.status == 409 && answer.body?["error"] == "account_deleting") {
      return failed(const ShareRefused(ShareRefusal.accountDeleting));
    }
    if (answer.status != 200 || ids is! List) {
      return failed(const ShareRefused(ShareRefusal.busy));
    }
    return (ids: {for (final id in ids.whereType<String>()) id}, failure: null);
  }

  Future<Map<String, ShareOutcome>> _shareChunk(
    List<CharaDetailRecord> chunk,
    ShareSession session,
    String moduleVersion,
    _ShareImages? images,
  ) async {
    Map<String, ShareOutcome> everyOne(ShareOutcome o) => {for (final r in chunk) r.id: o};
    // A share begun under one account sends nothing once the device holds another: the server would publish the
    // records under the new account while their notes named the first. Checked before any note is written.
    if (!_session.holds(session)) {
      return everyOne(const LoginRequired());
    }
    final pending = [
      for (final record in chunk)
        entryOf(record.id) ??
            RecordShare(
              recordId: record.id,
              accountId: session.accountId,
              clientKey: newClientKey(),
              state: RecordShareState.pending,
            ),
    ];
    final keys = [for (final note in pending) note.keyHash];
    // Begun before a new note is written, so no list can decide a note this share has written and not yet sent.
    _sends.begin(keys);
    try {
      for (final note in pending) {
        // Kept before sending, so the key survives whatever happens to the reply.
        await _put(note);
      }
      return await _sendChunk(chunk, session, moduleVersion, images, pending);
    } finally {
      _sends.end(keys);
    }
  }

  Future<Map<String, ShareOutcome>> _sendChunk(
    List<CharaDetailRecord> chunk,
    ShareSession session,
    String moduleVersion,
    _ShareImages? images,
    List<RecordShare> pending,
  ) async {
    Map<String, ShareOutcome> everyOne(ShareOutcome o) => {for (final r in chunk) r.id: o};
    final declared = [for (final record in chunk) await images?.of(record.id)];
    final shares = [
      for (final (i, note) in pending.indexed)
        {
          "client_key": note.clientKey,
          "record": postedForm(chunk[i], moduleVersion: moduleVersion),
          if (declared[i] case final bundle?) "images": bundle.declaration,
        },
    ];
    final ShareAnswer answer;
    try {
      answer = await _session.send("POST", "/api/shares", data: {"shares": shares}, under: session);
    } on DioException {
      return everyOne(const ShareUnreachable());
    } on StateError {
      return everyOne(const LoginRequired());
    }
    final results = answer.body?["results"];
    if (answer.status == 200 && results is List && results.length == pending.length) {
      final outcomes = <String, ShareOutcome>{};
      for (final (i, note) in pending.indexed) {
        final result = results[i];
        final outcome = await _applyResult(note, result);
        // Images were asked for and the share holds none: the record has none a share can carry, or the share was
        // already made by an earlier attempt that declared none, which a resend does not change.
        final leftOut = declared[i] == null || result is Map && result["images"] == "none";
        outcomes[note.recordId] = outcome is Shared && images != null && leftOut
            ? Shared(outcome.entry, imagesLeftOut: true)
            : outcome;
      }
      return outcomes;
    }
    if (answer.status == 401) {
      return everyOne(const LoginRequired());
    }
    final reason = _refusalOf(answer.body?["error"]) ?? ShareRefusal.busy;
    return everyOne(ShareRefused(reason, retryAfter: _retryAfter(answer.headers)));
  }

  /// Writes one share's result into its own note, and answers its outcome: [ImagesUnsent] for a share the server
  /// holds and still waits for images of, whose note stays pending.
  Future<ShareOutcome> _applyResult(RecordShare note, Object? result) async {
    final map = result is Map ? result : const {};
    switch (map["status"]) {
      case "created" || "existing":
        final id = map["id"];
        final url = map["url"];
        if (id is! String || url is! String) {
          return const ShareRefused(ShareRefusal.busy);
        }
        if (_imagesPending(map)) {
          final located = note.locatedAs(id: id, url: url, sharedOn: note.sharedOn ?? _today());
          await _put(located);
          return ImagesUnsent(located);
        }
        final shared = note.confirmedAs(id: id, url: url, sharedOn: _today());
        await _put(shared);
        return Shared(shared);
      case "skipped":
        return const ShareSkipped();
      default:
        return ShareRefused(_refusalOf(map["error"]) ?? ShareRefusal.rejected);
    }
  }

  /// Unshares the account's share [id]. The API's own 404 means it is already gone, which is the same result.
  Future<UnshareOutcome> unshare(String id) async {
    final ShareAnswer answer;
    try {
      answer = await _session.send("DELETE", "/api/shares/$id");
    } on DioException {
      return UnshareOutcome.unreachable;
    } on StateError {
      return UnshareOutcome.loginRequired;
    }
    if (answer.status == 204 || _apiSaysNotFound(answer)) {
      await _drop([
        for (final e in state.entries)
          if (e.value.id == id) e.key,
      ]);
      return UnshareOutcome.unshared;
    }
    return switch (answer.status) {
      401 => UnshareOutcome.loginRequired,
      403 => UnshareOutcome.forbidden,
      _ => UnshareOutcome.failed,
    };
  }

  /// Lists the account's shares and matches the notes against them by `client_key_hash`: a pending note the list
  /// holds becomes shared — or stays pending, with the share's id, while the server waits for its images — and a note
  /// of this account the list does not hold is dropped.
  ///
  /// The list is the server's state at some moment between asking for it and its answer, so it decides only a note no
  /// send of which ([_sends]) was unanswered when the list was asked for or has begun since: the server may hold any
  /// other — or hold it otherwise — whatever the list says, and that note is left as it is.
  Future<ShareListing> refreshFromServer() async {
    final session = ref.read(recordShareSessionProvider);
    if (session == null) {
      return const SharesLoginRequired();
    }
    try {
      return await _listUnder(session);
    } finally {
      ref.read(shareListingsProvider.notifier)._count();
    }
  }

  Future<ShareListing> _listUnder(ShareSession session) async {
    final askedAt = _sends.now();
    final ShareAnswer answer;
    try {
      answer = await _session.send("GET", "/api/me/shares", under: session);
    } on DioException {
      return const SharesUnreachable();
    } on StateError {
      return const SharesLoginRequired();
    }
    if (answer.status == 401) {
      return const SharesLoginRequired();
    }
    if (answer.status == 409 && answer.body?["error"] == "account_deleting") {
      return const SharesAccountDeleting();
    }
    final listed = answer.status == 200 ? _sharesOf(answer.json) : null;
    if (listed == null) {
      return const SharesUnreachable();
    }
    final byHash = {for (final s in listed) s.clientKeyHash: s};
    bool decides(String key, RecordShare note) =>
        note.accountId == session.accountId && _sends.quietSince(key, askedAt);
    // Each note is read from the notes as they are, right before it is written: a write awaits the store, and a note
    // may be dropped or a send of it begun in between.
    for (final key in state.keys.toList()) {
      final (note, share) = (state[key], byHash[key]);
      if (note == null || share == null || !decides(key, note)) {
        continue;
      }
      final (id, url, sharedOn) = (share.id, share.url, share.sharedOn);
      final matched = share.imagesPending
          ? note.locatedAs(id: id, url: url, sharedOn: sharedOn)
          : note.confirmedAs(id: id, url: url, sharedOn: sharedOn);
      if (note.state != matched.state || note.id != matched.id) {
        await _put(matched);
      }
    }
    await _drop([
      for (final MapEntry(:key, value: note) in state.entries)
        if (!byHash.containsKey(key) && decides(key, note)) key,
    ]);
    return SharesListed(listed);
  }

  List<AccountShare>? _sharesOf(Object? data) {
    if (data is! List) {
      return null;
    }
    final shares = <AccountShare>[];
    for (final item in data) {
      if (item is! Map) {
        return null;
      }
      final (id, url, sharedOn, hash, summary) = (
        item["id"],
        item["url"],
        item["shared_on"],
        item["client_key_hash"],
        item["summary"],
      );
      if (id is! String || url is! String || sharedOn is! String || hash is! String) {
        return null;
      }
      final cardName = switch (summary) {
        {"trainee": {"card": {"name": final String name}}} when name.isNotEmpty => name,
        _ => null,
      };
      final evaluation = switch (summary) {
        {"evaluation": final int value} => value,
        _ => null,
      };
      shares.add((
        id: id,
        url: url,
        sharedOn: sharedOn,
        clientKeyHash: hash,
        cardName: cardName,
        evaluation: evaluation,
        imagesPending: _imagesPending(item),
      ));
    }
    return shares;
  }
}

final recordSharesProvider = NotifierProvider<RecordShares, Map<String, RecordShare>>(RecordShares.new);

/// How many times [RecordShares.refreshFromServer] has had the server's answer — or its failure — to the account's
/// list: each time the account tab is shown, after an unshare, and on the reload button. Each is a moment the account's
/// holdings are read anew, so the account's usage is asked for with every one, and agrees with the list beside it.
class ShareListings extends Notifier<int> {
  @override
  int build() => 0;

  void _count() => state++;
}

final shareListingsProvider = NotifierProvider<ShareListings, int>(ShareListings.new);

/// Whether the share confirmations start with "share the images too" checked: the choice of the last share this
/// device made, off until one is made. Set when a share starts, not when the box is merely toggled.
final shareImagesChoiceProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.shareImages.name, defaultValue: false);
});

/// How long the sending of share images waits after a 429 before sending once more. The site's rate limit counts
/// `/api/` requests from one address over 10 seconds, so 10 seconds is the wait that lets one window pass.
final shareImagesRetryDelayProvider = Provider<Duration>((_) => const Duration(seconds: 10));

/// The image bundles of one share's records in [source] ([shareImageBundleOf]), each worked out once from what its
/// directory holds when first asked for, and kept for the rest of that share; null for a record that has none a share
/// can carry, or whose directory cannot be read.
class _ShareImages {
  final Ref _ref;
  final RecordSource source;
  final _bundles = <String, Future<ShareImageBundle?>>{};

  _ShareImages(this._ref, this.source);

  Future<ShareImageBundle?> of(String recordId) => _bundles[recordId] ??= _read(recordId);

  Future<ShareImageBundle?> _read(String recordId) async {
    final info = _ref.read(pathInfoProvider);
    final directory = recordDirOfId(info, source, recordId);
    try {
      // Read under the record's lock: an archive or a write-back rewrites the images in place.
      final files = await platformRecordRecoveryGate.runForRecords(
        info.storageDir,
        [recordId],
        () => readRecordImageFiles(directory),
        declaration: const LongReadDeclaration.none(reason: 'reads one record\'s images, a few megabytes'),
      );
      final images = await compute(recordShareImagesOf, files);
      return images == null ? null : shareImageBundleOf(images);
    } on Exception catch (e) {
      logger.w("A record's images could not be read for a share: ${e.runtimeType}");
      return null;
    }
  }
}

/// The requests of this device that can make the server hold a share or change what it holds — `POST /api/shares` and
/// the `PUT` of a share's images — by the share's key hash: how many have not answered, and at which [now] one last
/// began or ended. Held in memory only: once the app has exited, none of its requests is unanswered.
class _Sends {
  final _open = <String, int>{};
  final _lastAt = <String, int>{};
  var _clock = 0;

  /// A point after every begin and end so far, and before every one to come.
  int now() => ++_clock;

  void begin(Iterable<String> keys) {
    for (final key in keys) {
      _open[key] = (_open[key] ?? 0) + 1;
      _lastAt[key] = now();
    }
  }

  void end(Iterable<String> keys) {
    for (final key in keys) {
      _open[key] = (_open[key] ?? 1) - 1;
      _lastAt[key] = now();
    }
  }

  /// Whether no send of [key] was unanswered at [since] (a [now]) and none has begun since: then a list asked for at
  /// [since] shows how the server holds that share, or that it holds none, as this device left it.
  bool quietSince(String key, int since) => (_open[key] ?? 0) == 0 && (_lastAt[key] ?? 0) < since;
}
