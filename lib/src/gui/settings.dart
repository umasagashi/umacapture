import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umasagashi_app/src/state/notifier.dart';

import 'app_widget.dart';

class ListCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const ListCard({
    Key? key,
    this.title,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Column(
        children: [
          if (title != null)
            ListTile(
              tileColor: theme.colorScheme.surfaceVariant,
              title: Text(title!, style: theme.textTheme.headline5),
            ),
          ...children,
        ],
      ),
    );
  }
}

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
        child: Container(
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(vertical: 8),
          width: 100,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(width: 1, color: theme.colorScheme.onBackground)),
          ),
          child: Text(name(current)),
        ),
        initialValue: current,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<T>>[
          for (final item in values)
            PopupMenuItem<T>(
              value: item,
              child: Text(name(item)),
            ),
        ],
        onSelected: (T item) => ref.read(provider.notifier).setValue(item),
        tooltip: '', // disable tool tip
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

class _BrightnessWidget extends ToggleButtonWidget<ThemeMode> {
  static const _iconMap = <ThemeMode, Widget>{
    ThemeMode.light: Icon(Icons.wb_sunny),
    ThemeMode.dark: Icon(Icons.brightness_3),
    ThemeMode.system: Icon(Icons.brightness_auto),
  };

  _BrightnessWidget({
    Key? key,
  }) : super(
          key: key,
          title: 'Brightness',
          description: 'Change the brightness of this app.',
          icon: (mode) => _iconMap[mode]!,
          provider: themeSettingProvider,
        );
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: ListView(
        children: [
          ListCard(
            title: 'Theme',
            children: [
              _BrightnessWidget(),
            ],
          ),
        ],
      ),
    );
  }
}
