// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'parser.dart';

class ParserMapper extends ClassMapperBase<Parser> {
  ParserMapper._();

  static ParserMapper? _instance;
  static ParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ParserMapper._());
      EvaluationValueParserMapper.ensureInitialized();
      CharaCardParserMapper.ensureInitialized();
      StatusSpeedParserMapper.ensureInitialized();
      StatusStaminaParserMapper.ensureInitialized();
      StatusPowerParserMapper.ensureInitialized();
      StatusGutsParserMapper.ensureInitialized();
      StatusIntelligenceParserMapper.ensureInitialized();
      TurfGroundAptitudeParserMapper.ensureInitialized();
      DirtGroundAptitudeParserMapper.ensureInitialized();
      ShortRangeAptitudeParserMapper.ensureInitialized();
      MileRangeAptitudeParserMapper.ensureInitialized();
      MiddleRangeAptitudeParserMapper.ensureInitialized();
      LongRangeAptitudeParserMapper.ensureInitialized();
      LeadPaceAptitudeParserMapper.ensureInitialized();
      WithPaceAptitudeParserMapper.ensureInitialized();
      OffPaceAptitudeParserMapper.ensureInitialized();
      LateChargeAptitudeParserMapper.ensureInitialized();
      SkillParserMapper.ensureInitialized();
      FactorSetParserMapper.ensureInitialized();
      FansParserMapper.ensureInitialized();
      ForeignAptitudeParserMapper.ensureInitialized();
      TrainedDateParserMapper.ensureInitialized();
      CapturedDateParserMapper.ensureInitialized();
      RaceWinningCountParserMapper.ensureInitialized();
      RecordTypeParserMapper.ensureInitialized();
      CampaignScenarioParserMapper.ensureInitialized();
      TraineeIdParserMapper.ensureInitialized();
      RaceStrategyParserMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'Parser';
  @override
  Function get typeFactory =>
      <T>(f) => f<Parser<T>>();

  @override
  final MappableFields<Parser> fields = const {};

  static Parser<T> _instantiate<T>(DecodingData data) {
    throw MapperException.missingSubclass(
      'Parser',
      'type',
      '${data.value['type']}',
    );
  }

  @override
  final Function instantiate = _instantiate;

  static Parser<T> fromMap<T>(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Parser<T>>(map);
  }

  static Parser<T> fromJson<T>(String json) {
    return ensureInitialized().decodeJson<Parser<T>>(json);
  }
}

mixin ParserMappable<T> {
  String toJson();
  Map<String, dynamic> toMap();
}

class EvaluationValueParserMapper
    extends SubClassMapperBase<EvaluationValueParser> {
  EvaluationValueParserMapper._();

  static EvaluationValueParserMapper? _instance;
  static EvaluationValueParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = EvaluationValueParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'EvaluationValueParser';

  @override
  final MappableFields<EvaluationValueParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'EvaluationValueParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static EvaluationValueParser _instantiate(DecodingData data) {
    return EvaluationValueParser();
  }

  @override
  final Function instantiate = _instantiate;

  static EvaluationValueParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<EvaluationValueParser>(map);
  }

  static EvaluationValueParser fromJson(String json) {
    return ensureInitialized().decodeJson<EvaluationValueParser>(json);
  }
}

mixin EvaluationValueParserMappable {
  String toJson() {
    return EvaluationValueParserMapper.ensureInitialized()
        .encodeJson<EvaluationValueParser>(this as EvaluationValueParser);
  }

  Map<String, dynamic> toMap() {
    return EvaluationValueParserMapper.ensureInitialized()
        .encodeMap<EvaluationValueParser>(this as EvaluationValueParser);
  }
}

class CharaCardParserMapper extends SubClassMapperBase<CharaCardParser> {
  CharaCardParserMapper._();

  static CharaCardParserMapper? _instance;
  static CharaCardParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CharaCardParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'CharaCardParser';

  @override
  final MappableFields<CharaCardParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'CharaCardParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static CharaCardParser _instantiate(DecodingData data) {
    return CharaCardParser();
  }

  @override
  final Function instantiate = _instantiate;

  static CharaCardParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CharaCardParser>(map);
  }

  static CharaCardParser fromJson(String json) {
    return ensureInitialized().decodeJson<CharaCardParser>(json);
  }
}

