import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

final logger = Logger(printer: PrettyPrinter(printEmojis: false, lineLength: 100));

typedef CallbackMethod = void Function(String);

class MyChannel {
  static const channel = MethodChannel('dev.flutter.umasagashi_app/capturing_channel');
  CallbackMethod? callbackMethod;

  MyChannel() {
    channel.setMethodCallHandler(callDartFromJava);
  }

  void setCallback(CallbackMethod method) {
    callbackMethod = method;
  }

  Future<void> callJavaFromDart(String value) async {
    return await channel.invokeMethod('callJavaFromDart', value);
  }

  Future<dynamic> callDartFromJava(MethodCall call) {
    switch (call.method) {
      case 'callDartFromJava':
        logger.d('callDartFromJava ${call.arguments.toString()}');
        callbackMethod!(call.arguments.toString());
        return Future.value('called from platform!');
      default:
        logger.d('Unknowm method ${call.method}');
        throw MissingPluginException();
    }
  }
}
