import 'package:flutter/foundation.dart';

import '/src/core/storage/long_read_registry.dart';
import '/src/core/video_import_ops.dart';

/// Default-leg stub: this front end has no import path, so the capture page mounts no
/// import section at all. A real answer read at runtime, not a placeholder — the same
/// rule `capture_capability_stub.dart` states.
///
/// **Which targets actually land here is narrower than "desktop".** `video_import.dart`'s
/// conditional export sends anything with `dart.library.io` to `video_import_io.dart`,
/// which drives the Windows runner's import session and answers `Platform.isWindows`; web
/// goes to `video_import_web.dart`. This leg is the default one — an environment that
/// matches neither condition — and the io leg answers exactly the same "no" on every
/// non-Windows io target.
bool get videoImportAvailable => false;

/// Desktop stub: unreachable while [videoImportAvailable] is false, and false rather
/// than true so a caller that ever reads it alone still gets "cannot import here".
bool get videoImportSupported => false;

/// Desktop stub: no import ever runs, so this never notifies. A single shared constant
/// notifier (rather than one per read) keeps the desktop build from allocating state it
/// cannot use — the same reason the capture-capability stub shares one.
ValueListenable<VideoImportState> get videoImportState => _neverImports;

/// Desktop stub: nothing to start. Returns immediately without touching [preflight] or
/// [declaration], which exist only so the shared UI can be written once — no session is ever
/// opened here, so there is nothing for the registry to be told about.
Future<void> startVideoImport({
  required VideoImportPreflight preflight,
  required LongReadDeclaration declaration,
}) async {}

/// Desktop stub: nothing to cancel.
void cancelVideoImport() {}

/// Stub: no import ever runs here, so the runner's three `videoImport*` notifications cannot
/// arrive — and if one did there would be no slot for it to fill. Present only so this leg keeps
/// the same API surface as `video_import_io.dart`, which is the one that consumes them; the shared
/// dispatch in `PlatformController.handleNativeMessage` is written once against that surface.
void videoImportHandleNativeEvent(Map message) {}

final ValueNotifier<VideoImportState> _neverImports = ValueNotifier<VideoImportState>(VideoImportState.idle);
