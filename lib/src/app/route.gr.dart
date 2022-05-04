// **************************************************************************
// AutoRouteGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AutoRouteGenerator
// **************************************************************************
//
// ignore_for_file: type=lint

import 'package:auto_route/auto_route.dart' as _i3;
import 'package:flutter/material.dart' as _i4;

import '../gui/app_widget.dart' as _i1;
import '../gui/dummy.dart' as _i2;

class AppRouter extends _i3.RootStackRouter {
  AppRouter([_i4.GlobalKey<_i4.NavigatorState>? navigatorKey])
      : super(navigatorKey);

  @override
  final Map<String, _i3.PageFactory> pagesMap = {
    AppWidget.name: (routeData) {
      return _i3.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i1.AppWidget());
    },
    DashboardRoute.name: (routeData) {
      return _i3.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i2.DashboardPage());
    },
    CaptureRoute.name: (routeData) {
      return _i3.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i2.CapturePage());
    },
    SearchRoute.name: (routeData) {
      return _i3.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i2.SearchPage());
    },
    SettingsRoute.name: (routeData) {
      return _i3.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i2.SettingsPage());
    },
    GuideRoute.name: (routeData) {
      return _i3.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i2.GuidePage());
    }
  };

  @override
  List<_i3.RouteConfig> get routes => [
        _i3.RouteConfig(AppWidget.name, path: '/', children: [
          _i3.RouteConfig(DashboardRoute.name,
              path: '', parent: AppWidget.name),
          _i3.RouteConfig(CaptureRoute.name,
              path: 'capture-page', parent: AppWidget.name),
          _i3.RouteConfig(SearchRoute.name,
              path: 'search-page', parent: AppWidget.name),
          _i3.RouteConfig(SettingsRoute.name,
              path: 'settings-page', parent: AppWidget.name),
          _i3.RouteConfig(GuideRoute.name,
              path: 'guide-page', parent: AppWidget.name)
        ])
      ];
}

/// generated route for
/// [_i1.AppWidget]
class AppWidget extends _i3.PageRouteInfo<void> {
  const AppWidget({List<_i3.PageRouteInfo>? children})
      : super(AppWidget.name, path: '/', initialChildren: children);

  static const String name = 'AppWidget';
}

/// generated route for
/// [_i2.DashboardPage]
class DashboardRoute extends _i3.PageRouteInfo<void> {
  const DashboardRoute() : super(DashboardRoute.name, path: '');

  static const String name = 'DashboardRoute';
}

/// generated route for
/// [_i2.CapturePage]
class CaptureRoute extends _i3.PageRouteInfo<void> {
  const CaptureRoute() : super(CaptureRoute.name, path: 'capture-page');

  static const String name = 'CaptureRoute';
}

/// generated route for
/// [_i2.SearchPage]
class SearchRoute extends _i3.PageRouteInfo<void> {
  const SearchRoute() : super(SearchRoute.name, path: 'search-page');

  static const String name = 'SearchRoute';
}

/// generated route for
/// [_i2.SettingsPage]
class SettingsRoute extends _i3.PageRouteInfo<void> {
  const SettingsRoute() : super(SettingsRoute.name, path: 'settings-page');

  static const String name = 'SettingsRoute';
}

/// generated route for
/// [_i2.GuidePage]
class GuideRoute extends _i3.PageRouteInfo<void> {
  const GuideRoute() : super(GuideRoute.name, path: 'guide-page');

  static const String name = 'GuideRoute';
}
