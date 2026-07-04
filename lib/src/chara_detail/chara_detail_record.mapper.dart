// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'chara_detail_record.dart';

class RecordStageMapper extends EnumMapper<RecordStage> {
  RecordStageMapper._();

  static RecordStageMapper? _instance;
  static RecordStageMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RecordStageMapper._());
    }
    return _instance!;
  }

  static RecordStage fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  RecordStage decode(dynamic value) {
    switch (value) {
      case r'active':
        return RecordStage.active;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(RecordStage self) {
    switch (self) {
      case RecordStage.active:
        return r'active';
    }
  }
}

extension RecordStageMapperExtension on RecordStage {
  String toValue() {
    RecordStageMapper.ensureInitialized();
    return MapperContainer.globals.toValue<RecordStage>(this) as String;
  }
}

class RecordTypeMapper extends EnumMapper<RecordType> {
  RecordTypeMapper._();

  static RecordTypeMapper? _instance;
  static RecordTypeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RecordTypeMapper._());
    }
    return _instance!;
  }

  static RecordType fromValue(dynamic value) {
    ensureInitialized();
    return MapperContainer.globals.fromValue(value);
  }

  @override
  RecordType decode(dynamic value) {
    switch (value) {
      case r'Standard':
        return RecordType.standard;
      case r'InheritanceOnly':
        return RecordType.inheritanceOnly;
      case r'FriendStandard':
        return RecordType.friendStandard;
      case r'FriendInheritance':
        return RecordType.friendInheritance;
      default:
        throw MapperException.unknownEnumValue(value);
    }
  }

  @override
  dynamic encode(RecordType self) {
    switch (self) {
      case RecordType.standard:
        return r'Standard';
      case RecordType.inheritanceOnly:
        return r'InheritanceOnly';
      case RecordType.friendStandard:
        return r'FriendStandard';
      case RecordType.friendInheritance:
        return r'FriendInheritance';
    }
  }
}

extension RecordTypeMapperExtension on RecordType {
  String toValue() {
    RecordTypeMapper.ensureInitialized();
    return MapperContainer.globals.toValue<RecordType>(this) as String;
  }
}

class CharacterMapper extends ClassMapperBase<Character> {
  CharacterMapper._();

  static CharacterMapper? _instance;
  static CharacterMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CharacterMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Character';

  static int _$icon(Character v) => v.icon;
  static const Field<Character, int> _f$icon = Field('icon', _$icon);
  static int _$character(Character v) => v.character;
  static const Field<Character, int> _f$character = Field(
    'character',
    _$character,
  );
  static int _$card(Character v) => v.card;
  static const Field<Character, int> _f$card = Field('card', _$card);
  static int _$rank(Character v) => v.rank;
  static const Field<Character, int> _f$rank = Field('rank', _$rank);

  @override
  final MappableFields<Character> fields = const {
    #icon: _f$icon,
    #character: _f$character,
    #card: _f$card,
    #rank: _f$rank,
  };

  static Character _instantiate(DecodingData data) {
    return Character(
      data.dec(_f$icon),
      data.dec(_f$character),
      data.dec(_f$card),
      data.dec(_f$rank),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static Character fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Character>(map);
  }

  static Character fromJson(String json) {
    return ensureInitialized().decodeJson<Character>(json);
  }
}

mixin CharacterMappable {
  String toJson() {
    return CharacterMapper.ensureInitialized().encodeJson<Character>(
      this as Character,
    );
  }

  Map<String, dynamic> toMap() {
    return CharacterMapper.ensureInitialized().encodeMap<Character>(
      this as Character,
    );
  }
}

class CharacterStatusMapper extends ClassMapperBase<CharacterStatus> {
  CharacterStatusMapper._();

  static CharacterStatusMapper? _instance;
  static CharacterStatusMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CharacterStatusMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'CharacterStatus';

  static int _$speed(CharacterStatus v) => v.speed;
  static const Field<CharacterStatus, int> _f$speed = Field('speed', _$speed);
  static int _$stamina(CharacterStatus v) => v.stamina;
  static const Field<CharacterStatus, int> _f$stamina = Field(
    'stamina',
    _$stamina,
  );
  static int _$power(CharacterStatus v) => v.power;
  static const Field<CharacterStatus, int> _f$power = Field('power', _$power);
  static int _$guts(CharacterStatus v) => v.guts;
  static const Field<CharacterStatus, int> _f$guts = Field('guts', _$guts);
  static int _$intelligence(CharacterStatus v) => v.intelligence;
  static const Field<CharacterStatus, int> _f$intelligence = Field(
    'intelligence',
    _$intelligence,
  );

