// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'skill_difference.dart';

class SkillDifferenceColumnSpecMapper
    extends SubClassMapperBase<SkillDifferenceColumnSpec> {
  SkillDifferenceColumnSpecMapper._();

  static SkillDifferenceColumnSpecMapper? _instance;
  static SkillDifferenceColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = SkillDifferenceColumnSpecMapper._(),
      );
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      SkillDialogElementsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'SkillDifferenceColumnSpec';

  static String _$id(SkillDifferenceColumnSpec v) => v.id;
  static const Field<SkillDifferenceColumnSpec, String> _f$id = Field(
    'id',
    _$id,
  );
  static String _$title(SkillDifferenceColumnSpec v) => v.title;
  static const Field<SkillDifferenceColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(SkillDifferenceColumnSpec v) => v.parser;
  static const Field<SkillDifferenceColumnSpec, Parser<dynamic>> _f$parser =
      Field('parser', _$parser);
  static Set<int> _$query(SkillDifferenceColumnSpec v) => v.query;
  static const Field<SkillDifferenceColumnSpec, Set<int>> _f$query = Field(
    'query',
    _$query,
    opt: true,
    def: const {},
  );
  static Set<String> _$tags(SkillDifferenceColumnSpec v) => v.tags;
  static const Field<SkillDifferenceColumnSpec, Set<String>> _f$tags = Field(
    'tags',
    _$tags,
    opt: true,
    def: const {},
  );
  static bool _$selectByTag(SkillDifferenceColumnSpec v) => v.selectByTag;
  static const Field<SkillDifferenceColumnSpec, bool> _f$selectByTag = Field(
    'selectByTag',
    _$selectByTag,
    opt: true,
    def: false,
  );
  static int _$max(SkillDifferenceColumnSpec v) => v.max;
  static const Field<SkillDifferenceColumnSpec, int> _f$max = Field(
    'max',
    _$max,
    opt: true,
    def: 3,
  );
  static bool _$hideCommonItems(SkillDifferenceColumnSpec v) =>
      v.hideCommonItems;
  static const Field<SkillDifferenceColumnSpec, bool> _f$hideCommonItems =
      Field('hideCommonItems', _$hideCommonItems, opt: true, def: false);
  static bool _$showAllWhenQueryIsEmpty(SkillDifferenceColumnSpec v) =>
      v.showAllWhenQueryIsEmpty;
  static const Field<SkillDifferenceColumnSpec, bool>
  _f$showAllWhenQueryIsEmpty = Field(
    'showAllWhenQueryIsEmpty',
    _$showAllWhenQueryIsEmpty,
    opt: true,
    def: true,
  );
  static bool _$showAvailableOnly(SkillDifferenceColumnSpec v) =>
      v.showAvailableOnly;
  static const Field<SkillDifferenceColumnSpec, bool> _f$showAvailableOnly =
      Field('showAvailableOnly', _$showAvailableOnly, opt: true, def: true);
  static Set<SkillDialogElements> _$hiddenElements(
    SkillDifferenceColumnSpec v,
  ) => v.hiddenElements;
  static const Field<SkillDifferenceColumnSpec, Set<SkillDialogElements>>
  _f$hiddenElements = Field(
    'hiddenElements',
    _$hiddenElements,
    opt: true,
    def: const {},
  );
  static bool _$hidden(SkillDifferenceColumnSpec v) => v.hidden;
  static const Field<SkillDifferenceColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(SkillDifferenceColumnSpec v) => v.description;
  static const Field<SkillDifferenceColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static double? _$width(SkillDifferenceColumnSpec v) => v.width;
  static const Field<SkillDifferenceColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );
  static String _$labelKey(SkillDifferenceColumnSpec v) => v.labelKey;
  static const Field<SkillDifferenceColumnSpec, String> _f$labelKey = Field(
    'labelKey',
    _$labelKey,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<SkillDifferenceColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #query: _f$query,
    #tags: _f$tags,
    #selectByTag: _f$selectByTag,
    #max: _f$max,
    #hideCommonItems: _f$hideCommonItems,
    #showAllWhenQueryIsEmpty: _f$showAllWhenQueryIsEmpty,
    #showAvailableOnly: _f$showAvailableOnly,
    #hiddenElements: _f$hiddenElements,
    #hidden: _f$hidden,
    #description: _f$description,
    #width: _f$width,
    #labelKey: _f$labelKey,
  };
  @override
  final bool ignoreNull = true;

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'SkillDifferenceColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static SkillDifferenceColumnSpec _instantiate(DecodingData data) {
    return SkillDifferenceColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      query: data.dec(_f$query),
      tags: data.dec(_f$tags),
      selectByTag: data.dec(_f$selectByTag),
      max: data.dec(_f$max),
      hideCommonItems: data.dec(_f$hideCommonItems),
      showAllWhenQueryIsEmpty: data.dec(_f$showAllWhenQueryIsEmpty),
      showAvailableOnly: data.dec(_f$showAvailableOnly),
      hiddenElements: data.dec(_f$hiddenElements),
      hidden: data.dec(_f$hidden),
      description: data.dec(_f$description),
      width: data.dec(_f$width),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static SkillDifferenceColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SkillDifferenceColumnSpec>(map);
  }

  static SkillDifferenceColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<SkillDifferenceColumnSpec>(json);
  }
}

mixin SkillDifferenceColumnSpecMappable {
  String toJson() {
    return SkillDifferenceColumnSpecMapper.ensureInitialized()
        .encodeJson<SkillDifferenceColumnSpec>(
          this as SkillDifferenceColumnSpec,
        );
  }

  Map<String, dynamic> toMap() {
    return SkillDifferenceColumnSpecMapper.ensureInitialized()
        .encodeMap<SkillDifferenceColumnSpec>(
          this as SkillDifferenceColumnSpec,
        );
  }
}

