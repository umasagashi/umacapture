// U18: the texts a sharer publishes beside the shares — the tagline of one share, and the account's public profile
// (trainer name and in-game trainer id). The server keeps both and checks them; the app reads them, holds what it read
// as the value an edit starts from, and writes with that value as `previous`, so an edit never overwrites a value it
// did not see.
import 'package:dio/dio.dart';

import '/src/chara_detail/record_share_session.dart';
import '/src/core/utils.dart';

/// How many code points a tagline may hold, as the server counts them.
const taglineMaxLength = 80;

/// How many code points a trainer name may hold, as the server counts them.
const trainerNameMaxLength = 20;

/// The account's public profile. Each field is null when the sharer has not written it. [gameTrainerId] holds the
/// digits only, as the server stores it.
typedef SharerProfile = ({String? trainerName, String? gameTrainerId});

/// [text] as the server would store it: trimmed, and null when nothing is left.
String? canonicalSharerText(String text) {
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The digits of an in-game trainer id as typed — the separators the game shows (spaces, hyphens, commas) dropped —
/// or null when nothing is left. Whether they form an id is [isGameTrainerId]'s.
String? canonicalGameTrainerId(String text) => canonicalSharerText(text.replaceAll(RegExp(r"[\s\-,]"), ""));

/// Whether [digits] is an in-game trainer id: 9 or 12 ASCII digits.
bool isGameTrainerId(String digits) => RegExp(r"^(\d{9}|\d{12})$").hasMatch(digits);

/// [digits] grouped by three from the left, as the game shows an id.
String formatGameTrainerId(String digits) => [
  for (var i = 0; i < digits.length; i += 3) digits.substring(i, i + 3 > digits.length ? digits.length : i + 3),
].join(" ");

/// Why the server did not store a text.
enum SharerTextRefusal {
  /// The account's writes of today are used up.
  accountDailyLimit,

  /// Every account's writes of today are used up.
  serviceDailyLimit,

  /// Sharing is paused; only clearing a text goes through.
  sharingPaused,

  /// The account's sharing storage is full.
  storageFull,

  /// The server refused the text itself.
  invalid,

  /// The share is gone.
  shareGone,

  /// The server has no route for the text: it is older than the feature.
  unsupported,

  /// The account is being deleted.
  accountDeleting,
  loginRequired,
  unreachable,
  failed,
}

/// What writing a text ended with: [T] is the text's value as the server holds it.
sealed class SharerTextOutcome<T> {
  const SharerTextOutcome();
}

/// Stored; [value] is the server's form of it, the `previous` of the next edit.
final class SharerTextSaved<T> extends SharerTextOutcome<T> {
  final T value;

  const SharerTextSaved(this.value);
}

/// Nothing was stored: the value had changed elsewhere since the edit started. [current] is the value now.
final class SharerTextChanged<T> extends SharerTextOutcome<T> {
  final T current;

  const SharerTextChanged(this.current);
}

final class SharerTextRefused<T> extends SharerTextOutcome<T> {
  final SharerTextRefusal reason;

  const SharerTextRefused(this.reason);
}

SharerProfile? _profileOf(Object? map) {
  if (map is! Map) {
    return null;
  }
  final (name, id) = (map["trainer_name"], map["game_trainer_id"]);
  if (name is! String? || id is! String?) {
    return null;
  }
  return (trainerName: name, gameTrainerId: id);
}

Map<String, Object?> _profileJson(SharerProfile p) => {
  "trainer_name": p.trainerName,
  "game_trainer_id": p.gameTrainerId,
};

/// What reading the account's public profile ended with.
sealed class SharerProfileRead {
  const SharerProfileRead();
}

/// The server answered the profile.
final class SharerProfileHeld extends SharerProfileRead {
  final SharerProfile profile;

  const SharerProfileHeld(this.profile);
}

/// The server has no public profile: a Worker older than the profile answers `GET /api/me` without a `profile` key.
final class SharerProfileUnsupported extends SharerProfileRead {
  const SharerProfileUnsupported();
}

/// The read failed — no connection, a status other than 200, or a body that is not a profile. It says nothing about the
/// profile the server holds, so it does not replace one already read.
final class SharerProfileUnread extends SharerProfileRead {
  const SharerProfileUnread();
}

/// The account's public profile as `GET /api/me` answers under [under].
Future<SharerProfileRead> readSharerProfile(RecordShareSession session, ShareSession under) async {
  final ShareAnswer answer;
  try {
    answer = await session.send("GET", "/api/me", under: under);
  } on DioException {
    return const SharerProfileUnread();
  } on StateError {
    return const SharerProfileUnread();
  }
  final body = answer.body;
  if (answer.status != 200 || body == null) {
    return const SharerProfileUnread();
  }
  if (!body.containsKey("profile")) {
    logger.i("The sharing server has no public profile");
    return const SharerProfileUnsupported();
  }
  return switch (_profileOf(body["profile"])) {
    final profile? => SharerProfileHeld(profile),
    null => const SharerProfileUnread(),
  };
}

/// Writes the account's public profile as [value], over [previous] — the value the edit started from.
Future<SharerTextOutcome<SharerProfile>> writeSharerProfile(
  RecordShareSession session, {
  required SharerProfile value,
  required SharerProfile previous,
}) => _write(
  session,
  "/api/me/profile",
  {..._profileJson(value), "previous": _profileJson(previous)},
  read: (body) => _profileOf(body),
  readChanged: (body) => _profileOf(body["profile"]),
);

/// Writes the tagline of the account's share [shareId] as [value], over [previous] — the value the edit started from.
Future<SharerTextOutcome<String?>> writeShareTagline(
  RecordShareSession session,
  String shareId, {
  required String? value,
  required String? previous,
}) =>
    _write(
      session,
      "/api/shares/$shareId/tagline",
      {"tagline": value, "previous": previous},
      read: (body) => switch (body["tagline"]) {
        final String? t => (t,),
        _ => null,
      },
      readChanged: (body) => switch (body["tagline"]) {
        final String? t => (t,),
        _ => null,
      },
    ).then(
      (o) => switch (o) {
        SharerTextSaved(:final value) => SharerTextSaved(value.$1),
        SharerTextChanged(:final current) => SharerTextChanged(current.$1),
        SharerTextRefused(:final reason) => SharerTextRefused(reason),
      },
    );

Future<SharerTextOutcome<T>> _write<T extends Object>(
  RecordShareSession session,
  String path,
  Map<String, Object?> data, {
  required T? Function(Map<String, Object?> body) read,
  required T? Function(Map<String, Object?> body) readChanged,
}) async {
  SharerTextOutcome<T> refused(SharerTextRefusal r) => SharerTextRefused<T>(r);
  final ShareAnswer answer;
  try {
    answer = await session.send("PUT", path, data: data);
  } on DioException {
    return refused(SharerTextRefusal.unreachable);
  } on StateError {
    return refused(SharerTextRefusal.loginRequired);
  }
  final body = answer.body;
  final error = body?["error"];
  if (answer.status == 200 && body != null) {
    if (read(body) case final value?) {
      return SharerTextSaved<T>(value);
    }
    return refused(SharerTextRefusal.failed);
  }
  if (answer.status == 409 && error == "changed" && body != null) {
    if (readChanged(body) case final current?) {
      return SharerTextChanged<T>(current);
    }
    return refused(SharerTextRefusal.failed);
  }
  // The route's own 404 is JSON; a Worker that has no such route answers plain text.
  if (answer.status == 404) {
    return refused(error == "not_found" ? SharerTextRefusal.shareGone : SharerTextRefusal.unsupported);
  }
  return refused(switch ((answer.status, error)) {
    (401, _) => SharerTextRefusal.loginRequired,
    (429, "daily_limit") when body?["scope"] == "service" => SharerTextRefusal.serviceDailyLimit,
    (429, "daily_limit") => SharerTextRefusal.accountDailyLimit,
    (_, "sharing_paused") => SharerTextRefusal.sharingPaused,
    (_, "storage_full") => SharerTextRefusal.storageFull,
    (_, "invalid_payload") => SharerTextRefusal.invalid,
    (_, "account_deleting") => SharerTextRefusal.accountDeleting,
    _ => SharerTextRefusal.failed,
  });
}
