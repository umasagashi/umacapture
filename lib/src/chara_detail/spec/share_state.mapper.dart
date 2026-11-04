// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'share_state.dart';

class ShareColumnStateMapper extends EnumMapper<ShareColumnState> {
  ShareColumnStateMapper._();

  static ShareColumnStateMapper? _instance;
  static ShareColumnStateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ShareColumnStateMapper._());
    }
    return _instance!;
  }

  static ShareColumnState fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  ShareColumnState decode(dynamic value) {
    switch (value) {
      case r'shared':
        return ShareColumnState.shared;
      case r'pending':
        return ShareColumnState.pending;
      case r'none':
        return ShareColumnState.none;
      case r'notShareable':
        return ShareColumnState.notShareable;
      case r'loggedOut':
        return ShareColumnState.loggedOut;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(ShareColumnState self) {
    switch (self) {
      case ShareColumnState.shared:
        return r'shared';
      case ShareColumnState.pending:
        return r'pending';
      case ShareColumnState.none:
        return r'none';
      case ShareColumnState.notShareable:
        return r'notShareable';
      case ShareColumnState.loggedOut:
        return r'loggedOut';
    }
  }
}

extension ShareColumnStateMapperExtension on ShareColumnState {
  String toValue() {
    ShareColumnStateMapper.ensureInitialized();
    return MapperContainer.globals.toValue<ShareColumnState>(this) as String;
  }
}

class ShareColumnPredicateMapper extends ClassMapperBase<ShareColumnPredicate> {
  ShareColumnPredicateMapper._();

  static ShareColumnPredicateMapper? _instance;
  static ShareColumnPredicateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ShareColumnPredicateMapper._());
      ShareColumnStateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ShareColumnPredicate';

  static Set<ShareColumnState> _$rejects(ShareColumnPredicate v) => v.rejects;
  static const Field<ShareColumnPredicate, Set<ShareColumnState>> _f$rejects =
      Field('rejects', _$rejects, opt: true, def: const {});

  @override
  final MappableFields<ShareColumnPredicate> fields = const {
    #rejects: _f$rejects,
  };

  static ShareColumnPredicate _instantiate(DecodingData data) {
    return ShareColumnPredicate(rejects: data.dec(_f$rejects));
  }

  @override
  final Function instantiate = _instantiate;

  static ShareColumnPredicate fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ShareColumnPredicate>(map);
  }

  static ShareColumnPredicate fromJson(String json) {
    return ensureInitialized().decodeJson<ShareColumnPredicate>(json);
  }
}

mixin ShareColumnPredicateMappable {
  String toJson() {
    return ShareColumnPredicateMapper.ensureInitialized()
        .encodeJson<ShareColumnPredicate>(this as ShareColumnPredicate);
  }

  Map<String, dynamic> toMap() {
    return ShareColumnPredicateMapper.ensureInitialized()
        .encodeMap<ShareColumnPredicate>(this as ShareColumnPredicate);
  }
}

class ShareStateColumnSpecMapper
    extends SubClassMapperBase<ShareStateColumnSpec> {
  ShareStateColumnSpecMapper._();

  static ShareStateColumnSpecMapper? _instance;
  static ShareStateColumnSpecMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ShareStateColumnSpecMapper._());
      ColumnSpecMapper.ensureInitialized().addSubMapper(_instance!);
      ShareColumnPredicateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ShareStateColumnSpec';

  static String _$id(ShareStateColumnSpec v) => v.id;
  static const Field<ShareStateColumnSpec, String> _f$id = Field('id', _$id);
  static String _$title(ShareStateColumnSpec v) => v.title;
  static const Field<ShareStateColumnSpec, String> _f$title = Field(
    'title',
    _$title,
  );
  static ShareColumnPredicate _$predicate(ShareStateColumnSpec v) =>
      v.predicate;
  static const Field<ShareStateColumnSpec, ShareColumnPredicate> _f$predicate =
      Field('predicate', _$predicate);
  static bool _$hidden(ShareStateColumnSpec v) => v.hidden;
  static const Field<ShareStateColumnSpec, bool> _f$hidden = Field(
    'hidden',
    _$hidden,
    opt: true,
    def: false,
  );
  static String? _$description(ShareStateColumnSpec v) => v.description;
  static const Field<ShareStateColumnSpec, String> _f$description = Field(
    'description',
    _$description,
    opt: true,
  );
  static double? _$width(ShareStateColumnSpec v) => v.width;
  static const Field<ShareStateColumnSpec, double> _f$width = Field(
    'width',
    _$width,
    opt: true,
  );

  @override
  final MappableFields<ShareStateColumnSpec> fields = const {
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
  final dynamic discriminatorValue = 'ShareStateColumnSpec';
  @override
  late final ClassMapperBase superMapper = ColumnSpecMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static ShareStateColumnSpec _instantiate(DecodingData data) {
    return ShareStateColumnSpec(
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

  static ShareStateColumnSpec fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ShareStateColumnSpec>(map);
  }

  static ShareStateColumnSpec fromJson(String json) {
    return ensureInitialized().decodeJson<ShareStateColumnSpec>(json);
  }
}

mixin ShareStateColumnSpecMappable {
  String toJson() {
    return ShareStateColumnSpecMapper.ensureInitialized()
        .encodeJson<ShareStateColumnSpec>(this as ShareStateColumnSpec);
  }

  Map<String, dynamic> toMap() {
    return ShareStateColumnSpecMapper.ensureInitialized()
        .encodeMap<ShareStateColumnSpec>(this as ShareStateColumnSpec);
  }
}

