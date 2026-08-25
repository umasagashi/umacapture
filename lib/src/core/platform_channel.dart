/// The app's single capture channel to the recognition core.
///
/// The transport is selected at compile time, mirroring the `fs_backend.dart`
/// pattern: on desktop (`dart.library.io`) it is a Flutter `MethodChannel`
/// (`platform_channel_io.dart`); on web (`dart.library.js_interop`) it is a
/// `WasmWorkerClient`-backed adapter (`platform_channel_web.dart`). Both files
/// expose the identical public surface — the `PlatformChannel` class (constructor,
/// `setCallback`, and its instance `Dart -> native` methods) and the
/// `PlatformCallback` typedef — so `PlatformController` and its `handleNativeMessage`
/// dispatch are reused verbatim across platforms.
///
/// **How many those methods are is deliberately not written down**, here or in either leg.
/// The count is not the contract — *identical on both legs* is — and a written count is a
/// second statement of the surface that nothing checks: this file said "nine" and
/// `wasm_worker_client.dart` said "eight" while the io leg's instance surface had ten, and
/// neither figure was revisited when a method was added. What actually holds the two legs
/// together is that `PlatformController` compiles against whichever one it gets, so a member
/// missing from one is a compile error — which no prose count could ever have been. The
/// `static` members sit outside this shared surface on purpose and say so at their own sites.
///
/// `dispose()` is part of that shared surface and **returns whether tearing the channel
/// down also ended a capture session that was still running**. The two transports differ
/// there and only there: a desktop session lives in the native runner and outlives any
/// channel (`false`, always), while a web session *is* the channel — the `MediaStream` it
/// holds and the worker live supply it drives — so disposing it ends the session. The
/// answer is data rather than behaviour precisely so the reaction to it (announcing the
/// end, see `PlatformController.dispose`) lives once, in shared code, and cannot drift.
library;

export 'platform_channel_io.dart' if (dart.library.js_interop) 'platform_channel_web.dart';