  @override
  final MappableFields<CharacterStatus> fields = const {
    #speed: _f$speed,
    #stamina: _f$stamina,
    #power: _f$power,
    #guts: _f$guts,
    #intelligence: _f$intelligence,
  };

  static CharacterStatus _instantiate(DecodingData data) {
    return CharacterStatus(
      data.dec(_f$speed),
      data.dec(_f$stamina),
      data.dec(_f$power),
      data.dec(_f$guts),
      data.dec(_f$intelligence),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CharacterStatus fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CharacterStatus>(map);
  }

  static CharacterStatus fromJson(String json) {
    return ensureInitialized().decodeJson<CharacterStatus>(json);
  }
}

mixin CharacterStatusMappable {
  String toJson() {
    return CharacterStatusMapper.ensureInitialized()
        .encodeJson<CharacterStatus>(this as CharacterStatus);
  }

  Map<String, dynamic> toMap() {
    return CharacterStatusMapper.ensureInitialized().encodeMap<CharacterStatus>(
      this as CharacterStatus,
    );
  }
}

class GroundAptitudeMapper extends ClassMapperBase<GroundAptitude> {
  GroundAptitudeMapper._();

  static GroundAptitudeMapper? _instance;
  static GroundAptitudeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = GroundAptitudeMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'GroundAptitude';

  static int _$turf(GroundAptitude v) => v.turf;
  static const Field<GroundAptitude, int> _f$turf = Field('turf', _$turf);
  static int _$dirt(GroundAptitude v) => v.dirt;
  static const Field<GroundAptitude, int> _f$dirt = Field('dirt', _$dirt);

  @override
  final MappableFields<GroundAptitude> fields = const {
    #turf: _f$turf,
    #dirt: _f$dirt,
  };

  static GroundAptitude _instantiate(DecodingData data) {
    return GroundAptitude(data.dec(_f$turf), data.dec(_f$dirt));
  }

  @override
  final Function instantiate = _instantiate;

  static GroundAptitude fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<GroundAptitude>(map);
  }

  static GroundAptitude fromJson(String json) {
    return ensureInitialized().decodeJson<GroundAptitude>(json);
  }
}

mixin GroundAptitudeMappable {
  String toJson() {
    return GroundAptitudeMapper.ensureInitialized().encodeJson<GroundAptitude>(
      this as GroundAptitude,
    );
  }

  Map<String, dynamic> toMap() {
    return GroundAptitudeMapper.ensureInitialized().encodeMap<GroundAptitude>(
      this as GroundAptitude,
    );
  }
}

class DistanceAptitudeMapper extends ClassMapperBase<DistanceAptitude> {
  DistanceAptitudeMapper._();

  static DistanceAptitudeMapper? _instance;
  static DistanceAptitudeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = DistanceAptitudeMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'DistanceAptitude';

  static int _$shortRange(DistanceAptitude v) => v.shortRange;
  static const Field<DistanceAptitude, int> _f$shortRange = Field(
    'shortRange',
    _$shortRange,
    key: r'short_range',
  );
  static int _$mileRange(DistanceAptitude v) => v.mileRange;
  static const Field<DistanceAptitude, int> _f$mileRange = Field(
    'mileRange',
    _$mileRange,
    key: r'mile_range',
  );
  static int _$middleRange(DistanceAptitude v) => v.middleRange;
  static const Field<DistanceAptitude, int> _f$middleRange = Field(
    'middleRange',
    _$middleRange,
    key: r'middle_range',
  );
  static int _$longRange(DistanceAptitude v) => v.longRange;
  static const Field<DistanceAptitude, int> _f$longRange = Field(
    'longRange',
    _$longRange,
    key: r'long_range',
  );

  @override
  final MappableFields<DistanceAptitude> fields = const {
    #shortRange: _f$shortRange,
    #mileRange: _f$mileRange,
    #middleRange: _f$middleRange,
    #longRange: _f$longRange,
  };

