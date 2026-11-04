import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '/const.dart';
import '/src/gui/chara_detail/account_sync_section.dart';
import '/src/gui/chara_detail/record_share_list_dialog.dart';
import '/src/gui/chara_detail/share_account_section.dart';
import '/src/gui/common.dart';

/// The account tab: the device's login to the sharing server, then what the account carries — sync and the shares —
/// and, last, deleting the account. Each card decides from the session whether it has anything to show, so a card
/// that would be empty is not drawn at all.
@RoutePage()
class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const ListTilePageRootWidget(
      maxContentWidth: settingsPageMaxContentWidth,
      children: [AccountIntroCard(), AccountCard(), AccountSyncCard(), RecordShareListCard(), AccountDeletionCard()],
    );
  }
}

/// What the account is for and what it keeps, with the privacy policy and the trial-release notice inline. Shown in
/// every login state, since it is what a reader weighs before logging in.
class AccountIntroCard extends StatelessWidget {
  const AccountIntroCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListCard(
      padding: const EdgeInsets.all(16),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinkedText(
          "$tr_share_account.intro.text".tr(),
          links: {
            "privacy": (label: "$tr_share_account.intro.privacy_link".tr(), url: Const.privacyUrl),
            "notice": (label: "$tr_share_account.intro.notice_link".tr(), url: Const.noticeUrl),
          },
        ),
      ],
    );
  }
}
