// Publishing a record to the record-sharing server, and withdrawing it again.
//
// Shared by web and Windows. The record leaves the device only as the posted form below; the server
// names the values, so the app sends sids. The delete key is made here, before anything is sent, and
// kept in the `publishedRecords` store: a reply that never arrives cannot leave a public record that
// nobody is able to withdraw.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/const.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/platform_controller.dart';
import '/src/core/sentry_util.dart';
import '/src/core/version_check.dart';
import '/src/preference/storage_box.dart';

part 'publication.mapper.dart';

/// Whether [record] may be published from this device: only a training of this device's trainer.
///
/// A device-side policy and not a defence: the server never receives `trainer_id`, so it can refuse a
/// friend's record type and nothing more.
bool canPublish(CharaDetailRecord record, String trainerId) =>
    !record.isFriend && record.metadata.trainerId == trainerId;

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

/// The posted form v1 of [record]: what `POST /api/records` receives as `record`.
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

/// A new delete key: 128 random bits, 22 characters, the form the server accepts.
String newDeleteKey() => _randomToken(16);

/// A new confirmation ticket: 256 random bits, 43 characters.
String newTicket() => _randomToken(32);

/// SHA-256 of [secret]'s UTF-8 text in lowercase hex: what the server stores, and the store's key.
String secretHash(String secret) => sha256.convert(utf8.encode(secret)).toString();

@MappableEnum()
enum PublicationState { pending, published }

/// One publication this device made, kept until the user withdraws it or drops the note.
///
/// Keyed in the store by [secretHash] of [deleteKey], which does not change when a pending
/// publication is confirmed, so confirming it is a single write.
@MappableClass(caseStyle: CaseStyle.snakeCase, ignoreNull: true)
class PublicationEntry with PublicationEntryMappable {
  final String recordId;
  final String deleteKey;
  final PublicationState state;
  final String? id;
  final String? url;
  final String? publishedOn;

  const PublicationEntry({
    required this.recordId,
    required this.deleteKey,
    required this.state,
    this.id,
    this.url,
    this.publishedOn,
  });

  String get keyHash => secretHash(deleteKey);
}

/// Why the server refused a publication, past the cases the app answers by itself.
enum PublishRefusal {
  dailyLimit,
  storageFull,
  serverTablesOlder,
  rejected,
  publishingPaused,
  temporarilyUnavailable,

  /// A 429 or 5xx that is not the server's own JSON: Cloudflare's rate limit or its daily quota.
  busy,
}

sealed class PublishOutcome {
  const PublishOutcome();
}

final class Published extends PublishOutcome {
  final PublicationEntry entry;

  const Published(this.entry);
}

/// The record is already public; it is withdrawn and published again to change it.
final class AlreadyPublished extends PublishOutcome {
  final PublicationEntry entry;

  const AlreadyPublished(this.entry);
}

/// Not a training of this device's trainer ([canPublish]). Nothing was sent.
final class NotPublishable extends PublishOutcome {
  const NotPublishable();
}

/// No installed module states its version, so the posted form cannot be made. Nothing was sent.
final class ModuleUnavailable extends PublishOutcome {
  const ModuleUnavailable();
}

/// The confirmation in the browser has to be done (again) before publishing.
final class TicketRequired extends PublishOutcome {
  const TicketRequired();
}

final class PublishRefused extends PublishOutcome {
  final PublishRefusal reason;
  final Duration? retryAfter;

  const PublishRefused(this.reason, {this.retryAfter});
}

/// No answer arrived. The pending note keeps the key, and publishing again resends with it.
final class PublishUnreachable extends PublishOutcome {
  const PublishUnreachable();
}

enum WithdrawOutcome { withdrawn, forbidden, unreachable, failed }

enum RecoveryOutcome { published, notOnServer, unreachable }

/// The [Dio] every sharing request goes through: diagnostics log the method, URL and status only.
final publicationDioProvider = Provider<Dio>((ref) => createDiagnosticDio(operation: "publish_record"));

