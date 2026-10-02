import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/execution_controller.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/chara_detail/exporter.dart';
import '/src/core/platform_controller.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/export_button.dart';

const _trTrigger = "pages.addon.trigger";

/// Placeholders available for every trigger. Besides `event`, this is the
/// install-constant directory of the downloaded master data, populated by
/// [enrichPayload] for any trigger so an action can read any module file (the
/// ID→name tables) via `{modules_dir}`.
const _commonPlaceholders = <String>["event", "modules_dir"];

/// Placeholders carrying a captured record's file/directory paths, id, and the
/// `record.json` contents, populated by [enrichPayload] when the trigger
/// provides a `record_id` (i.e. the record-captured trigger). `record_json_path`
/// is the path to the file; `record_json` is its decoded contents.
const recordPlaceholders = <String>[
  "record_id",
  "record_dir",
  "record_json_path",
  "record_json",
  "trainee_icon_path",
  "skill_image_path",
  "factor_image_path",
  "campaign_image_path",
];

/// Placeholders populated only by the export-completed trigger.
const _exportPlaceholders = <String>["export_path", "export_file_name", "export_delivery"];

/// Placeholders describing the upstream task in a `taskExecuted` chain.
/// `task_status` is the upstream's terminal status (success/failure/cancelled/
/// timeout), so a chained task can branch on the outcome.
const _taskPlaceholders = <String>["task_name", "task_id", "task_status"];

/// The `{placeholders}` that actually carry a value for [event], surfaced in the
/// edit dialog so users only see placeholders relevant to their trigger.
List<String> placeholdersForTrigger(TriggerEvent event) {
  return switch (event) {
    TriggerEvent.recordCaptured => [..._commonPlaceholders, ...recordPlaceholders],
    TriggerEvent.recordExported => [..._commonPlaceholders, ..._exportPlaceholders],
    // A chained task inherits the upstream task's payload, so any of these may
    // be present depending on what triggered the source task.
    TriggerEvent.taskExecuted => [
      ..._commonPlaceholders,
      ..._taskPlaceholders,
      ...recordPlaceholders,
      ..._exportPlaceholders,
    ],
    _ => _commonPlaceholders,
  };
}

PayloadMap recordExportedPayload(ExportResult result) {
  final payload = <String, String>{
    "event": "record_exported",
    "export_file_name": result.fileName,
    "export_delivery": result.delivery.payloadValue,
  };
  final path = result.path;
  if (path != null) {
    payload["export_path"] = path.path;
  }
  return payload;
}

/// One triggerable event: its [TriggerEvent], a localized label, and a closure
/// that wires the event's source — a typed event provider via `ref.listen`, or
/// [appLaunchDeliveryProvider] for the launch — and emits a normalized
/// [PayloadMap]. The closure erases the differing sources behind a uniform emit
/// callback. It runs on every dispatcher build.
///
/// `emit` returns the completion of the tasks it started (see
/// `AddonExecutionController.run`). Only the close of the window awaits it.
class TriggerCatalogEntry {
  final TriggerEvent event;
  final String labelKey;
  final void Function(WidgetRef ref, Future<void> Function(PayloadMap payload) emit) subscribe;

  /// Whether a browser ever delivers this event. False keeps the trigger visible but unselectable
  /// in the task editor on web, as `BuiltinActionDescriptor.supportsWeb` does for an action; the
  /// entry states the reason where it sets it.
  final bool supportsWeb;

  const TriggerCatalogEntry({
    required this.event,
    required this.labelKey,
    required this.subscribe,
    this.supportsWeb = true,
  });
}

/// Whether this process's launch has been handed to the addon dispatcher yet.
///
/// The launch is a fact about the process, not an event on a stream: it happens once, before anything
/// can subscribe, so a broadcast of it would reach no one. It is held here as data instead. The
/// container holding this provider lives exactly as long as the app — one per process on Windows, one
/// per page load on web — so its initial `false` *is* "launched and not yet delivered", and [take] turns
/// it true once, leaving nothing for a rebuilt dispatcher to deliver again.
class AppLaunchDelivery extends Notifier<bool> {
  @override
  bool build() => false;

  /// Marks the launch delivered and answers whether this call is the one that did.
  bool take() {
    if (state) return false;
    state = true;
    return true;
  }
}

final appLaunchDeliveryProvider = NotifierProvider<AppLaunchDelivery, bool>(AppLaunchDelivery.new);

/// One close of the window, held open by the tasks bound to [TriggerEvent.appExiting].
///
/// The dispatcher [hold]s the completion of every task it starts for the close; the window goes once
/// [settled] has, which is when each of those tasks has ended — by finishing, by its own timeout, or by
/// being cancelled — and written its history entry.
class AppExitRequest {
  final _held = <Future<void>>[];

  void hold(Future<void> done) => _held.add(done);

  /// Completes when everything held has, whether it succeeded or not: a close that waited for a task
  /// has nothing left to wait for once that task has ended, however it ended.
  Future<void> settled() async {
    try {
      await Future.wait(_held);
    } catch (e, s) {
      logger.w("An app-exit task ended with an error; closing anyway.", e, s);
    }
  }
}

/// The close of the window being answered, or null when none is.
///
/// Held as data so that one close is answered at a time — a second close while the first waits
/// finds it here — and so the dispatcher can subscribe to it like any other event source.
class AppExitRequests extends Notifier<AppExitRequest?> {
  @override
  AppExitRequest? build() => null;

