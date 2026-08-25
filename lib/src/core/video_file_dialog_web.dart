/// The browser "choose one of your recordings" dialog, shared by every feature that needs one.
///
/// The web twin of `video_file_dialog_io.dart`, and it exists for the same reason: video import and
/// the video-import error report both ask the user for a clip, and a second copy of the dialog is a
/// second copy of its filter. Both legs read the single container list in `video_file_dialog_ops.dart`,
/// so a clip the import will open is a clip the report can re-open on either front end.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '/src/core/video_file_dialog_ops.dart';

/// Opens the browser's file dialog and returns the chosen clip, or null when the user dismissed it.
///
/// **A bare `<input type="file">` rather than `package:file_picker`, deliberately**: the picker's web
/// backend reads the whole selection into memory (`readAsBytes`), and a screen recording is routinely
/// gigabytes. What leaves here is a `File` handle, which the worker hands straight to mediabunny's
/// ranged `BlobSource`, so nothing on this side ever holds the encoded clip — which is precisely how
/// the removed import implementation ran out of memory.
///
/// The filter is [videoFileAcceptAttribute], the browser spelling of the one container list; see
/// there for why the concrete extensions are listed alongside `video/*`.
Future<web.File?> pickVideoFileFromBrowser() {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = videoFileAcceptAttribute
    ..multiple = false;
  input.style.display = 'none';
  web.document.body?.appendChild(input);
  final completer = Completer<web.File?>();
  void finish(web.File? file) {
    if (completer.isCompleted) {
      return;
    }
    completer.complete(file);
  }

  // Two exits, because `change` alone never fires for a dismissed dialog: `cancel` is what tells us the user
  // closed it empty. An engine that implements neither leaves this future pending until the user picks
  // something, rather than reporting a cancellation that did not happen.
  //
  // THE COST OF THAT PENDING FUTURE IS NO LONGER THE OLD IMPLEMENTATION'S, and the sentence that used to
  // justify it here ("the same behaviour the old implementation had") was measuring the wrong thing: an open
  // dialog is now `CaptureActivity.pickingClip`, which withdraws live capture and both error-report links as
  // well as the import control, so a pick that never answers strands all four features rather than one. The
  // caller's `finally` (`video_import_web.dart`) returns the front end to idle for every *throw* out of this
  // future, but a future that never settles is the one shape no unwind on that side can reach.
  //
  // Not closed with a timer or a `focus` fallback, deliberately: a user may legitimately stand in this dialog
  // for minutes, and the widely used "the window regained focus, so it must have been dismissed" trick races
  // `change` — the two events have no specified order — so it would turn a *successful* pick into a silent
  // cancellation on the path every user takes, to rescue an engine this app has never been run on. (Which
  // engines those are is not asserted here: `cancel` and WebCodecs shipped independently, so "every browser
  // that can decode a clip also fires `cancel`" is a claim about version tables and not one this file can
  // check.) The escape that would cost nothing on the ordinary path is a control the user can press while
  // `picking` — a capture-card decision, not this file's.
  input.addEventListener('change', ((web.Event _) => finish(input.files?.item(0))).toJS);
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
  input.click();
  // A closure, not `input.remove`: tearing off an external extension-type interop member is rejected by the
  // CFE's js_interop checks on every web target (dart2js, DDC and wasm alike), so the tear-off form did not
  // compile at all.
  return completer.future.whenComplete(() => input.remove());
}
