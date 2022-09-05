import 'package:easy_localization/easy_localization.dart';

// ignore: depend_on_referenced_packages
import 'package:easy_logger/easy_logger.dart';
import 'package:logger/logger.dart';

import '/src/core/utils.dart';

extension LevelMessagesExtension on LevelMessages {
  Level get asLoggerLevel {
    switch (this) {
      case LevelMessages.debug:
        return Level.debug;
      case LevelMessages.info:
        return Level.info;
      case LevelMessages.warning:
        return Level.warning;
      case LevelMessages.error:
        return Level.error;
    }
  }
}

void _easyLocalizationPrinter(Object object, {String? name, StackTrace? stackTrace, LevelMessages? level}) {
  final loggerLevel = level?.asLoggerLevel ?? EasyLocalization.logger.defaultLevel.asLoggerLevel;
  final message = "$name: ${object.toString()}";
  if (stackTrace == null) {
    logger.log(loggerLevel, message);
  } else {
    logger.log(loggerLevel, message, "EasyLocalizationError", stackTrace);
  }
}

Future<void> setupLocalization() async {
  EasyLocalization.logger = EasyLogger(
    name: "Easy Localization",
    printer: _easyLocalizationPrinter,
    enableLevels: [
      // LevelMessages.debug,
      LevelMessages.info,
      LevelMessages.error,
      LevelMessages.warning,
    ],
  );
  await EasyLocalization.ensureInitialized();
}
