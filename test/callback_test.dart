// Unit tests for the small callback utilities: the value-binding extension and
// the ChangeNotifier subclass that re-exposes notifyListeners().
//
// Run: .fvm/flutter_sdk/bin/flutter test test/callback_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/callback.dart';

void main() {
  group('CallbackExtension.bind', () {
    test('captures the value and forwards it on each call', () {
      final received = <int>[];
      final Callback<int> callback = received.add;

      final bound = callback.bind(7);
      bound();
      bound();

      expect(received, [7, 7]);
    });

    test('separate bindings of the same callback stay independent', () {
      final received = <String>[];
      final Callback<String> callback = received.add;

      callback.bind('a')();
      callback.bind('b')();

      expect(received, ['a', 'b']);
    });

    test('binds a null value for a nullable callback', () {
      int? seen = -1;
      void capture(int? value) => seen = value;

      capture.bind(null)();

      expect(seen, isNull);
    });
  });

  group('PlainChangeNotifier', () {
    test('notifies every registered listener on each call', () {
      final notifier = PlainChangeNotifier();
      var a = 0;
      var b = 0;
      notifier.addListener(() => a++);
      notifier.addListener(() => b++);

      notifier.notifyListeners();
      notifier.notifyListeners();

      expect(a, 2);
      expect(b, 2);
    });

    test('a removed listener no longer fires', () {
      final notifier = PlainChangeNotifier();
      var count = 0;
      void listener() => count++;
      notifier.addListener(listener);

      notifier.notifyListeners();
      notifier.removeListener(listener);
      notifier.notifyListeners();

      expect(count, 1);
    });

    test('notifying after dispose throws (ChangeNotifier contract)', () {
      final notifier = PlainChangeNotifier()..dispose();
      expect(notifier.notifyListeners, throwsFlutterError);
    });
  });
}
