import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_controller.dart';
import '../core/utils.dart';

final _toastStreamsProvider = Provider<List<StreamProvider<ToastData>>>((ref) {
  return [
    platformStreamProvider,
  ];
});

enum ToastType {
  success,
  error,
}

class ToastData {
  final ToastType type;
  final String description;

  ToastData({required this.type, required this.description});

  ToastData.success(this.description) : type = ToastType.success;

  ToastData.error(this.description) : type = ToastType.error;
}

class ToastLayer extends ConsumerWidget {
  const ToastLayer({Key? key}) : super(key: key);

  static Widget asSibling({required Widget child}) {
    return Column(
      children: [
        Expanded(child: child),
        const ToastLayer(),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    for (final stream in ref.watch(_toastStreamsProvider)) {
      ref.watch(stream).whenData((data) => _showToast(context, data));
    }
    return Container();
  }

  IconData getIcon(ToastData data) {
    switch (data.type) {
      case ToastType.success:
        return Icons.check_circle;
      case ToastType.error:
        return Icons.error;
      default:
        throw ArgumentError.value(data.type);
    }
  }

  Color getColor(ToastData data) {
    switch (data.type) {
      case ToastType.success:
        return Colors.green.shade500;
      case ToastType.error:
        return Colors.red.shade400;
      default:
        throw ArgumentError.value(data.type);
    }
  }

  void _showToast(BuildContext context, ToastData data) {
    final snackBar = ScaffoldMessenger.of(context);
    final parentSize = MediaQuery.of(context).size;
    final barWidth = min(parentSize.width - 20.0, 600.0);
    final isNarrow = barWidth < 600.0;
    final icon = getIcon(data);
    final color = getColor(data);
    const duration = Duration(seconds: 10);

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
            logger.d('onPressed');
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
