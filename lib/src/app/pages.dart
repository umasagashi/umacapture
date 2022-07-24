import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '/src/app/route.gr.dart';

class PageLabel {
  final PageRouteInfo route;
  final String label;
  final Icon selectedIcon;
  final Icon unselectedIcon;

  const PageLabel({
    required this.route,
    required this.label,
    required this.selectedIcon,
    required this.unselectedIcon,
  });
}

class Pages {
  static final labels = <PageLabel>[
    PageLabel(
      route: const DashboardRoute(),
      label: "pages.dashboard.title".tr(),
      selectedIcon: const Icon(Icons.dashboard),
      unselectedIcon: const Icon(Icons.dashboard_outlined),
    ),
    PageLabel(
      route: const CaptureRoute(),
      label: "pages.capture.title".tr(),
      selectedIcon: const Icon(Icons.videocam),
      unselectedIcon: const Icon(Icons.videocam_outlined),
    ),
    PageLabel(
      route: const CharaDetailRoute(),
      label: "pages.chara_detail.title".tr(),
      selectedIcon: const Icon(Icons.manage_search),
      unselectedIcon: const Icon(Icons.manage_search_outlined),
    ),
    PageLabel(
      route: const SettingsRoute(),
      label: "pages.settings.title".tr(),
      selectedIcon: const Icon(Icons.settings),
      unselectedIcon: const Icon(Icons.settings_outlined),
    ),
  ];

  static final routes = labels.map((e) => e.route).toList();

  static PageLabel at(int index) => labels[index];
}