mixin CharaCardParserMappable {
  String toJson() {
    return CharaCardParserMapper.ensureInitialized()
        .encodeJson<CharaCardParser>(this as CharaCardParser);
  }

  Map<String, dynamic> toMap() {
    return CharaCardParserMapper.ensureInitialized().encodeMap<CharaCardParser>(
      this as CharaCardParser,
    );
  }
}

class StatusSpeedParserMapper extends SubClassMapperBase<StatusSpeedParser> {
  StatusSpeedParserMapper._();

  static StatusSpeedParserMapper? _instance;
  static StatusSpeedParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = StatusSpeedParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'StatusSpeedParser';

  @override
  final MappableFields<StatusSpeedParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'StatusSpeedParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static StatusSpeedParser _instantiate(DecodingData data) {
    return StatusSpeedParser();
  }

  @override
  final Function instantiate = _instantiate;

  static StatusSpeedParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<StatusSpeedParser>(map);
  }

  static StatusSpeedParser fromJson(String json) {
    return ensureInitialized().decodeJson<StatusSpeedParser>(json);
  }
}

mixin StatusSpeedParserMappable {
  String toJson() {
    return StatusSpeedParserMapper.ensureInitialized()
        .encodeJson<StatusSpeedParser>(this as StatusSpeedParser);
  }

  Map<String, dynamic> toMap() {
    return StatusSpeedParserMapper.ensureInitialized()
        .encodeMap<StatusSpeedParser>(this as StatusSpeedParser);
  }
}

class StatusStaminaParserMapper
    extends SubClassMapperBase<StatusStaminaParser> {
  StatusStaminaParserMapper._();

  static StatusStaminaParserMapper? _instance;
  static StatusStaminaParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = StatusStaminaParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'StatusStaminaParser';

  @override
  final MappableFields<StatusStaminaParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'StatusStaminaParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static StatusStaminaParser _instantiate(DecodingData data) {
    return StatusStaminaParser();
  }

  @override
  final Function instantiate = _instantiate;

  static StatusStaminaParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<StatusStaminaParser>(map);
  }

  static StatusStaminaParser fromJson(String json) {
    return ensureInitialized().decodeJson<StatusStaminaParser>(json);
  }
}

mixin StatusStaminaParserMappable {
  String toJson() {
    return StatusStaminaParserMapper.ensureInitialized()
        .encodeJson<StatusStaminaParser>(this as StatusStaminaParser);
  }

  Map<String, dynamic> toMap() {
    return StatusStaminaParserMapper.ensureInitialized()
        .encodeMap<StatusStaminaParser>(this as StatusStaminaParser);
  }
}

class StatusPowerParserMapper extends SubClassMapperBase<StatusPowerParser> {
  StatusPowerParserMapper._();

  static StatusPowerParserMapper? _instance;
  static StatusPowerParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = StatusPowerParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'StatusPowerParser';

  @override
  final MappableFields<StatusPowerParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'StatusPowerParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static StatusPowerParser _instantiate(DecodingData data) {
    return StatusPowerParser();
  }

  @override
  final Function instantiate = _instantiate;

  static StatusPowerParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<StatusPowerParser>(map);
  }

  static StatusPowerParser fromJson(String json) {
    return ensureInitialized().decodeJson<StatusPowerParser>(json);
  }
}

mixin StatusPowerParserMappable {
  String toJson() {
    return StatusPowerParserMapper.ensureInitialized()
        .encodeJson<StatusPowerParser>(this as StatusPowerParser);
  }

  Map<String, dynamic> toMap() {
    return StatusPowerParserMapper.ensureInitialized()
        .encodeMap<StatusPowerParser>(this as StatusPowerParser);
  }
}

class StatusGutsParserMapper extends SubClassMapperBase<StatusGutsParser> {
  StatusGutsParserMapper._();

