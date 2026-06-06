// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'memo.dart';

class RegExpPredicateMapper extends ClassMapperBase<RegExpPredicate> {
  RegExpPredicateMapper._();

  static RegExpPredicateMapper? _instance;
  static RegExpPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RegExpPredicateMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'RegExpPredicate';

  static RegExp? _$pattern(RegExpPredicate v) => v.pattern;
  static const Field<RegExpPredicate, RegExp> _f$pattern = Field(
    'pattern',
    _$pattern,
    opt: true,
  );

  @override
  final MappableFields<RegExpPredicate> fields = const {#pattern: _f$pattern};

  static RegExpPredicate _instantiate(DecodingData data) {
    return RegExpPredicate(pattern: data.dec(_f$pattern));
  }

  @override
  final Function instantiate = _instantiate;

  static RegExpPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RegExpPredicate>(map);
  }

  static RegExpPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<RegExpPredicate>(json);
  }
}

mixin RegExpPredicateMappable {
  String toJson() {
    return RegExpPredicateMapper.ensureInitialized()
        .encodeJson<RegExpPredicate>(this as RegExpPredicate);
  }

  Map<String, dynamic> toMap() {
    return RegExpPredicateMapper.ensureInitialized().encodeMap<RegExpPredicate>(
      this as RegExpPredicate,
    );
  }
}

class MemoColumnSpecMapper extends SubClassMapperBase<MemoColumnSpec> {
  MemoColumnSpecMapper._();

  static MemoColumnSpecMapper? _instance;
  static MemoColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MemoColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      RegExpPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'MemoColumnSpec';

  static String _$id(MemoColumnSpec v) => v.id;
  static const Field<MemoColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(MemoColumnSpec v) => v.title;
  static const Field<MemoColumnSpec, String> _f$title = Field('title', _$title);
  static Parser<dynamic> _$parser(MemoColumnSpec v) => v.parser;
  static const Field<MemoColumnSpec, Parser<dynamic>> _f$parser = Field(
    'parser',
    _$parser,
  );
  static RegExpPredicate _$predicate(MemoColumnSpec v) => v.predicate;
  static const Field<MemoColumnSpec, RegExpPredicate> _f$predicate = Field(
    'predicate',
    _$predicate,
  );
  static String _$storageKey(MemoColumnSpec v) => v.storageKey;
  static const Field<MemoColumnSpec, String> _f$storageKey = Field(
    'storageKey',
    _$storageKey,
  );
  static String? _$description(MemoColumnSpec v) => v.description;
  static const Field<MemoColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );

  @override
  final MappableFields<MemoColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #predicate: _f$predicate,
    #storageKey: _f$storageKey,
    #description: _f$description,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'MemoColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static MemoColumnSpec _instantiate(DecodingData data) {
    return MemoColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      predicate: data.dec(_f$predicate),
      storageKey: data.dec(_f$storageKey),
      description: data.dec(_f$description),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static MemoColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MemoColumnSpec>(map);
  }

  static MemoColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<MemoColumnSpec>(json);
  }
}

mixin MemoColumnSpecMappable {
  String toJson() {
    return MemoColumnSpecMapper.ensureInitialized().encodeJson<MemoColumnSpec>(
      this as MemoColumnSpec,
    );
  }

  Map<String, dynamic> toMap() {
    return MemoColumnSpecMapper.ensureInitialized().encodeMap<MemoColumnSpec>(
      this as MemoColumnSpec,
    );
  }
}

