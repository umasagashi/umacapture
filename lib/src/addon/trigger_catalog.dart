import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/execution_controller.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/chara_detail/exporter.dart';
import '/src/core/platform_controller.dart';
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
/// that wires the correct typed event provider via `ref.listen` and emits a
/// normalized [PayloadMap]. The closure erases the differing provider payload
/// types behind a uniform emit callback.
class TriggerCatalogEntry {
  final TriggerEvent event;
  final String labelKey;
  final void Function(WidgetRef ref, void Function(PayloadMap payload) emit) subscribe;

  const TriggerCatalogEntry({required this.event, required this.labelKey, required this.subscribe});
}

/// All automatically-triggerable events. `manual` is intentionally absent: it is
/// fired directly by the run button, not by an event stream.
final triggerCatalog = <TriggerCatalogEntry>[
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

/// The localization key for any [TriggerEvent]'s long description, including
/// `manual`. By convention the description key is the label key plus
/// `_description`.
String triggerDescriptionKey(TriggerEvent event) => "${triggerLabelKey(event)}_description";
