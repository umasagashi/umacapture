import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import '/src/app/pages.dart';
import '/src/app/route.gr.dart';
import '/src/core/notification_controller.dart';
import '/src/core/platform_controller.dart';
import '/src/gui/chara_detail/data_table_widget.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';
import '/src/preference/window_state.dart';

final themeSettingProvider = StateNotifierProvider<ExclusiveItemsNotifier<ThemeMode>, ThemeMode>((ref) {
  final box = ref.watch(storageBoxProvider);
  return ExclusiveItemsNotifier<ThemeMode>(
    entry: StorageEntry(box: box, key: SettingsEntryKey.themeMode.name),
    values: [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
    defaultValue: ThemeMode.system,
  );
});

final fontBoldSettingProvider = StateNotifierProvider<BooleanNotifier, bool>((ref) {
  final box = ref.watch(storageBoxProvider);
  return BooleanNotifier(
    entry: StorageEntry(box: box, key: SettingsEntryKey.fontBold.name),
    defaultValue: true,
  );
});

final sidebarExtendedStateProvider = StateNotifierProvider<BooleanNotifier, bool>((ref) {
  final box = ref.watch(storageBoxProvider);
  return BooleanNotifier(
    entry: StorageEntry(box: box, key: SettingsEntryKey.sidebarExtended.name),
    defaultValue: true,
  );
});

StreamController<void> applicationWidgetRebuildEventController = StreamController();
final _applicationWidgetRebuildEventProvider = StreamProvider<void>((ref) {
  if (applicationWidgetRebuildEventController.hasListener) {
    applicationWidgetRebuildEventController = StreamController();
  }
  return applicationWidgetRebuildEventController.stream;
});

class _Sidebar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
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
                label: Text(pageLabel.label, style: theme.textTheme.titleMedium),
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
            style: ButtonStyle(shape: MaterialStateProperty.all(const RoundedRectangleBorder())),
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
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // To keep the state, child has to be placed on the same layer in both layouts.
        final wide = constraints.maxWidth >= 900;
        return Scaffold(
          appBar: wide
              ? null
              : AppBar(
                  title: Text(
                    Pages.at(router.activeIndex).label,
                    style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onPrimary),
                  ),
                ),
          drawer: wide ? null : const _Drawer(),
          body: NotificationLayer.asSibling(
            child: Row(
              children: [
                if (wide) _Sidebar(),
                Expanded(child: child),
              ],
            ),
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

class _WindowFrame extends ConsumerStatefulWidget {
  final Widget child;
  final WindowStateBox _windowStateBox;

  _WindowFrame({Key? key, required this.child})
      : _windowStateBox = WindowStateBox(),
        super(key: key);

  @override
  ConsumerState<_WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends ConsumerState<_WindowFrame> with WindowListener {
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
    final theme = Theme.of(context);
    return Container(
      // The top edge of the window frame is not visible, so 1 pixel padding is added instead.
      // But 1 pixel is thicker than the others, so the color is mixed with the title bar to make it look better.
      padding: const EdgeInsets.only(top: 1),
      color: theme.colorScheme.surface.blend(Colors.black, 50),
      child: Scaffold(
        appBar: _WindowTitleBar(
          icon: SizedBox(
            width: 24,
            height: 24,
            child: Image.asset("assets/image/app_icon.png", filterQuality: FilterQuality.medium),
          ),
          title: Text('umacapture', style: theme.textTheme.bodyMedium!),
        ),
        body: widget.child,
      ),
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
          return _WindowFrame(child: _ResponsiveScaffold(child: child));
        } else {
          return _ResponsiveScaffold(child: child);
        }
      },
    );
  }
}

class ApplicationWidget extends ConsumerStatefulWidget {
  final router = AppRouter();

  ApplicationWidget({Key? key}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => ApplicationWidgetState();
}

class ApplicationWidgetState extends ConsumerState<ApplicationWidget> {
  TextStyle? modifyFontWeight(TextStyle? base, int offset) {
    return base?.copyWith(
        fontWeight: FontWeight
            .values[math.min((base.fontWeight?.index ?? FontWeight.normal.index) + offset, FontWeight.w900.index)]);
  }

