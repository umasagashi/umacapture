import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

class CurrentPlatform {
  static bool isWindows() {
    return defaultTargetPlatform == TargetPlatform.windows;
  }

  static bool isLinux() {
    return defaultTargetPlatform == TargetPlatform.linux;
  }

  static bool isMacOS() {
    return defaultTargetPlatform == TargetPlatform.macOS;
  }

  static bool isAndroid() {
    return defaultTargetPlatform == TargetPlatform.android;
  }

  static bool isIOS() {
    return defaultTargetPlatform == TargetPlatform.iOS;
  }

  static bool isWeb() {
    return kIsWeb;
  }

  static bool isMobile() {
    return isAndroid() || isIOS();
  }

  static bool isDesktop() {
    return isWindows() || isLinux() || isMacOS();
  }

  static bool hasWindowFrame() {
    return !isWeb() && isDesktop();
  }
}

final logger = Logger(
    printer: PrettyPrinter(
  printEmojis: false,
  printTime: true,
  lineLength: 80,
));

class ProviderLogger extends ProviderObserver {
  @override
  void didUpdateProvider(
    ProviderBase provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    logger.d(
      'provider: ${provider.name ?? provider.runtimeType}, '
      'value: $previousValue -> $newValue',
    );
  }
}

class StreamSubscriptionController {
  List<StreamSubscription> subscriptions = [];

  void update<T>({
    required Iterable<Stream<T>> streams,
    required void Function(T event) onData,
  }) {
    for (final sub in subscriptions) {
      sub.cancel();
    }
    subscriptions.clear();
    for (final stream in streams) {
      subscriptions.add(stream.listen(onData));
    }
  }
}
