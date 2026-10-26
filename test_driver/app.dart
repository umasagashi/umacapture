// Driver-enabled entrypoint for live demonstration / manual driving of the real
// app. Registers the Flutter Driver extension, then runs the production main()
// unchanged, so the app behaves exactly as shipped but can be driven from an
// external Flutter Driver client (e.g. the Dart MCP flutter_driver tooling).
//
// Two things a driven run needs that flutter_driver's own commands do not reach are added here, and
// nothing else differs from the shipped app:
//
// * Every file dialog is answered by a script ([_ScriptedPicker]), so no native dialog ever opens.
// * Pointer events are dispatched inside the app ([_dispatchPointer]), which reaches what a
//   flutter_driver tap cannot (a secondary click, a press held for a given time) without moving the
//   OS cursor or taking focus.
//
// Run: .fvm/flutter_sdk/bin/flutter run -d windows -t test_driver/app.dart
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
// TrinaBaseCell is the widget a grid cell is laid out as; the package does not export it.
// ignore: implementation_imports
import 'package:trina_grid/src/ui/trina_base_cell.dart';
import 'package:umacapture/main.dart' as app;
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/record_share_session.dart';
import 'package:umacapture/src/chara_detail/record_sync.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/platform_controller.dart';

Future<void> main() async {
  enableFlutterDriverExtension(handler: _handleRequest);
  // Set after the plugin registrant has installed the platform's picker and before the app can open one.
  FilePickerPlatform.instance = _ScriptedPicker();
  await app.main();
}

/// Answers the driver's `request_data`:
///
/// * `harness_state` reports, as data, the app state the live-capture harness judges a clip by
///   (tool/live_capture_test/app_drive_run.py): the capture attempt and its status, the last capture
///   event, the ids each record store holds, whether the factor table has loaded, and the pending
///   enhancement candidates.
/// * `sync_state` reports the record sync as the account sync section reads it.
/// * `pick:<json list of paths>`, `save:<path>` and `cancel` queue the answer of the next file dialog
///   ([_ScriptedPicker]).
/// * `pointer:<json>` dispatches one press ([_dispatchPointer]).
/// * `locate_cell:<json>` finds a grid cell on screen ([_locateCell]).
Future<String> _handleRequest(String? message) async {
  final m = message ?? '';
  if (m.startsWith('pick:')) {
    return _queueAnswer((jsonDecode(m.substring(5)) as List).cast<String>());
  }
  if (m.startsWith('save:')) {
    return _queueAnswer(m.substring(5));
  }
  if (m == 'cancel') {
    return _queueAnswer(null);
  }
  if (m.startsWith('pointer:')) {
    return jsonEncode(await _dispatchPointer(jsonDecode(m.substring(8)) as Map<String, dynamic>));
  }
  if (m.startsWith('locate_cell:')) {
    return jsonEncode(_locateCell(jsonDecode(m.substring(12)) as Map<String, dynamic>));
  }
  if (m != 'harness_state' && m != 'sync_state') {
    return jsonEncode({'error': 'unknown message: $message'});
  }
  final container = _findContainer();
  if (container == null) {
    // runApp has not mounted the ProviderScope yet; the harness polls again.
    return jsonEncode({'container': false});
  }
  return jsonEncode(m == 'harness_state' ? _harnessState(container) : _syncState(container));
}

/// The answers of the file dialogs to come, oldest first: a list of paths answers a pick, a path
/// answers a save, and null dismisses either.
final Queue<Object?> _answers = Queue();

String _queueAnswer(Object? answer) {
  _answers.add(answer);
  return jsonEncode({'queued': _answers.length});
}

/// The next queued answer, or null (a dismissal) when none is queued — so a dialog the script did not
/// expect is dismissed rather than opened on the user's desktop.
Object? _nextAnswer() => _answers.isEmpty ? null : _answers.removeFirst();

/// Answers every file dialog of the app from [_answers]. `FilePicker.pickFile` reaches [pickFiles].
class _ScriptedPicker extends FilePickerPlatform {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    final answer = _nextAnswer();
    if (answer is! List<String>) {
      return null;
    }
    return FilePickerResult([
      for (final path in answer)
        PlatformFile(path: path, name: path.split(RegExp(r'[\\/]')).last, size: File(path).lengthSync()),
    ]);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    required String fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    required Uint8List bytes,
    Function(FilePickerStatus)? onFileLoading,
    bool lockParentWindow = false,
  }) async {
    final answer = _nextAnswer();
    if (answer is! String) {
      return null;
    }
    // The platform picker writes the bytes to the chosen path before it answers; so does this one.
    await File(answer).writeAsBytes(bytes, flush: true);
    return answer;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    final answer = _nextAnswer();
    return answer is String ? answer : null;
  }
}