  static StatusGutsParserMapper? _instance;
  static StatusGutsParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = StatusGutsParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'StatusGutsParser';

  @override
  final MappableFields<StatusGutsParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'StatusGutsParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static StatusGutsParser _instantiate(DecodingData data) {
    return StatusGutsParser();
  }

  @override
  final Function instantiate = _instantiate;

  static StatusGutsParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<StatusGutsParser>(map);
  }

  static StatusGutsParser fromJson(String json) {
    return ensureInitialized().decodeJson<StatusGutsParser>(json);
  }
}

mixin StatusGutsParserMappable {
  String toJson() {
    return StatusGutsParserMapper.ensureInitialized()
        .encodeJson<StatusGutsParser>(this as StatusGutsParser);
  }

  Map<String, dynamic> toMap() {
    return StatusGutsParserMapper.ensureInitialized()
        .encodeMap<StatusGutsParser>(this as StatusGutsParser);
  }
}

class StatusIntelligenceParserMapper
    extends SubClassMapperBase<StatusIntelligenceParser> {
  StatusIntelligenceParserMapper._();

  static StatusIntelligenceParserMapper? _instance;
  static StatusIntelligenceParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = StatusIntelligenceParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'StatusIntelligenceParser';

  @override
  final MappableFields<StatusIntelligenceParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'StatusIntelligenceParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static StatusIntelligenceParser _instantiate(DecodingData data) {
    return StatusIntelligenceParser();
  }

  @override
  final Function instantiate = _instantiate;

  static StatusIntelligenceParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<StatusIntelligenceParser>(map);
  }

  static StatusIntelligenceParser fromJson(String json) {
    return ensureInitialized().decodeJson<StatusIntelligenceParser>(json);
  }
}

mixin StatusIntelligenceParserMappable {
  String toJson() {
    return StatusIntelligenceParserMapper.ensureInitialized()
        .encodeJson<StatusIntelligenceParser>(this as StatusIntelligenceParser);
  }

  Map<String, dynamic> toMap() {
    return StatusIntelligenceParserMapper.ensureInitialized()
        .encodeMap<StatusIntelligenceParser>(this as StatusIntelligenceParser);
  }
}

class TurfGroundAptitudeParserMapper
    extends SubClassMapperBase<TurfGroundAptitudeParser> {
  TurfGroundAptitudeParserMapper._();

  static TurfGroundAptitudeParserMapper? _instance;
  static TurfGroundAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = TurfGroundAptitudeParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'TurfGroundAptitudeParser';

  @override
  final MappableFields<TurfGroundAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'TurfGroundAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static TurfGroundAptitudeParser _instantiate(DecodingData data) {
    return TurfGroundAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static TurfGroundAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TurfGroundAptitudeParser>(map);
  }

  static TurfGroundAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<TurfGroundAptitudeParser>(json);
  }
}

mixin TurfGroundAptitudeParserMappable {
  String toJson() {
    return TurfGroundAptitudeParserMapper.ensureInitialized()
        .encodeJson<TurfGroundAptitudeParser>(this as TurfGroundAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return TurfGroundAptitudeParserMapper.ensureInitialized()
        .encodeMap<TurfGroundAptitudeParser>(this as TurfGroundAptitudeParser);
  }
}

class DirtGroundAptitudeParserMapper
    extends SubClassMapperBase<DirtGroundAptitudeParser> {
  DirtGroundAptitudeParserMapper._();

  static DirtGroundAptitudeParserMapper? _instance;
  static DirtGroundAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = DirtGroundAptitudeParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'DirtGroundAptitudeParser';

  @override
  final MappableFields<DirtGroundAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'DirtGroundAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static DirtGroundAptitudeParser _instantiate(DecodingData data) {
    return DirtGroundAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static DirtGroundAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<DirtGroundAptitudeParser>(map);
  }

  static DirtGroundAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<DirtGroundAptitudeParser>(json);
  }
}

