import 'package:auto_route/auto_route.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import '../app/pages.dart';
import '../app/route.gr.dart';
import '../preference/window_state.dart';
import '../state/settings_state.dart';

class _Sidebar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabsRouter = AutoTabsRouter.of(context);
    final isExtended = ref.watch(sidebarExtendedStateProvider);
    return Stack(
      children: [
        NavigationRail(
          extended: isExtended,
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
            child: Icon(isExtended ? Icons.chevron_left : Icons.chevron_right),
            onPressed: () => ref.read(sidebarExtendedStateProvider.notifier).toggle(),
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

class _Windowed extends ConsumerStatefulWidget {
  final Widget child;
  final WindowStateBox _windowStateBox;

  _Windowed({Key? key, required this.child})
      : _windowStateBox = WindowStateBox(),
        super(key: key);

  @override
  ConsumerState<_Windowed> createState() => _WindowedState();
}

class _WindowedState extends ConsumerState<_Windowed> with WindowListener {
  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowResized() {
    windowManager.getSize().then((size) => widget._windowStateBox.setSize(size));
    super.onWindowResized();
  }

  @override
  void onWindowMoved() {
    windowManager.getPosition().then((offset) => widget._windowStateBox.setOffset(offset));
    super.onWindowMoved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const _WindowTitleBar(
        icon: Icon(Icons.circle_outlined),
        title: Text('umasagashi'),
      ),
      body: widget.child,
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

class App extends ConsumerWidget {
  App({Key? key}) : super(key: key);

  final _router = AppRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeSettingProvider);

    return MaterialApp.router(
      title: 'umasagashi',
      theme: FlexThemeData.light(
        scheme: FlexScheme.blue,
        surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
        blendLevel: 20,
        appBarOpacity: 0.95,
        subThemesData: const FlexSubThemesData(
          blendOnLevel: 20,
          blendOnColors: false,
          navigationRailIndicatorOpacity: 0.54,
          navigationRailOpacity: 0.98,
          navigationRailLabelType: NavigationRailLabelType.none,
        ),
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        fontFamily: GoogleFonts.notoSans().fontFamily,
      ),
      darkTheme: FlexThemeData.dark(
        scheme: FlexScheme.blue,
        surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
        blendLevel: 18,
        appBarStyle: FlexAppBarStyle.background,
        appBarOpacity: 0.90,
        appBarElevation: 12.5,
        subThemesData: const FlexSubThemesData(
          blendOnLevel: 30,
          navigationRailIndicatorOpacity: 0.54,
          navigationRailOpacity: 0.98,
          navigationRailLabelType: NavigationRailLabelType.none,
        ),
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        fontFamily: GoogleFonts.notoSans().fontFamily,
      ),
      themeMode: themeMode,
      routerDelegate: _router.delegate(),
      routeInformationParser: _router.defaultRouteParser(),
    );
  }
}
