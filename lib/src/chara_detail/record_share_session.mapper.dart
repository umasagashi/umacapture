// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'record_share_session.dart';

class ShareSessionMapper extends ClassMapperBase<ShareSession> {
  ShareSessionMapper._();

  static ShareSessionMapper? _instance;
  static ShareSessionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ShareSessionMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ShareSession';

  static String _$token(ShareSession v) => v.token;
  static const Field<ShareSession, String> _f$token = Field('token', _$token);
  static int _$expiresAt(ShareSession v) => v.expiresAt;
  static const Field<ShareSession, int> _f$expiresAt = Field(
    'expiresAt',
    _$expiresAt,
    key: r'expires_at',
  );
  static String _$accountId(ShareSession v) => v.accountId;
  static const Field<ShareSession, String> _f$accountId = Field(
    'accountId',
    _$accountId,
    key: r'account_id',
  );
  static bool _$deleting(ShareSession v) => v.deleting;
  static const Field<ShareSession, bool> _f$deleting = Field(
    'deleting',
    _$deleting,
  );

  @override
  final MappableFields<ShareSession> fields = const {
    #token: _f$token,
    #expiresAt: _f$expiresAt,
    #accountId: _f$accountId,
    #deleting: _f$deleting,
  };

  static ShareSession _instantiate(DecodingData data) {
    return ShareSession(
      token: data.dec(_f$token),
      expiresAt: data.dec(_f$expiresAt),
      accountId: data.dec(_f$accountId),
      deleting: data.dec(_f$deleting),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ShareSession fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ShareSession>(map);
  }

  static ShareSession fromJson(String json) {
    return ensureInitialized().decodeJson<ShareSession>(json);
  }
}

mixin ShareSessionMappable {
  String toJson() {
    return ShareSessionMapper.ensureInitialized().encodeJson<ShareSession>(
      this as ShareSession,
    );
  }

  Map<String, dynamic> toMap() {
    return ShareSessionMapper.ensureInitialized().encodeMap<ShareSession>(
      this as ShareSession,
    );
  }
}

