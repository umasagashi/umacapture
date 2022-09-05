import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/sentry_util.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

// ignore: constant_identifier_names
const tr_privacy = "app.privacy";

final allowPostUserDataStateProvider = BooleanNotifierProvider((ref) {
  final box = ref.watch(storageBoxProvider);
  return BooleanNotifier(
    entry: StorageEntry(box: box, key: SettingsEntryKey.allowPostUserData.name),
    defaultValue: true,
  );
});

StorageEntry<bool> _getAllowPostUserDataSettingEntry() {
  return StorageBox(StorageBoxKey.settings).entry<bool>(SettingsEntryKey.allowPostUserData.name);
}

enum PostUserData {
  notConfirmed,
  allow,
  deny,
}

PostUserData allowPostUserData() {
  final value = _getAllowPostUserDataSettingEntry().pull();
  if (value == null) {
    return PostUserData.notConfirmed;
  } else if (value) {
    return PostUserData.allow;
  } else {
    return PostUserData.deny;
  }
}

bool isFeedbackAvailable(WidgetRef ref) {
  return isSentryAvailable() && ref.watch(allowPostUserDataStateProvider);
}
