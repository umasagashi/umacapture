// Driver-enabled entrypoint for live demonstration / manual driving of the real
// app. Registers the Flutter Driver extension, then runs the production main()
// unchanged, so the app behaves exactly as shipped but can be driven from an
// external Flutter Driver client (e.g. the Dart MCP flutter_driver tooling).
//
// Run: .fvm/flutter_sdk/bin/flutter run -d windows -t test_driver/app.dart
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umacapture/main.dart' as app;
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/platform_controller.dart';

Future<void> main() async {
  enableFlutterDriverExtension(handler: _handleRequest);
  await app.main();
}

/// Answers the driver's `request_data`. `harness_state` reports, as data, the app state the
/// live-capture harness judges a clip by (tool/live_capture_test/app_drive_run.py): the capture
/// attempt and its status, the last capture event, the ids each record store holds, whether the
/// factor table has loaded, and the pending enhancement candidates.
Future<String> _handleRequest(String? message) async {
  if (message != 'harness_state') {
    return jsonEncode({'error': 'unknown message: $message'});
  }
  final container = _findContainer();
  if (container == null) {
    // runApp has not mounted the ProviderScope yet; the harness polls again.
    return jsonEncode({'container': false});
  }
  return jsonEncode(_harnessState(container));
}

/// The app's own container, read from the ProviderScope that `main.dart` mounts. Reading it rather
/// than building one is what makes the answer the running app's state.
ProviderContainer? _findContainer() {
  ProviderContainer? found;
  void visit(Element element) {
    if (found != null) {
      return;
    }
    final widget = element.widget;
    if (widget is UncontrolledProviderScope) {
      found = widget.container;
      return;
    }
    element.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) {
    visit(root);
  }
  return found;
}

Map<String, Object?> _harnessState(ProviderContainer container) {
  final capture = container.read(charaDetailCaptureStateProvider);
  final event = container.read(captureEventProvider);
  final active = container.read(charaDetailRecordStorageLoaderProvider);
  final archive = container.read(charaDetailArchiveStorageLoaderProvider);
  return {
    'container': true,
    'capture': {
      'attempt_id': capture.attemptId,
      'status': capture.status.name,
      'link_id': capture.link?.id,
      'duplicate_record_id': capture.duplicateRecordId,
    },
    'event': switch (event) {
      CharaCaptureEvent() => {'status': event.status.name, 'record_id': event.recordId},
      VideoImportCaptureEvent() => {'status': 'videoImport', 'record_id': null},
      null => null,
    },
    'store': {
      'active_loaded': active.hasValue,
      'active_ids': [for (final record in active.value ?? const []) record.id],
      'archive_ids': [for (final record in archive.value ?? const []) record.id],
    },
    'factor_info_loaded': container.read(factorInfoLoader).hasValue,
    'candidates': [
      for (final candidate in container.read(pendingEnhancementCandidatesProvider))
        {'older': candidate.olderId, 'newer': candidate.newerId, 'enhanced': candidate.enhancedId},
    ],
  };
}
