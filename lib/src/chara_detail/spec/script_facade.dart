// Wrapper-interop facade for the user-defined script column.
//
// Each model facet is exposed to the dart_eval sandbox as a hand-written
// wrapper class (`$`-class implementing [$Instance]). Their methods run as real
// Dart, so they can receive and invoke user closures (`where`, `map`, ...), use
// `List` natively, and expose statically-typed getters. The user script imports
// the synthetic library `package:script/facade.dart`, which has NO source: the
// [FacadePlugin] defines every bridge class under that uri at compile time and
// registers the `Cell` constructor and color-map functions at runtime.
//
// The backing data is a single plain `Map` per record (built by the enrichment
// step in `script.dart`). Wrappers read this map lazily. Because the map holds
// only plain values/lists, it can be transferred to a preview isolate verbatim.
//
// Three rules must hold or the static typing collapses to dynamic dispatch (see
// memory `dart-eval-0.8.5-constraints`):
//   1. getters are declared in `getters:` (not `methods:`),
//   2. `$getRuntimeType` returns `rt.lookupType(type.spec!)`,
//   3. closure parameters are declared with a typed `genericFunction`.

// The collection wrappers expose `rewrap`/`wrapElement` returning the private
// base type as internal plumbing; that is intentional, not public surface.
// ignore_for_file: library_private_types_in_public_api

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

/// The synthetic library the user script imports. It has no on-disk source;
/// [FacadePlugin] populates it.
const facadeUri = 'package:script/facade.dart';

/// Per-category name→code tables (`category → {name: code}`), injected just
/// before a script runs and read by [$Coded.codeOf] / `atLeast` / `atMost`.
///
/// A `$Coded` map carries only its own `{code, name}`, so it cannot resolve an
/// arbitrary target name to a code on its own. The full tables are global to a
/// grid build (derived from the same labels as the enrichment step), so rather
/// than embed a heavy table into every record (and copy it across the preview
/// isolate per row), the coded map carries a light `category` tag and the table
/// lives here. Set from `ScriptColumnSpec.parse` (main isolate) and
/// `_previewEntry` (preview isolate) before execution; both are synchronous, so
/// a single library-level holder is safe. It is plain JSON data, so it crosses
/// the isolate boundary verbatim.
Map<String, Map<String, int>> scriptCodeTables = const {};

/// A script-facing error whose [toString] is the bare message, so the ⚠ cell
/// tooltip and the preview check show it without an `Exception:` prefix.
class ScriptLookupError implements Exception {
  ScriptLookupError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Resolves [name] to its code within the [self] coded map's category, throwing
/// a [ScriptLookupError] when the field has no category, no table is loaded, or
/// the name is unknown (a typo surfaces loudly instead of silently mismatching).
int _codeOfName(Map self, String name) {
  final category = self['category'];
  if (category is! String) {
    throw ScriptLookupError('this field has no comparable order (codeOf/atLeast/atMost unavailable)');
  }
  final table = scriptCodeTables[category];
  if (table == null) {
    throw ScriptLookupError('no lookup table for $category');
  }
  final code = table[name];
  if (code == null) {
    throw ScriptLookupError('unknown $category name: $name');
  }
  return code;
}

// --- Facade type references --------------------------------------------------

// The root type is named `CharaRecord`, NOT `Record`: a bridge type named
// `Record` collides with dart:core's `Record` in the dart_eval compiler, which
// silently degrades method calls (`where`, `map`, ...) to dynamic dispatch and
// crashes at runtime. Getters happen to survive, which is why the original PoC
// (getter-only) missed it.
const recordType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'CharaRecord'));
const statusType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Status'));
const aptitudesType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Aptitudes'));
const groundAptitudeType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'GroundAptitude'));
const distanceAptitudeType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'DistanceAptitude'));
const styleAptitudeType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'StyleAptitude'));
const codedType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Coded'));
const skillListType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'SkillList'));
const skillType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Skill'));
const factorListType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'FactorList'));
const factorType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Factor'));
const factorGroupListType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'FactorGroupList'));
const factorGroupType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'FactorGroup'));
const raceListType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'RaceList'));
const raceType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Race'));
const supportCardListType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'SupportCardList'));
const supportCardType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'SupportCard'));
const scenarioType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Scenario'));
const familyType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Family'));
const parentType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Parent'));
const ratingsType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Ratings'));
const memosType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Memos'));
const metadataType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Metadata'));
const valueListType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'ValueList'));
const cellType = BridgeTypeRef(BridgeTypeSpec(facadeUri, 'Cell'));

// --- Core type references ----------------------------------------------------

const _intT = BridgeTypeRef(CoreTypes.int);
const _boolT = BridgeTypeRef(CoreTypes.bool);
const _numT = BridgeTypeRef(CoreTypes.num);
const _doubleT = BridgeTypeRef(CoreTypes.double);
const _stringT = BridgeTypeRef(CoreTypes.string);
const _dynT = BridgeTypeRef(CoreTypes.dynamic);

// --- Declaration helpers -----------------------------------------------------

