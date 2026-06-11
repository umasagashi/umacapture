import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/app/route.dart';

class PageLabel {
  final PageRouteInfo route;
  final String label;
  final Icon selectedIcon;
  final Icon unselectedIcon;

  const PageLabel({required this.route, required this.label, required this.selectedIcon, required this.unselectedIcon});
}

class Pages {
  static final labels = <PageLabel>[
    PageLabel(
      route: const DashboardRoute(),
      label: "pages.dashboard.title".tr(),
      selectedIcon: const Icon(Symbols.dashboard_rounded, fill: 1),
      unselectedIcon: const Icon(Symbols.dashboard_rounded),
    ),
    PageLabel(
      route: const CaptureRoute(),
      label: "pages.capture.title".tr(),
      selectedIcon: const Icon(Symbols.videocam_rounded, fill: 1),
      unselectedIcon: const Icon(Symbols.videocam_rounded),
    ),
    PageLabel(
      route: const CharaDetailRoute(),
      label: "pages.chara_detail.title".tr(),
      selectedIcon: const Icon(Symbols.database_search_rounded, fill: 1),
      unselectedIcon: const Icon(Symbols.database_search_rounded),
    ),
    PageLabel(
      route: const AddonRoute(),
      label: "pages.addon.title".tr(),
      selectedIcon: const Icon(Symbols.extension_rounded, fill: 1),
      unselectedIcon: const Icon(Symbols.extension_rounded),
    ),
    PageLabel(
      route: const SettingsRoute(),
      label: "pages.settings.title".tr(),
      selectedIcon: const Icon(Symbols.settings_rounded, fill: 1),
      unselectedIcon: const Icon(Symbols.settings_rounded),
    ),
  ];

  static final routes = labels.map((e) => e.route).toList();

  static PageLabel at(int index) => labels[index];
}
