// The time a value is written at.
//
// A record's body and archive state, and each rating, memo and column title, are one value held with the time it
// was written: of two, the later stands. That time is the writing device's clock, except that it is always after the
// time of the value it replaces — a device whose clock is behind the value it holds writes just after that value, so a
// value this device writes never loses to the one it replaced ([syncWriteTime]). Every time a value is written at comes
// from [valueWriteTime], whichever value it is.

import 'package:flutter/foundation.dart';

import '/src/chara_detail/record_operation.dart';

/// The clock values are written by, in milliseconds since the epoch.
@visibleForTesting
int Function() valueWriteClock = () => DateTime.now().millisecondsSinceEpoch;

/// The time to write a value at, over a value written at [current] (null where there is none, or it carries no time):
/// [syncWriteTime] by [valueWriteClock]. The clock is read once per call.
int valueWriteTime(int? current) => syncWriteTime(valueWriteClock(), current);