BridgeMethodDef _getter(BridgeTypeRef ret, {bool nullable = false}) =>
    BridgeMethodDef(BridgeFunctionDef(returns: BridgeTypeAnnotation(ret, nullable: nullable)));

/// `Ret name(String key)` with a possibly-nullable return (e.g. `ratings.get`).
BridgeMethodDef _keyMethod(BridgeTypeRef ret, {bool nullable = false}) => BridgeMethodDef(
  BridgeFunctionDef(
    returns: BridgeTypeAnnotation(ret, nullable: nullable),
    params: [BridgeParameter('key', const BridgeTypeAnnotation(_stringT), false)],
  ),
);

/// `bool hasTag(String name)`.
BridgeMethodDef _stringArgMethod(BridgeTypeRef ret) => BridgeMethodDef(
  BridgeFunctionDef(
    returns: BridgeTypeAnnotation(ret),
    params: [BridgeParameter('name', const BridgeTypeAnnotation(_stringT), false)],
  ),
);

/// `String join([String sep])` — the separator is an optional positional.
BridgeMethodDef _joinMethod() => BridgeMethodDef(
  BridgeFunctionDef(
    returns: const BridgeTypeAnnotation(_stringT),
    params: [BridgeParameter('sep', const BridgeTypeAnnotation(_stringT, nullable: true), true)],
  ),
);

/// A method taking `closureRet Function(elem)`. The closure parameter is typed
/// so the user's closure parameter resolves statically (rule 3).
BridgeMethodDef _closureMethod(BridgeTypeRef ret, BridgeTypeRef elem, BridgeTypeRef closureRet) => BridgeMethodDef(
  BridgeFunctionDef(
    returns: BridgeTypeAnnotation(ret),
    params: [
      BridgeParameter(
        'f',
        BridgeTypeAnnotation(
          BridgeTypeRef.genericFunction(
            BridgeFunctionDef(
              returns: BridgeTypeAnnotation(closureRet),
              params: [BridgeParameter('e', BridgeTypeAnnotation(elem), false)],
            ),
          ),
        ),
        false,
      ),
    ],
  ),
);

/// The shared declaration for every collection wrapper (`SkillList`, ...).
BridgeClassDef _collectionDecl(BridgeTypeRef self, BridgeTypeRef elem) => BridgeClassDef(
  BridgeClassType(self),
  constructors: const {},
  getters: {
    'length': _getter(_intT),
    'isEmpty': _getter(_boolT),
    'isNotEmpty': _getter(_boolT),
    'first': _getter(elem),
    'firstOrNull': _getter(elem, nullable: true),
  },
  methods: {
    'where': _closureMethod(self, elem, _boolT),
    'whereNot': _closureMethod(self, elem, _boolT),
    'any': _closureMethod(_boolT, elem, _boolT),
    'every': _closureMethod(_boolT, elem, _boolT),
    'map': _closureMethod(valueListType, elem, _dynT),
  },
  wrap: true,
);

// --- Base instances ----------------------------------------------------------

/// Common plumbing for a wrapper backed by a [Map].
abstract class _MapInstance implements $Instance {
  _MapInstance(this.$value);

  @override
  final Map $value;

  late final $Instance _superclass = $Object($value);

  BridgeTypeRef get $typeRef;

  $Value? _fallback(Runtime rt, String id) => _superclass.$getProperty(rt, id);

  @override
  void $setProperty(Runtime rt, String id, $Value value) => _superclass.$setProperty(rt, id, value);

  @override
  int $getRuntimeType(Runtime rt) => rt.lookupType($typeRef.spec!);

  @override
  dynamic get $reified => $value;
}

/// Common plumbing for a collection wrapper backed by a `List` of element maps.
abstract class _CollectionInstance implements $Instance {
  _CollectionInstance(this.$value);

  @override
  final List $value;

  late final $Instance _superclass = $Object($value);

  BridgeTypeRef get $typeRef;

  /// Wraps a raw element (a `Map`) into its element facade.
  $Instance wrapElement(Object? element);

  /// Builds the same collection type from a filtered backing list.
  _CollectionInstance rewrap(List list);

  bool _test(Runtime rt, EvalCallable test, Object? element) {
    final result = test.call(rt, null, [wrapElement(element)]);
    return result != null && result.$value == true;
  }

  @override
  $Value? $getProperty(Runtime rt, String id) {
    final list = $value;
    switch (id) {
      case 'length':
        return $int(list.length);
      case 'isEmpty':
        return $bool(list.isEmpty);
      case 'isNotEmpty':
        return $bool(list.isNotEmpty);
      case 'first':
        return wrapElement(list.first);
      case 'firstOrNull':
        return list.isEmpty ? $null() : wrapElement(list.first);
      case 'where':
        return $Function(
          (rt, t, a) => rewrap([
            for (final e in list)
              if (_test(rt, a[0] as EvalCallable, e)) e,
          ]),
        );
      case 'whereNot':
        return $Function(
          (rt, t, a) => rewrap([
            for (final e in list)
              if (!_test(rt, a[0] as EvalCallable, e)) e,
          ]),
        );
      case 'any':
        return $Function((rt, t, a) => $bool(list.any((e) => _test(rt, a[0] as EvalCallable, e))));
      case 'every':
        return $Function((rt, t, a) => $bool(list.every((e) => _test(rt, a[0] as EvalCallable, e))));
      case 'map':
        return $Function((rt, t, a) {
          final fn = a[0] as EvalCallable;
          return $ValueList.wrap([
            for (final e in list) fn.call(rt, null, [wrapElement(e)])?.$value,
          ]);
        });
    }
    return _superclass.$getProperty(rt, id);
  }

