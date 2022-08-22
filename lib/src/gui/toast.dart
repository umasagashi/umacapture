import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/utils.dart';

StreamController<ToastData> _plainToastEventController = StreamController();
final plainToastEventProvider = StreamProvider<ToastData>((ref) {
  if (_plainToastEventController.hasListener) {
    _plainToastEventController = StreamController();
  }
  return _plainToastEventController.stream;
});

enum ToastType {
  success,
  info,
  warning,
  error,
}

class ToastData {
  final ToastType type;
  final String? description;
  final Widget? label;
  final Duration? duration;
  final VoidCallback? onTap;
  final PageRouteInfo? navigateOnTab;

  ToastData(this.type, {this.description, this.label, this.duration, this.onTap, this.navigateOnTab}) {
    assert(description != null || label != null);
  }
}

class Toaster {
  static show(ToastData data) {
    _plainToastEventController.sink.add(data);
  }

  final double narrowWidth;
  final Map<ToastType, Duration> durationMap = {
    ToastType.success: const Duration(seconds: 5),
    ToastType.info: const Duration(seconds: 5),
    ToastType.warning: const Duration(seconds: 10),
    ToastType.error: const Duration(seconds: 10),
  };
  final Map<ToastType, IconData> iconMap = {
    ToastType.success: Icons.check_circle,
    ToastType.info: Icons.info,
    ToastType.warning: Icons.warning,
    ToastType.error: Icons.dangerous,
  };
  final Map<ToastType, Color> colorMap = {
    ToastType.success: Colors.green.shade500,
    ToastType.info: Colors.blue.shade500,
    ToastType.warning: Colors.orange.shade500,
    ToastType.error: Colors.red.shade400,
  };

  Toaster({
    this.narrowWidth = 600.0,
  });

  void showToast(BuildContext context, ToastData data) {
    final snackBar = ScaffoldMessenger.of(context);
    final parentSize = MediaQuery.of(context).size;
    final barWidth = Math.min(parentSize.width - 20.0, narrowWidth);
    final isNarrow = barWidth < narrowWidth;

    snackBar.showSnackBar(
      SnackBar(
        width: barWidth,
        padding: const EdgeInsets.symmetric(vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        backgroundColor: colorMap[data.type],
        behavior: SnackBarBehavior.floating,
        dismissDirection: isNarrow ? DismissDirection.horizontal : DismissDirection.down,
        duration: data.duration ?? durationMap[data.type]!,
        action: isNarrow ? null : SnackBarAction(textColor: Colors.white, label: 'CLOSE', onPressed: () {}),
        content: TextButton.icon(
          icon: Icon(iconMap[data.type], color: Colors.white),
          label: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Align(
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: data.label ?? Text(data.description!, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
          style: ButtonStyle(overlayColor: MaterialStateProperty.all<Color>(Colors.transparent)),
          onPressed: () {
            snackBar.hideCurrentSnackBar(reason: SnackBarClosedReason.action);
            data.onTap?.call();
            if (data.navigateOnTab != null) {
              AutoTabsRouter.of(context).navigate(data.navigateOnTab!);
            }
          },
        ),
      ),
    );
  }
}
