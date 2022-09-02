import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:recase/recase.dart';
import 'package:url_launcher/url_launcher.dart';

import '/const.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/platform_controller.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/app_widget.dart';
import '/src/gui/capture.dart';
import '/src/gui/common.dart';
import '/src/gui/license_alt.dart' as license;
import '/src/preference/notifier.dart';
import '/src/preference/privacy_setting.dart';

// ignore: constant_identifier_names
const tr_settings = "pages.settings";

class ToggleButtonWidget<T> extends ConsumerWidget {
  final String title;
  final String description;
  final Widget Function(T) icon;
  final StateNotifierProvider<ExclusiveItemsNotifier<T>, T> provider;

  const ToggleButtonWidget({
    Key? key,
    required this.title,
    required this.description,
    required this.icon,
    required this.provider,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(provider);
    final values = ref.read(provider.notifier).values;
    return ListTile(
      isThreeLine: true,
      title: Text(title),
      subtitle: Text(description),
      trailing: Align(
        widthFactor: 1,
        child: ToggleButtons(
          isSelected: values.map((e) => e == current).toList(),
          onPressed: (index) => ref.read(provider.notifier).setIndex(index),
          children: values.map<Widget>((e) => icon(e)).toList(),
        ),
      ),
      onTap: () => ref.read(provider.notifier).next(),
    );
  }
}

class DropdownButtonWidget<T> extends ConsumerWidget {
  final String title;
  final String description;
  final String Function(T) name;
  final StateNotifierProvider<ExclusiveItemsNotifier<T>, T> provider;

  const DropdownButtonWidget({
    Key? key,
    required this.title,
    required this.description,
    required this.name,
    required this.provider,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(provider);
    final values = ref.read(provider.notifier).values;
    final theme = Theme.of(context);
    return ListTile(
      isThreeLine: true,
      title: Text(title),
      subtitle: Text(description),
      trailing: PopupMenuButton<T>(
        // disable tool tip
        tooltip: '',
        initialValue: current,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<T>>[
          for (final item in values)
            PopupMenuItem<T>(
              value: item,
              child: Text(name(item)),
            ),
        ],
        onSelected: (T item) => ref.read(provider.notifier).setValue(item),
        child: Container(
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(vertical: 8),
          width: 100,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(width: 1, color: theme.colorScheme.onBackground)),
          ),
          child: Text(name(current)),
        ),
      ),
      onTap: () => ref.read(provider.notifier).next(),
    );
  }
}

class SwitchWidget extends ConsumerWidget {
  final Widget title;
  final Widget description;
  final StateNotifierProvider<BooleanNotifier, bool> provider;

  const SwitchWidget({
    Key? key,
    required this.title,
    required this.description,
    required this.provider,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      isThreeLine: true,
      title: title,
      subtitle: description,
      trailing: Align(
        widthFactor: 1,
        child: Switch(
          value: ref.watch(provider),
          onChanged: (enabled) => ref.read(provider.notifier).set(enabled),
        ),
      ),
      onTap: () => ref.read(provider.notifier).toggle(),
    );
  }
}

class _BrightnessWidget extends ConsumerWidget {
  static final _iconMap = <ThemeMode, Widget>{
    ThemeMode.light: Tooltip(
      message: "$tr_settings.style.brightness.choice.light".tr(),
      child: const Icon(Icons.wb_sunny),
    ),
    ThemeMode.dark: Tooltip(
      message: "$tr_settings.style.brightness.choice.dark".tr(),
      child: const Icon(Icons.brightness_3),
    ),
    ThemeMode.system: Tooltip(
      message: "$tr_settings.style.brightness.choice.system".tr(),
      child: const Icon(Icons.brightness_auto),
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ToggleButtonWidget<ThemeMode>(
      title: "$tr_settings.style.brightness.title".tr(),
      description: "$tr_settings.style.brightness.description".tr(),
      icon: (mode) => _iconMap[mode]!,
      provider: themeSettingProvider,
    );
  }
}

class StyleSettingsGroup extends ConsumerWidget {
  const StyleSettingsGroup({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_settings.style.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        _BrightnessWidget(),
        SwitchWidget(
          title: Text("$tr_settings.style.font_bold.title".tr()),
          description: Text("$tr_settings.style.font_bold.description".tr()),
          provider: fontBoldSettingProvider,
        ),
      ],
    );
  }
}

class CaptureSettingsGroup extends ConsumerWidget {
  const CaptureSettingsGroup({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCapturing = ref.watch(capturingStateProvider);
    return ListCard(
      title: "$tr_settings.capture.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        SwitchWidget(
          title: Text("$tr_settings.capture.auto_start.title".tr()),
          description: Text("$tr_settings.capture.auto_start.description".tr()),
          provider: autoStartCaptureStateProvider,
        ),
        DropdownButtonWidget<CharaDetailRecordImageMode?>(
          title: "$tr_settings.capture.auto_copy.title".tr(),
          description: "$tr_settings.capture.auto_copy.description".tr(),
          name: (e) => "$tr_settings.capture.auto_copy.choice.${e!.name.snakeCase}".tr(),
          provider: autoCopyClipboardStateProvider,
        ),
        Disabled(
          disabled: isCapturing,
          tooltip: "$tr_settings.capture.force_resize.disabled_tooltip".tr(),
          child: SwitchWidget(
            title: Text("$tr_settings.capture.force_resize.title".tr()),
            description: Text("$tr_settings.capture.force_resize.description".tr()),
            provider: forceResizeModeStateProvider,
          ),
        ),
      ],
    );
  }
}