  @override
  void $setProperty(Runtime rt, String id, $Value value) => _superclass.$setProperty(rt, id, value);

  @override
  int $getRuntimeType(Runtime rt) => rt.lookupType($typeRef.spec!);

  @override
  dynamic get $reified => $value;
}

// --- Value readers -----------------------------------------------------------

$Value _wrapTag(Runtime rt, $Value? target, List<$Value?> args) {
  final tags = (target!.$value as Map)['tags'] as List;
  return $bool(tags.contains(args[0]?.$value));
}

// --- Record ------------------------------------------------------------------

class $Record extends _MapInstance {
  $Record.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(recordType),
    constructors: const {},
    getters: {
      'status': _getter(statusType),
      'aptitudes': _getter(aptitudesType),
      'skills': _getter(skillListType),
      'factors': _getter(factorListType),
      'factorGroups': _getter(factorGroupListType),
      'races': _getter(raceListType),
      'supportCards': _getter(supportCardListType),
      'scenario': _getter(scenarioType),
      'ratings': _getter(ratingsType),
      'memos': _getter(memosType),
      'metadata': _getter(metadataType),
      'trainee': _getter(codedType),
      'charaRank': _getter(codedType),
      'family': _getter(familyType),
      'evaluationValue': _getter(_intT),
      'fans': _getter(_intT),
      'trainedDate': _getter(_stringT),
      'capturedDate': _getter(_stringT),
      'id': _getter(_stringT),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => recordType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'status':
        return $Status.wrap($value['status'] as Map);
      case 'aptitudes':
        return $Aptitudes.wrap($value['aptitudes'] as Map);
      case 'skills':
        return $SkillList.wrap($value['skills'] as List);
      case 'factors':
        return $FactorList.wrap($value['factors'] as List);
      case 'factorGroups':
        return $FactorGroupList.wrap($value['factorGroups'] as List);
      case 'races':
        return $RaceList.wrap($value['races'] as List);
      case 'supportCards':
        return $SupportCardList.wrap($value['supportCards'] as List);
      case 'scenario':
        return $Scenario.wrap($value['scenario'] as Map);
      case 'ratings':
        return $Ratings.wrap($value['ratings'] as Map);
      case 'memos':
        return $Memos.wrap($value['memos'] as Map);
      case 'metadata':
        return $Metadata.wrap($value['metadata'] as Map);
      case 'trainee':
        return $Coded.wrap($value['trainee'] as Map);
      case 'charaRank':
        return $Coded.wrap($value['charaRank'] as Map);
      case 'family':
        return $Family.wrap($value['family'] as Map);
      case 'evaluationValue':
        return $int($value['evaluationValue'] as int);
      case 'fans':
        return $int($value['fans'] as int);
      case 'trainedDate':
        return $String($value['trainedDate'] as String);
      case 'capturedDate':
        return $String($value['capturedDate'] as String);
      case 'id':
        return $String($value['id'] as String);
    }
    return _fallback(rt, id);
  }
}

// --- Status ------------------------------------------------------------------

class $Status extends _MapInstance {
  $Status.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(statusType),
    constructors: const {},
    getters: {
      'speed': _getter(_intT),
      'stamina': _getter(_intT),
      'power': _getter(_intT),
      'guts': _getter(_intT),
      'intelligence': _getter(_intT),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => statusType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    final v = $value[id];
    if (v is int) return $int(v);
    return _fallback(rt, id);
  }
}

// --- Aptitudes ---------------------------------------------------------------

class $Aptitudes extends _MapInstance {
  $Aptitudes.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(aptitudesType),
    constructors: const {},
    getters: {
      'ground': _getter(groundAptitudeType),
      'distance': _getter(distanceAptitudeType),
      'style': _getter(styleAptitudeType),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => aptitudesType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'ground':
        return $GroundAptitude.wrap($value['ground'] as Map);
      case 'distance':
        return $DistanceAptitude.wrap($value['distance'] as Map);
      case 'style':
        return $StyleAptitude.wrap($value['style'] as Map);
    }
    return _fallback(rt, id);
  }
}

/// A wrapper whose every getter resolves to a [$Coded] leaf read from the map.
abstract class _CodedFields extends _MapInstance {
  _CodedFields(super.$value);

  @override
  $Value? $getProperty(Runtime rt, String id) {
    final v = $value[id];
    if (v is Map) return $Coded.wrap(v);
    return _fallback(rt, id);
  }
}

