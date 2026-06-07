import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/gui/chara_detail/export_button.dart';

const _trTrigger = "pages.addon.trigger";

/// Template variables available in external-program argument templates, surfaced
/// in the edit dialog so users know which `{tokens}` they can use.
const addonTemplateVariables = <String>["event", "record_id", "export_path"];

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
    event: TriggerEvent.error,
    labelKey: "$_trTrigger.error",
    subscribe: (ref, emit) => ref.listen<AsyncValue<int>>(errorEventProvider, (_, c) {
      c.whenData((_) => emit({"event": "error"}));
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