  ThemeData modifyTheme(WidgetRef ref, ThemeData base) {
    final offset = ref.watch(fontBoldSettingProvider) ? 3 : 0;
    return base.copyWith(
      tooltipTheme: base.tooltipTheme.copyWith(
        textStyle: modifyFontWeight(base.tooltipTheme.textStyle, offset),
        waitDuration: const Duration(milliseconds: 100),
        showDuration: Duration.zero,
      ),
      chipTheme: base.chipTheme.copyWith(
        labelStyle: modifyFontWeight(base.chipTheme.labelStyle, offset),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide.none),
        side: BorderSide(
          width: 0.5,
          color: base.chipTheme.selectedColor ?? base.colorScheme.primaryContainer,
        ),
        elevation: 0,
        pressElevation: 0,
      ),
      textTheme: base.textTheme.copyWith(
        displayLarge: modifyFontWeight(base.textTheme.displayLarge, offset),
        displayMedium: modifyFontWeight(base.textTheme.displayMedium, offset),
        displaySmall: modifyFontWeight(base.textTheme.displaySmall, offset),
        headlineLarge: modifyFontWeight(base.textTheme.headlineLarge, offset),
        headlineMedium: modifyFontWeight(base.textTheme.headlineMedium, offset),
        headlineSmall: modifyFontWeight(base.textTheme.headlineSmall, offset),
        titleLarge: modifyFontWeight(base.textTheme.titleLarge, offset),
        titleMedium: modifyFontWeight(base.textTheme.titleMedium, offset),
        titleSmall: modifyFontWeight(base.textTheme.titleSmall, offset),
        bodyLarge: modifyFontWeight(base.textTheme.bodyLarge, offset),
        bodyMedium: modifyFontWeight(base.textTheme.bodyMedium, offset),
        bodySmall: modifyFontWeight(base.textTheme.bodySmall, offset),
        labelLarge: modifyFontWeight(base.textTheme.labelLarge, offset),
        labelMedium: modifyFontWeight(base.textTheme.labelMedium, offset),
        labelSmall: modifyFontWeight(base.textTheme.labelSmall, offset),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Ensure that the controller is created at app startup.
    // If not, Auto Start option will not work.
    ref.read(platformControllerLoader);

    // Also, start up loaders here.
    ref.read(charaDetailInitialDataLoader);

    // Rebuild this widget when requested.
    ref.listen(_applicationWidgetRebuildEventProvider, (_, __) => setState(() {}));

    final theme = FlexThemeData.light(
      scheme: FlexScheme.blue,
      surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
      blendLevel: 20,
      appBarOpacity: 0.95,
      subThemesData: const FlexSubThemesData(
        blendOnLevel: 20,
        blendOnColors: false,
        navigationRailMutedUnselectedLabel: false,
        navigationRailMutedUnselectedIcon: false,
        navigationRailLabelType: NavigationRailLabelType.none,
      ),
      visualDensity: FlexColorScheme.comfortablePlatformDensity,
      useMaterial3: true,
      fontFamily: GoogleFonts.mPlusRounded1c().fontFamily,
    );

    final darkTheme = FlexThemeData.dark(
      scheme: FlexScheme.blue,
      surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
      blendLevel: 15,
      appBarStyle: FlexAppBarStyle.background,
      appBarOpacity: 0.90,
      subThemesData: const FlexSubThemesData(
        blendOnLevel: 30,
        navigationRailMutedUnselectedLabel: false,
        navigationRailMutedUnselectedIcon: false,
        navigationRailLabelType: NavigationRailLabelType.none,
      ),
      visualDensity: FlexColorScheme.comfortablePlatformDensity,
      useMaterial3: true,
      fontFamily: GoogleFonts.mPlusRounded1c().fontFamily,
    );

    final themeMode = ref.watch(themeSettingProvider);
    return MaterialApp.router(
      title: 'umacapture',
      theme: modifyTheme(ref, theme),
      darkTheme: modifyTheme(ref, darkTheme),
      themeMode: themeMode,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      routerDelegate: widget.router.delegate(),
      routeInformationParser: widget.router.defaultRouteParser(),
    );
  }
}
