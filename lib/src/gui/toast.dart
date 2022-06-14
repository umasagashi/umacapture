import 'dart:math';

import 'package:flutter/material.dart';

import '../core/utils.dart';

enum ToastType {
  success,
  info,
  warning,
  error,
}

class ToastData {
  final ToastType type;
  final String description;

  ToastData({required this.type, required this.description});

  ToastData.success(this.description) : type = ToastType.success;

  ToastData.info(this.description) : type = ToastType.info;

  ToastData.warning(this.description) : type = ToastType.warning;

  ToastData.error(this.description) : type = ToastType.error;
}

class Toaster {
  final double narrowWidth;
  final Duration duration;

  Toaster({
    this.narrowWidth = 600.0,
    required this.duration,
  });

  IconData _getIcon(ToastData data) {
    switch (data.type) {
      case ToastType.success:
        return Icons.check_circle;
      case ToastType.info:
        return Icons.info;
      case ToastType.warning:
        return Icons.warning;
      case ToastType.error:
        return Icons.dangerous;
      default:
        throw ArgumentError.value(data.type);
    }
  }

  Color _getColor(ToastData data) {
    switch (data.type) {
      case ToastType.success:
        return Colors.green.shade500;
      case ToastType.info:
        return Colors.blue.shade500;
      case ToastType.warning:
        return Colors.orange.shade500;
      case ToastType.error:
        return Colors.red.shade400;
      default:
        throw ArgumentError.value(data.type);
    }
  }

  void showToast(BuildContext context, ToastData data) {
    final snackBar = ScaffoldMessenger.of(context);
    final parentSize = MediaQuery.of(context).size;
    final barWidth = min(parentSize.width - 20.0, narrowWidth);
    final isNarrow = barWidth < narrowWidth;
    final icon = _getIcon(data);
    final color = _getColor(data);

    snackBar.showSnackBar(
      SnackBar(
        width: barWidth,
        padding: const EdgeInsets.symmetric(vertical: 10),
        behavior: SnackBarBehavior.floating,
        content: TextButton.icon(
          icon: Icon(icon, color: Colors.white),
          label: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Align(
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: Text(data.description, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
          style: ButtonStyle(overlayColor: MaterialStateProperty.all<Color>(Colors.transparent)),
          onPressed: () {
            logger.d('ToastLayer.onPressed');
            snackBar.hideCurrentSnackBar(reason: SnackBarClosedReason.action);
          },
        ),
        backgroundColor: color,
        duration: duration,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        dismissDirection: isNarrow ? DismissDirection.horizontal : DismissDirection.down,
        action: isNarrow ? null : SnackBarAction(textColor: Colors.white, label: 'CLOSE', onPressed: () {}),
      ),
    );
  }
}