class $GroundAptitude extends _CodedFields {
  $GroundAptitude.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(groundAptitudeType),
    constructors: const {},
    getters: {'turf': _getter(codedType), 'dirt': _getter(codedType)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => groundAptitudeType;
}

class $DistanceAptitude extends _CodedFields {
  $DistanceAptitude.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(distanceAptitudeType),
    constructors: const {},
    getters: {
      'short': _getter(codedType),
      'mile': _getter(codedType),
      'middle': _getter(codedType),
      'long': _getter(codedType),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => distanceAptitudeType;
}

class $StyleAptitude extends _CodedFields {
  $StyleAptitude.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(styleAptitudeType),
    constructors: const {},
    getters: {
      'leadPace': _getter(codedType),
      'withPace': _getter(codedType),
      'offPace': _getter(codedType),
      'lateCharge': _getter(codedType),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => styleAptitudeType;
}

// --- Coded -------------------------------------------------------------------

class $Coded extends _MapInstance {
  $Coded.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(codedType),
    constructors: const {},
    getters: {'name': _getter(_stringT), 'code': _getter(_intT)},
    methods: {
      'codeOf': _stringArgMethod(_intT),
      'atLeast': _stringArgMethod(_boolT),
      'atMost': _stringArgMethod(_boolT),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => codedType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'name':
        return $String($value['name'] as String);
      case 'code':
        return $int($value['code'] as int);
      case 'codeOf':
        return $Function((rt, t, a) => $int(_codeOfName(t!.$value as Map, a[0]!.$value as String)));
      case 'atLeast':
        return $Function((rt, t, a) {
          final self = t!.$value as Map;
          return $bool((self['code'] as int) >= _codeOfName(self, a[0]!.$value as String));
        });
      case 'atMost':
        return $Function((rt, t, a) {
          final self = t!.$value as Map;
          return $bool((self['code'] as int) <= _codeOfName(self, a[0]!.$value as String));
        });
    }
    return _fallback(rt, id);
  }
}

// --- Skills ------------------------------------------------------------------

class $SkillList extends _CollectionInstance {
  $SkillList.wrap(super.$value);

  static final declaration = _collectionDecl(skillListType, skillType);

  @override
  BridgeTypeRef get $typeRef => skillListType;

  @override
  $Instance wrapElement(Object? element) => $Skill.wrap(element as Map);

  @override
  _CollectionInstance rewrap(List list) => $SkillList.wrap(list);
}

class $Skill extends _MapInstance {
  $Skill.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(skillType),
    constructors: const {},
    getters: {'id': _getter(_intT), 'name': _getter(_stringT), 'level': _getter(_intT, nullable: true)},
    methods: {'hasTag': _stringArgMethod(_boolT)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => skillType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'id':
        return $int($value['id'] as int);
      case 'name':
        return $String($value['name'] as String);
      case 'level':
        final level = $value['level'];
        return level == null ? $null() : $int(level as int);
      case 'hasTag':
        return $Function(_wrapTag);
    }
    return _fallback(rt, id);
  }
}

// --- Factors -----------------------------------------------------------------

class $FactorList extends _CollectionInstance {
  $FactorList.wrap(super.$value);

  static final declaration = _collectionDecl(factorListType, factorType);

  @override
  BridgeTypeRef get $typeRef => factorListType;

  @override
  $Instance wrapElement(Object? element) => $Factor.wrap(element as Map);

  @override
  _CollectionInstance rewrap(List list) => $FactorList.wrap(list);
}

class $Factor extends _MapInstance {
  $Factor.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(factorType),
    constructors: const {},
    getters: {'id': _getter(_intT), 'name': _getter(_stringT), 'star': _getter(_intT), 'subject': _getter(codedType)},
    methods: {'hasTag': _stringArgMethod(_boolT)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => factorType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'id':
        return $int($value['id'] as int);
      case 'name':
        return $String($value['name'] as String);
      case 'star':
        return $int($value['star'] as int);
      case 'subject':
        return $Coded.wrap($value['subject'] as Map);
      case 'hasTag':
        return $Function(_wrapTag);
    }
    return _fallback(rt, id);
  }
}

// --- Factor groups -----------------------------------------------------------

class $FactorGroupList extends _CollectionInstance {
  $FactorGroupList.wrap(super.$value);

  static final declaration = _collectionDecl(factorGroupListType, factorGroupType);

  @override
  BridgeTypeRef get $typeRef => factorGroupListType;

  @override
  $Instance wrapElement(Object? element) => $FactorGroup.wrap(element as Map);

  @override
  _CollectionInstance rewrap(List list) => $FactorGroupList.wrap(list);
}

class $FactorGroup extends _MapInstance {
  $FactorGroup.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(factorGroupType),
    constructors: const {},
    getters: {
      'id': _getter(_intT),
      'name': _getter(_stringT),
      'totalStar': _getter(_intT),
      'selfStar': _getter(_intT),
      'parent1Star': _getter(_intT),
      'parent2Star': _getter(_intT),
    },
    methods: {'hasTag': _stringArgMethod(_boolT)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => factorGroupType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'id':
        return $int($value['id'] as int);
      case 'name':
        return $String($value['name'] as String);
      case 'totalStar':
        return $int($value['totalStar'] as int);
      case 'selfStar':
        return $int($value['selfStar'] as int);
      case 'parent1Star':
        return $int($value['parent1Star'] as int);
      case 'parent2Star':
        return $int($value['parent2Star'] as int);
      case 'hasTag':
        return $Function(_wrapTag);
    }
    return _fallback(rt, id);
  }
}

