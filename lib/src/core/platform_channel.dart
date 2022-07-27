import 'package:flutter/services.dart';

import '/src/core/callback.dart';
import '/src/core/utils.dart';

typedef PlatformCallback = StringCallback;

class PlatformChannel {
  static const channel = MethodChannel('dev.flutter.umasagashi/capturing_channel');
  PlatformCallback? callbackMethod;

  PlatformChannel() {
    channel.setMethodCallHandler(callbackFromPlatform);
  }

  void setCallback(PlatformCallback method) {
    callbackMethod = method;
  }

  Future<void> setConfig(String config) async {
    logger.d('setConfig: ${config.length}');
    return await channel.invokeMethod('setConfig', config);
  }

  Future<void> startCapture() async {
    logger.d('startCapture');
    return await channel.invokeMethod('startCapture');
  }

  Future<void> stopCapture() async {
    return await channel.invokeMethod('stopCapture');
  }

  Future<dynamic> callbackFromPlatform(MethodCall call) {
    switch (call.method) {
      case 'notify':
        callbackMethod!(call.arguments.toString());
        return Future.value('called from platform!');
      default:
        logger.d('Unknowm method ${call.method}');
        throw MissingPluginException();
    }
  }
}
