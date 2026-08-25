import 'package:flutter/foundation.dart';

import '/src/core/wasm_worker_client.dart';

/// Whether this browser can drive web live screen capture: WebCodecs `VideoFrame`
/// (the pull supply path's only engine requirement), a `getDisplayMedia` frame
/// source, and cross-origin isolation. Feature detection only — no browser
/// sniffing — so any engine meeting all three lights up. See
/// `WasmWorkerClient.isLiveCaptureSupported`.
bool get liveCaptureSupported => WasmWorkerClient().isLiveCaptureSupported;

/// Whether starting a session has to route through a source picker the user must
/// answer. True here: `getDisplayMedia` may only be called inside the tap's
/// transient activation, so the capture button has to open the guidance banner and
/// invoke the start synchronously instead of awaiting anything first. Not an engine
/// property — every browser requires it.
bool get liveCaptureNeedsSourcePicker => true;

/// Why the running live session's source has stopped supplying frames, or null
/// while it is healthy (or no session is running). Non-null only once the
/// suspension has outlasted `WasmWorkerClient.liveSupplyStallNoticeDelay`, so a
/// transient mute never flickers a warning at the user. See
/// `WasmWorkerClient.liveSupplyStall`.
ValueListenable<String?> get liveCaptureStallNotice => WasmWorkerClient().liveSupplyStall;

/// `content_frozen` while the shared picture is not changing, null otherwise. Unlike
/// [liveCaptureStallNotice] this describes frames that ARE arriving, and it is
/// withdrawn as soon as they carry new pixels again. See
/// `WasmWorkerClient.liveContentFrozen`.
ValueListenable<String?> get liveCaptureContentFrozenNotice => WasmWorkerClient().liveContentFrozen;
