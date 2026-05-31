import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

final _consoleLogger = Logger(
  level: kDebugMode ? Level.verbose : Level.info,
  filter: ProductionFilter(),
  printer: PrettyPrinter(
    printEmojis: false,
    printTime: true,
    lineLength: 80,
    colors: false,
  ),
);

SentryLevel _toSentryLevel(Level level) {
  switch (level) {
    case Level.verbose:
    case Level.debug:
      return SentryLevel.debug;
    case Level.info:
      return SentryLevel.info;
    case Level.warning:
      return SentryLevel.warning;
    case Level.error:
      return SentryLevel.error;
    case Level.wtf:
      return SentryLevel.fatal;
    default:
      return SentryLevel.info;
  }
}

class AppLogger {
  static const _maxBreadcrumbMessageLength = 1000;

  void v(dynamic message, [dynamic error, StackTrace? stackTrace]) =>
      log(Level.verbose, message, error, stackTrace);

  void d(dynamic message, [dynamic error, StackTrace? stackTrace]) =>
      log(Level.debug, message, error, stackTrace);

  void i(dynamic message, [dynamic error, StackTrace? stackTrace]) =>
      log(Level.info, message, error, stackTrace);

  void w(dynamic message, [dynamic error, StackTrace? stackTrace]) =>
      log(Level.warning, message, error, stackTrace);

  void e(dynamic message, [dynamic error, StackTrace? stackTrace]) =>
      log(Level.error, message, error, stackTrace);

  void wtf(dynamic message, [dynamic error, StackTrace? stackTrace]) =>
      log(Level.wtf, message, error, stackTrace);

  void log(Level level, dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _consoleLogger.log(level, message, error: error, stackTrace: stackTrace);
    if (level != Level.verbose) {
      _addBreadcrumb(level, message, error);
    }
  }

  void _addBreadcrumb(Level level, dynamic message, dynamic error) {
    if (!HubAdapter().isEnabled) return;

    var text = message?.toString() ?? '';
    if (text.length > _maxBreadcrumbMessageLength) {
      text = '${text.substring(0, _maxBreadcrumbMessageLength)}...';
    }

    Sentry.addBreadcrumb(Breadcrumb(
      message: text,
      level: _toSentryLevel(level),
      category: 'log',
      timestamp: DateTime.now().toUtc(),
      data: error == null ? null : {'error': error.toString()},
    ));
  }
}

final logger = AppLogger();

// riverpod 3 made ProviderObserver a `base` class and reshaped didUpdateProvider
// to receive a ProviderObserverContext instead of (provider, container).
base class ProviderLogger extends ProviderObserver {
  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final provider = context.provider;
    final String p = previousValue.toString();
    final String n = newValue.toString();
    const limit = 300;
    logger.v(
      "provider: ${provider.name ?? provider.runtimeType}, "
      "value: ${p.length < limit ? p : "${p.substring(0, limit)}..."}"
      " -> ${n.length < limit ? n : "${n.substring(0, limit)}..."}",
    );
  }
}