// --- Races -------------------------------------------------------------------

class $RaceList extends _CollectionInstance {
  $RaceList.wrap(super.$value);

  static final declaration = _collectionDecl(raceListType, raceType);

  @override
  BridgeTypeRef get $typeRef => raceListType;

  @override
  $Instance wrapElement(Object? element) => $Race.wrap(element as Map);

  @override
  _CollectionInstance rewrap(List list) => $RaceList.wrap(list);
}

class $Race extends _MapInstance {
  $Race.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(raceType),
    constructors: const {},
    getters: {
      'title': _getter(codedType),
      'place': _getter(_intT),
      'position': _getter(_intT),
      'won': _getter(_boolT),
      'ground': _getter(codedType),
      'distance': _getter(codedType),
      'strategy': _getter(codedType),
      'weather': _getter(codedType),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => raceType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'place':
        return $int($value['place'] as int);
      case 'position':
        return $int($value['position'] as int);
      case 'won':
        return $bool($value['won'] == true);
      case 'title':
      case 'ground':
      case 'distance':
      case 'strategy':
      case 'weather':
        return $Coded.wrap($value[id] as Map);
    }
    return _fallback(rt, id);
  }
}

// --- Support cards -----------------------------------------------------------

class $SupportCardList extends _CollectionInstance {
  $SupportCardList.wrap(super.$value);

  static final declaration = _collectionDecl(supportCardListType, supportCardType);

  @override
  BridgeTypeRef get $typeRef => supportCardListType;

  @override
  $Instance wrapElement(Object? element) => $SupportCard.wrap(element as Map);

  @override
  _CollectionInstance rewrap(List list) => $SupportCardList.wrap(list);
}

class $SupportCard extends _MapInstance {
  $SupportCard.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(supportCardType),
    constructors: const {},
    getters: {'id': _getter(_intT), 'rank': _getter(codedType), 'level': _getter(_intT)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => supportCardType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'id':
        return $int($value['id'] as int);
      case 'level':
        return $int($value['level'] as int);
      case 'rank':
        return $Coded.wrap($value['rank'] as Map);
    }
    return _fallback(rt, id);
  }
}

// --- Scenario ----------------------------------------------------------------

class $Scenario extends _MapInstance {
  $Scenario.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(scenarioType),
    constructors: const {},
    getters: {'id': _getter(_intT), 'name': _getter(_stringT)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => scenarioType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'id':
        return $int($value['id'] as int);
      case 'name':
        return $String($value['name'] as String);
    }
    return _fallback(rt, id);
  }
}

// --- Family (inheritance tree) -----------------------------------------------

class $Family extends _MapInstance {
  $Family.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(familyType),
    constructors: const {},
    getters: {'parent1': _getter(parentType), 'parent2': _getter(parentType)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => familyType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'parent1':
      case 'parent2':
        return $Parent.wrap($value[id] as Map);
    }
    return _fallback(rt, id);
  }
}

class $Parent extends _MapInstance {
  $Parent.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(parentType),
    constructors: const {},
    getters: {
      'self': _getter(codedType),
      'parent1': _getter(codedType),
      'parent2': _getter(codedType),
      'rental': _getter(_boolT, nullable: true),
    },
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => parentType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'self':
      case 'parent1':
      case 'parent2':
        return $Coded.wrap($value[id] as Map);
      case 'rental':
        final rental = $value['rental'];
        return rental == null ? $null() : $bool(rental == true);
    }
    return _fallback(rt, id);
  }
}

// --- Ratings -----------------------------------------------------------------

class $Ratings extends _MapInstance {
  $Ratings.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(ratingsType),
    constructors: const {},
    methods: {'get': _keyMethod(_doubleT, nullable: true)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => ratingsType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    if (id == 'get') {
      return $Function((rt, t, a) {
        final v = (t!.$value as Map)[a[0]?.$value];
        return v == null ? $null() : $double((v as num).toDouble());
      });
    }
    return _fallback(rt, id);
  }
}

// --- Memos -------------------------------------------------------------------

class $Memos extends _MapInstance {
  $Memos.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(memosType),
    constructors: const {},
    methods: {'get': _keyMethod(_stringT, nullable: true)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => memosType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    if (id == 'get') {
      return $Function((rt, t, a) {
        final v = (t!.$value as Map)[a[0]?.$value];
        return v == null ? $null() : $String(v as String);
      });
    }
    return _fallback(rt, id);
  }
}

// --- Metadata ----------------------------------------------------------------

class $Metadata extends _MapInstance {
  $Metadata.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(metadataType),
    constructors: const {},
    getters: {'recordType': _getter(codedType), 'strategy': _getter(codedType), 'isFriend': _getter(_boolT)},
    wrap: true,
  );

  @override
  BridgeTypeRef get $typeRef => metadataType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'isFriend':
        return $bool($value['isFriend'] == true);
      case 'recordType':
      case 'strategy':
        return $Coded.wrap($value[id] as Map);
    }
    return _fallback(rt, id);
  }
}

