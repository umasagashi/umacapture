// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'ranged_label.dart';

class RangedLabelColumnSpecMapper
    extends SubClassMapperBase<RangedLabelColumnSpec> {
  RangedLabelColumnSpecMapper._();

  static RangedLabelColumnSpecMapper? _instance;
  static RangedLabelColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RangedLabelColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      IsInRangeIntegerPredicateMapper.ensureInitialized();
      ColumnSpecCellActionMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RangedLabelColumnSpec';

  static String _$id(RangedLabelColumnSpec v) => v.id;
  static const Field<RangedLabelColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(RangedLabelColumnSpec v) => v.title;
  static const Field<RangedLabelColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(RangedLabelColumnSpec v) => v.parser;
  static const Field<RangedLabelColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static String _$labelKey(RangedLabelColumnSpec v) => v.labelKey;
  static const Field<RangedLabelColumnSpec, String> _f$labelKey = Field(
    'labelKey',
    _$labelKey,
  );
  static IsInRangeIntegerPredicate _$predicate(RangedLabelColumnSpec v) =>
      v.predicate;
  static const Field<RangedLabelColumnSpec, IsInRangeIntegerPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static ColumnSpecCellAction _$cellAction(RangedLabelColumnSpec v) =>
      v.cellAction;
  static const Field<RangedLabelColumnSpec, ColumnSpecCellAction>
  _f$cellAction = Field('cellAction', _$cellAction, opt: true);
  static bool _$hidden(RangedLabelColumnSpec v) => v.hidden;
  static const Field<RangedLabelColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(RangedLabelColumnSpec v) => v.description;
  static const Field<RangedLabelColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );

  @override
  final MappableFields<RangedLabelColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #labelKey: _f$labelKey,
    #predicate: _f$predicate,
    #cellAction: _f$cellAction,
    #hidden: _f$hidden,
    #description: _f$description,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RangedLabelColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RangedLabelColumnSpec _instantiate(DecodingData data) {
    return RangedLabelColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      labelKey: data.dec(_f$labelKey),
      predicate: data.dec(_f$predicate),
      cellAction: data.dec(_f$cellAction),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RangedLabelColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RangedLabelColumnSpec>(map);
  }

  static RangedLabelColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<RangedLabelColumnSpec>(json);
  }
}

mixin RangedLabelColumnSpecMappable {
  String toJson() {
    return RangedLabelColumnSpecMapper.ensureInitialized()
        .encodeJson<RangedLabelColumnSpec>(this as RangedLabelColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return RangedLabelColumnSpecMapper.ensureInitialized()
        .encodeMap<RangedLabelColumnSpec>(this as RangedLabelColumnSpec);
  }
}

