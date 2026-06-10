// Driver-enabled entrypoint for live demonstration / manual driving of the real
// app. Registers the Flutter Driver extension, then runs the production main()
// unchanged, so the app behaves exactly as shipped but can be driven from an
// external Flutter Driver client (e.g. the Dart MCP flutter_driver tooling).
//
// Run: .fvm/flutter_sdk/bin/flutter run -d windows -t test_driver/app.dart
import 'package:flutter_driver/driver_extension.dart';
import 'package:umacapture/main.dart' as app;

Future<void> main() async {
  enableFlutterDriverExtension();
  await app.main();
}
