// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'race_grade.dart';

class RaceGradeWinningCountColumnSpecMapper
    extends SubClassMapperBase<RaceGradeWinningCountColumnSpec> {
  RaceGradeWinningCountColumnSpecMapper._();

  static RaceGradeWinningCountColumnSpecMapper? _instance;
  static RaceGradeWinningCountColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = RaceGradeWinningCountColumnSpecMapper._(),
      );
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      IsInRangeIntegerPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RaceGradeWinningCountColumnSpec';

  static String _$id(RaceGradeWinningCountColumnSpec v) => v.id;
  static const Field<RaceGradeWinningCountColumnSpec, String> _f$id = Field(
    'id',
    _$id,
  );
  static String _$title(RaceGradeWinningCountColumnSpec v) => v.title;
  static const Field<RaceGradeWinningCountColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static IsInRangeIntegerPredicate _$predicate(
    RaceGradeWinningCountColumnSpec v,
  ) => v.predicate;
  static const Field<RaceGradeWinningCountColumnSpec, IsInRangeIntegerPredicate>
  _f$predicate = Field('predicate', _$predicate);
  static String _$grade(RaceGradeWinningCountColumnSpec v) => v.grade;
  static const Field<RaceGradeWinningCountColumnSpec, String> _f$grade = Field(
    'grade',
    _$grade,
    opt: true,
    def: "grade_g1",
  );
  static Set<int> _$selection(RaceGradeWinningCountColumnSpec v) => v.selection;
  static const Field<RaceGradeWinningCountColumnSpec, Set<int>> _f$selection =
      Field('selection', _$selection, opt: true, def: const {});
  static bool _$hidden(RaceGradeWinningCountColumnSpec v) => v.hidden;
  static const Field<RaceGradeWinningCountColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(RaceGradeWinningCountColumnSpec v) =>
      v.description;
  static const Field<RaceGradeWinningCountColumnSpec, String> _f$description =
      Field('description', _$description, opt: true);
  static double? _$width(RaceGradeWinningCountColumnSpec v) => v.width;
  static const Field<RaceGradeWinningCountColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );

  @override
  final MappableFields<RaceGradeWinningCountColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #predicate: _f$predicate,
    #grade: _f$grade,
    #selection: _f$selection,
    #hidden: _f$hidden,
    #description: _f$description,
    #width: _f$width,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RaceGradeWinningCountColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RaceGradeWinningCountColumnSpec _instantiate(DecodingData data) {
    return RaceGradeWinningCountColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      predicate: data.dec(_f$predicate),
      grade: data.dec(_f$grade),
      selection: data.dec(_f$selection),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
      width: data.dec(_f$width),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RaceGradeWinningCountColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RaceGradeWinningCountColumnSpec>(map);
  }

  static RaceGradeWinningCountColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<RaceGradeWinningCountColumnSpec>(
      json,
    );
  }
}

mixin RaceGradeWinningCountColumnSpecMappable {
  String toJson() {
    return RaceGradeWinningCountColumnSpecMapper.ensureInitialized()
        .encodeJson<RaceGradeWinningCountColumnSpec>(
          this as RaceGradeWinningCountColumnSpec,
        );
  }

  Map<String, dynamic> toMap() {
    return RaceGradeWinningCountColumnSpecMapper.ensureInitialized()
        .encodeMap<RaceGradeWinningCountColumnSpec>(
          this as RaceGradeWinningCountColumnSpec,
        );
  }
}

