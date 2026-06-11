// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'script.dart';

class ScriptColumnSpecMapper extends SubClassMapperBase<ScriptColumnSpec> {
  ScriptColumnSpecMapper._();

  static ScriptColumnSpecMapper? _instance;
  static ScriptColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ScriptColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'ScriptColumnSpec';

  static String _$id(ScriptColumnSpec v) => v.id;
  static const Field<ScriptColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(ScriptColumnSpec v) => v.title;
  static const Field<ScriptColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static String _$source(ScriptColumnSpec v) => v.source;
  static const Field<ScriptColumnSpec, String> _f$source = Field(
    'source',
    _$source,
  );
  static int _$apiVersion(ScriptColumnSpec v) => v.apiVersion;
  static const Field<ScriptColumnSpec, int> _f$apiVersion = Field(
    'apiVersion',
    _$apiVersion,
    opt: true,
    def: scriptApiVersion,
  );
  static String? _$description(ScriptColumnSpec v) => v.description;
  static const Field<ScriptColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static bool _$hidden(ScriptColumnSpec v) => v.hidden;
  static const Field<ScriptColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );

  @override
  final MappableFields<ScriptColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #source: _f$source,
    #apiVersion: _f$apiVersion,
    #description: _f$description,
    #hidden: _f$hidden,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'ScriptColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static ScriptColumnSpec _instantiate(DecodingData data) {
    return ScriptColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      source: data.dec(_f$source),
      apiVersion: data.dec(_f$apiVersion),
      description: data.dec(_f$description),
      hidden: data.dec(_f$hidden),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ScriptColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ScriptColumnSpec>(map);
  }

  static ScriptColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<ScriptColumnSpec>(json);
  }
}

mixin ScriptColumnSpecMappable {
  String toJson() {
    return ScriptColumnSpecMapper.ensureInitialized()
        .encodeJson<ScriptColumnSpec>(this as ScriptColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return ScriptColumnSpecMapper.ensureInitialized()
        .encodeMap<ScriptColumnSpec>(this as ScriptColumnSpec);
  }
}

