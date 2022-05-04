import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:window_manager/window_manager.dart';

import '../app/pages.dart';

final logger = Logger(printer: PrettyPrinter(printEmojis: false, lineLength: 100));

class _Sidebar extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  late bool _extended;

  @override
  void initState() {
    super.initState();
    _extended = true;
  }

  void toggleExtend() {
    setState(() {
      _extended = !_extended;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabsRouter = AutoTabsRouter.of(context);
    return Stack(
      children: [
        NavigationRail(
          extended: _extended,
          selectedIndex: tabsRouter.activeIndex,
          useIndicator: true,
          destinations: [
            for (final pageLabel in Pages.labels)
              NavigationRailDestination(
                icon: pageLabel.unselectedIcon,
                selectedIcon: pageLabel.selectedIcon,
                label: Text(pageLabel.label),
                padding: EdgeInsets.zero,
              ),
          ],
          onDestinationSelected: (index) => tabsRouter.setActiveIndex(index),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: TextButton(
            child: Icon(_extended ? Icons.chevron_left : Icons.chevron_right),
            onPressed: () => toggleExtend(),
          ),
        ),
      ],
    );
  }
}

class _Drawer extends StatelessWidget {
  const _Drawer({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final tabsRouter = AutoTabsRouter.of(context);
    return Drawer(
      child: ListView(
        children: [
          for (final entry in Pages.labels.asMap().entries)
            ListTile(
              leading: entry.value.unselectedIcon,
              title: Text(entry.value.label),
              onTap: () {
                tabsRouter.setActiveIndex(entry.key);
                context.router.pop();
              },
            )
        ],
      ),
    );
  }
}

class _ResponsiveScaffold extends StatelessWidget {
  final Widget child;

  const _ResponsiveScaffold({
    Key? key,
    required this.child,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final router = AutoTabsRouter.of(context); // router can stay outside of LayoutBuilder.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // To keep the state, child has to be placed on the same layer in both layouts.
        final wide = constraints.maxWidth >= 900;
        return Scaffold(
          appBar: wide ? null : AppBar(title: Text(Pages.at(router.activeIndex).label)),
          drawer: wide ? null : const _Drawer(),
          body: Row(
            children: [
              if (wide) _Sidebar(),
              Expanded(child: child),
            ],
          ),
        );
      },
    );
  }
}

class _WindowTitleBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget icon;
  final Widget title;

  const _WindowTitleBar({
    Key? key,
    required this.icon,
    required this.title,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WindowCaption(
      brightness: theme.brightness,
      backgroundColor: theme.colorScheme.surface,
      title: Container(
        transform: Matrix4.translationValues(-16, 0, 0), // Remove fixed padding in WindowCaption.
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: FittedBox(child: icon),
            ),
            title,
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kWindowCaptionHeight);
}

class _Windowed extends StatelessWidget {
  final Widget child;

  const _Windowed({Key? key, required this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const _WindowTitleBar(
        icon: Icon(Icons.circle_outlined),
        title: Text('umasagashi'),
      ),
      body: child,
    );
  }
}

class AppWidget extends StatelessWidget {
  const AppWidget({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final kIsDesktop = {
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);

    return AutoTabsRouter(
      routes: Pages.routes,
      builder: (context, child, animation) {
        if (!kIsWeb && kIsDesktop) {
          return _Windowed(child: _ResponsiveScaffold(child: child));
        } else {
          return _ResponsiveScaffold(child: child);
        }
      },
    );
  }
}
