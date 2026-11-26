import 'dart:async';

/// How code that acts on wall-clock moments tells time: the device clock ([now]) and the timer it waits with
/// ([timer]). Held behind a provider so tests can hold both.
class DeviceTime {
  const DeviceTime({this.now = DateTime.now, this.timer = Timer.new});

  final DateTime Function() now;
  final Timer Function(Duration duration, void Function() callback) timer;
}
