// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'character.dart';

class CharacterCardPredicateMapper
    extends ClassMapperBase<CharacterCardPredicate> {
  CharacterCardPredicateMapper._();

  static CharacterCardPredicateMapper? _instance;
  static CharacterCardPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CharacterCardPredicateMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'CharacterCardPredicate';

  static Set<int> _$rejects(CharacterCardPredicate v) => v.rejects;
  static const Field<CharacterCardPredicate, Set<int>> _f$rejects = Field(
    'rejects',
    _$rejects,
    opt: true,
    def: const {},
  );

  @override
  final MappableFields<CharacterCardPredicate> fields = const {
    #rejects: _f$rejects,
  };

  static CharacterCardPredicate _instantiate(DecodingData data) {
    return CharacterCardPredicate(rejects: data.dec(_f$rejects));
  }

  @override
  final Function instantiate = _instantiate;

  static CharacterCardPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CharacterCardPredicate>(map);
  }

  static CharacterCardPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<CharacterCardPredicate>(json);
  }
}

mixin CharacterCardPredicateMappable {
  String toJson() {
    return CharacterCardPredicateMapper.ensureInitialized()
        .encodeJson<CharacterCardPredicate>(this as CharacterCardPredicate);
  }

  Map<String, dynamic> toMap() {
    return CharacterCardPredicateMapper.ensureInitialized()
        .encodeMap<CharacterCardPredicate>(this as CharacterCardPredicate);
  }
}

class CharacterCardColumnSpecMapper
    extends SubClassMapperBase<CharacterCardColumnSpec> {
  CharacterCardColumnSpecMapper._();

  static CharacterCardColumnSpecMapper? _instance;
  static CharacterCardColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = CharacterCardColumnSpecMapper._(),
      );
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      CharacterCardPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'CharacterCardColumnSpec';

  static String _$id(CharacterCardColumnSpec v) => v.id;
  static const Field<CharacterCardColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(CharacterCardColumnSpec v) => v.title;
  static const Field<CharacterCardColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(CharacterCardColumnSpec v) => v.parser;
  static const Field<CharacterCardColumnSpec, Parser<dynamic>> _f$parser =
      Field('parser', _$parser);
  static CharacterCardPredicate _$predicate(CharacterCardColumnSpec v) =>
      v.predicate;
  static const Field<CharacterCardColumnSpec, CharacterCardPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static bool _$hidden(CharacterCardColumnSpec v) => v.hidden;
  static const Field<CharacterCardColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );

  @override
  final MappableFields<CharacterCardColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #predicate: _f$predicate,
    #hidden: _f$hidden,
  };

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'CharacterCardColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static CharacterCardColumnSpec _instantiate(DecodingData data) {
    return CharacterCardColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      predicate: data.dec(_f$predicate),
      hidden: data.dec(_f$hidden),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CharacterCardColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CharacterCardColumnSpec>(map);
  }

  static CharacterCardColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<CharacterCardColumnSpec>(json);
  }
}

mixin CharacterCardColumnSpecMappable {
  String toJson() {
    return CharacterCardColumnSpecMapper.ensureInitialized()
        .encodeJson<CharacterCardColumnSpec>(this as CharacterCardColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return CharacterCardColumnSpecMapper.ensureInitialized()
        .encodeMap<CharacterCardColumnSpec>(this as CharacterCardColumnSpec);
  }
}

