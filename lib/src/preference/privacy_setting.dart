import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/sentry_util.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

/// The consent switch, which additionally discards the telemetry ID on opt-out.
///
/// Every opt-out reaches [set] (the settings switch calls it directly, and `toggle`
/// delegates to it), so this is the one place the deletion has to hang off. Opting
/// in again mints a fresh ID rather than resurrecting the old one; see
/// [deleteTelemetryId].
class _AllowPostUserDataNotifier extends BooleanNotifier {
  _AllowPostUserDataNotifier({required super.defaultValue, super.entryKey});

  @override
  void set(bool value) {
    super.set(value);
    if (!value) {
      deleteTelemetryId();
    }
  }
}

final allowPostUserDataStateProvider = BooleanNotifierProvider(() {
  return _AllowPostUserDataNotifier(entryKey: SettingsEntryKey.allowPostUserData.name, defaultValue: true);
});

StorageEntry<bool> _getAllowPostUserDataSettingEntry() {
  return StorageBox(StorageBoxKey.settings).entry<bool>(SettingsEntryKey.allowPostUserData.name);
}

enum PostUserData { notConfirmed, allow, deny }

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