mixin DirtGroundAptitudeParserMappable {
  String toJson() {
    return DirtGroundAptitudeParserMapper.ensureInitialized()
        .encodeJson<DirtGroundAptitudeParser>(this as DirtGroundAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return DirtGroundAptitudeParserMapper.ensureInitialized()
        .encodeMap<DirtGroundAptitudeParser>(this as DirtGroundAptitudeParser);
  }
}

class ShortRangeAptitudeParserMapper
    extends SubClassMapperBase<ShortRangeAptitudeParser> {
  ShortRangeAptitudeParserMapper._();

  static ShortRangeAptitudeParserMapper? _instance;
  static ShortRangeAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = ShortRangeAptitudeParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'ShortRangeAptitudeParser';

  @override
  final MappableFields<ShortRangeAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'ShortRangeAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static ShortRangeAptitudeParser _instantiate(DecodingData data) {
    return ShortRangeAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static ShortRangeAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ShortRangeAptitudeParser>(map);
  }

  static ShortRangeAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<ShortRangeAptitudeParser>(json);
  }
}

mixin ShortRangeAptitudeParserMappable {
  String toJson() {
    return ShortRangeAptitudeParserMapper.ensureInitialized()
        .encodeJson<ShortRangeAptitudeParser>(this as ShortRangeAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return ShortRangeAptitudeParserMapper.ensureInitialized()
        .encodeMap<ShortRangeAptitudeParser>(this as ShortRangeAptitudeParser);
  }
}

class MileRangeAptitudeParserMapper
    extends SubClassMapperBase<MileRangeAptitudeParser> {
  MileRangeAptitudeParserMapper._();

  static MileRangeAptitudeParserMapper? _instance;
  static MileRangeAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = MileRangeAptitudeParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'MileRangeAptitudeParser';

  @override
  final MappableFields<MileRangeAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'MileRangeAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static MileRangeAptitudeParser _instantiate(DecodingData data) {
    return MileRangeAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static MileRangeAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MileRangeAptitudeParser>(map);
  }

  static MileRangeAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<MileRangeAptitudeParser>(json);
  }
}

mixin MileRangeAptitudeParserMappable {
  String toJson() {
    return MileRangeAptitudeParserMapper.ensureInitialized()
        .encodeJson<MileRangeAptitudeParser>(this as MileRangeAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return MileRangeAptitudeParserMapper.ensureInitialized()
        .encodeMap<MileRangeAptitudeParser>(this as MileRangeAptitudeParser);
  }
}

class MiddleRangeAptitudeParserMapper
    extends SubClassMapperBase<MiddleRangeAptitudeParser> {
  MiddleRangeAptitudeParserMapper._();

  static MiddleRangeAptitudeParserMapper? _instance;
  static MiddleRangeAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = MiddleRangeAptitudeParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'MiddleRangeAptitudeParser';

  @override
  final MappableFields<MiddleRangeAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'MiddleRangeAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static MiddleRangeAptitudeParser _instantiate(DecodingData data) {
    return MiddleRangeAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static MiddleRangeAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<MiddleRangeAptitudeParser>(map);
  }

  static MiddleRangeAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<MiddleRangeAptitudeParser>(json);
  }
}

mixin MiddleRangeAptitudeParserMappable {
  String toJson() {
    return MiddleRangeAptitudeParserMapper.ensureInitialized()
        .encodeJson<MiddleRangeAptitudeParser>(
          this as MiddleRangeAptitudeParser,
        );
  }

  Map<String, dynamic> toMap() {
    return MiddleRangeAptitudeParserMapper.ensureInitialized()
        .encodeMap<MiddleRangeAptitudeParser>(
          this as MiddleRangeAptitudeParser,
        );
  }
}

class LongRangeAptitudeParserMapper
    extends SubClassMapperBase<LongRangeAptitudeParser> {
  LongRangeAptitudeParserMapper._();

  static LongRangeAptitudeParserMapper? _instance;
  static LongRangeAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = LongRangeAptitudeParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'LongRangeAptitudeParser';

  @override
  final MappableFields<LongRangeAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'LongRangeAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static LongRangeAptitudeParser _instantiate(DecodingData data) {
    return LongRangeAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static LongRangeAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<LongRangeAptitudeParser>(map);
  }

  static LongRangeAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<LongRangeAptitudeParser>(json);
  }
}

