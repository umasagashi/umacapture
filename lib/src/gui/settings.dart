import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';

import '/src/chara_detail/storage.dart';
import '/src/gui/app_widget.dart';
import '/src/gui/capture.dart';
import '/src/gui/common.dart';
import '/src/state/notifier.dart';

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
  final String title;
  final String description;
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
      title: Text(title),
      subtitle: Text(description),
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
          title: "$tr_settings.style.font_bold.title".tr(),
          description: "$tr_settings.style.font_bold.description".tr(),
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
    return ListCard(
      title: "$tr_settings.capture.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        SwitchWidget(
          title: "$tr_settings.capture.auto_start.title".tr(),
          description: "$tr_settings.capture.auto_start.description".tr(),
          provider: autoStartCaptureStateProvider,
        ),
        DropdownButtonWidget<CharaDetailRecordImageMode?>(
          title: "$tr_settings.capture.auto_copy.title".tr(),
          description: "$tr_settings.capture.auto_copy.description".tr(),
          name: (e) => "$tr_settings.capture.auto_copy.choice.${(e?.name ?? "disabled").snakeCase}".tr(),
          provider: autoCopyClipboardStateProvider,
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
      ],
    );
  }
}
