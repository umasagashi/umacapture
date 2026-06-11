// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'family_registration.dart';

class FamilyRegistrationPredicateMapper
    extends ClassMapperBase<FamilyRegistrationPredicate> {
  FamilyRegistrationPredicateMapper._();

  static FamilyRegistrationPredicateMapper? _instance;
  static FamilyRegistrationPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = FamilyRegistrationPredicateMapper._(),
      );
    }
    return _instance!;
  }

  @override
  final String id = 'FamilyRegistrationPredicate';

  static Set<int> _$rejects(FamilyRegistrationPredicate v) => v.rejects;
  static const Field<FamilyRegistrationPredicate, Set<int>> _f$rejects = Field(
    'rejects',
    _$rejects,
    opt: true,
    def: const {},
  );

  @override
  final MappableFields<FamilyRegistrationPredicate> fields = const {
    #rejects: _f$rejects,
  };

  static FamilyRegistrationPredicate _instantiate(DecodingData data) {
    return FamilyRegistrationPredicate(rejects: data.dec(_f$rejects));
  }

  @override
  final Function instantiate = _instantiate;

  static FamilyRegistrationPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FamilyRegistrationPredicate>(map);
  }

  static FamilyRegistrationPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<FamilyRegistrationPredicate>(json);
  }
}

mixin FamilyRegistrationPredicateMappable {
  String toJson() {
    return FamilyRegistrationPredicateMapper.ensureInitialized()
        .encodeJson<FamilyRegistrationPredicate>(
          this as FamilyRegistrationPredicate,
        );
  }

  Map<String, dynamic> toMap() {
    return FamilyRegistrationPredicateMapper.ensureInitialized()
        .encodeMap<FamilyRegistrationPredicate>(
          this as FamilyRegistrationPredicate,
        );
  }
}

class FamilyRegistrationColumnSpecMapper
    extends SubClassMapperBase<FamilyRegistrationColumnSpec> {
  FamilyRegistrationColumnSpecMapper._();

  static FamilyRegistrationColumnSpecMapper? _instance;
  static FamilyRegistrationColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = FamilyRegistrationColumnSpecMapper._(),
      );
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      FamilyRegistrationPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FamilyRegistrationColumnSpec';

  static String _$id(FamilyRegistrationColumnSpec v) => v.id;
  static const Field<FamilyRegistrationColumnSpec, String> _f$id = Field(
    'id',
    _$id,
  );
  static String _$title(FamilyRegistrationColumnSpec v) => v.title;
  static const Field<FamilyRegistrationColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static FamilyRegistrationPredicate _$predicate(
    FamilyRegistrationColumnSpec v,
  ) => v.predicate;
  static const Field<FamilyRegistrationColumnSpec, FamilyRegistrationPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static bool _$hidden(FamilyRegistrationColumnSpec v) => v.hidden;
  static const Field<FamilyRegistrationColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );

  @override
  final MappableFields<FamilyRegistrationColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #predicate: _f$predicate,
    #hidden: _f$hidden,
  };

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'FamilyRegistrationColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static FamilyRegistrationColumnSpec _instantiate(DecodingData data) {
    return FamilyRegistrationColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      predicate: data.dec(_f$predicate),
      hidden: data.dec(_f$hidden),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static FamilyRegistrationColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FamilyRegistrationColumnSpec>(map);
  }

  static FamilyRegistrationColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<FamilyRegistrationColumnSpec>(json);
  }
}

mixin FamilyRegistrationColumnSpecMappable {
  String toJson() {
    return FamilyRegistrationColumnSpecMapper.ensureInitialized()
        .encodeJson<FamilyRegistrationColumnSpec>(
          this as FamilyRegistrationColumnSpec,
        );
  }

  Map<String, dynamic> toMap() {
    return FamilyRegistrationColumnSpecMapper.ensureInitialized()
        .encodeMap<FamilyRegistrationColumnSpec>(
          this as FamilyRegistrationColumnSpec,
        );
  }
}

