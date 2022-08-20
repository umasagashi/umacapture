import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '/src/gui/common.dart';

class WindowCaptionButtonAlt extends StatefulWidget {
  final Widget icon;
  final String tooltip;
  final VoidCallback onPressed;

  const WindowCaptionButtonAlt({
    Key? key,
    required this.icon,
    this.tooltip = "",
    required this.onPressed,
  }) : super(key: key);

  @override
  State<WindowCaptionButtonAlt> createState() => _WindowCaptionButtonState();
}

class _WindowCaptionButtonState extends State<WindowCaptionButtonAlt> {
  bool hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onExit: (value) => setState(() => hovering = false),
        onHover: (value) => setState(() => hovering = true),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 46, minHeight: kWindowCaptionHeight),
            decoration: BoxDecoration(
              color: hovering ? theme.colorScheme.onSurface.withOpacity(0.06) : Colors.transparent,
            ),
            child: Center(
              child: widget.icon,
            ),
          ),
        ),
      ),
    );
  }
}

class WindowCaptionAlt extends StatefulWidget implements PreferredSizeWidget {
  const WindowCaptionAlt({Key? key}) : super(key: key);

  @override
  State<WindowCaptionAlt> createState() => _WindowCaptionAltState();

  @override
  Size get preferredSize => const Size.fromHeight(kWindowCaptionHeight);
}

class _WindowCaptionAltState extends State<WindowCaptionAlt> with WindowListener {
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
  void onWindowMaximize() {
    setState(() {});
  }

  @override
  void onWindowUnmaximize() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSentryEnabled = HubAdapter().isEnabled;
    return Container(
      color: theme.colorScheme.surface,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Image.asset(
                      "assets/image/app_icon.png",
                      filterQuality: FilterQuality.medium,
                      height: 24,
                    ),
                  ),
                  Text('umacapture', style: theme.textTheme.bodyMedium!),
                ],
              ),
            ),
          ),
          if (isSentryEnabled)
            WindowCaptionButtonAlt(
              icon: Icon(
                Icons.feedback_outlined,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              tooltip: "app.feedback.tooltip".tr(),
              onPressed: () {
                showFeedbackDialog(context);
              },
            ),
          WindowCaptionButton.minimize(
            brightness: theme.brightness,
            onPressed: () async {
              bool isMinimized = await windowManager.isMinimized();
              if (isMinimized) {
                windowManager.restore();
              } else {
                windowManager.minimize();
              }
            },
          ),
          FutureBuilder<bool>(
            future: windowManager.isMaximized(),
            builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
              if (snapshot.data == true) {
                return WindowCaptionButton.unmaximize(
                  brightness: theme.brightness,
                  onPressed: () {
                    windowManager.unmaximize();
                  },
                );
              }
              return WindowCaptionButton.maximize(
                brightness: theme.brightness,
                onPressed: () {
                  windowManager.maximize();
                },
              );
            },
          ),
          WindowCaptionButton.close(
            brightness: theme.brightness,
            onPressed: () {
              windowManager.close();
            },
          ),
        ],
      ),
    );
  }
}