  static DistanceAptitude _instantiate(DecodingData data) {
    return DistanceAptitude(
      data.dec(_f$shortRange),
      data.dec(_f$mileRange),
      data.dec(_f$middleRange),
      data.dec(_f$longRange),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static DistanceAptitude fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<DistanceAptitude>(map);
  }

  static DistanceAptitude fromJson(String json) {
    return ensureInitialized().decodeJson<DistanceAptitude>(json);
  }
}

mixin DistanceAptitudeMappable {
  String toJson() {
    return DistanceAptitudeMapper.ensureInitialized()
        .encodeJson<DistanceAptitude>(this as DistanceAptitude);
  }

  Map<String, dynamic> toMap() {
    return DistanceAptitudeMapper.ensureInitialized()
        .encodeMap<DistanceAptitude>(this as DistanceAptitude);
  }
}

class StyleAptitudeMapper extends ClassMapperBase<StyleAptitude> {
  StyleAptitudeMapper._();

  static StyleAptitudeMapper? _instance;
  static StyleAptitudeMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = StyleAptitudeMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'StyleAptitude';

  static int _$leadPace(StyleAptitude v) => v.leadPace;
  static const Field<StyleAptitude, int> _f$leadPace = Field(
    'leadPace',
    _$leadPace,
    key: r'lead_pace',
  );
  static int _$withPace(StyleAptitude v) => v.withPace;
  static const Field<StyleAptitude, int> _f$withPace = Field(
    'withPace',
    _$withPace,
    key: r'with_pace',
  );
  static int _$offPace(StyleAptitude v) => v.offPace;
  static const Field<StyleAptitude, int> _f$offPace = Field(
    'offPace',
    _$offPace,
    key: r'off_pace',
  );
  static int _$lateCharge(StyleAptitude v) => v.lateCharge;
  static const Field<StyleAptitude, int> _f$lateCharge = Field(
    'lateCharge',
    _$lateCharge,
    key: r'late_charge',
  );

  @override
  final MappableFields<StyleAptitude> fields = const {
    #leadPace: _f$leadPace,
    #withPace: _f$withPace,
    #offPace: _f$offPace,
    #lateCharge: _f$lateCharge,
  };

  static StyleAptitude _instantiate(DecodingData data) {
    return StyleAptitude(
      data.dec(_f$leadPace),
      data.dec(_f$withPace),
      data.dec(_f$offPace),
      data.dec(_f$lateCharge),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static StyleAptitude fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<StyleAptitude>(map);
  }

  static StyleAptitude fromJson(String json) {
    return ensureInitialized().decodeJson<StyleAptitude>(json);
  }
}

mixin StyleAptitudeMappable {
  String toJson() {
    return StyleAptitudeMapper.ensureInitialized().encodeJson<StyleAptitude>(
      this as StyleAptitude,
    );
  }

  Map<String, dynamic> toMap() {
    return StyleAptitudeMapper.ensureInitialized().encodeMap<StyleAptitude>(
      this as StyleAptitude,
    );
  }
}

class AptitudeSetMapper extends ClassMapperBase<AptitudeSet> {
  AptitudeSetMapper._();

  static AptitudeSetMapper? _instance;
  static AptitudeSetMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AptitudeSetMapper._());
      GroundAptitudeMapper.ensureInitialized();
      DistanceAptitudeMapper.ensureInitialized();
      StyleAptitudeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'AptitudeSet';

  static GroundAptitude _$ground(AptitudeSet v) => v.ground;
  static const Field<AptitudeSet, GroundAptitude> _f$ground = Field(
    'ground',
    _$ground,
  );
  static DistanceAptitude _$distance(AptitudeSet v) => v.distance;
  static const Field<AptitudeSet, DistanceAptitude> _f$distance = Field(
    'distance',
    _$distance,
  );
  static StyleAptitude _$style(AptitudeSet v) => v.style;
  static const Field<AptitudeSet, StyleAptitude> _f$style = Field(
    'style',
    _$style,
  );

  @override
  final MappableFields<AptitudeSet> fields = const {
    #ground: _f$ground,
    #distance: _f$distance,
    #style: _f$style,
  };

  static AptitudeSet _instantiate(DecodingData data) {
    return AptitudeSet(
      data.dec(_f$ground),
      data.dec(_f$distance),
      data.dec(_f$style),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static AptitudeSet fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<AptitudeSet>(map);
  }

  static AptitudeSet fromJson(String json) {
    return ensureInitialized().decodeJson<AptitudeSet>(json);
  }
}

mixin AptitudeSetMappable {
  String toJson() {
    return AptitudeSetMapper.ensureInitialized().encodeJson<AptitudeSet>(
      this as AptitudeSet,
    );
  }

  Map<String, dynamic> toMap() {
    return AptitudeSetMapper.ensureInitialized().encodeMap<AptitudeSet>(
      this as AptitudeSet,
    );
  }
}

class SkillMapper extends ClassMapperBase<Skill> {
  SkillMapper._();

