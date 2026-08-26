import 'package:flutter/foundation.dart';

/// Desktop stub: native capture needs no browser capability, so it is always
/// supported. `capture.dart` reads this at runtime on desktop too — the constant
/// `true` is the answer, not a placeholder for one.
bool get liveCaptureSupported => true;

/// Desktop stub: the native recorder picks its own target window from the
/// configured window titles, so no picker and no user gesture stand between the
/// button and the session.
bool get liveCaptureNeedsSourcePicker => false;

/// Desktop stub: the frame source is the native window recorder, which has no
/// browser-side supply to stall, so this never notifies. A single shared constant
/// listenable (rather than one per read) keeps the desktop build from allocating a
/// notifier it can never use.
ValueListenable<String?> get liveCaptureStallNotice => _neverStalls;

/// Desktop stub: the content-freeze verdict is measured in the wasm worker over the
/// frames a browser share supplies, and desktop has neither. Shares [_neverStalls]
/// for the same reason [liveCaptureStallNotice] does — both mean "this front end has
/// nothing to report here", and one constant answers both.
ValueListenable<String?> get liveCaptureContentFrozenNotice => _neverStalls;

final ValueNotifier<String?> _neverStalls = ValueNotifier<String?>(null);
