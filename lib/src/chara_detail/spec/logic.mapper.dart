// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'logic.dart';

class LogicModeMapper extends EnumMapper<LogicMode> {
  LogicModeMapper._();

  static LogicModeMapper? _instance;
  static LogicModeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = LogicModeMapper._());
    }
    return _instance!;
  }

  static LogicMode fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  LogicMode decode(dynamic value) {
    switch (value) {
      case r'and':
        return LogicMode.and;
      case r'or':
        return LogicMode.or;
      case r'not':
        return LogicMode.not;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(LogicMode self) {
    switch (self) {
      case LogicMode.and:
        return r'and';
      case LogicMode.or:
        return r'or';
      case LogicMode.not:
        return r'not';
    }
  }
}

extension LogicModeMapperExtension on LogicMode {
  String toValue() {
    LogicModeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<LogicMode>(this) as String;
  }
}

class LogicColumnSpecMapper extends SubClassMapperBase<LogicColumnSpec> {
  LogicColumnSpecMapper._();

  static LogicColumnSpecMapper? _instance;
  static LogicColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = LogicColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      LogicModeMapper.ensureInitialized();
      ColumnSpecMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'LogicColumnSpec';

  static String _$id(LogicColumnSpec v) => v.id;
  static const Field<LogicColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(LogicColumnSpec v) => v.title;
  static const Field<LogicColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static LogicMode _$logic(LogicColumnSpec v) => v.logic;
  static const Field<LogicColumnSpec, LogicMode> _f$logic = Field(
    'logic',
    _$logic,
  );
  static List<ColumnSpec<dynamic>> _$children(LogicColumnSpec v) => v.children;
  static const Field<LogicColumnSpec, List<ColumnSpec<dynamic>>> _f$children =
      Field('children', _$children, opt: true, def: const []);

  @override
  final MappableFields<LogicColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #logic: _f$logic,
    #children: _f$children,
  };

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'LogicColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static LogicColumnSpec _instantiate(DecodingData data) {
    return LogicColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      logic: data.dec(_f$logic),
      children: data.dec(_f$children),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static LogicColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<LogicColumnSpec>(map);
  }

  static LogicColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<LogicColumnSpec>(json);
  }
}

mixin LogicColumnSpecMappable {
  String toJson() {
    return LogicColumnSpecMapper.ensureInitialized()
        .encodeJson<LogicColumnSpec>(this as LogicColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return LogicColumnSpecMapper.ensureInitialized().encodeMap<LogicColumnSpec>(
      this as LogicColumnSpec,
    );
  }
}

