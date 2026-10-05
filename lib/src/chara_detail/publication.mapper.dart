// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'publication.dart';

class PublicationStateMapper extends EnumMapper<PublicationState> {
  PublicationStateMapper._();

  static PublicationStateMapper? _instance;
  static PublicationStateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PublicationStateMapper._());
    }
    return _instance!;
  }

  static PublicationState fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  PublicationState decode(dynamic value) {
    switch (value) {
      case r'pending':
        return PublicationState.pending;
      case r'published':
        return PublicationState.published;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(PublicationState self) {
    switch (self) {
      case PublicationState.pending:
        return r'pending';
      case PublicationState.published:
        return r'published';
    }
  }
}

extension PublicationStateMapperExtension on PublicationState {
  String toValue() {
    PublicationStateMapper.ensureInitialized();
    return MapperContainer.globals.toValue<PublicationState>(this) as String;
  }
}

class PublicationEntryMapper extends ClassMapperBase<PublicationEntry> {
  PublicationEntryMapper._();

  static PublicationEntryMapper? _instance;
  static PublicationEntryMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PublicationEntryMapper._());
      PublicationStateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'PublicationEntry';

  static String _$recordId(PublicationEntry v) => v.recordId;
  static const Field<PublicationEntry, String> _f$recordId = Field(
    'recordId',
    _$recordId,
    key: r'record_id',
  );
  static String _$deleteKey(PublicationEntry v) => v.deleteKey;
  static const Field<PublicationEntry, String> _f$deleteKey = Field(
    'deleteKey',
    _$deleteKey,
    key: r'delete_key',
  );
  static PublicationState _$state(PublicationEntry v) => v.state;
  static const Field<PublicationEntry, PublicationState> _f$state = Field(
    'state',
    _$state,
  );
  static String? _$id(PublicationEntry v) => v.id;
  static const Field<PublicationEntry, String> _f$id = Field(
    'id',
    _$id,
    opt: true,
  );
  static String? _$url(PublicationEntry v) => v.url;
  static const Field<PublicationEntry, String> _f$url = Field(
    'url',
    _$url,
    opt: true,
  );
  static String? _$publishedOn(PublicationEntry v) => v.publishedOn;
  static const Field<PublicationEntry, String> _f$publishedOn = Field(
    'publishedOn',
    _$publishedOn,
    key: r'published_on',
    opt: true,
  );

  @override
  final MappableFields<PublicationEntry> fields = const {
    #recordId: _f$recordId,
    #deleteKey: _f$deleteKey,
    #state: _f$state,
    #id: _f$id,
    #url: _f$url,
    #publishedOn: _f$publishedOn,
  };
  @override
  final bool ignoreNull = true;

  static PublicationEntry _instantiate(DecodingData data) {
    return PublicationEntry(
      recordId: data.dec(_f$recordId),
      deleteKey: data.dec(_f$deleteKey),
      state: data.dec(_f$state),
      id: data.dec(_f$id),
      url: data.dec(_f$url),
      publishedOn: data.dec(_f$publishedOn),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static PublicationEntry fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<PublicationEntry>(map);
  }

  static PublicationEntry fromJson(String json) {
    return ensureInitialized().decodeJson<PublicationEntry>(json);
  }
}

mixin PublicationEntryMappable {
  String toJson() {
    return PublicationEntryMapper.ensureInitialized()
        .encodeJson<PublicationEntry>(this as PublicationEntry);
  }

  Map<String, dynamic> toMap() {
    return PublicationEntryMapper.ensureInitialized()
        .encodeMap<PublicationEntry>(this as PublicationEntry);
  }
}

