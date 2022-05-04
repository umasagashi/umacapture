import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import 'route.gr.dart';

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
  static const labels = <PageLabel>[
    PageLabel(
      route: DashboardRoute(),
      label: 'Dashboard',
      selectedIcon: Icon(Icons.dashboard),
      unselectedIcon: Icon(Icons.dashboard_outlined),
    ),
    PageLabel(
      route: CaptureRoute(),
      label: 'Capture',
      selectedIcon: Icon(Icons.videocam),
      unselectedIcon: Icon(Icons.videocam_outlined),
    ),
    PageLabel(
      route: SearchRoute(),
      label: 'Search',
      selectedIcon: Icon(Icons.search),
      unselectedIcon: Icon(Icons.search_outlined),
    ),
    PageLabel(
      route: SettingsRoute(),
      label: 'Settings',
      selectedIcon: Icon(Icons.settings),
      unselectedIcon: Icon(Icons.settings_outlined),
    ),
    PageLabel(
      route: GuideRoute(),
      label: 'Guide',
      selectedIcon: Icon(Icons.help),
      unselectedIcon: Icon(Icons.help_outline),
    ),
  ];

  static final routes = labels.map((e) => e.route).toList();

  static PageLabel at(int index) => labels[index];
}
