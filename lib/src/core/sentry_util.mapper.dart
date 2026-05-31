// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'sentry_util.dart';

class SentryRateLimitMapper extends ClassMapperBase<SentryRateLimit> {
  SentryRateLimitMapper._();

  static SentryRateLimitMapper? _instance;
  static SentryRateLimitMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SentryRateLimitMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'SentryRateLimit';

  static bool _$available(SentryRateLimit v) => v.available;
  static const Field<SentryRateLimit, bool> _f$available = Field(
    'available',
    _$available,
  );
  static int _$rateLimitPerMonth(SentryRateLimit v) => v.rateLimitPerMonth;
  static const Field<SentryRateLimit, int> _f$rateLimitPerMonth = Field(
    'rateLimitPerMonth',
    _$rateLimitPerMonth,
    key: r'rate_limit_per_month',
  );

  @override
  final MappableFields<SentryRateLimit> fields = const {
    #available: _f$available,
    #rateLimitPerMonth: _f$rateLimitPerMonth,
  };

  static SentryRateLimit _instantiate(DecodingData data) {
    return SentryRateLimit(
      data.dec(_f$available),
      data.dec(_f$rateLimitPerMonth),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static SentryRateLimit fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SentryRateLimit>(map);
  }

  static SentryRateLimit fromJson(String json) {
    return ensureInitialized().decodeJson<SentryRateLimit>(json);
  }
}

mixin SentryRateLimitMappable {
  String toJson() {
    return SentryRateLimitMapper.ensureInitialized()
        .encodeJson<SentryRateLimit>(this as SentryRateLimit);
  }

  Map<String, dynamic> toMap() {
    return SentryRateLimitMapper.ensureInitialized().encodeMap<SentryRateLimit>(
      this as SentryRateLimit,
    );
  }
}

