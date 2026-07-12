import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';

import '/src/addon/addon_dispatcher.dart';
import '/src/app/pages.dart';
import '/src/app/route.dart';
import '/src/core/notification_controller.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/data_table_widget.dart';
import '/src/gui/common.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/window_manager_alt.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/window_state.dart';

final kIsDesktop = {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(defaultTargetPlatform);

final themeSettingProvider = ExclusiveItemsNotifierProvider<ThemeMode>(() {
  return ExclusiveItemsNotifier<ThemeMode>(
    entryKey: SettingsEntryKey.themeMode.name,
    values: [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
    defaultValue: ThemeMode.system,
  );
});

final fontBoldSettingProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.fontBold.name, defaultValue: true);
});

final sidebarExtendedStateProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.sidebarExtended.name, defaultValue: true);
});

final applicationWidgetRebuildEvent = EventStreamProvider<void>();
final _applicationWidgetRebuildEventProvider = applicationWidgetRebuildEvent.provider;

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
          // Slightly narrower than the M3 default (256) when expanded; the
          // labels do not need the full width and it leaves more room for content.
          minExtendedWidth: 220,
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
            style: ButtonStyle(shape: WidgetStateProperty.all(const RoundedRectangleBorder())),
            child: Icon(isExtended ? Symbols.chevron_left_rounded : Symbols.chevron_right_rounded),
            onPressed: () => ref.read(sidebarExtendedStateProvider.notifier).toggle(),
          ),
        ),
      ],
    );
  }
}

class _Drawer extends StatelessWidget {
  const _Drawer();

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
            ),
        ],
      ),
    );
  }
}

class _ResponsiveScaffold extends StatelessWidget {
  final Widget child;

  const _ResponsiveScaffold({required this.child});

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
                    // Match the M3 surface app bar (background is colorScheme.surface,
                    // icons are onSurface); onPrimary here was a leftover from the
                    // dropped primary-colored app-bar style and read near-white on
                    // the light surface.
                    style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onSurface),
                  ),
                ),
          drawer: wide ? null : const _Drawer(),
          body: Stack(
            fit: StackFit.expand,
            children: [
              NotificationLayer.asSibling(
                child: Row(
                  children: [
                    if (wide) _Sidebar(),
                    Expanded(child: child),
                  ],
                ),
              ),
              // Invisible sibling that runs addon tasks on app events. Mounted
              // here so it lives for the whole session, like NotificationLayer.
              const AddonDispatcher(),
            ],
          ),
        );
      },
    );
  }
}

class _WindowFrame extends ConsumerStatefulWidget {
  final Widget child;
  final WindowStateBox _windowStateBox;

  _WindowFrame({required this.child}) : _windowStateBox = WindowStateBox();

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
      color: theme.colorScheme.surface,
      child: Scaffold(appBar: const WindowCaptionAlt(), body: widget.child),
    );
  }
}

@RoutePage(name: 'AppWidgetRoute')
class AppWidget extends StatelessWidget {
  const AppWidget({super.key});

  Widget root(Widget child) {
    return DialogLayer(child: _ResponsiveScaffold(child: child));
  }

  @override
  Widget build(BuildContext context) {
    return AutoTabsRouter(
      routes: Pages.routes,
      builder: (context, child) {
        if (!kIsWeb && kIsDesktop) {
          return _WindowFrame(child: root(child));
        } else {
          return root(child);
        }
      },
    );
  }
}

class ApplicationWidget extends ConsumerStatefulWidget {
  final router = AppRouter();

