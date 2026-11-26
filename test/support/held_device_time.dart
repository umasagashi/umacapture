// The device's time ([DeviceTime]) held by a test, for the code that tells time through a provider: the record
// sync's moments and the sharing session's expiry.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/device_time.dart';

/// The device's time ([DeviceTime]), held by the test: the clock it sets ([now]), and each
/// timer started ([timers]), which it fires ([HeldTimer.fire]).
class HeldDeviceTime {
  DateTime now = DateTime.utc(2030);

  /// Every timer started, the first first.
  final timers = <HeldTimer>[];

  DeviceTime get time => DeviceTime(
    now: () => now,
    timer: (duration, callback) {
      final timer = HeldTimer(duration, callback);
      timers.add(timer);
      return timer;
    },
  );
}

/// A timer of [HeldDeviceTime]: it runs [_callback] when the test fires it, where it was not cancelled.
class HeldTimer implements Timer {
  HeldTimer(this.duration, this._callback);

  /// The time it was started for.
  final Duration duration;
  final void Function() _callback;
  var _active = true;

  /// Runs it, as its time coming does.
  void fire() {
    expect(_active, isTrue, reason: 'a timer that was cancelled, or has run, does not run');
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}
