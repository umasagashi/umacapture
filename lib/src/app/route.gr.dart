// **************************************************************************
// AutoRouteGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AutoRouteGenerator
// **************************************************************************
//
// ignore_for_file: type=lint

import 'package:auto_route/auto_route.dart' as _i6;
import 'package:flutter/material.dart' as _i7;

import '../gui/app_widget.dart' as _i1;
import '../gui/capture.dart' as _i3;
import '../gui/chara_detail.dart' as _i4;
import '../gui/dashboard.dart' as _i2;
import '../gui/settings.dart' as _i5;

class AppRouter extends _i6.RootStackRouter {
  AppRouter([_i7.GlobalKey<_i7.NavigatorState>? navigatorKey])
      : super(navigatorKey);

  @override
  final Map<String, _i6.PageFactory> pagesMap = {
    AppWidget.name: (routeData) {
      return _i6.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i1.AppWidget());
    },
    DashboardRoute.name: (routeData) {
      return _i6.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i2.DashboardPage());
    },
    CaptureRoute.name: (routeData) {
      return _i6.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i3.CapturePage());
    },
    CharaDetailRoute.name: (routeData) {
      return _i6.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i4.CharaDetailPage());
    },
    SettingsRoute.name: (routeData) {
      return _i6.MaterialPageX<dynamic>(
          routeData: routeData, child: const _i5.SettingsPage());
    }
  };

  @override
  List<_i6.RouteConfig> get routes => [
        _i6.RouteConfig(AppWidget.name, path: '/', children: [
          _i6.RouteConfig(DashboardRoute.name,
              path: '', parent: AppWidget.name),
          _i6.RouteConfig(CaptureRoute.name,
              path: 'capture-page', parent: AppWidget.name),
          _i6.RouteConfig(CharaDetailRoute.name,
              path: 'chara-detail-page', parent: AppWidget.name),
          _i6.RouteConfig(SettingsRoute.name,
              path: 'settings-page', parent: AppWidget.name)
        ])
      ];
}

/// generated route for
/// [_i1.AppWidget]
class AppWidget extends _i6.PageRouteInfo<void> {
  const AppWidget({List<_i6.PageRouteInfo>? children})
      : super(AppWidget.name, path: '/', initialChildren: children);

  static const String name = 'AppWidget';
}

/// generated route for
/// [_i2.DashboardPage]
class DashboardRoute extends _i6.PageRouteInfo<void> {
  const DashboardRoute() : super(DashboardRoute.name, path: '');

  static const String name = 'DashboardRoute';
}

/// generated route for
/// [_i3.CapturePage]
class CaptureRoute extends _i6.PageRouteInfo<void> {
  const CaptureRoute() : super(CaptureRoute.name, path: 'capture-page');

  static const String name = 'CaptureRoute';
}

/// generated route for
/// [_i4.CharaDetailPage]
class CharaDetailRoute extends _i6.PageRouteInfo<void> {
  const CharaDetailRoute()
      : super(CharaDetailRoute.name, path: 'chara-detail-page');

  static const String name = 'CharaDetailRoute';
}

/// generated route for
/// [_i5.SettingsPage]
class SettingsRoute extends _i6.PageRouteInfo<void> {
  const SettingsRoute() : super(SettingsRoute.name, path: 'settings-page');

  static const String name = 'SettingsRoute';
}