mixin LongRangeAptitudeParserMappable {
  String toJson() {
    return LongRangeAptitudeParserMapper.ensureInitialized()
        .encodeJson<LongRangeAptitudeParser>(this as LongRangeAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return LongRangeAptitudeParserMapper.ensureInitialized()
        .encodeMap<LongRangeAptitudeParser>(this as LongRangeAptitudeParser);
  }
}

class LeadPaceAptitudeParserMapper
    extends SubClassMapperBase<LeadPaceAptitudeParser> {
  LeadPaceAptitudeParserMapper._();

  static LeadPaceAptitudeParserMapper? _instance;
  static LeadPaceAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = LeadPaceAptitudeParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'LeadPaceAptitudeParser';

  @override
  final MappableFields<LeadPaceAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'LeadPaceAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static LeadPaceAptitudeParser _instantiate(DecodingData data) {
    return LeadPaceAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static LeadPaceAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<LeadPaceAptitudeParser>(map);
  }

  static LeadPaceAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<LeadPaceAptitudeParser>(json);
  }
}

mixin LeadPaceAptitudeParserMappable {
  String toJson() {
    return LeadPaceAptitudeParserMapper.ensureInitialized()
        .encodeJson<LeadPaceAptitudeParser>(this as LeadPaceAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return LeadPaceAptitudeParserMapper.ensureInitialized()
        .encodeMap<LeadPaceAptitudeParser>(this as LeadPaceAptitudeParser);
  }
}

class WithPaceAptitudeParserMapper
    extends SubClassMapperBase<WithPaceAptitudeParser> {
  WithPaceAptitudeParserMapper._();

  static WithPaceAptitudeParserMapper? _instance;
  static WithPaceAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = WithPaceAptitudeParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'WithPaceAptitudeParser';

  @override
  final MappableFields<WithPaceAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'WithPaceAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static WithPaceAptitudeParser _instantiate(DecodingData data) {
    return WithPaceAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static WithPaceAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<WithPaceAptitudeParser>(map);
  }

  static WithPaceAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<WithPaceAptitudeParser>(json);
  }
}

mixin WithPaceAptitudeParserMappable {
  String toJson() {
    return WithPaceAptitudeParserMapper.ensureInitialized()
        .encodeJson<WithPaceAptitudeParser>(this as WithPaceAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return WithPaceAptitudeParserMapper.ensureInitialized()
        .encodeMap<WithPaceAptitudeParser>(this as WithPaceAptitudeParser);
  }
}

class OffPaceAptitudeParserMapper
    extends SubClassMapperBase<OffPaceAptitudeParser> {
  OffPaceAptitudeParserMapper._();

  static OffPaceAptitudeParserMapper? _instance;
  static OffPaceAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = OffPaceAptitudeParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'OffPaceAptitudeParser';

  @override
  final MappableFields<OffPaceAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'OffPaceAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static OffPaceAptitudeParser _instantiate(DecodingData data) {
    return OffPaceAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static OffPaceAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<OffPaceAptitudeParser>(map);
  }

  static OffPaceAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<OffPaceAptitudeParser>(json);
  }
}

mixin OffPaceAptitudeParserMappable {
  String toJson() {
    return OffPaceAptitudeParserMapper.ensureInitialized()
        .encodeJson<OffPaceAptitudeParser>(this as OffPaceAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return OffPaceAptitudeParserMapper.ensureInitialized()
        .encodeMap<OffPaceAptitudeParser>(this as OffPaceAptitudeParser);
  }
}

class LateChargeAptitudeParserMapper
    extends SubClassMapperBase<LateChargeAptitudeParser> {
  LateChargeAptitudeParserMapper._();

  static LateChargeAptitudeParserMapper? _instance;
  static LateChargeAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = LateChargeAptitudeParserMapper._(),
      );
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'LateChargeAptitudeParser';

  @override
  final MappableFields<LateChargeAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'LateChargeAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static LateChargeAptitudeParser _instantiate(DecodingData data) {
    return LateChargeAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static LateChargeAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<LateChargeAptitudeParser>(map);
  }

  static LateChargeAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<LateChargeAptitudeParser>(json);
  }
}