  ApplicationWidget({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => ApplicationWidgetState();
}

class ApplicationWidgetState extends ConsumerState<ApplicationWidget> {
  @override
  void initState() {
    super.initState();
    // Reclaim scratch space left over from a previous run. The native pipeline
    // can leave scraping fragments in the temp tree when a capture is interrupted
    // (or the app is killed), so empty it once at startup -- keeping the temp
    // directory itself -- rather than on exit, which never runs after a crash.
    ref.read(pathInfoLoader.future).then((info) => info.tempDir.clearSync()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      logger.e("Failed to clear temp directory on startup.", error, stackTrace);
    });
  }

  TextStyle? modifyFontWeight(TextStyle? base, int offset) {
    // FontWeight.index was deprecated in favor of the numeric `value` (100-900).
    // Reproduce the old index (value ~/ 100 - 1, clamped to 0..8) and step by `offset`,
    // capping at w900 (index 8), then pick from the still-supported `values` list.
    const maxIndex = 8; // FontWeight.w900 is the last of the 9 standard weights.
    final baseValue = base?.fontWeight?.value ?? FontWeight.normal.value;
    final baseIndex = (baseValue ~/ 100 - 1).clamp(0, maxIndex);
    return base?.copyWith(fontWeight: FontWeight.values[Math.min(baseIndex + offset, maxIndex)]);
  }

  ThemeData modifyTheme(WidgetRef ref, ThemeData base) {
    final offset = ref.watch(fontBoldSettingProvider) ? 3 : 0;
    final isLight = base.colorScheme.brightness == Brightness.light;
    // Recolor the two lowest surface-container tints to a pale "water blue"
    // derived from secondaryContainer (lightened toward the surface), so the
    // lowest cards/rows read with a soft blue cast instead of neutral grey.
    final scheme = base.colorScheme;
    final tintedScheme = scheme.copyWith(
      surfaceContainerLowest: Color.lerp(scheme.secondaryContainer, scheme.surface, 0.65),
      surfaceContainerLow: Color.lerp(scheme.secondaryContainer, scheme.surface, 0.45),
      // An even paler tint than surfaceContainerLowest (further lightened toward
      // surface), used as the subtle fill behind outlined NoteCard groups.
      surfaceBright: Color.lerp(scheme.secondaryContainer, scheme.surface, 0.82),
      // Role consolidation (frees the now-unused tertiaryContainer /
      // onTertiaryContainer names). Values are preserved, only the role they live
      // under changes: secondary absorbs the old tertiary accent (script column),
      // and tertiary now carries the card/dialog header band — the base
      // (pre-lightened) scaffold tint, paired with the old onTertiaryContainer.
      secondary: scheme.tertiary,
      onSecondary: scheme.onTertiary,
      tertiary: base.scaffoldBackgroundColor,
      onTertiary: scheme.onTertiaryContainer,
    );
    return base.copyWith(
      colorScheme: tintedScheme,
      // Page background uses the surfaceContainerHigh role.
      scaffoldBackgroundColor: scheme.surfaceContainerHigh,
      extensions: <ThemeExtension<dynamic>>[
        isLight ? AppSemanticColors.light(base.colorScheme) : AppSemanticColors.dark(base.colorScheme),
        AppChartColors.standard(),
        isLight ? CodeHighlightColors.light() : CodeHighlightColors.dark(),
      ],
      tooltipTheme: base.tooltipTheme.copyWith(
        textStyle: modifyFontWeight(base.tooltipTheme.textStyle, offset),
        waitDuration: const Duration(milliseconds: 100),
        showDuration: Duration.zero,
      ),
      // Chips carry a subtle outlineVariant border app-wide and default to a
      // single neutral tone (surfaceContainerHigh). `side` is set explicitly
      // because FilterChip/ChoiceChip otherwise paint the Material 3
      // state-dependent outline (unselected), which overrides `shape.side`.
      // Per-chip `backgroundColor` / `shape` still override these (e.g.
      // primaryContainer action chips, the circular add button, selected filter
      // chips).
      chipTheme: base.chipTheme.copyWith(
        labelStyle: modifyFontWeight(base.chipTheme.labelStyle, offset),
        backgroundColor: base.colorScheme.surfaceContainerHigh,
        selectedColor: base.colorScheme.primaryContainer,
        side: BorderSide(color: base.colorScheme.outlineVariant, width: 0.5),
        shape: const StadiumBorder(),
      ),
      // Cards sit on the base surface role app-wide; raised accents (e.g. the
      // ListCard header band) layer above it via surfaceContainer roles.
      cardTheme: base.cardTheme.copyWith(color: scheme.surface),
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
      iconTheme: base.iconTheme.copyWith(weight: 600),
      // NavigationRail replaces (does not merge) the ambient IconTheme for its
      // destinations, so the global iconTheme weight above never reaches the
      // sidebar icons. Re-apply the weight on the rail's own icon themes while
      // preserving the size/color FlexColorScheme set.
      navigationRailTheme: base.navigationRailTheme.copyWith(
        selectedIconTheme: (base.navigationRailTheme.selectedIconTheme ?? const IconThemeData()).copyWith(weight: 600),
        unselectedIconTheme: (base.navigationRailTheme.unselectedIconTheme ?? const IconThemeData()).copyWith(
          weight: 600,
        ),
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
    ref.listen(_applicationWidgetRebuildEventProvider, (_, _) => setState(() {}));

    // Standard FlexColorScheme / Material-3 baseline, plus a light surface blend
    // (surfaceMode + blendLevel) to restore the previous brand-tinted surfaces.
    // Other legacy tuning (app-bar opacity/style, on-level blends) stays dropped
    // and is reapplied incrementally if needed.
    final lightTheme = modifyTheme(
      ref,
      FlexThemeData.light(
        scheme: FlexScheme.blue,
        surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
        blendLevel: 20,
        subThemesData: const FlexSubThemesData(outlinedButtonOutlineSchemeColor: SchemeColor.primary),
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        fontFamily: GoogleFonts.mPlusRounded1c().fontFamily,
      ),
    );

    final darkTheme = modifyTheme(
      ref,
      FlexThemeData.dark(
        scheme: FlexScheme.blue,
        surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
        blendLevel: 15,
        subThemesData: const FlexSubThemesData(outlinedButtonOutlineSchemeColor: SchemeColor.primary),
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        fontFamily: GoogleFonts.mPlusRounded1c().fontFamily,
      ),
    );

    final themeMode = ref.watch(themeSettingProvider);
    // BetterFeedback wraps MaterialApp (see FeedbackLayer docs): inside MaterialApp
    // it would override the app ColorScheme for all content.
    return FeedbackLayer(
      lightTheme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      child: MaterialApp.router(
        title: 'umacapture',
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: themeMode,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        routerConfig: widget.router.config(navigatorObservers: () => [AutoRouteObserver()]),
      ),
    );
  }
}