  static SkillMapper? _instance;
  static SkillMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SkillMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Skill';

  static int _$id(Skill v) => v.id;
  static const Field<Skill, int> _f$id = Field('id', _$id);
  static int? _$level(Skill v) => v.level;
  static const Field<Skill, int> _f$level = Field('level', _$level, opt: true);

  @override
  final MappableFields<Skill> fields = const {#id: _f$id, #level: _f$level};
  @override
  final bool ignoreNull = true;

  static Skill _instantiate(DecodingData data) {
    return Skill(id: data.dec(_f$id), level: data.dec(_f$level));
  }

  @override
  final Function instantiate = _instantiate;

  static Skill fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Skill>(map);
  }

  static Skill fromJson(String json) {
    return ensureInitialized().decodeJson<Skill>(json);
  }
}

mixin SkillMappable {
  String toJson() {
    return SkillMapper.ensureInitialized().encodeJson<Skill>(this as Skill);
  }

  Map<String, dynamic> toMap() {
    return SkillMapper.ensureInitialized().encodeMap<Skill>(this as Skill);
  }
}

class FactorMapper extends ClassMapperBase<Factor> {
  FactorMapper._();

  static FactorMapper? _instance;
  static FactorMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Factor';

  static int _$id(Factor v) => v.id;
  static const Field<Factor, int> _f$id = Field('id', _$id);
  static int _$star(Factor v) => v.star;
  static const Field<Factor, int> _f$star = Field('star', _$star);

  @override
  final MappableFields<Factor> fields = const {#id: _f$id, #star: _f$star};

  static Factor _instantiate(DecodingData data) {
    return Factor(data.dec(_f$id), data.dec(_f$star));
  }

  @override
  final Function instantiate = _instantiate;

  static Factor fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Factor>(map);
  }

  static Factor fromJson(String json) {
    return ensureInitialized().decodeJson<Factor>(json);
  }
}

mixin FactorMappable {
  String toJson() {
    return FactorMapper.ensureInitialized().encodeJson<Factor>(this as Factor);
  }

  Map<String, dynamic> toMap() {
    return FactorMapper.ensureInitialized().encodeMap<Factor>(this as Factor);
  }
}

class FactorSetMapper extends ClassMapperBase<FactorSet> {
  FactorSetMapper._();

  static FactorSetMapper? _instance;
  static FactorSetMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FactorSetMapper._());
      FactorMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'FactorSet';

  static List<Factor> _$self(FactorSet v) => v.self;
  static const Field<FactorSet, List<Factor>> _f$self = Field('self', _$self);
  static List<Factor> _$parent1(FactorSet v) => v.parent1;
  static const Field<FactorSet, List<Factor>> _f$parent1 = Field(
    'parent1',
    _$parent1,
  );
  static List<Factor> _$parent2(FactorSet v) => v.parent2;
  static const Field<FactorSet, List<Factor>> _f$parent2 = Field(
    'parent2',
    _$parent2,
  );

  @override
  final MappableFields<FactorSet> fields = const {
    #self: _f$self,
    #parent1: _f$parent1,
    #parent2: _f$parent2,
  };

  static FactorSet _instantiate(DecodingData data) {
    return FactorSet(
      data.dec(_f$self),
      data.dec(_f$parent1),
      data.dec(_f$parent2),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static FactorSet fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<FactorSet>(map);
  }

  static FactorSet fromJson(String json) {
    return ensureInitialized().decodeJson<FactorSet>(json);
  }
}

mixin FactorSetMappable {
  String toJson() {
    return FactorSetMapper.ensureInitialized().encodeJson<FactorSet>(
      this as FactorSet,
    );
  }

  Map<String, dynamic> toMap() {
    return FactorSetMapper.ensureInitialized().encodeMap<FactorSet>(
      this as FactorSet,
    );
  }
}

class SupportCardMapper extends ClassMapperBase<SupportCard> {
  SupportCardMapper._();

  static SupportCardMapper? _instance;
  static SupportCardMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = SupportCardMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'SupportCard';

