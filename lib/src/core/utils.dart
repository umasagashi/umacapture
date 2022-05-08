import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

final kIsDesktop = {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
}.contains(defaultTargetPlatform);

final kIsWindowed = !kIsWeb && kIsDesktop;

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
