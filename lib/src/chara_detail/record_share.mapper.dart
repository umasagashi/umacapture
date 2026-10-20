// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'record_share.dart';

class RecordShareStateMapper extends EnumMapper<RecordShareState> {
  RecordShareStateMapper._();

  static RecordShareStateMapper? _instance;
  static RecordShareStateMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RecordShareStateMapper._());
    }
    return _instance!;
  }

  static RecordShareState fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  RecordShareState decode(dynamic value) {
    switch (value) {
      case r'pending':
        return RecordShareState.pending;
      case r'shared':
        return RecordShareState.shared;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(RecordShareState self) {
    switch (self) {
      case RecordShareState.pending:
        return r'pending';
      case RecordShareState.shared:
        return r'shared';
    }
  }
}

extension RecordShareStateMapperExtension on RecordShareState {
  String toValue() {
    RecordShareStateMapper.ensureInitialized();
    return MapperContainer.globals.toValue<RecordShareState>(this) as String;
  }
}

class RecordShareMapper extends ClassMapperBase<RecordShare> {
  RecordShareMapper._();

  static RecordShareMapper? _instance;
  static RecordShareMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RecordShareMapper._());
      RecordShareStateMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'RecordShare';

  static String _$recordId(RecordShare v) => v.recordId;
  static const Field<RecordShare, String> _f$recordId = Field(
    'recordId',
    _$recordId,
    key: r'record_id',
  );
  static String _$accountId(RecordShare v) => v.accountId;
  static const Field<RecordShare, String> _f$accountId = Field(
    'accountId',
    _$accountId,
    key: r'account_id',
  );
  static String _$clientKey(RecordShare v) => v.clientKey;
  static const Field<RecordShare, String> _f$clientKey = Field(
    'clientKey',
    _$clientKey,
    key: r'client_key',
  );
  static RecordShareState _$state(RecordShare v) => v.state;
  static const Field<RecordShare, RecordShareState> _f$state = Field(
    'state',
    _$state,
  );
  static String? _$id(RecordShare v) => v.id;
  static const Field<RecordShare, String> _f$id = Field('id', _$id, opt: true);
  static String? _$url(RecordShare v) => v.url;
  static const Field<RecordShare, String> _f$url = Field(
    'url',
    _$url,
    opt: true,
  );
  static String? _$sharedOn(RecordShare v) => v.sharedOn;
  static const Field<RecordShare, String> _f$sharedOn = Field(
    'sharedOn',
    _$sharedOn,
    key: r'shared_on',
    opt: true,
  );

  @override
  final MappableFields<RecordShare> fields = const {
    #recordId: _f$recordId,
    #accountId: _f$accountId,
    #clientKey: _f$clientKey,
    #state: _f$state,
    #id: _f$id,
    #url: _f$url,
    #sharedOn: _f$sharedOn,
  };
  @override
  final bool ignoreNull = true;

  static RecordShare _instantiate(DecodingData data) {
    return RecordShare(
      recordId: data.dec(_f$recordId),
      accountId: data.dec(_f$accountId),
      clientKey: data.dec(_f$clientKey),
      state: data.dec(_f$state),
      id: data.dec(_f$id),
      url: data.dec(_f$url),
      sharedOn: data.dec(_f$sharedOn),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RecordShare fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RecordShare>(map);
  }

  static RecordShare fromJson(String json) {
    return ensureInitialized().decodeJson<RecordShare>(json);
  }
}

mixin RecordShareMappable {
  String toJson() {
    return RecordShareMapper.ensureInitialized().encodeJson<RecordShare>(
      this as RecordShare,
    );
  }

  Map<String, dynamic> toMap() {
    return RecordShareMapper.ensureInitialized().encodeMap<RecordShare>(
      this as RecordShare,
    );
  }
}

