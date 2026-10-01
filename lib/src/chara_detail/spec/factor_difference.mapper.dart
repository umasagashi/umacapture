// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'factor_difference.dart';

class FactorDifferenceColumnSpecMapper
    extends SubClassMapperBase<FactorDifferenceColumnSpec> {
  FactorDifferenceColumnSpecMapper._();

  static FactorDifferenceColumnSpecMapper? _instance;
  static FactorDifferenceColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = FactorDifferenceColumnSpecMapper._(),
      );
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ParserMapper.ensureInitialized();
      FactorSearchSubjectModeMapper.ensureInitialized();
      FactorNotationModeMapper.ensureInitialized();
      FactorDialogElementsMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FactorDifferenceColumnSpec';

  static String _$id(FactorDifferenceColumnSpec v) => v.id;
  static const Field<FactorDifferenceColumnSpec, String> _f$id = Field(
    'id',
    _$id,
  );
  static String _$title(FactorDifferenceColumnSpec v) => v.title;
  static const Field<FactorDifferenceColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static Parser<dynamic> _$parser(FactorDifferenceColumnSpec v) => v.parser;
  static const Field<FactorDifferenceColumnSpec, Parser<dynamic>> _f$parser =
      Field('parser', _$parser);
  static Set<int> _$query(FactorDifferenceColumnSpec v) => v.query;
  static const Field<FactorDifferenceColumnSpec, Set<int>> _f$query = Field(
    'query',
    _$query,
    opt: true,
    def: const {},
  );
  static Set<String> _$factorTags(FactorDifferenceColumnSpec v) => v.factorTags;
  static const Field<FactorDifferenceColumnSpec, Set<String>> _f$factorTags =
      Field('factorTags', _$factorTags, opt: true, def: const {});
  static Set<String> _$skillTags(FactorDifferenceColumnSpec v) => v.skillTags;
  static const Field<FactorDifferenceColumnSpec, Set<String>> _f$skillTags =
      Field('skillTags', _$skillTags, opt: true, def: const {});
  static bool _$selectByTag(FactorDifferenceColumnSpec v) => v.selectByTag;
  static const Field<FactorDifferenceColumnSpec, bool> _f$selectByTag = Field(
    'selectByTag',
    _$selectByTag,
    opt: true,
    def: false,
  );
  static FactorSearchSubjectMode _$subject(FactorDifferenceColumnSpec v) =>
      v.subject;
  static const Field<FactorDifferenceColumnSpec, FactorSearchSubjectMode>
  _f$subject = Field(
    'subject',
    _$subject,
    opt: true,
    def: FactorSearchSubjectMode.family,
  );
  static FactorNotationMode _$notationMode(FactorDifferenceColumnSpec v) =>
      v.notationMode;
  static const Field<FactorDifferenceColumnSpec, FactorNotationMode>
  _f$notationMode = Field(
    'notationMode',
    _$notationMode,
    opt: true,
    def: FactorNotationMode.nameStarTotal,
  );
  static int _$max(FactorDifferenceColumnSpec v) => v.max;
  static const Field<FactorDifferenceColumnSpec, int> _f$max = Field(
    'max',
    _$max,
    opt: true,
    def: 3,
  );
  static bool _$hideCommonItems(FactorDifferenceColumnSpec v) =>
      v.hideCommonItems;
  static const Field<FactorDifferenceColumnSpec, bool> _f$hideCommonItems =
      Field('hideCommonItems', _$hideCommonItems, opt: true, def: false);
  static bool _$showAllWhenQueryIsEmpty(FactorDifferenceColumnSpec v) =>
      v.showAllWhenQueryIsEmpty;
  static const Field<FactorDifferenceColumnSpec, bool>
  _f$showAllWhenQueryIsEmpty = Field(
    'showAllWhenQueryIsEmpty',
    _$showAllWhenQueryIsEmpty,
    opt: true,
    def: true,
  );
  static bool _$showAvailableOnly(FactorDifferenceColumnSpec v) =>
      v.showAvailableOnly;
  static const Field<FactorDifferenceColumnSpec, bool> _f$showAvailableOnly =
      Field('showAvailableOnly', _$showAvailableOnly, opt: true, def: true);
  static Set<FactorDialogElements> _$hiddenElements(
    FactorDifferenceColumnSpec v,
  ) => v.hiddenElements;
  static const Field<FactorDifferenceColumnSpec, Set<FactorDialogElements>>
  _f$hiddenElements = Field(
    'hiddenElements',
    _$hiddenElements,
    opt: true,
    def: const {},
  );
  static bool _$hidden(FactorDifferenceColumnSpec v) => v.hidden;
  static const Field<FactorDifferenceColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(FactorDifferenceColumnSpec v) => v.description;
  static const Field<FactorDifferenceColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static double? _$width(FactorDifferenceColumnSpec v) => v.width;
  static const Field<FactorDifferenceColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );
  static String _$labelKey(FactorDifferenceColumnSpec v) => v.labelKey;
  static const Field<FactorDifferenceColumnSpec, String> _f$labelKey = Field(
    'labelKey',
    _$labelKey,
    mode: FieldMode.member,
  );

  @override
  final MappableFields<FactorDifferenceColumnSpec> fields = const {
    #id: _f$id,
    #title: _f$title,
    #parser: _f$parser,
    #query: _f$query,
    #factorTags: _f$factorTags,
    #skillTags: _f$skillTags,
    #selectByTag: _f$selectByTag,
    #subject: _f$subject,
    #notationMode: _f$notationMode,
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
  final dynamic discriminatorValue = 'FactorDifferenceColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static FactorDifferenceColumnSpec _instantiate(DecodingData data) {
    return FactorDifferenceColumnSpec(
      id: data.dec(_f$id),
      title: data.dec(_f$title),
      parser: data.dec(_f$parser),
      query: data.dec(_f$query),
      factorTags: data.dec(_f$factorTags),
      skillTags: data.dec(_f$skillTags),
      selectByTag: data.dec(_f$selectByTag),
      subject: data.dec(_f$subject),
      notationMode: data.dec(_f$notationMode),
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

  static FactorDifferenceColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FactorDifferenceColumnSpec>(map);
  }

  static FactorDifferenceColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<FactorDifferenceColumnSpec>(json);
  }
}

mixin FactorDifferenceColumnSpecMappable {
  String toJson() {
    return FactorDifferenceColumnSpecMapper.ensureInitialized()
        .encodeJson<FactorDifferenceColumnSpec>(
          this as FactorDifferenceColumnSpec,
        );
  }

  Map<String, dynamic> toMap() {
    return FactorDifferenceColumnSpecMapper.ensureInitialized()
        .encodeMap<FactorDifferenceColumnSpec>(
          this as FactorDifferenceColumnSpec,
        );
  }
}

