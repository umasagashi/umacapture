// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'execution_models.dart';

class ExecutionStatusMapper extends EnumMapper<ExecutionStatus> {
  ExecutionStatusMapper._();

  static ExecutionStatusMapper? _instance;
  static ExecutionStatusMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ExecutionStatusMapper._());
    }
    return _instance!;
  }

  static ExecutionStatus fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  ExecutionStatus decode(dynamic value) {
    switch (value) {
      case r'running':
        return ExecutionStatus.running;
      case r'success':
        return ExecutionStatus.success;
      case r'failure':
        return ExecutionStatus.failure;
      case r'cancelled':
        return ExecutionStatus.cancelled;
      case r'timeout':
        return ExecutionStatus.timeout;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(ExecutionStatus self) {
    switch (self) {
      case ExecutionStatus.running:
        return r'running';
      case ExecutionStatus.success:
        return r'success';
      case ExecutionStatus.failure:
        return r'failure';
      case ExecutionStatus.cancelled:
        return r'cancelled';
      case ExecutionStatus.timeout:
        return r'timeout';
    }
  }
}

extension ExecutionStatusMapperExtension on ExecutionStatus {
  String toValue() {
    ExecutionStatusMapper.ensureInitialized();
    return MapperContainer.globals.toValue<ExecutionStatus>(this) as String;
  }
}

class HistoryEntryMapper extends ClassMapperBase<HistoryEntry> {
  HistoryEntryMapper._();

  static HistoryEntryMapper? _instance;
  static HistoryEntryMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = HistoryEntryMapper._());
      TriggerEventMapper.ensureInitialized();
      ExecutionStatusMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'HistoryEntry';

  static String _$executionId(HistoryEntry v) => v.executionId;
  static const Field<HistoryEntry, String> _f$executionId = Field(
    'executionId',
    _$executionId,
    key: r'execution_id',
  );
  static String _$taskId(HistoryEntry v) => v.taskId;
  static const Field<HistoryEntry, String> _f$taskId = Field(
    'taskId',
    _$taskId,
    key: r'task_id',
  );
  static String _$taskName(HistoryEntry v) => v.taskName;
  static const Field<HistoryEntry, String> _f$taskName = Field(
    'taskName',
    _$taskName,
    key: r'task_name',
  );
  static TriggerEvent _$trigger(HistoryEntry v) => v.trigger;
  static const Field<HistoryEntry, TriggerEvent> _f$trigger = Field(
    'trigger',
    _$trigger,
  );
  static ExecutionStatus _$status(HistoryEntry v) => v.status;
  static const Field<HistoryEntry, ExecutionStatus> _f$status = Field(
    'status',
    _$status,
  );
  static DateTime _$startedAt(HistoryEntry v) => v.startedAt;
  static const Field<HistoryEntry, DateTime> _f$startedAt = Field(
    'startedAt',
    _$startedAt,
    key: r'started_at',
  );
  static int _$durationMs(HistoryEntry v) => v.durationMs;
  static const Field<HistoryEntry, int> _f$durationMs = Field(
    'durationMs',
    _$durationMs,
    key: r'duration_ms',
  );
  static int? _$exitCode(HistoryEntry v) => v.exitCode;
  static const Field<HistoryEntry, int> _f$exitCode = Field(
    'exitCode',
    _$exitCode,
    key: r'exit_code',
    opt: true,
  );
  static String? _$error(HistoryEntry v) => v.error;
  static const Field<HistoryEntry, String> _f$error = Field(
    'error',
    _$error,
    opt: true,
  );
  static String? _$output(HistoryEntry v) => v.output;
  static const Field<HistoryEntry, String> _f$output = Field(
    'output',
    _$output,
    opt: true,
  );

  @override
  final MappableFields<HistoryEntry> fields = const {
    #executionId: _f$executionId,
    #taskId: _f$taskId,
    #taskName: _f$taskName,
    #trigger: _f$trigger,
    #status: _f$status,
    #startedAt: _f$startedAt,
    #durationMs: _f$durationMs,
    #exitCode: _f$exitCode,
    #error: _f$error,
    #output: _f$output,
  };

  static HistoryEntry _instantiate(DecodingData data) {
    return HistoryEntry(
      executionId: data.dec(_f$executionId),
      taskId: data.dec(_f$taskId),
      taskName: data.dec(_f$taskName),
      trigger: data.dec(_f$trigger),
      status: data.dec(_f$status),
      startedAt: data.dec(_f$startedAt),
      durationMs: data.dec(_f$durationMs),
      exitCode: data.dec(_f$exitCode),
      error: data.dec(_f$error),
      output: data.dec(_f$output),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static HistoryEntry fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<HistoryEntry>(map);
  }

  static HistoryEntry fromJson(String json) {
    return ensureInitialized().decodeJson<HistoryEntry>(json);
  }
}

mixin HistoryEntryMappable {
  String toJson() {
    return HistoryEntryMapper.ensureInitialized().encodeJson<HistoryEntry>(
      this as HistoryEntry,
    );
  }

  Map<String, dynamic> toMap() {
    return HistoryEntryMapper.ensureInitialized().encodeMap<HistoryEntry>(
      this as HistoryEntry,
    );
  }
}