  /// Opens a close, or returns null when one is already open.
  ///
  /// Opening it notifies the dispatcher's subscription synchronously, so by the time this returns the
  /// request holds every task the close started.
  AppExitRequest? open() {
    if (state != null) return null;
    return state = AppExitRequest();
  }

  /// Closes the request once it has been answered.
  void close() => state = null;

  /// Answers the platform's request to close the window: opens a close, waits until its tasks have
  /// settled, and lets the app go. [onHeld] runs between the two, for a view of the wait.
  ///
  /// A second close while the first waits is declined: the first already answers it, and a double
  /// click on the close button must not be read as "stop waiting". Stopping is cancelling the tasks.
  Future<AppExitResponse> request({void Function()? onHeld}) async {
    final request = open();
    if (request == null) return AppExitResponse.cancel;
    try {
      onHeld?.call();
      await request.settled();
    } finally {
      close();
    }
    return AppExitResponse.exit;
  }
}

final appExitRequestsProvider = NotifierProvider<AppExitRequests, AppExitRequest?>(AppExitRequests.new);

/// All automatically-triggerable events. `manual` is intentionally absent: it is
/// fired directly by the run button, not by an event stream.
final triggerCatalog = <TriggerCatalogEntry>[
  TriggerCatalogEntry(
    event: TriggerEvent.appStarted,
    labelKey: "$_trTrigger.app_started",
    subscribe: (ref, emit) {
      if (ref.read(appLaunchDeliveryProvider)) return;
      // Taken after this frame rather than here: `subscribe` runs inside the dispatcher's build, and
      // running a task writes the execution controller's state, which riverpod refuses while the tree
      // is building. The flag and not the callback is what makes it once — every build before that
      // frame schedules a callback, and only the first to take the launch emits it. An unmounted
      // dispatcher takes nothing, so the launch waits for the next one.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!ref.context.mounted) return;
        if (ref.read(appLaunchDeliveryProvider.notifier).take()) emit({"event": "app_started"});
      });
    },
  ),
  TriggerCatalogEntry(
    event: TriggerEvent.appExiting,
    labelKey: "$_trTrigger.app_exiting",
    // Not offered on web: a browser gives a closing page no time to finish asynchronous work, and
    // Flutter web never asks the app whether it may exit, so there is no close to hold open.
    supportsWeb: false,
    subscribe: (ref, emit) => ref.listen<AppExitRequest?>(appExitRequestsProvider, (_, request) {
      request?.hold(emit({"event": "app_exiting"}));
    }),
  ),
  TriggerCatalogEntry(
    event: TriggerEvent.captureStarted,
    labelKey: "$_trTrigger.capture_started",
    subscribe: (ref, emit) => ref.listen<AsyncValue<bool>>(captureTriggeredEventProvider, (_, c) {
      c.whenData((started) {
        if (started) emit({"event": "capture_started"});
      });
    }),
  ),
  TriggerCatalogEntry(
    event: TriggerEvent.captureStopped,
    labelKey: "$_trTrigger.capture_stopped",
    subscribe: (ref, emit) => ref.listen<AsyncValue<bool>>(captureTriggeredEventProvider, (_, c) {
      c.whenData((started) {
        if (!started) emit({"event": "capture_stopped"});
      });
    }),
  ),
  TriggerCatalogEntry(
    event: TriggerEvent.recordCaptured,
    labelKey: "$_trTrigger.record_captured",
    // The event carries the producing session's kind as well as the id now; the payload keeps only
    // the id, because "a record was captured" is what this trigger has always meant and an import's
    // records are captures too. Widening the payload is a separate, user-visible decision.
    subscribe: (ref, emit) =>
        ref.listen<AsyncValue<CharaDetailRecordCapturedEvent>>(charaDetailRecordCapturedEventProvider, (_, c) {
          c.whenData((e) => emit({"event": "record_captured", "record_id": e.id}));
        }),
  ),
  TriggerCatalogEntry(
    event: TriggerEvent.recordExported,
    labelKey: "$_trTrigger.record_exported",
    subscribe: (ref, emit) => ref.listen<AsyncValue<ExportResult>>(recordExportEventProvider, (_, c) {
      c.whenData((result) => emit(recordExportedPayload(result)));
    }),
  ),
  TriggerCatalogEntry(
    event: TriggerEvent.taskExecuted,
    labelKey: "$_trTrigger.task_executed",
    subscribe: (ref, emit) => ref.listen<AsyncValue<PayloadMap>>(taskExecutedEventProvider, (_, c) {
      c.whenData(emit);
    }),
  ),
];

/// The localization key for any [TriggerEvent]'s short label, including `manual`.
String triggerLabelKey(TriggerEvent event) {
  if (event == TriggerEvent.manual) return "$_trTrigger.manual";
  return triggerCatalog.firstWhere((e) => e.event == event).labelKey;
}

/// Whether a browser ever delivers [event] (see [TriggerCatalogEntry.supportsWeb]). `manual` is the
/// ▶ button, which every host has.
bool triggerSupportsWeb(TriggerEvent event) {
  if (event == TriggerEvent.manual) return true;
  return triggerCatalog.firstWhere((e) => e.event == event).supportsWeb;
}

/// The localization key for any [TriggerEvent]'s long description, including
/// `manual`. By convention the description key is the label key plus
/// `_description`.
String triggerDescriptionKey(TriggerEvent event) => "${triggerLabelKey(event)}_description";