// --- ValueList (result of `map`) ---------------------------------------------

class $ValueList implements $Instance {
  $ValueList.wrap(this.$value);

  @override
  final List $value;

  late final $Instance _superclass = $Object($value);

  static final declaration = BridgeClassDef(
    BridgeClassType(valueListType),
    constructors: const {},
    getters: {
      'sum': _getter(_numT),
      'max': _getter(_numT, nullable: true),
      'min': _getter(_numT, nullable: true),
      'average': _getter(_numT, nullable: true),
      'length': _getter(_intT),
    },
    methods: {'join': _joinMethod()},
    wrap: true,
  );

  Iterable<num> get _numbers => $value.map((e) {
    if (e is num) {
      return e;
    }
    throw ScriptLookupError('sum/max/min/average require numeric values, got ${e.runtimeType}');
  });

  $Value _num(num value) => value is int ? $int(value) : $double(value.toDouble());

  @override
  $Value? $getProperty(Runtime rt, String id) {
    switch (id) {
      case 'length':
        return $int($value.length);
      case 'sum':
        return _num(_numbers.fold<num>(0, (a, b) => a + b));
      case 'max':
        return $value.isEmpty ? $null() : _num(_numbers.reduce((a, b) => a > b ? a : b));
      case 'min':
        return $value.isEmpty ? $null() : _num(_numbers.reduce((a, b) => a < b ? a : b));
      case 'average':
        return $value.isEmpty ? $null() : $double(_numbers.fold<num>(0, (a, b) => a + b) / $value.length);
      case 'join':
        return $Function((rt, t, a) {
          final sep = (a.isNotEmpty ? a[0]?.$value?.toString() : null) ?? ', ';
          return $String($value.map((e) => '$e').join(sep));
        });
    }
    return _superclass.$getProperty(rt, id);
  }

  @override
  void $setProperty(Runtime rt, String id, $Value value) => _superclass.$setProperty(rt, id, value);

  @override
  int $getRuntimeType(Runtime rt) => rt.lookupType(valueListType.spec!);

  @override
  dynamic get $reified => $value;
}

// --- Cell (constructed in-script) --------------------------------------------

class $Cell extends _MapInstance {
  $Cell.wrap(super.$value);

  static final declaration = BridgeClassDef(
    BridgeClassType(cellType),
    constructors: {
      '': BridgeConstructorDef(
        BridgeFunctionDef(
          returns: const BridgeTypeAnnotation(cellType),
          params: [BridgeParameter('display', const BridgeTypeAnnotation(_stringT), false)],
          // color/background/icon/iconColor are declared `dynamic` rather than
          // `String?`: dart_eval emits an unconditional BoxString when a value
          // is passed to a `String` param, which crashes on `null` (and the
          // manual documents `color: cond ? "white" : null`). `dynamic` skips
          // the box; `construct` reads the raw value as a `String?`.
          namedParams: [
            BridgeParameter('sort', const BridgeTypeAnnotation(_dynT, nullable: true), true),
            BridgeParameter('color', const BridgeTypeAnnotation(_dynT, nullable: true), true),
            BridgeParameter('background', const BridgeTypeAnnotation(_dynT, nullable: true), true),
            BridgeParameter('icon', const BridgeTypeAnnotation(_dynT, nullable: true), true),
            BridgeParameter('iconColor', const BridgeTypeAnnotation(_dynT, nullable: true), true),
          ],
        ),
      ),
    },
    getters: {
      'display': _getter(_stringT),
      'sort': _getter(_dynT, nullable: true),
      'color': _getter(_stringT, nullable: true),
      'background': _getter(_stringT, nullable: true),
      'icon': _getter(_stringT, nullable: true),
      'iconColor': _getter(_stringT, nullable: true),
    },
    wrap: true,
  );

  static $Value? construct(Runtime rt, $Value? target, List<$Value?> args) {
    return $Cell.wrap({
      'display': args[0]?.$value,
      'sort': args[1]?.$value,
      'color': args[2]?.$value,
      'background': args[3]?.$value,
      'icon': args[4]?.$value,
      'iconColor': args[5]?.$value,
    });
  }

  @override
  BridgeTypeRef get $typeRef => cellType;

  @override
  $Value? $getProperty(Runtime rt, String id) {
    final v = $value[id];
    switch (id) {
      case 'display':
        return $String(v as String);
      case 'sort':
        if (v == null) return $null();
        if (v is int) return $int(v);
        if (v is double) return $double(v);
        if (v is String) return $String(v);
        return $double((v as num).toDouble());
      case 'color':
      case 'background':
      case 'icon':
      case 'iconColor':
        return v == null ? $null() : $String(v as String);
    }
    return _fallback(rt, id);
  }
}

// --- Color map / colormap functions ------------------------------------------