  static int _$id(SupportCard v) => v.id;
  static const Field<SupportCard, int> _f$id = Field('id', _$id);
  static int _$rank(SupportCard v) => v.rank;
  static const Field<SupportCard, int> _f$rank = Field('rank', _$rank);
  static int _$level(SupportCard v) => v.level;
  static const Field<SupportCard, int> _f$level = Field('level', _$level);

  @override
  final MappableFields<SupportCard> fields = const {
    #id: _f$id,
    #rank: _f$rank,
    #level: _f$level,
  };

  static SupportCard _instantiate(DecodingData data) {
    return SupportCard(data.dec(_f$id), data.dec(_f$rank), data.dec(_f$level));
  }

  @override
  final Function instantiate = _instantiate;

  static SupportCard fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<SupportCard>(map);
  }

  static SupportCard fromJson(String json) {
    return ensureInitialized().decodeJson<SupportCard>(json);
  }
}

mixin SupportCardMappable {
  String toJson() {
    return SupportCardMapper.ensureInitialized().encodeJson<SupportCard>(
      this as SupportCard,
    );
  }

  Map<String, dynamic> toMap() {
    return SupportCardMapper.ensureInitialized().encodeMap<SupportCard>(
      this as SupportCard,
    );
  }
}

class ParentMapper extends ClassMapperBase<Parent> {
  ParentMapper._();

  static ParentMapper? _instance;
  static ParentMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ParentMapper._());
      CharacterMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'Parent';

  static Character _$self(Parent v) => v.self;
  static const Field<Parent, Character> _f$self = Field('self', _$self);
  static Character _$parent1(Parent v) => v.parent1;
  static const Field<Parent, Character> _f$parent1 = Field(
    'parent1',
    _$parent1,
  );
  static Character _$parent2(Parent v) => v.parent2;
  static const Field<Parent, Character> _f$parent2 = Field(
    'parent2',
    _$parent2,
  );
  static bool? _$rental(Parent v) => v.rental;
  static const Field<Parent, bool> _f$rental = Field('rental', _$rental);

  @override
  final MappableFields<Parent> fields = const {
    #self: _f$self,
    #parent1: _f$parent1,
    #parent2: _f$parent2,
    #rental: _f$rental,
  };
  @override
  final bool ignoreNull = true;

  static Parent _instantiate(DecodingData data) {
    return Parent(
      data.dec(_f$self),
      data.dec(_f$parent1),
      data.dec(_f$parent2),
      data.dec(_f$rental),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static Parent fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Parent>(map);
  }

  static Parent fromJson(String json) {
    return ensureInitialized().decodeJson<Parent>(json);
  }
}

mixin ParentMappable {
  String toJson() {
    return ParentMapper.ensureInitialized().encodeJson<Parent>(this as Parent);
  }

  Map<String, dynamic> toMap() {
    return ParentMapper.ensureInitialized().encodeMap<Parent>(this as Parent);
  }
}

class FamilyMapper extends ClassMapperBase<Family> {
  FamilyMapper._();

  static FamilyMapper? _instance;
  static FamilyMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = FamilyMapper._());
      ParentMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'Family';

  static Parent _$parent1(Family v) => v.parent1;
  static const Field<Family, Parent> _f$parent1 = Field('parent1', _$parent1);
  static Parent _$parent2(Family v) => v.parent2;
  static const Field<Family, Parent> _f$parent2 = Field('parent2', _$parent2);

  @override
  final MappableFields<Family> fields = const {
    #parent1: _f$parent1,
    #parent2: _f$parent2,
  };

  static Family _instantiate(DecodingData data) {
    return Family(data.dec(_f$parent1), data.dec(_f$parent2));
  }

  @override
  final Function instantiate = _instantiate;

  static Family fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Family>(map);
  }

  static Family fromJson(String json) {
    return ensureInitialized().decodeJson<Family>(json);
  }
}

mixin FamilyMappable {
  String toJson() {
    return FamilyMapper.ensureInitialized().encodeJson<Family>(this as Family);
  }

  Map<String, dynamic> toMap() {
    return FamilyMapper.ensureInitialized().encodeMap<Family>(this as Family);
  }
}

class ScenarioMapper extends ClassMapperBase<Scenario> {
  ScenarioMapper._();

  static ScenarioMapper? _instance;
  static ScenarioMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ScenarioMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Scenario';

  static int _$id(Scenario v) => v.id;
  static const Field<Scenario, int> _f$id = Field('id', _$id);