mixin LateChargeAptitudeParserMappable {
  String toJson() {
    return LateChargeAptitudeParserMapper.ensureInitialized()
        .encodeJson<LateChargeAptitudeParser>(this as LateChargeAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return LateChargeAptitudeParserMapper.ensureInitialized()
        .encodeMap<LateChargeAptitudeParser>(this as LateChargeAptitudeParser);
  }
}

class SkillParserMapper extends SubClassMapperBase<SkillParser> {
  SkillParserMapper._();

  static SkillParserMapper? _instance;
  static SkillParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'SkillParser';

  @override
  final MappableFields<SkillParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'SkillParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static SkillParser _instantiate(DecodingData data) {
    return SkillParser();
  }

  @override
  final Function instantiate = _instantiate;

  static SkillParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SkillParser>(map);
  }

  static SkillParser fromJson(String json) {
    return ensureInitialized().decodeJson<SkillParser>(json);
  }
}

mixin SkillParserMappable {
  String toJson() {
    return SkillParserMapper.ensureInitialized().encodeJson<SkillParser>(
      this as SkillParser,
    );
  }

  Map<String, dynamic> toMap() {
    return SkillParserMapper.ensureInitialized().encodeMap<SkillParser>(
      this as SkillParser,
    );
  }
}

class FactorSetParserMapper extends SubClassMapperBase<FactorSetParser> {
  FactorSetParserMapper._();

  static FactorSetParserMapper? _instance;
  static FactorSetParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorSetParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'FactorSetParser';

  @override
  final MappableFields<FactorSetParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'FactorSetParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static FactorSetParser _instantiate(DecodingData data) {
    return FactorSetParser();
  }

  @override
  final Function instantiate = _instantiate;

  static FactorSetParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FactorSetParser>(map);
  }

  static FactorSetParser fromJson(String json) {
    return ensureInitialized().decodeJson<FactorSetParser>(json);
  }
}

mixin FactorSetParserMappable {
  String toJson() {
    return FactorSetParserMapper.ensureInitialized()
        .encodeJson<FactorSetParser>(this as FactorSetParser);
  }

  Map<String, dynamic> toMap() {
    return FactorSetParserMapper.ensureInitialized().encodeMap<FactorSetParser>(
      this as FactorSetParser,
    );
  }
}

class FansParserMapper extends SubClassMapperBase<FansParser> {
  FansParserMapper._();

  static FansParserMapper? _instance;
  static FansParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FansParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'FansParser';

  @override
  final MappableFields<FansParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'FansParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static FansParser _instantiate(DecodingData data) {
    return FansParser();
  }

  @override
  final Function instantiate = _instantiate;

  static FansParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FansParser>(map);
  }

  static FansParser fromJson(String json) {
    return ensureInitialized().decodeJson<FansParser>(json);
  }
}

mixin FansParserMappable {
  String toJson() {
    return FansParserMapper.ensureInitialized().encodeJson<FansParser>(
      this as FansParser,
    );
  }

  Map<String, dynamic> toMap() {
    return FansParserMapper.ensureInitialized().encodeMap<FansParser>(
      this as FansParser,
    );
  }
}

class ForeignAptitudeParserMapper
    extends SubClassMapperBase<ForeignAptitudeParser> {
  ForeignAptitudeParserMapper._();

  static ForeignAptitudeParserMapper? _instance;
  static ForeignAptitudeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ForeignAptitudeParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'ForeignAptitudeParser';

  @override
  final MappableFields<ForeignAptitudeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'ForeignAptitudeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static ForeignAptitudeParser _instantiate(DecodingData data) {
    return ForeignAptitudeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static ForeignAptitudeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ForeignAptitudeParser>(map);
  }

  static ForeignAptitudeParser fromJson(String json) {
    return ensureInitialized().decodeJson<ForeignAptitudeParser>(json);
  }
}

mixin ForeignAptitudeParserMappable {
  String toJson() {
    return ForeignAptitudeParserMapper.ensureInitialized()
        .encodeJson<ForeignAptitudeParser>(this as ForeignAptitudeParser);
  }

  Map<String, dynamic> toMap() {
    return ForeignAptitudeParserMapper.ensureInitialized()
        .encodeMap<ForeignAptitudeParser>(this as ForeignAptitudeParser);
  }
}

