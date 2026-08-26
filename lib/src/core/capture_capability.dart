/// Compile-time-selected capability probe for web live screen capture.
///
/// Mirrors `platform_channel.dart`: on desktop (`dart.library.io`) it resolves to a
/// stub whose [liveCaptureSupported] is always true (desktop capture is native and
/// needs no browser feature), and on web to the real probe backed by
/// `WasmWorkerClient.isLiveCaptureSupported`.
///
/// This conditional-export pair is the *only* mechanism the capture page uses to
/// decide these three questions: it reads the capabilities directly, with no
/// `kIsWeb` on top. Each stub value is therefore a real desktop answer that is read
/// at runtime, not a placeholder — keep them that way, because a second gate on the
/// caller side is what lets the two mechanisms drift apart.
///
/// It also carries the running session's two supply notices — [liveCaptureStallNotice]
/// ("the source has stopped supplying frames") and [liveCaptureContentFrozenNotice]
/// ("frames arrive, but the picture in them is not changing"). The web platform
/// channel has no Riverpod `ref`, so the capture page listens to the client's
/// notifiers directly. Neither ends a session: both are notices, and only the user
/// stops a capture.
///
/// [liveCaptureNeedsSourcePicker] says whether starting a session has to route
/// through a user-gesture-scoped source picker, which is what makes the start path
/// differ between the two front ends.

library;

export 'capture_capability_stub.dart' if (dart.library.js_interop) 'capture_capability_web.dart';