  @override
  final MappableFields<Scenario> fields = const {#id: _f$id};

  static Scenario _instantiate(DecodingData data) {
    return Scenario(data.dec(_f$id));
  }

  @override
  final Function instantiate = _instantiate;

  static Scenario fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Scenario>(map);
  }

  static Scenario fromJson(String json) {
    return ensureInitialized().decodeJson<Scenario>(json);
  }
}

mixin ScenarioMappable {
  String toJson() {
    return ScenarioMapper.ensureInitialized().encodeJson<Scenario>(
      this as Scenario,
    );
  }

  Map<String, dynamic> toMap() {
    return ScenarioMapper.ensureInitialized().encodeMap<Scenario>(
      this as Scenario,
    );
  }
}

class RaceMapper extends ClassMapperBase<Race> {
  RaceMapper._();

  static RaceMapper? _instance;
  static RaceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RaceMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'Race';

  static int _$title(Race v) => v.title;
  static const Field<Race, int> _f$title = Field('title', _$title);
  static int _$place(Race v) => v.place;
  static const Field<Race, int> _f$place = Field('place', _$place);
  static int _$ground(Race v) => v.ground;
  static const Field<Race, int> _f$ground = Field('ground', _$ground);
  static int _$distance(Race v) => v.distance;
  static const Field<Race, int> _f$distance = Field('distance', _$distance);
  static int _$variation(Race v) => v.variation;
  static const Field<Race, int> _f$variation = Field('variation', _$variation);
  static int _$weather(Race v) => v.weather;
  static const Field<Race, int> _f$weather = Field('weather', _$weather);
  static int _$strategy(Race v) => v.strategy;
  static const Field<Race, int> _f$strategy = Field('strategy', _$strategy);
  static int _$turn(Race v) => v.turn;
  static const Field<Race, int> _f$turn = Field('turn', _$turn);
  static int _$position(Race v) => v.position;
  static const Field<Race, int> _f$position = Field('position', _$position);

  @override
  final MappableFields<Race> fields = const {
    #title: _f$title,
    #place: _f$place,
    #ground: _f$ground,
    #distance: _f$distance,
    #variation: _f$variation,
    #weather: _f$weather,
    #strategy: _f$strategy,
    #turn: _f$turn,
    #position: _f$position,
  };

  static Race _instantiate(DecodingData data) {
    return Race(
      data.dec(_f$title),
      data.dec(_f$place),
      data.dec(_f$ground),
      data.dec(_f$distance),
      data.dec(_f$variation),
      data.dec(_f$weather),
      data.dec(_f$strategy),
      data.dec(_f$turn),
      data.dec(_f$position),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static Race fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Race>(map);
  }

  static Race fromJson(String json) {
    return ensureInitialized().decodeJson<Race>(json);
  }
}

mixin RaceMappable {
  String toJson() {
    return RaceMapper.ensureInitialized().encodeJson<Race>(this as Race);
  }

  Map<String, dynamic> toMap() {
    return RaceMapper.ensureInitialized().encodeMap<Race>(this as Race);
  }
}

class RecordIdMapper extends ClassMapperBase<RecordId> {
  RecordIdMapper._();

  static RecordIdMapper? _instance;
  static RecordIdMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = RecordIdMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'RecordId';

  static String _$self(RecordId v) => v.self;
  static const Field<RecordId, String> _f$self = Field('self', _$self);
  static String? _$parent1(RecordId v) => v.parent1;
  static const Field<RecordId, String> _f$parent1 = Field('parent1', _$parent1);
  static String? _$parent2(RecordId v) => v.parent2;
  static const Field<RecordId, String> _f$parent2 = Field('parent2', _$parent2);

  @override
  final MappableFields<RecordId> fields = const {
    #self: _f$self,
    #parent1: _f$parent1,
    #parent2: _f$parent2,
  };
  @override
  final bool ignoreNull = true;

  static RecordId _instantiate(DecodingData data) {
    return RecordId(
      data.dec(_f$self),
      data.dec(_f$parent1),
      data.dec(_f$parent2),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static RecordId fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<RecordId>(map);
  }

  static RecordId fromJson(String json) {
    return ensureInitialized().decodeJson<RecordId>(json);
  }
}

mixin RecordIdMappable {
  String toJson() {
    return RecordIdMapper.ensureInitialized().encodeJson<RecordId>(
      this as RecordId,
    );
  }

  Map<String, dynamic> toMap() {
    return RecordIdMapper.ensureInitialized().encodeMap<RecordId>(
      this as RecordId,
    );
  }
}

class MetadataMapper extends ClassMapperBase<Metadata> {
  MetadataMapper._();