/// Named colors usable in `color` / `background` / `iconColor`, as opaque
/// 0xAARRGGBB ints (Material shade-500 values). The renderer in `script.dart`
/// converts a resolved int into a Flutter `Color`.
const Map<String, int> kNamedColors = {
  'red': 0xFFF44336,
  'pink': 0xFFE91E63,
  'purple': 0xFF9C27B0,
  'deepPurple': 0xFF673AB7,
  'indigo': 0xFF3F51B5,
  'blue': 0xFF2196F3,
  'lightBlue': 0xFF03A9F4,
  'cyan': 0xFF00BCD4,
  'teal': 0xFF009688,
  'green': 0xFF4CAF50,
  'lightGreen': 0xFF8BC34A,
  'lime': 0xFFCDDC39,
  'yellow': 0xFFFFEB3B,
  'amber': 0xFFFFC107,
  'orange': 0xFFFF9800,
  'deepOrange': 0xFFFF5722,
  'brown': 0xFF795548,
  'grey': 0xFF9E9E9E,
  'blueGrey': 0xFF607D8B,
  'black': 0xFF000000,
  'white': 0xFFFFFFFF,
};

/// Resolves a color string (named or `#RRGGBB` / `#AARRGGBB`) to 0xAARRGGBB,
/// or `null` if it cannot be parsed.
int? resolveColorArgb(String? source) {
  if (source == null) return null;
  final value = source.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('#')) {
    var hex = value.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    return int.tryParse(hex, radix: 16);
  }
  return kNamedColors[value];
}

String _hex2(int x) => x.toRadixString(16).padLeft(2, '0');

String _argbToHex(int argb) {
  final a = (argb >> 24) & 0xFF;
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return a == 0xFF ? '#${_hex2(r)}${_hex2(g)}${_hex2(b)}' : '#${_hex2(a)}${_hex2(r)}${_hex2(g)}${_hex2(b)}';
}

/// Evaluates one channel of a piecewise-linear colormap at [t] (0..1).
///
/// [stops] is an ascending list of `[position, value]` control points whose
/// values are in 0..1; the returned byte is `round(255 * value)`. Positions of
/// [t] outside the first/last stop clamp to that stop's value.
int _jetChannel(double t, List<List<double>> stops) {
  if (t <= stops.first[0]) return (255 * stops.first[1]).round().clamp(0, 255);
  if (t >= stops.last[0]) return (255 * stops.last[1]).round().clamp(0, 255);
  for (var i = 1; i < stops.length; i++) {
    final s1 = stops[i][0];
    if (t <= s1) {
      final s0 = stops[i - 1][0];
      final v0 = stops[i - 1][1];
      final v1 = stops[i][1];
      final v = v0 + (v1 - v0) * (t - s0) / (s1 - s0);
      return (255 * v).round().clamp(0, 255);
    }
  }
  return (255 * stops.last[1]).round().clamp(0, 255);
}

// Canonical matplotlib `jet` segment data: ascending `[position, value]` control
// points for each channel (values 0..1). At t=0 only blue is lit (dark blue);
// at t=1 only red is half-lit (dark red).
const List<List<double>> _jetRed = [
  [0.00, 0.0],
  [0.35, 0.0],
  [0.66, 1.0],
  [0.89, 1.0],
  [1.00, 0.5],
];
const List<List<double>> _jetGreen = [
  [0.000, 0.0],
  [0.125, 0.0],
  [0.375, 1.0],
  [0.640, 1.0],
  [0.910, 0.0],
  [1.000, 0.0],
];
const List<List<double>> _jetBlue = [
  [0.00, 0.5],
  [0.11, 1.0],
  [0.34, 1.0],
  [0.65, 0.0],
  [1.00, 0.0],
];

/// `heat(num value, {num min, num max})` → hex string following matplotlib's
/// `jet` colormap (low = dark blue … through cyan, green, yellow, red … high =
/// dark red).
$Value? heatFn(Runtime rt, $Value? target, List<$Value?> args) {
  final value = (args[0]?.$value as num).toDouble();
  final min = (args[1]?.$value as num?)?.toDouble() ?? 0.0;
  final max = (args[2]?.$value as num?)?.toDouble() ?? 1.0;
  final t = max == min ? 0.0 : ((value - min) / (max - min)).clamp(0.0, 1.0);
  final r = _jetChannel(t, _jetRed);
  final g = _jetChannel(t, _jetGreen);
  final b = _jetChannel(t, _jetBlue);
  return $String('#${_hex2(r)}${_hex2(g)}${_hex2(b)}');
}

/// `lerpColor(String a, String b, num t)` → hex string (channel-wise blend).
$Value? lerpColorFn(Runtime rt, $Value? target, List<$Value?> args) {
  final a = resolveColorArgb(args[0]?.$value as String?) ?? 0xFF000000;
  final b = resolveColorArgb(args[1]?.$value as String?) ?? 0xFFFFFFFF;
  final t = ((args[2]?.$value as num).toDouble()).clamp(0.0, 1.0);
  int blend(int shift) {
    final ca = (a >> shift) & 0xFF;
    final cb = (b >> shift) & 0xFF;
    return (ca + (cb - ca) * t).round() & 0xFF;
  }

  final argb = (blend(24) << 24) | (blend(16) << 16) | (blend(8) << 8) | blend(0);
  return $String(_argbToHex(argb));
}

