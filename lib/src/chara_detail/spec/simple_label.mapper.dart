// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'simple_label.dart';

class SimpleLabelPredicateMapper extends ClassMapperBase<SimpleLabelPredicate> {
  SimpleLabelPredicateMapper._();

  static SimpleLabelPredicateMapper? _instance;
  static SimpleLabelPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SimpleLabelPredicateMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'SimpleLabelPredicate';

  static Set<int> _$rejects(SimpleLabelPredicate v) => v.rejects;
  static const Field<SimpleLabelPredicate, Set<int>> _f$rejects = Field(
    'rejects',
    _$rejects,
    opt: true,
    def: const {},
  );

  @override
  final MappableFields<SimpleLabelPredicate> fields = const {
    #rejects: _f$rejects,
  };

  static SimpleLabelPredicate _instantiate(DecodingData data) {
    return SimpleLabelPredicate(rejects: data.dec(_f$rejects));
  }

  @override
  final Function instantiate = _instantiate;

  static SimpleLabelPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SimpleLabelPredicate>(map);
  }

  static SimpleLabelPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<SimpleLabelPredicate>(json);
  }
}

mixin SimpleLabelPredicateMappable {
  String toJson() {
    return SimpleLabelPredicateMapper.ensureInitialized()
        .encodeJson<SimpleLabelPredicate>(this as SimpleLabelPredicate);
  }

  Map<String, dynamic> toMap() {
    return SimpleLabelPredicateMapper.ensureInitialized()
        .encodeMap<SimpleLabelPredicate>(this as SimpleLabelPredicate);
  }
}

class SimpleLabelColumnSpecMapper
    extends SubClassMapperBase<SimpleLabelColumnSpec> {
  SimpleLabelColumnSpecMapper._();

  static SimpleLabelColumnSpecMapper? _instance;
  static SimpleLabelColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SimpleLabelColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      SimpleLabelPredicateMapper.ensureInitialized();
      ColumnSpecCellActionMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'SimpleLabelColumnSpec';

  static String _$id(SimpleLabelColumnSpec v) => v.id;
  static const Field<SimpleLabelColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(SimpleLabelColumnSpec v) => v.title;
  static const Field<SimpleLabelColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(SimpleLabelColumnSpec v) => v.parser;
  static const Field<SimpleLabelColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static String _$labelKey(SimpleLabelColumnSpec v) => v.labelKey;
  static const Field<SimpleLabelColumnSpec, String> _f$labelKey = Field(
    'labelKey',
    _$labelKey,
  );
  static SimpleLabelPredicate _$predicate(SimpleLabelColumnSpec v) =>
      v.predicate;
  static const Field<SimpleLabelColumnSpec, SimpleLabelPredicate> _f$predicate =
      Field('predicate', _$predicate);
  static ColumnSpecCellAction _$cellAction(SimpleLabelColumnSpec v) =>
      v.cellAction;
  static const Field<SimpleLabelColumnSpec, ColumnSpecCellAction>
  _f$cellAction = Field('cellAction', _$cellAction, opt: true);
  static bool _$hidden(SimpleLabelColumnSpec v) => v.hidden;
  static const Field<SimpleLabelColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(SimpleLabelColumnSpec v) => v.description;
  static const Field<SimpleLabelColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static double? _$width(SimpleLabelColumnSpec v) => v.width;
  static const Field<SimpleLabelColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );

  @override
  final MappableFields<SimpleLabelColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #labelKey: _f$labelKey,
    #predicate: _f$predicate,
    #cellAction: _f$cellAction,
    #hidden: _f$hidden,
    #description: _f$description,
    #width: _f$width,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'SimpleLabelColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static SimpleLabelColumnSpec _instantiate(DecodingData data) {
    return SimpleLabelColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      labelKey: data.dec(_f$labelKey),
      predicate: data.dec(_f$predicate),
      cellAction: data.dec(_f$cellAction),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
      width: data.dec(_f$width),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static SimpleLabelColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SimpleLabelColumnSpec>(map);
  }

  static SimpleLabelColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<SimpleLabelColumnSpec>(json);
  }
}

mixin SimpleLabelColumnSpecMappable {
  String toJson() {
    return SimpleLabelColumnSpecMapper.ensureInitialized()
        .encodeJson<SimpleLabelColumnSpec>(this as SimpleLabelColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return SimpleLabelColumnSpecMapper.ensureInitialized()
        .encodeMap<SimpleLabelColumnSpec>(this as SimpleLabelColumnSpec);
  }
}