  static MetadataMapper? _instance;
  static MetadataMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = MetadataMapper._());
      RecordIdMapper.ensureInitialized();
      RecordStageMapper.ensureInitialized();
      RecordTypeMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'Metadata';

  static String _$formatVersion(Metadata v) => v.formatVersion;
  static const Field<Metadata, String> _f$formatVersion = Field(
    'formatVersion',
    _$formatVersion,
    key: r'format_version',
  );
  static String _$region(Metadata v) => v.region;
  static const Field<Metadata, String> _f$region = Field('region', _$region);
  static RecordId _$recordId(Metadata v) => v.recordId;
  static const Field<Metadata, RecordId> _f$recordId = Field(
    'recordId',
    _$recordId,
    key: r'record_id',
  );
  static String _$trainerId(Metadata v) => v.trainerId;
  static const Field<Metadata, String> _f$trainerId = Field(
    'trainerId',
    _$trainerId,
    key: r'trainer_id',
  );
  static String _$capturedDate(Metadata v) => v.capturedDate;
  static const Field<Metadata, String> _f$capturedDate = Field(
    'capturedDate',
    _$capturedDate,
    key: r'captured_date',
  );
  static String _$recognizerVersion(Metadata v) => v.recognizerVersion;
  static const Field<Metadata, String> _f$recognizerVersion = Field(
    'recognizerVersion',
    _$recognizerVersion,
    key: r'recognizer_version',
  );
  static RecordStage _$stage(Metadata v) => v.stage;
  static const Field<Metadata, RecordStage> _f$stage = Field('stage', _$stage);
  static int _$strategy(Metadata v) => v.strategy;
  static const Field<Metadata, int> _f$strategy = Field('strategy', _$strategy);
  static int? _$relationBonus(Metadata v) => v.relationBonus;
  static const Field<Metadata, int> _f$relationBonus = Field(
    'relationBonus',
    _$relationBonus,
    key: r'relation_bonus',
  );
  static RecordType? _$recordType(Metadata v) => v.recordType;
  static const Field<Metadata, RecordType> _f$recordType = Field(
    'recordType',
    _$recordType,
    key: r'record_type',
  );

  @override
  final MappableFields<Metadata> fields = const {
    #formatVersion: _f$formatVersion,
    #region: _f$region,
    #recordId: _f$recordId,
    #trainerId: _f$trainerId,
    #capturedDate: _f$capturedDate,
    #recognizerVersion: _f$recognizerVersion,
    #stage: _f$stage,
    #strategy: _f$strategy,
    #relationBonus: _f$relationBonus,
    #recordType: _f$recordType,
  };
  @override
  final bool ignoreNull = true;

  static Metadata _instantiate(DecodingData data) {
    return Metadata(
      data.dec(_f$formatVersion),
      data.dec(_f$region),
      data.dec(_f$recordId),
      data.dec(_f$trainerId),
      data.dec(_f$capturedDate),
      data.dec(_f$recognizerVersion),
      data.dec(_f$stage),
      data.dec(_f$strategy),
      data.dec(_f$relationBonus),
      data.dec(_f$recordType),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static Metadata fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<Metadata>(map);
  }

  static Metadata fromJson(String json) {
    return ensureInitialized().decodeJson<Metadata>(json);
  }
}

mixin MetadataMappable {
  String toJson() {
    return MetadataMapper.ensureInitialized().encodeJson<Metadata>(
      this as Metadata,
    );
  }

  Map<String, dynamic> toMap() {
    return MetadataMapper.ensureInitialized().encodeMap<Metadata>(
      this as Metadata,
    );
  }
}

class CharaDetailRecordMapper extends ClassMapperBase<CharaDetailRecord> {
  CharaDetailRecordMapper._();

  static CharaDetailRecordMapper? _instance;
  static CharaDetailRecordMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = CharaDetailRecordMapper._());
      MetadataMapper.ensureInitialized();
      CharacterMapper.ensureInitialized();
      CharacterStatusMapper.ensureInitialized();
      AptitudeSetMapper.ensureInitialized();
      SkillMapper.ensureInitialized();
      FactorSetMapper.ensureInitialized();
      SupportCardMapper.ensureInitialized();
      FamilyMapper.ensureInitialized();
      ScenarioMapper.ensureInitialized();
      RaceMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'CharaDetailRecord';