/// The confirmation ticket, held in memory only and dropped when the server stops accepting it.
class PublicationTicket extends Notifier<String?> {
  @override
  String? build() => null;

  /// The confirmation page to open in the browser for the current ticket, making one if needed.
  ///
  /// Only the ticket's hash is in the URL: the ticket itself first leaves the device in a body.
  Uri verificationUrl() {
    final ticket = state ??= newTicket();
    return Uri.parse("${Const.sharingOrigin}/api/verify").replace(queryParameters: {"h": secretHash(ticket)});
  }

  void drop() => state = null;
}

final publicationTicketProvider = NotifierProvider<PublicationTicket, String?>(PublicationTicket.new);

/// The server's answer: its status and, when the body is the server's JSON, the `error` it names.
typedef _Answer = ({int status, Map<String, Object?>? body, Headers headers});

/// Whether the sharing API itself answered that the row does not exist.
///
/// A bare 404 is not enough: with sharing switched off, the assets-only deployment answers 404 for every API path
/// while the row is still stored.
bool _apiSaysNotFound(_Answer answer) => answer.status == 404 && answer.body?["error"] == "not_found";

Future<_Answer> _send(Dio dio, String method, String path, {Object? data, String? bearer}) async {
  final response = await dio.request<String>(
    "${Const.sharingOrigin}$path",
    data: data == null ? null : jsonEncode(data),
    options: Options(
      method: method,
      contentType: Headers.jsonContentType,
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      headers: {if (bearer != null) "Authorization": "Bearer $bearer"},
    ),
  );
  Map<String, Object?>? body;
  try {
    final decoded = jsonDecode(response.data ?? "");
    body = decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    body = null;
  }
  return (status: response.statusCode ?? 0, body: body, headers: response.headers);
}

PublishRefusal? _refusalOf(String? error) => switch (error) {
  "daily_limit" => PublishRefusal.dailyLimit,
  "storage_full" => PublishRefusal.storageFull,
  "server_tables_older" => PublishRefusal.serverTablesOlder,
  "invalid_payload" || "payload_too_large" => PublishRefusal.rejected,
  "publishing_paused" => PublishRefusal.publishingPaused,
  "temporarily_unavailable" => PublishRefusal.temporarilyUnavailable,
  _ => null,
};

Duration? _retryAfter(Headers headers) {
  final seconds = int.tryParse(headers.value("retry-after") ?? "");
  return seconds == null ? null : Duration(seconds: seconds);
}

String _today() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

/// The publications this device made, by [PublicationEntry.keyHash], mirrored in the store.
class PublishedRecords extends Notifier<Map<String, PublicationEntry>> {
  StorageBox get _box => StorageBox(StorageBoxKey.publishedRecords);

  @override
  Map<String, PublicationEntry> build() {
    final entries = <String, PublicationEntry>{};
    for (final (:key, :value) in _box.entries()) {
      if (value is String) {
        entries[key] = PublicationEntryMapper.fromJson(value);
      }
    }
    return entries;
  }

  Future<void> _put(PublicationEntry entry) async {
    state = {...state, entry.keyHash: entry};
    await _box.push(entry.keyHash, entry.toJson());
  }

  /// Drops the note for [keyHash]. Only the user does this: a key that is gone cannot withdraw.
  Future<void> forget(String keyHash) async {
    state = {...state}..remove(keyHash);
    await _box.delete(keyHash);
  }

  PublicationEntry? entryOf(String recordId) => state.values.where((e) => e.recordId == recordId).firstOrNull;

  /// Publishes [record], resending with the key of an unconfirmed earlier attempt on the same record.
  Future<PublishOutcome> publish(CharaDetailRecord record) async {
    if (!canPublish(record, ref.read(trainerIdProvider))) {
      return const NotPublishable();
    }
    final earlier = entryOf(record.id);
    if (earlier != null && earlier.state == PublicationState.published) {
      return AlreadyPublished(earlier);
    }
    final moduleVersion = (await ref.read(moduleVersionLoader.future))?.recognizerVersionText;
    if (moduleVersion == null) {
      return const ModuleUnavailable();
    }
    final ticket = ref.read(publicationTicketProvider);
    if (ticket == null) {
      return const TicketRequired();
    }
    final pending =
        earlier ?? PublicationEntry(recordId: record.id, deleteKey: newDeleteKey(), state: PublicationState.pending);
    // Kept before sending, so the key survives whatever happens to the reply.
    await _put(pending);
    return _answerPublish(pending, ticket, postedForm(record, moduleVersion: moduleVersion));
  }

