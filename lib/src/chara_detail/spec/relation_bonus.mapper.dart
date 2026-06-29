// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'relation_bonus.dart';

class RelationBonusColumnSpecMapper
    extends SubClassMapperBase<RelationBonusColumnSpec> {
  RelationBonusColumnSpecMapper._();

  static RelationBonusColumnSpecMapper? _instance;
  static RelationBonusColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = RelationBonusColumnSpecMapper._(),
      );
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      IsInRangeIntegerPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RelationBonusColumnSpec';

  static String _$id(RelationBonusColumnSpec v) => v.id;
  static const Field<RelationBonusColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(RelationBonusColumnSpec v) => v.title;
  static const Field<RelationBonusColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static IsInRangeIntegerPredicate _$predicate(RelationBonusColumnSpec v) =>
      v.predicate;
  static const Field<RelationBonusColumnSpec, IsInRangeIntegerPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static bool _$hidden(RelationBonusColumnSpec v) => v.hidden;
  static const Field<RelationBonusColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(RelationBonusColumnSpec v) => v.description;
  static const Field<RelationBonusColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static double? _$width(RelationBonusColumnSpec v) => v.width;
  static const Field<RelationBonusColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );

  @override
  final MappableFields<RelationBonusColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #predicate: _f$predicate,
    #hidden: _f$hidden,
    #description: _f$description,
    #width: _f$width,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RelationBonusColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RelationBonusColumnSpec _instantiate(DecodingData data) {
    return RelationBonusColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      predicate: data.dec(_f$predicate),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
      width: data.dec(_f$width),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RelationBonusColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RelationBonusColumnSpec>(map);
  }

  static RelationBonusColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<RelationBonusColumnSpec>(json);
  }
}

mixin RelationBonusColumnSpecMappable {
  String toJson() {
    return RelationBonusColumnSpecMapper.ensureInitialized()
        .encodeJson<RelationBonusColumnSpec>(this as RelationBonusColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return RelationBonusColumnSpecMapper.ensureInitialized()
        .encodeMap<RelationBonusColumnSpec>(this as RelationBonusColumnSpec);
  }
}

