import 'package:flutter/services.dart';

import '/src/core/callback.dart';
import '/src/core/path_entity.dart';
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

  Future<void> setConfig(String config) {
    return channel.invokeMethod('setConfig', config);
  }

  Future<void> setPlatformConfig(String config) {
    return channel.invokeMethod('setPlatformConfig', config);
  }

  Future<void> startCapture() {
    return channel.invokeMethod('startCapture');
  }

  Future<void> stopCapture() {
    return channel.invokeMethod('stopCapture');
  }

  Future<void> updateRecord(String id) {
    return channel.invokeMethod('updateRecord', id);
  }

  Future<void> copyToClipboardFromFile(FilePath path) {
    return channel.invokeMethod('copyToClipboardFromFile', path.path);
  }

  Future<void> takeScreenshot(FilePath path) {
    return channel.invokeMethod('takeScreenshot', path.path);
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