/// The device ids of dispatched pointers start here, apart from the real mouse's, so the app's mouse
/// tracking never mistakes one for the other.
int _nextDevice = 9000;

/// Presses at `x`, `y` (logical pixels, the coordinates flutter_driver's `get_offset` answers in) with
/// `buttons` (1 primary, 2 secondary), holds for `hold_ms` and releases, through the app's own gesture
/// binding: the OS cursor and the window focus are not touched.
Future<Map<String, Object?>> _dispatchPointer(Map<String, dynamic> spec) async {
  final position = Offset((spec['x'] as num).toDouble(), (spec['y'] as num).toDouble());
  final buttons = (spec['buttons'] as int?) ?? kPrimaryButton;
  final hold = Duration(milliseconds: (spec['hold_ms'] as int?) ?? 50);
  final device = _nextDevice++;
  final binding = GestureBinding.instance;
  const kind = PointerDeviceKind.mouse;
  binding.handlePointerEvent(PointerAddedEvent(device: device, position: position, kind: kind));
  binding.handlePointerEvent(
    PointerDownEvent(pointer: device, device: device, position: position, kind: kind, buttons: buttons),
  );
  await Future<void>.delayed(hold);
  binding.handlePointerEvent(PointerUpEvent(pointer: device, device: device, position: position, kind: kind));
  binding.handlePointerEvent(PointerRemovedEvent(device: device, position: position, kind: kind));
  return {'ok': true};
}

/// The on-screen rects of the grid cells of record `record` — in the column titled `column`, in the
/// row-check column where `column` is `#check`, or in any column where `column` is absent — in the
/// coordinates [_dispatchPointer] takes, with the size of the view. Where `inner` names a widget type,
/// each cell also carries the rect of the first widget of that type inside it (a rating cell's
/// `RatingBar`). Only cells the grid has laid out are found: a row scrolled out of the grid is not.
Map<String, Object?> _locateCell(Map<String, dynamic> spec) {
  final recordId = spec['record'] as String;
  final column = spec['column'] as String?;
  final inner = spec['inner'] as String?;
  Map<String, double>? rectOf(Element element) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      return null;
    }
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return {'left': rect.left, 'top': rect.top, 'width': rect.width, 'height': rect.height};
  }

  Map<String, double>? innerRectOf(Element cell) {
    Map<String, double>? found;
    void visit(Element element) {
      if (found != null) {
        return;
      }
      if (element.widget.runtimeType.toString() == inner) {
        found = rectOf(element);
        return;
      }
      element.visitChildElements(visit);
    }

    cell.visitChildElements(visit);
    return found;
  }

  bool columnMatches(TrinaColumn candidate) => switch (column) {
    null => true,
    '#check' => candidate.enableRowChecked,
    _ => candidate.getUserData<ColumnSpec>()?.title == column,
  };
  final cells = <Map<String, Object?>>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is TrinaBaseCell &&
        widget.row.getUserData<CharaDetailRecord>()?.id == recordId &&
        columnMatches(widget.column)) {
      final rect = rectOf(element);
      if (rect != null) {
        cells.add({
          'column': widget.column.getUserData<ColumnSpec>()?.title,
          ...rect,
          if (inner != null) 'inner': innerRectOf(element),
        });
      }
    }
    element.visitChildElements(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) {
    visit(root);
  }
  final view = WidgetsBinding.instance.renderViews.first.size;
  return {
    'cells': cells,
    'view': {'width': view.width, 'height': view.height},
  };
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

/// The record sync as the account sync section shows it: whether the device is logged in and sync is on
/// for that account, whether a round runs, the counts it shows, the halt it tells, and what the last
/// round this run of the app ran told.
Map<String, Object?> _syncState(ProviderContainer container) {
  final sync = container.read(recordSyncProvider);
  final session = container.read(recordShareSessionProvider);
  final counts = sync.countsFor(session?.accountId);
  final told = sync.told;
  return {
    'container': true,
    'logged_in': session != null,
    'on': sync.onFor(session?.accountId),
    'running': sync.running,
    'last_synced': sync.lastSynced?.toIso8601String(),
    'counts': counts == null
        ? null
        : {'restored': counts.restored, 'split_off': counts.splitOff, 'added': counts.added},
    'halt': container.read(syncHaltProvider)?.name,
    'told': told == null
        ? null
        : {
            'end': told.end.name,
            'restored': told.restored,
            'split_off': told.splitOff,
            'added': told.added,
            'withheld': told.withheld,
            'long_memos': told.longMemos,
            'waiting_for_room': told.waitingForRoom,
            'waiting_for_the_day': told.waitingForTheDay,
          },
  };
}
