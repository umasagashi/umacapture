import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/execution_controller.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/gui/chara_detail/export_button.dart';

const _trTrigger = "pages.addon.trigger";

/// Tokens available for every trigger.
const _commonTokens = <String>["event"];

/// Tokens carrying a captured record's data, populated by [enrichPayload] when
/// the trigger provides a `record_id` (i.e. the record-captured trigger).
const recordTokens = <String>[
  "record_id",
  "card_name",
  "rank",
  "evaluation_value",
  "fans",
  "speed",
  "stamina",
  "power",
  "guts",
  "intelligence",
  "scenario",
  "trained_date",
  "trainer_id",
  "record_dir",
  "trainee_icon_path",
];

/// Tokens populated only by the export-completed trigger.
const _exportTokens = <String>["export_path"];

/// Tokens describing the upstream task in a `taskExecuted` chain.
const _taskTokens = <String>["task_name", "task_id"];

/// The `{tokens}` that actually carry a value for [event], surfaced as tappable
/// chips in the edit dialog so users only see tokens relevant to their trigger.
List<String> tokensForTrigger(TriggerEvent event) {
  return switch (event) {
    TriggerEvent.recordCaptured => [..._commonTokens, ...recordTokens],
    TriggerEvent.recordExported => [..._commonTokens, ..._exportTokens],
    // A chained task inherits the upstream task's payload, so any of these may
    // be present depending on what triggered the source task.
    TriggerEvent.taskExecuted => [..._commonTokens, ..._taskTokens, ...recordTokens, ..._exportTokens],
    _ => _commonTokens,
  };
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
    subscribe: (ref, emit) => ref.listen<AsyncValue<String>>(charaDetailRecordCapturedEventProvider, (_, c) {
      c.whenData((id) => emit({"event": "record_captured", "record_id": id}));
    }),
  ),
  TriggerCatalogEntry(
    event: TriggerEvent.recordExported,
    labelKey: "$_trTrigger.record_exported",
    subscribe: (ref, emit) => ref.listen<AsyncValue<PathEntity>>(recordExportEventProvider, (_, c) {
      c.whenData((path) => emit({"event": "record_exported", "export_path": path.path}));
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
