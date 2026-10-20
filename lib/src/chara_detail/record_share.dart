// Sharing a record under the logged-in account, unsharing it, and listing the account's shares.
//
// Shared by web and Windows. The record leaves the device only as the posted form below; the server
// names the values, so the app sends sids. Each share carries a client key made here and kept in the
// `recordShares` store before anything is sent, so a share whose reply never arrived is found again:
// a resend with the same key answers the id the first send created, and the account's list names each
// share by the hash of its key.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/core/platform_controller.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/preference/storage_box.dart';

part 'record_share.mapper.dart';

/// Whether [record] may be shared: only a training of a trainer the account holds, or of this device's own.
///
/// A device-side policy and not a defence: the server never receives `trainer_id`, so it can refuse a
/// friend's record type and nothing more.
bool canShare(CharaDetailRecord record, Iterable<String> trainerIds) =>
    !record.isFriend && trainerIds.contains(record.metadata.trainerId);

Map<String, Object?> _chara(Character c) => {"character": c.character, "card": c.card};

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
    "trainee": {"character": record.trainee.character, "card": record.trainee.card, "rank": record.trainee.rank},
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

  /// This note once the server has the share as [id], under the same key.
  RecordShare confirmedAs({required String id, required String url, required String sharedOn}) => RecordShare(
    recordId: recordId,
    accountId: accountId,
    clientKey: clientKey,
    state: RecordShareState.shared,
    id: id,
    url: url,
    sharedOn: sharedOn,
  );
}

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
}

sealed class ShareOutcome {
  const ShareOutcome();
}

final class Shared extends ShareOutcome {
  final RecordShare entry;

  const Shared(this.entry);
}

/// The record is already shared; it is unshared and shared again to change it.
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

/// One share of the account, as `GET /api/me/shares` lists it.
typedef AccountShare = ({String id, String url, String sharedOn, String clientKeyHash, Map<String, Object?> summary});

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

  @override
  Map<String, RecordShare> build() {
    final entries = <String, RecordShare>{};
    for (final (:key, :value) in _box.entries()) {
      if (key == shareSessionKey || value is! String) {
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

  /// Shares [records] under the session, [maxSharesPerRequest] to a request, and answers each record's outcome
  /// by its id. Each share's note is written from its own result only.
  Future<Map<String, ShareOutcome>> shareAll(List<CharaDetailRecord> records) async {
    final session = ref.read(recordShareSessionProvider);
    if (session == null) {
      return {for (final r in records) r.id: const LoginRequired()};
    }
    final moduleVersion = (await ref.read(moduleVersionLoader.future))?.recognizerVersionText;
    if (moduleVersion == null) {
      return {for (final r in records) r.id: const ModuleUnavailable()};
    }
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
      if (record.isFriend) {
        outcomes[record.id] = const NotShareable();
        continue;
      }
      if (!canShare(record, [ownTrainerId])) {
        account ??= await _accountTrainerIds();
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
    for (var start = 0; start < toSend.length; start += maxSharesPerRequest) {
      final chunk = toSend.sublist(start, min(start + maxSharesPerRequest, toSend.length));
      final answered = await _shareChunk(chunk, session.accountId, moduleVersion);
      outcomes.addAll(answered);
      final stop = answered.values.any(
        (o) => o is LoginRequired || o is ShareUnreachable || o is ShareRefused && o.reason == ShareRefusal.busy,
      );
      if (stop) {
        for (final record in toSend.skip(start + chunk.length)) {
          outcomes[record.id] = answered.values.first;
        }
        break;
      }
    }
    return outcomes;
  }

  /// The trainer ids the account holds, or the outcome that stands for every record needing them when the server
  /// did not tell. Asked only for a record that is not this device's own training.
  Future<({Set<String> ids, ShareOutcome? failure})> _accountTrainerIds() async {
    ({Set<String> ids, ShareOutcome? failure}) failed(ShareOutcome o) => (ids: const {}, failure: o);
    final ShareAnswer answer;
    try {
      answer = await _session.send("GET", "/api/me");
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
    String accountId,
    String moduleVersion,
  ) async {
    final pending = <RecordShare>[];
    for (final record in chunk) {
      final earlier = entryOf(record.id);
      final note =
          earlier ??
          RecordShare(
            recordId: record.id,
            accountId: accountId,
            clientKey: newClientKey(),
            state: RecordShareState.pending,
          );
      // Kept before sending, so the key survives whatever happens to the reply.
      await _put(note);
      pending.add(note);
    }
    final shares = [
      for (final (i, note) in pending.indexed)
        {"client_key": note.clientKey, "record": postedForm(chunk[i], moduleVersion: moduleVersion)},
    ];
    Map<String, ShareOutcome> everyOne(ShareOutcome o) => {for (final r in chunk) r.id: o};
    final ShareAnswer answer;
    try {
      answer = await _session.send("POST", "/api/shares", data: {"shares": shares});
    } on DioException {
      return everyOne(const ShareUnreachable());
    } on StateError {
      return everyOne(const LoginRequired());
    }
    final results = answer.body?["results"];
    if (answer.status == 200 && results is List && results.length == pending.length) {
      final outcomes = <String, ShareOutcome>{};
      for (final (i, note) in pending.indexed) {
        outcomes[note.recordId] = await _applyResult(note, results[i]);
      }
      return outcomes;
    }
    if (answer.status == 401) {
      return everyOne(const LoginRequired());
    }
    final reason = _refusalOf(answer.body?["error"]) ?? ShareRefusal.busy;
    return everyOne(ShareRefused(reason, retryAfter: _retryAfter(answer.headers)));
  }

  /// Writes one share's result into its own note, and answers its outcome.
  Future<ShareOutcome> _applyResult(RecordShare note, Object? result) async {
    final map = result is Map ? result : const {};
    switch (map["status"]) {
      case "created" || "existing":
        final id = map["id"];
        final url = map["url"];
        if (id is! String || url is! String) {
          return const ShareRefused(ShareRefusal.busy);
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
  /// holds becomes shared, and a note of this account the list does not hold is dropped.
  Future<ShareListing> refreshFromServer() async {
    final session = ref.read(recordShareSessionProvider);
    if (session == null) {
      return const SharesLoginRequired();
    }
    final ShareAnswer answer;
    try {
      answer = await _session.send("GET", "/api/me/shares");
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
    final gone = <String>[];
    for (final MapEntry(:key, value: note) in state.entries.toList()) {
      if (note.accountId != session.accountId) {
        continue;
      }
      final share = byHash[key];
      if (share == null) {
        gone.add(key);
      } else if (note.state != RecordShareState.shared || note.id != share.id) {
        await _put(note.confirmedAs(id: share.id, url: share.url, sharedOn: share.sharedOn));
      }
    }
    await _drop(gone);
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
      shares.add((
        id: id,
        url: url,
        sharedOn: sharedOn,
        clientKeyHash: hash,
        summary: summary is Map<String, Object?> ? summary : const {},
      ));
    }
    return shares;
  }
}

final recordSharesProvider = NotifierProvider<RecordShares, Map<String, RecordShare>>(RecordShares.new);