class SystemGroup extends ConsumerWidget {
  const SystemGroup({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_settings.system.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        DropdownButtonWidget<ClipboardPasteImageMode?>(
          title: "$tr_settings.system.clipboard_paste_image_mode.title".tr(),
          description: "$tr_settings.system.clipboard_paste_image_mode.description".tr(),
          name: (e) => "$tr_settings.system.clipboard_paste_image_mode.choice.${e!.name.snakeCase}".tr(),
          provider: clipboardPasteImageModeProvider,
        ),
      ],
    );
  }
}

class PrivacySettingsGroup extends ConsumerWidget {
  const PrivacySettingsGroup({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListCard(
      title: "$tr_settings.privacy.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        SwitchWidget(
          title: Text(
            "$tr_settings.privacy.allow_post_user_data.title".tr(),
          ),
          description: RichText(
            text: TextSpan(
              style: theme.textTheme.bodyMedium!.copyWith(
                color: theme.textTheme.bodyMedium!.color!.withOpacity(0.8),
              ),
              children: [
                TextSpan(text: "$tr_settings.privacy.allow_post_user_data.description".tr()),
                TextSpan(
                  text: "$tr_settings.privacy.allow_post_user_data.sample_link".tr(),
                  style: const TextStyle(decoration: TextDecoration.underline),
                  recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Const.sentrySampleUrl),
                ),
              ],
            ),
          ),
          provider: allowPostUserDataStateProvider,
        ),
      ],
    );
  }
}

class _LicenseMaterialLocalizationsDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _LicenseMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';

  @override
  Future<MaterialLocalizations> load(Locale locale) => _LicenseMaterialLocalizations.load(locale);

  @override
  bool shouldReload(_LicenseMaterialLocalizationsDelegate old) => false;

  @override
  String toString() => 'LicenseMaterialLocalizations.delegate(en_US)';
}

class _LicenseMaterialLocalizations extends DefaultMaterialLocalizations {
  const _LicenseMaterialLocalizations();

  static const LocalizationsDelegate<MaterialLocalizations> delegate = _LicenseMaterialLocalizationsDelegate();

  static Future<MaterialLocalizations> load(Locale locale) {
    return SynchronousFuture<MaterialLocalizations>(const _LicenseMaterialLocalizations());
  }

  @override
  String get licensesPageTitle => "";
}

class _LicensePageDialog extends ConsumerWidget {
  const _LicensePageDialog({
    Key? key,
  }) : super(key: key);

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const _LicensePageDialog());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CardDialog(
      dialogTitle: "$tr_settings.about.license.dialog.title".tr(),
      closeButtonTooltip: "$tr_settings.about.license.dialog.close_button".tr(),
      usePageView: false,
      content: Expanded(
        child: Localizations(
          delegates: const <LocalizationsDelegate<dynamic>>[
            _LicenseMaterialLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
            DefaultMaterialLocalizations.delegate,
          ],
          locale: const Locale('en'),
          child: license.LicensePage(
            applicationVersion: ref.read(localAppVersionLoader).value.toString(),
          ),
        ),
      ),
    );
  }
}

class AboutGroup extends ConsumerWidget {
  const AboutGroup({Key? key}) : super(key: key);

  String moduleVersion(WidgetRef ref) {
    return ref.watch(moduleVersionLoader).when(
          loading: () => "checking...",
          error: (e, __) => "ERROR: $e",
          data: (data) => data?.toLocal().toString() ?? "$tr_settings.version_check.unknown_version".tr(),
        );
  }

  String appVersion(WidgetRef ref) {
    return ref.watch(appVersionCheckLoader).when(
          loading: () => "checking...",
          error: (e, __) => "ERROR: $e",
          data: (data) => data.local.toString(),
        );
  }

  String versionString(WidgetRef ref) {
    return "$tr_settings.about.version.description".tr(namedArgs: {
      "app_version": appVersion(ref),
      "module_version": moduleVersion(ref),
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_settings.about.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        ListTile(
          title: Text("$tr_settings.about.license.title".tr()),
          subtitle: Text("$tr_settings.about.license.description".tr()),
          onTap: () {
            _LicensePageDialog.show(ref.base);
          },
        ),
        ListTile(
          isThreeLine: true,
          title: Text("$tr_settings.about.version.title".tr()),
          subtitle: Text(versionString(ref)),
          trailing: const Align(
            widthFactor: 1,
            child: Padding(
              padding: EdgeInsets.only(right: 16),
              child: Icon(Icons.paste),
            ),
          ),
          onTap: () => Pasteboard.writeText(versionString(ref)),
        ),
      ],
    );
  }
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const ListTilePageRootWidget(
      children: [
        StyleSettingsGroup(),
        CaptureSettingsGroup(),
        SystemGroup(),
        PrivacySettingsGroup(),
        AboutGroup(),
      ],
    );
  }
}
