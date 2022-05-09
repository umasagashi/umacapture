import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umasagashi_app/src/state/settings_state.dart';

import '../core/utils.dart';

class _SectionGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionGroup({
    Key? key,
    required this.title,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Column(
        children: [
          ListTile(
            tileColor: theme.colorScheme.surfaceVariant,
            title: Text(
              title,
              style: theme.textTheme.headline5,
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _ThemeModeWidget extends ConsumerWidget {
  static const _iconMap = <ThemeMode, Widget>{
    ThemeMode.light: Icon(Icons.wb_sunny),
    ThemeMode.dark: Icon(Icons.brightness_3),
    ThemeMode.system: Icon(Icons.brightness_auto),
  };

  final String title;

  const _ThemeModeWidget({required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentMode = ref.watch(themeSettingProvider);
    final values = ref.read(themeSettingProvider.notifier).values;
    return ListTile(
      enableFeedback: true,
      title: Text(title),
      subtitle: Text(currentMode.name),
      trailing: ToggleButtons(
        isSelected: values.map((e) => e == currentMode).toList(),
        onPressed: (index) {
          ref.read(themeSettingProvider.notifier).setIndex(index);
        },
        children: values.map<Widget>((e) => _iconMap[e]!).toList(),
      ),
      onTap: () {
        ref.read(themeSettingProvider.notifier).next();
      },
    );
  }
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({Key? key})
      : title = 'settings',
        super(key: key);

  final String title;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    logger.d('_SettingsPageState.build');
    super.build(context);
    return Scaffold(
      body: ListView(
        children: const [
          _SectionGroup(
            title: 'Theme',
            children: [
              _ThemeModeWidget(title: 'Brightness'),
            ],
          ),
        ],
      ),
    );
  }
}