  Future<PublishOutcome> _answerPublish(PublicationEntry pending, String ticket, Map<String, Object?> form) async {
    final _Answer answer;
    try {
      answer = await _send(
        ref.read(publicationDioProvider),
        "POST",
        "/api/records",
        data: {"ticket": ticket, "delete_key": pending.deleteKey, "record": form},
      );
    } on DioException {
      return const PublishUnreachable();
    }
    if (answer.status == 200 || answer.status == 201) {
      final published = _confirmed(pending, answer.body);
      if (published == null) {
        return const PublishRefused(PublishRefusal.busy);
      }
      await _put(published);
      return Published(published);
    }
    final error = answer.body?["error"] as String?;
    if (answer.status == 401 && error == "ticket_required") {
      ref.read(publicationTicketProvider.notifier).drop();
      return const TicketRequired();
    }
    final reason = _refusalOf(error) ?? PublishRefusal.busy;
    return PublishRefused(reason, retryAfter: _retryAfter(answer.headers));
  }

  PublicationEntry? _confirmed(PublicationEntry pending, Map<String, Object?>? body) {
    final id = body?["id"];
    final url = body?["url"];
    if (id is! String || url is! String) {
      return null;
    }
    return PublicationEntry(
      recordId: pending.recordId,
      deleteKey: pending.deleteKey,
      state: PublicationState.published,
      id: id,
      url: url,
      publishedOn: _today(),
    );
  }

  /// Asks the server whether the pending note [keyHash] was published, and confirms it if so.
  ///
  /// The API's own 404 leaves the note alone: the user decides whether to drop it. Any other 404 is not an answer
  /// about the row, so it is [RecoveryOutcome.unreachable].
  Future<RecoveryOutcome> recover(String keyHash) async {
    final entry = state[keyHash];
    if (entry == null) {
      return RecoveryOutcome.notOnServer;
    }
    final _Answer answer;
    try {
      answer = await _send(
        ref.read(publicationDioProvider),
        "POST",
        "/api/records/lookup",
        data: {"delete_key": entry.deleteKey},
      );
    } on DioException {
      return RecoveryOutcome.unreachable;
    }
    final published = answer.status == 200 ? _confirmed(entry, answer.body) : null;
    if (published != null) {
      await _put(published);
      return RecoveryOutcome.published;
    }
    return _apiSaysNotFound(answer) ? RecoveryOutcome.notOnServer : RecoveryOutcome.unreachable;
  }

  /// Withdraws the publication [keyHash]. The API's own 404 means it is already gone, which is the same result.
  ///
  /// Any other 404 keeps the key: the row may still be stored, and the key is the only way left to remove it.
  Future<WithdrawOutcome> withdraw(String keyHash) async {
    final entry = state[keyHash];
    final id = entry?.id;
    if (entry == null || id == null) {
      return WithdrawOutcome.failed;
    }
    final _Answer answer;
    try {
      answer = await _send(ref.read(publicationDioProvider), "DELETE", "/api/records/$id", bearer: entry.deleteKey);
    } on DioException {
      return WithdrawOutcome.unreachable;
    }
    if (answer.status == 204 || _apiSaysNotFound(answer)) {
      await forget(keyHash);
      return WithdrawOutcome.withdrawn;
    }
    return answer.status == 403 ? WithdrawOutcome.forbidden : WithdrawOutcome.failed;
  }
}

final publishedRecordsProvider = NotifierProvider<PublishedRecords, Map<String, PublicationEntry>>(
  PublishedRecords.new,
);