/// `when(bool cond, dynamic value)` → `value` if `cond` else `null`.
///
/// A null-safe replacement for the ternary `cond ? value : null`: dart_eval
/// 0.8.5 crashes compiling `cond ? <literal> : null` (an unconditional Box op
/// that fails on the null branch), so the manual steers conditional styling
/// through this helper instead.
$Value? whenFn(Runtime rt, $Value? target, List<$Value?> args) {
  final cond = args[0]?.$value == true;
  return cond ? (args[1] ?? $null()) : $null();
}

/// `days(String date)` → whole days since the Unix epoch for the date's local
/// civil day.
///
/// Accepts both `YYYY/MM/DD` (e.g. `trainedDate`) and ISO-8601 (e.g.
/// `capturedDate`) by normalizing `/` to `-` before parsing. The result is the
/// calendar day in local time (matching how the standard date columns display
/// `capturedDate` via `toLocal()`), reduced to a day-granularity integer so the
/// time-of-day is absorbed and the value is timezone-stable for date-only input.
/// Throws on an unparseable string.
$Value? daysFn(Runtime rt, $Value? target, List<$Value?> args) {
  final source = args[0]?.$value as String?;
  final parsed = source == null ? null : DateTime.tryParse(source.replaceAll('/', '-'));
  if (parsed == null) {
    throw ScriptLookupError('cannot parse date: $source');
  }
  final local = parsed.toLocal();
  // UTC midnight of the civil date: its epoch millis are an exact day multiple.
  return $int(DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay);
}

final _daysDecl = BridgeFunctionDeclaration(
  facadeUri,
  'days',
  BridgeFunctionDef(
    returns: const BridgeTypeAnnotation(_intT),
    params: [BridgeParameter('date', const BridgeTypeAnnotation(_stringT), false)],
  ),
);

final _whenDecl = BridgeFunctionDeclaration(
  facadeUri,
  'when',
  BridgeFunctionDef(
    returns: const BridgeTypeAnnotation(_dynT, nullable: true),
    params: [
      BridgeParameter('cond', const BridgeTypeAnnotation(_boolT), false),
      BridgeParameter('value', const BridgeTypeAnnotation(_dynT, nullable: true), false),
    ],
  ),
);

final _heatDecl = BridgeFunctionDeclaration(
  facadeUri,
  'heat',
  BridgeFunctionDef(
    returns: const BridgeTypeAnnotation(_stringT),
    params: [BridgeParameter('value', const BridgeTypeAnnotation(_numT), false)],
    namedParams: [
      BridgeParameter('min', const BridgeTypeAnnotation(_numT, nullable: true), true),
      BridgeParameter('max', const BridgeTypeAnnotation(_numT, nullable: true), true),
    ],
  ),
);

final _lerpColorDecl = BridgeFunctionDeclaration(
  facadeUri,
  'lerpColor',
  BridgeFunctionDef(
    returns: const BridgeTypeAnnotation(_stringT),
    params: [
      BridgeParameter('a', const BridgeTypeAnnotation(_stringT), false),
      BridgeParameter('b', const BridgeTypeAnnotation(_stringT), false),
      BridgeParameter('t', const BridgeTypeAnnotation(_numT), false),
    ],
  ),
);

// --- Plugin ------------------------------------------------------------------

/// Defines every facade class and top-level function under [facadeUri].
///
/// Must be added to BOTH the [Compiler] (`configureForCompile`) and the
/// [Runtime] (`configureForRuntime`).
class FacadePlugin implements EvalPlugin {
  @override
  String get identifier => 'umacapture_script_facade';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(_whenDecl);
    registry.defineBridgeTopLevelFunction(_heatDecl);
    registry.defineBridgeTopLevelFunction(_lerpColorDecl);
    registry.defineBridgeTopLevelFunction(_daysDecl);
    for (final declaration in _classDeclarations) {
      registry.defineBridgeClass(declaration);
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(facadeUri, 'Cell.', $Cell.construct);
    runtime.registerBridgeFunc(facadeUri, 'when', whenFn);
    runtime.registerBridgeFunc(facadeUri, 'heat', heatFn);
    runtime.registerBridgeFunc(facadeUri, 'lerpColor', lerpColorFn);
    runtime.registerBridgeFunc(facadeUri, 'days', daysFn);
  }

  static final List<BridgeClassDef> _classDeclarations = [
    $Record.declaration,
    $Status.declaration,
    $Aptitudes.declaration,
    $GroundAptitude.declaration,
    $DistanceAptitude.declaration,
    $StyleAptitude.declaration,
    $Coded.declaration,
    $SkillList.declaration,
    $Skill.declaration,
    $FactorList.declaration,
    $Factor.declaration,
    $FactorGroupList.declaration,
    $FactorGroup.declaration,
    $RaceList.declaration,
    $Race.declaration,
    $SupportCardList.declaration,
    $SupportCard.declaration,
    $Scenario.declaration,
    $Family.declaration,
    $Parent.declaration,
    $Ratings.declaration,
    $Memos.declaration,
    $Metadata.declaration,
    $ValueList.declaration,
    $Cell.declaration,
  ];
}
