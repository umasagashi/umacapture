/// Compile-time-selected video-import front end.
///
/// Mirrors `capture_capability.dart` and `platform_channel.dart`: on `dart.library.io` it
/// resolves to the native implementation, which drives the Windows runner's import session
/// over the method channel, and on `dart.library.js_interop` to the web one, backed by
/// `WasmWorkerClient`'s `videoImport` capture session. The stub stays as the **default**
/// leg — the one an environment that matches neither condition gets — and answers
/// "no import path here", which is also what `video_import_io.dart` answers on every io
/// target that is not Windows (see [videoImportAvailable] there).
///
/// The split is a conditional export rather than a `kIsWeb` branch so neither build
/// compiles the other's glue: a Windows build reaches no `dart:js_interop`, and a web
/// build reaches no `dart:io` and no `MethodChannel`. Where there is no import path the
/// capture page's import section renders nothing at all rather than a disabled control.
///
/// The two capability questions are deliberately separate. [videoImportAvailable] asks
/// whether this *front end* has an import path (a build-time fact — plus, on io, which
/// operating system this is); [videoImportSupported] asks whether it can actually decode.
/// Only web has a real runtime answer to the second (a WebCodecs and cross-origin-isolation
/// probe): a browser that fails it gets an explained, disabled control — the feature exists
/// here, it just cannot run — while a front end with no path gets no control at all.
///
/// **The io leg carries a sixth member the other two do not need**,
/// `videoImportHandleNativeEvent`: the runner's three `videoImport*` notifications ride the
/// shared `notify` queue and arrive through `PlatformController.handleNativeMessage`, while
/// web's are consumed by `WasmWorkerClient` before that relay ever sees them.
library;

export 'video_import_stub.dart'
    if (dart.library.io) 'video_import_io.dart'
    if (dart.library.js_interop) 'video_import_web.dart';
