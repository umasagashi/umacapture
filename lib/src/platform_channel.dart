import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

final logger = Logger(printer: PrettyPrinter(printEmojis: false, lineLength: 100));

typedef CallbackMethod = void Function(String);

class MyChannel {
  static const channel = MethodChannel('dev.flutter.umasagashi_app/capturing_channel');
  CallbackMethod? callbackMethod;

  MyChannel() {
    channel.setMethodCallHandler(callbackFromPlatform);
  }

  void setCallback(CallbackMethod method) {
    callbackMethod = method;
  }

  Future<void> setConfig(String config) async {
    logger.d('setConfig $config');
    return await channel.invokeMethod('setConfig', config);
  }

  Future<void> startCapture() async {
    return await channel.invokeMethod('startCapture');
  }

  Future<void> stopCapture() async {
    return await channel.invokeMethod('stopCapture');
  }

  Future<dynamic> callbackFromPlatform(MethodCall call) {
    switch (call.method) {
      case 'notify':
        logger.d('notify ${call.arguments.toString()}');
        callbackMethod!(call.arguments.toString());
        return Future.value('called from platform!');
      default:
        logger.d('Unknowm method ${call.method}');
        throw MissingPluginException();
    }
  }
}
