// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'chara_rank.dart';

class CharaRankColumnSpecMapper
    extends SubClassMapperBase<CharaRankColumnSpec> {
  CharaRankColumnSpecMapper._();

  static CharaRankColumnSpecMapper? _instance;
  static CharaRankColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CharaRankColumnSpecMapper._());
      RangedLabelColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      IsInRangeIntegerPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'CharaRankColumnSpec';

  static String _$id(CharaRankColumnSpec v) => v.id;
  static const Field<CharaRankColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(CharaRankColumnSpec v) => v.title;
  static const Field<CharaRankColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(CharaRankColumnSpec v) => v.parser;
  static const Field<CharaRankColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static String _$labelKey(CharaRankColumnSpec v) => v.labelKey;
  static const Field<CharaRankColumnSpec, String> _f$labelKey = Field(
    'labelKey',
    _$labelKey,
  );
  static IsInRangeIntegerPredicate _$predicate(CharaRankColumnSpec v) =>
      v.predicate;
  static const Field<CharaRankColumnSpec, IsInRangeIntegerPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static ColumnSpecCellAction _$cellAction(CharaRankColumnSpec v) =>
      v.cellAction;
  static const Field<CharaRankColumnSpec, ColumnSpecCellAction> _f$cellAction =
      Field('cellAction', _$cellAction, mode: FieldMode.member);

  @override
  final MappableFields<CharaRankColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #labelKey: _f$labelKey,
    #predicate: _f$predicate,
    #cellAction: _f$cellAction,
  };

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'CharaRankColumnSpec';
  @override
  late final ClassMapperBase superMapper =
      RangedLabelColumnSpecMapper.ensureInitialized();

  static CharaRankColumnSpec _instantiate(DecodingData data) {
    return CharaRankColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      labelKey: data.dec(_f$labelKey),
      predicate: data.dec(_f$predicate),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CharaRankColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CharaRankColumnSpec>(map);
  }

  static CharaRankColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<CharaRankColumnSpec>(json);
  }
}

mixin CharaRankColumnSpecMappable {
  String toJson() {
    return CharaRankColumnSpecMapper.ensureInitialized()
        .encodeJson<CharaRankColumnSpec>(this as CharaRankColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return CharaRankColumnSpecMapper.ensureInitialized()
        .encodeMap<CharaRankColumnSpec>(this as CharaRankColumnSpec);
  }
}