class TrainedDateParserMapper extends SubClassMapperBase<TrainedDateParser> {
  TrainedDateParserMapper._();

  static TrainedDateParserMapper? _instance;
  static TrainedDateParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TrainedDateParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'TrainedDateParser';

  @override
  final MappableFields<TrainedDateParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'TrainedDateParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static TrainedDateParser _instantiate(DecodingData data) {
    return TrainedDateParser();
  }

  @override
  final Function instantiate = _instantiate;

  static TrainedDateParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TrainedDateParser>(map);
  }

  static TrainedDateParser fromJson(String json) {
    return ensureInitialized().decodeJson<TrainedDateParser>(json);
  }
}

mixin TrainedDateParserMappable {
  String toJson() {
    return TrainedDateParserMapper.ensureInitialized()
        .encodeJson<TrainedDateParser>(this as TrainedDateParser);
  }

  Map<String, dynamic> toMap() {
    return TrainedDateParserMapper.ensureInitialized()
        .encodeMap<TrainedDateParser>(this as TrainedDateParser);
  }
}

class CapturedDateParserMapper extends SubClassMapperBase<CapturedDateParser> {
  CapturedDateParserMapper._();

  static CapturedDateParserMapper? _instance;
  static CapturedDateParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CapturedDateParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'CapturedDateParser';

  @override
  final MappableFields<CapturedDateParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'CapturedDateParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static CapturedDateParser _instantiate(DecodingData data) {
    return CapturedDateParser();
  }

  @override
  final Function instantiate = _instantiate;

  static CapturedDateParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CapturedDateParser>(map);
  }

  static CapturedDateParser fromJson(String json) {
    return ensureInitialized().decodeJson<CapturedDateParser>(json);
  }
}

mixin CapturedDateParserMappable {
  String toJson() {
    return CapturedDateParserMapper.ensureInitialized()
        .encodeJson<CapturedDateParser>(this as CapturedDateParser);
  }

  Map<String, dynamic> toMap() {
    return CapturedDateParserMapper.ensureInitialized()
        .encodeMap<CapturedDateParser>(this as CapturedDateParser);
  }
}

class RaceWinningCountParserMapper
    extends SubClassMapperBase<RaceWinningCountParser> {
  RaceWinningCountParserMapper._();

  static RaceWinningCountParserMapper? _instance;
  static RaceWinningCountParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RaceWinningCountParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'RaceWinningCountParser';

  @override
  final MappableFields<RaceWinningCountParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RaceWinningCountParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RaceWinningCountParser _instantiate(DecodingData data) {
    return RaceWinningCountParser();
  }

  @override
  final Function instantiate = _instantiate;

  static RaceWinningCountParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RaceWinningCountParser>(map);
  }

  static RaceWinningCountParser fromJson(String json) {
    return ensureInitialized().decodeJson<RaceWinningCountParser>(json);
  }
}

mixin RaceWinningCountParserMappable {
  String toJson() {
    return RaceWinningCountParserMapper.ensureInitialized()
        .encodeJson<RaceWinningCountParser>(this as RaceWinningCountParser);
  }

  Map<String, dynamic> toMap() {
    return RaceWinningCountParserMapper.ensureInitialized()
        .encodeMap<RaceWinningCountParser>(this as RaceWinningCountParser);
  }
}

class RecordTypeParserMapper extends SubClassMapperBase<RecordTypeParser> {
  RecordTypeParserMapper._();

  static RecordTypeParserMapper? _instance;
  static RecordTypeParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RecordTypeParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'RecordTypeParser';

  @override
  final MappableFields<RecordTypeParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RecordTypeParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RecordTypeParser _instantiate(DecodingData data) {
    return RecordTypeParser();
  }

  @override
  final Function instantiate = _instantiate;

  static RecordTypeParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RecordTypeParser>(map);
  }

  static RecordTypeParser fromJson(String json) {
    return ensureInitialized().decodeJson<RecordTypeParser>(json);
  }
}