  static Metadata _$metadata(CharaDetailRecord v) => v.metadata;
  static const Field<CharaDetailRecord, Metadata> _f$metadata = Field(
    'metadata',
    _$metadata,
  );
  static Character _$trainee(CharaDetailRecord v) => v.trainee;
  static const Field<CharaDetailRecord, Character> _f$trainee = Field(
    'trainee',
    _$trainee,
  );
  static int _$evaluationValue(CharaDetailRecord v) => v.evaluationValue;
  static const Field<CharaDetailRecord, int> _f$evaluationValue = Field(
    'evaluationValue',
    _$evaluationValue,
    key: r'evaluation_value',
  );
  static CharacterStatus _$status(CharaDetailRecord v) => v.status;
  static const Field<CharaDetailRecord, CharacterStatus> _f$status = Field(
    'status',
    _$status,
  );
  static AptitudeSet _$aptitudes(CharaDetailRecord v) => v.aptitudes;
  static const Field<CharaDetailRecord, AptitudeSet> _f$aptitudes = Field(
    'aptitudes',
    _$aptitudes,
  );
  static List<Skill> _$skills(CharaDetailRecord v) => v.skills;
  static const Field<CharaDetailRecord, List<Skill>> _f$skills = Field(
    'skills',
    _$skills,
  );
  static FactorSet _$factors(CharaDetailRecord v) => v.factors;
  static const Field<CharaDetailRecord, FactorSet> _f$factors = Field(
    'factors',
    _$factors,
  );
  static List<SupportCard> _$supportCards(CharaDetailRecord v) =>
      v.supportCards;
  static const Field<CharaDetailRecord, List<SupportCard>> _f$supportCards =
      Field('supportCards', _$supportCards, key: r'support_cards');
  static Family _$family(CharaDetailRecord v) => v.family;
  static const Field<CharaDetailRecord, Family> _f$family = Field(
    'family',
    _$family,
  );
  static int _$fans(CharaDetailRecord v) => v.fans;
  static const Field<CharaDetailRecord, int> _f$fans = Field('fans', _$fans);
  static Scenario _$scenario(CharaDetailRecord v) => v.scenario;
  static const Field<CharaDetailRecord, Scenario> _f$scenario = Field(
    'scenario',
    _$scenario,
  );
  static String _$trainedDate(CharaDetailRecord v) => v.trainedDate;
  static const Field<CharaDetailRecord, String> _f$trainedDate = Field(
    'trainedDate',
    _$trainedDate,
    key: r'trained_date',
  );
  static List<Race> _$races(CharaDetailRecord v) => v.races;
  static const Field<CharaDetailRecord, List<Race>> _f$races = Field(
    'races',
    _$races,
  );

  @override
  final MappableFields<CharaDetailRecord> fields = const {
    #metadata: _f$metadata,
    #trainee: _f$trainee,
    #evaluationValue: _f$evaluationValue,
    #status: _f$status,
    #aptitudes: _f$aptitudes,
    #skills: _f$skills,
    #factors: _f$factors,
    #supportCards: _f$supportCards,
    #family: _f$family,
    #fans: _f$fans,
    #scenario: _f$scenario,
    #trainedDate: _f$trainedDate,
    #races: _f$races,
  };
  @override
  final bool ignoreNull = true;

  static CharaDetailRecord _instantiate(DecodingData data) {
    return CharaDetailRecord(
      data.dec(_f$metadata),
      data.dec(_f$trainee),
      data.dec(_f$evaluationValue),
      data.dec(_f$status),
      data.dec(_f$aptitudes),
      data.dec(_f$skills),
      data.dec(_f$factors),
      data.dec(_f$supportCards),
      data.dec(_f$family),
      data.dec(_f$fans),
      data.dec(_f$scenario),
      data.dec(_f$trainedDate),
      data.dec(_f$races),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static CharaDetailRecord fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<CharaDetailRecord>(map);
  }

  static CharaDetailRecord fromJson(String json) {
    return ensureInitialized().decodeJson<CharaDetailRecord>(json);
  }
}

mixin CharaDetailRecordMappable {
  String toJson() {
    return CharaDetailRecordMapper.ensureInitialized()
        .encodeJson<CharaDetailRecord>(this as CharaDetailRecord);
  }

  Map<String, dynamic> toMap() {
    return CharaDetailRecordMapper.ensureInitialized()
        .encodeMap<CharaDetailRecord>(this as CharaDetailRecord);
  }
}

