// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'task_definition.dart';

class TriggerEventMapper extends EnumMapper<TriggerEvent> {
  TriggerEventMapper._();

  static TriggerEventMapper? _instance;
  static TriggerEventMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TriggerEventMapper._());
    }
    return _instance!;
  }

  static TriggerEvent fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  TriggerEvent decode(dynamic value) {
    switch (value) {
      case r'captureStarted':
        return TriggerEvent.captureStarted;
      case r'captureStopped':
        return TriggerEvent.captureStopped;
      case r'recordCaptured':
        return TriggerEvent.recordCaptured;
      case r'recordExported':
        return TriggerEvent.recordExported;
      case r'taskExecuted':
        return TriggerEvent.taskExecuted;
      case r'manual':
        return TriggerEvent.manual;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(TriggerEvent self) {
    switch (self) {
      case TriggerEvent.captureStarted:
        return r'captureStarted';
      case TriggerEvent.captureStopped:
        return r'captureStopped';
      case TriggerEvent.recordCaptured:
        return r'recordCaptured';
      case TriggerEvent.recordExported:
        return r'recordExported';
      case TriggerEvent.taskExecuted:
        return r'taskExecuted';
      case TriggerEvent.manual:
        return r'manual';
    }
  }
}

extension TriggerEventMapperExtension on TriggerEvent {
  String toValue() {
    TriggerEventMapper.ensureInitialized();
    return MapperContainer.globals.toValue<TriggerEvent>(this) as String;
  }
}

class TaskDefinitionMapper extends ClassMapperBase<TaskDefinition> {
  TaskDefinitionMapper._();

  static TaskDefinitionMapper? _instance;
  static TaskDefinitionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TaskDefinitionMapper._());
      TriggerEventMapper.ensureInitialized();
      AddonActionMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'TaskDefinition';

  static String _$id(TaskDefinition v) => v.id;
  static const Field<TaskDefinition, String> _f$id = Field('id', _$id);
  static String _$name(TaskDefinition v) => v.name;
  static const Field<TaskDefinition, String> _f$name = Field('name', _$name);
  static bool _$enabled(TaskDefinition v) => v.enabled;
  static const Field<TaskDefinition, bool> _f$enabled = Field(
    'enabled',
    _$enabled,
    opt: true,
    def: true,
  );
  static TriggerEvent _$trigger(TaskDefinition v) => v.trigger;
  static const Field<TaskDefinition, TriggerEvent> _f$trigger = Field(
    'trigger',
    _$trigger,
  );
  static AddonAction _$action(TaskDefinition v) => v.action;
  static const Field<TaskDefinition, AddonAction> _f$action = Field(
    'action',
    _$action,
  );
  static String? _$sourceTaskId(TaskDefinition v) => v.sourceTaskId;
  static const Field<TaskDefinition, String> _f$sourceTaskId = Field(
    'sourceTaskId',
    _$sourceTaskId,
    key: r'source_task_id',
    opt: true,
  );

  @override
  final MappableFields<TaskDefinition> fields = const {
    #id: _f$id,
    #name: _f$name,
    #enabled: _f$enabled,
    #trigger: _f$trigger,
    #action: _f$action,
    #sourceTaskId: _f$sourceTaskId,
  };

  static TaskDefinition _instantiate(DecodingData data) {
    return TaskDefinition(
      id: data.dec(_f$id),
      name: data.dec(_f$name),
      enabled: data.dec(_f$enabled),
      trigger: data.dec(_f$trigger),
      action: data.dec(_f$action),
      sourceTaskId: data.dec(_f$sourceTaskId),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static TaskDefinition fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TaskDefinition>(map);
  }

  static TaskDefinition fromJson(String json) {
    return ensureInitialized().decodeJson<TaskDefinition>(json);
  }
}

mixin TaskDefinitionMappable {
  String toJson() {
    return TaskDefinitionMapper.ensureInitialized().encodeJson<TaskDefinition>(
      this as TaskDefinition,
    );
  }

  Map<String, dynamic> toMap() {
    return TaskDefinitionMapper.ensureInitialized().encodeMap<TaskDefinition>(
      this as TaskDefinition,
    );
  }
}