mixin RecordTypeParserMappable {
  String toJson() {
    return RecordTypeParserMapper.ensureInitialized()
        .encodeJson<RecordTypeParser>(this as RecordTypeParser);
  }

  Map<String, dynamic> toMap() {
    return RecordTypeParserMapper.ensureInitialized()
        .encodeMap<RecordTypeParser>(this as RecordTypeParser);
  }
}

class CampaignScenarioParserMapper
    extends SubClassMapperBase<CampaignScenarioParser> {
  CampaignScenarioParserMapper._();

  static CampaignScenarioParserMapper? _instance;
  static CampaignScenarioParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CampaignScenarioParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'CampaignScenarioParser';

  @override
  final MappableFields<CampaignScenarioParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'CampaignScenarioParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static CampaignScenarioParser _instantiate(DecodingData data) {
    return CampaignScenarioParser();
  }

  @override
  final Function instantiate = _instantiate;

  static CampaignScenarioParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CampaignScenarioParser>(map);
  }

  static CampaignScenarioParser fromJson(String json) {
    return ensureInitialized().decodeJson<CampaignScenarioParser>(json);
  }
}

mixin CampaignScenarioParserMappable {
  String toJson() {
    return CampaignScenarioParserMapper.ensureInitialized()
        .encodeJson<CampaignScenarioParser>(this as CampaignScenarioParser);
  }

  Map<String, dynamic> toMap() {
    return CampaignScenarioParserMapper.ensureInitialized()
        .encodeMap<CampaignScenarioParser>(this as CampaignScenarioParser);
  }
}

class TraineeIdParserMapper extends SubClassMapperBase<TraineeIdParser> {
  TraineeIdParserMapper._();

  static TraineeIdParserMapper? _instance;
  static TraineeIdParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TraineeIdParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'TraineeIdParser';

  @override
  final MappableFields<TraineeIdParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'TraineeIdParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static TraineeIdParser _instantiate(DecodingData data) {
    return TraineeIdParser();
  }

  @override
  final Function instantiate = _instantiate;

  static TraineeIdParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TraineeIdParser>(map);
  }

  static TraineeIdParser fromJson(String json) {
    return ensureInitialized().decodeJson<TraineeIdParser>(json);
  }
}

mixin TraineeIdParserMappable {
  String toJson() {
    return TraineeIdParserMapper.ensureInitialized()
        .encodeJson<TraineeIdParser>(this as TraineeIdParser);
  }

  Map<String, dynamic> toMap() {
    return TraineeIdParserMapper.ensureInitialized().encodeMap<TraineeIdParser>(
      this as TraineeIdParser,
    );
  }
}

class RaceStrategyParserMapper extends SubClassMapperBase<RaceStrategyParser> {
  RaceStrategyParserMapper._();

  static RaceStrategyParserMapper? _instance;
  static RaceStrategyParserMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RaceStrategyParserMapper._());
      ParserMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'RaceStrategyParser';

  @override
  final MappableFields<RaceStrategyParser> fields = const {};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'RaceStrategyParser';
  @override
  late final ClassMapperBase superMapper = ParserMapper.ensureInitialized();

  @override
  DecodingContext inherit(DecodingContext context) {
    return context.inherit(args: () => []);
  }

  static RaceStrategyParser _instantiate(DecodingData data) {
    return RaceStrategyParser();
  }

  @override
  final Function instantiate = _instantiate;

  static RaceStrategyParser fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RaceStrategyParser>(map);
  }

  static RaceStrategyParser fromJson(String json) {
    return ensureInitialized().decodeJson<RaceStrategyParser>(json);
  }
}

mixin RaceStrategyParserMappable {
  String toJson() {
    return RaceStrategyParserMapper.ensureInitialized()
        .encodeJson<RaceStrategyParser>(this as RaceStrategyParser);
  }

  Map<String, dynamic> toMap() {
    return RaceStrategyParserMapper.ensureInitialized()
        .encodeMap<RaceStrategyParser>(this as RaceStrategyParser);
  }
}

