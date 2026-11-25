// The account's public profile and list visibility, read together from the sharing server.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/record_share.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/sharer_text.dart';
import '/src/core/app_logger.dart';

/// What reading the account's list visibility ended with.
sealed class ListVisibilityRead {
  const ListVisibilityRead();
}

/// The server answered whether the account's list is public.
final class ListVisibilityHeld extends ListVisibilityRead {
  final bool public;

  const ListVisibilityHeld(this.public);
}

/// A Worker older than list visibility answers without a `list_public` key.
final class ListVisibilityUnsupported extends ListVisibilityRead {
  const ListVisibilityUnsupported();
}

/// No usable answer arrived; this says nothing about a value already held.
final class ListVisibilityUnread extends ListVisibilityRead {
  const ListVisibilityUnread();
}

typedef AccountPublicRead = ({SharerProfileRead profile, ListVisibilityRead list});

/// Null parts have not yet been answered. Each part otherwise keeps its last usable answer independently.
typedef AccountPublicState = ({SharerProfileRead? profile, ListVisibilityRead? list});

/// Older Workers always serve the list; an unanswered or unread value offers no list URL.
bool canOpenAccountList(ListVisibilityRead? read) => switch (read) {
  ListVisibilityHeld(public: true) || ListVisibilityUnsupported() => true,
  _ => false,
};

/// Reads both public settings in one request under [under].
Future<AccountPublicRead> readAccountPublic(RecordShareSession session, ShareSession under) async {
  const unread = (profile: SharerProfileUnread(), list: ListVisibilityUnread());
  final ShareAnswer answer;
  try {
    answer = await session.readMe(under: under);
  } on DioException {
    return unread;
  } on StateError {
    return unread;
  }
  final body = answer.body;
  if (answer.status != 200 || body == null) {
    return unread;
  }
  final profile = sharerProfileReadOf(body);
  final list = !body.containsKey("list_public")
      ? const ListVisibilityUnsupported()
      : switch (body["list_public"]) {
          final bool public => ListVisibilityHeld(public),
          _ => const ListVisibilityUnread(),
        };
  if (profile is SharerProfileUnsupported) {
    logger.i("The sharing server has no public profile");
  }
  if (list is ListVisibilityUnsupported) {
    logger.i("The sharing server has no list visibility");
  }
  return (profile: profile, list: list);
}

/// Writes the chosen visibility. The server's answer is authoritative; refusals leave the held value alone.
Future<SharerTextOutcome<bool>> writeListVisibility(RecordShareSession session, {required bool public}) async {
  final ShareAnswer answer;
  try {
    answer = await session.send("PUT", "/api/me/list", data: {"public": public});
  } on DioException {
    return const SharerTextRefused(SharerTextRefusal.unreachable);
  } on StateError {
    return const SharerTextRefused(SharerTextRefusal.loginRequired);
  }
  if (answer.status == 200) {
    return switch (answer.body?["public"]) {
      final bool stored => SharerTextSaved(stored),
      _ => const SharerTextRefused(SharerTextRefusal.failed),
    };
  }
  return SharerTextRefused(sharerTextRefusalOf(answer));
}

/// Holds the account's public settings, refreshing each time its shares are listed.
class AccountPublic extends Notifier<AccountPublicState> {
  int _request = 0;

  @override
  AccountPublicState build() {
    ref.watch(recordShareSessionProvider.select((session) => session?.accountId));
    // Rebuilding for another account invalidates every request of the previous account.
    _request++;
    ref.listen(shareListingsProvider, (_, _) => refresh());
    return (profile: null, list: null);
  }

  Future<void> refresh() async {
    final under = ref.read(recordShareSessionProvider);
    if (under == null || under.deleting) {
      return;
    }
    final request = ++_request;
    final read = await readAccountPublic(ref.read(recordShareSessionProvider.notifier), under);
    if (!ref.mounted || request != _request) {
      return;
    }
    state = (
      profile: switch ((read.profile, state.profile)) {
        (SharerProfileUnread(), final SharerProfileHeld held) => held,
        _ => read.profile,
      },
      list: switch ((read.list, state.list)) {
        (ListVisibilityUnread(), final ListVisibilityHeld held) => held,
        _ => read.list,
      },
    );
  }

  /// A save is newer than every read already in flight, and changes only the profile.
  void profileSaved(SharerProfile profile) {
    _request++;
    state = (profile: SharerProfileHeld(profile), list: state.list);
  }

  /// A save is newer than every read already in flight, and changes only the list visibility.
  void listSaved(bool public) {
    _request++;
    state = (profile: state.profile, list: ListVisibilityHeld(public));
  }
}

final accountPublicProvider = NotifierProvider.autoDispose<AccountPublic, AccountPublicState>(AccountPublic.new);
