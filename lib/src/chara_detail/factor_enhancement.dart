import 'package:collection/collection.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_operation.dart';
import '/src/chara_detail/spec/base.dart';

/// Whether a factor is one that factor enhancement can star up (coloured) or one it can add (white).
enum FactorColour { coloured, white }

/// Maps factor ids to [FactorColour], derived from the `factor_info` tags.
///
/// This is the single place the derivation lives: a factor tagged `factor_status` (blue),
/// `factor_aptitude` (red) or `factor_unique_skill` (green) is coloured, and every other factor —
/// including the `*_gene` ones — is white.
final class FactorClassifier {
  static const colouredTags = {'factor_status', 'factor_aptitude', 'factor_unique_skill'};

  final Map<int, FactorColour> _colours;

  FactorClassifier._(this._colours);

  factory FactorClassifier.fromInfo(Iterable<FactorInfo> info) {
    return FactorClassifier._({
      for (final factor in info)
        factor.sid: factor.tags.any(colouredTags.contains) ? FactorColour.coloured : FactorColour.white,
    });
  }

  /// The colour of [factorId], or null when the loaded `factor_info` does not know the id.
  FactorColour? colourOf(int factorId) => _colours[factorId];
}

/// How two self-factor lists relate under factor enhancement.
enum EnhancementRelation {
  /// Not the same uma as far as enhancement can tell.
  unrelated,

  /// The same uma twice with nothing to merge from either side.
  ///
  /// From [compareEnhancement]: the same self factors (ignoring order), each side satisfying the
  /// pre-enhancement guard. From [relateRecords]: also any exact duplicate
  /// ([CharaDetailRecord.isSameChara]), whatever its self factors hold.
  identical,

  /// The first list is the second one after enhancement.
  firstEnhanced,

  /// The second list is the first one after enhancement.
  secondEnhanced,
}

/// The fewest white factors a pre-enhancement list must carry for a pair to count.
///
/// A sparse white list is a subset of too many unrelated umas' lists, so below this count a pair would
/// over-match. Enhancing an uma with fewer whites is therefore undetectable, which the spec accepts.
const kEnhancementMinPreWhites = 5;

/// The star count every white factor added by enhancement carries.
const kEnhancementAddedWhiteStar = 3;

/// Decides whether [first] and [second] are the same uma before and after factor enhancement.
///
/// Enhancement only raises the stars of existing coloured factors and adds new whites at
/// [kEnhancementAddedWhiteStar] stars; the game appends added whites at the end of the list, so the
/// comparison is by factor id and ignores order. A list with an id the [classifier] does not know, or
/// with a repeated id, is a misrecognised record and relates to nothing.
EnhancementRelation compareEnhancement(List<Factor> first, List<Factor> second, FactorClassifier classifier) {
  return _relateSplits(SplitFactors.of(first, classifier), SplitFactors.of(second, classifier));
}

/// How two split self-factor lists relate; a list that could not be split relates to nothing.
EnhancementRelation _relateSplits(SplitFactors? a, SplitFactors? b) {
  if (a == null || b == null) {
    return EnhancementRelation.unrelated;
  }
  return a.relateTo(b);
}

/// A self-factor list split into its coloured and white factors, each keyed by id with its star count.
final class SplitFactors {
  final Map<int, int> coloured;
  final Map<int, int> white;

  SplitFactors._(this.coloured, this.white);

  /// Null when an id is unknown to [classifier] or repeats within [factors].
  static SplitFactors? of(List<Factor> factors, FactorClassifier classifier) {
    final coloured = <int, int>{};
    final white = <int, int>{};
    for (final factor in factors) {
      final target = switch (classifier.colourOf(factor.id)) {
        FactorColour.coloured => coloured,
        FactorColour.white => white,
        null => null,
      };
      if (target == null || coloured.containsKey(factor.id) || white.containsKey(factor.id)) {
        return null;
      }
      target[factor.id] = factor.star;
    }
    return SplitFactors._(coloured, white);
  }

  /// The sorted coloured ids joined into one string: two lists can only relate when this is equal.
  late final String colouredKey = (coloured.keys.toList()..sort()).join(',');

  EnhancementRelation relateTo(SplitFactors other) {
    if (colouredKey != other.colouredKey) {
      return EnhancementRelation.unrelated;
    }
    final firstEnhanced =
        _starsAtLeast(coloured, other.coloured) &&
        _whitesExtend(white, other.white) &&
        other.white.length >= kEnhancementMinPreWhites;
    final secondEnhanced =
        _starsAtLeast(other.coloured, coloured) &&
        _whitesExtend(other.white, white) &&
        white.length >= kEnhancementMinPreWhites;
    if (firstEnhanced && secondEnhanced) {
      return EnhancementRelation.identical;
    }
    if (firstEnhanced) {
      return EnhancementRelation.firstEnhanced;
    }
    if (secondEnhanced) {
      return EnhancementRelation.secondEnhanced;
    }
    return EnhancementRelation.unrelated;
  }

  /// Every coloured factor of [post] has at least the stars it has in [pre] (the key sets are equal).
  static bool _starsAtLeast(Map<int, int> post, Map<int, int> pre) {
    return pre.entries.every((e) => (post[e.key] ?? 0) >= e.value);
  }

  /// [post] keeps every white of [pre] unchanged and only adds whites at the added-white star count.
  static bool _whitesExtend(Map<int, int> post, Map<int, int> pre) {
    if (!pre.entries.every((e) => post[e.key] == e.value)) {
      return false;
    }
    return post.entries.every((e) => pre.containsKey(e.key) || e.value == kEnhancementAddedWhiteStar);
  }
}

/// An unordered pair of record ids.
final class RecordIdPair {
  final String first;
  final String second;

  const RecordIdPair._(this.first, this.second);

  factory RecordIdPair(String a, String b) => a.compareTo(b) <= 0 ? RecordIdPair._(a, b) : RecordIdPair._(b, a);

  @override
  bool operator ==(Object other) => other is RecordIdPair && other.first == first && other.second == second;

  @override
  int get hashCode => Object.hash(first, second);
}

/// Two stored records whose self factors relate by enhancement (or are identical).
final class EnhancementCandidate {
  /// The record whose id has existed longer (see [compareRecordAge]); its id is the one a merge keeps.
  final String olderId;
  final String newerId;

  /// The enhanced side, or null when both sides carry the same factors.
  final String? enhancedId;

  const EnhancementCandidate({required this.olderId, required this.newerId, required this.enhancedId});

  bool get identical => enhancedId == null;

  RecordIdPair get pair => RecordIdPair(olderId, newerId);
}

/// What of a stored record the candidate derivation reads: its id, its capture date and its
/// [CharaIdentity].
///
/// [findEnhancementCandidates], [relateRecords] and [compareRecordAge] take this and not the record,
/// so no other field of a record can decide a candidate: a derivation that needs one more field has
/// to add it here. A record type, so its equality — which decides whether the candidates are kept or
/// derived again ([EnhancementCandidateSource]) — compares every field it has without listing them.
typedef EnhancementSubject = ({String id, String capturedDate, CharaIdentity chara});

/// The [EnhancementSubject] of [record], worked out once per record instance ([_subjects]): a record
/// is immutable, and every change of one is a new instance, which has no subject yet.
EnhancementSubject enhancementSubjectOf(CharaDetailRecord record) =>
    _subjects[record] ??= (id: record.id, capturedDate: record.metadata.capturedDate, chara: record.charaIdentity);

/// The subject [enhancementSubjectOf] worked out of each record instance, held by the instance's
/// identity and gone with it.
final _subjects = Expando<EnhancementSubject>('EnhancementSubject');

/// Everything the candidates are derived from but the factor table: the subjects of the stored
/// records, in store order, and the dismissed pairs.
///
/// Equal by content, so a store publishing records whose subjects did not change — a binding, the
/// inheritance links, a reload of the same files — or the dismissed pairs arriving as the set they
/// already were, derives nothing again.
final class EnhancementCandidateSource {
  const EnhancementCandidateSource(this.subjects, this.dismissed);

  final List<EnhancementSubject> subjects;
  final Set<RecordIdPair> dismissed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnhancementCandidateSource &&
          const ListEquality<EnhancementSubject>().equals(subjects, other.subjects) &&
          const SetEquality<RecordIdPair>().equals(dismissed, other.dismissed);

  @override
  int get hashCode => Object.hash(subjects.length, dismissed.length);
}

/// Orders records by how long their id has existed: earlier `capturedDate` first, an unparseable date
/// after every parseable one, and the lexicographically smaller id on a tie.
///
/// This decides only which id survives a merge; which side is enhanced is decided by factor content
/// alone, because a pre-enhancement record can be captured again later. The order is the merge's
/// ([syncCompareAge]), of each record's id and the instant its date parses to.
int compareRecordAge(EnhancementSubject a, EnhancementSubject b) => syncCompareAge(_ageOf(a), _ageOf(b));

/// What [syncCompareAge] orders a record by: its id and the instant its capture date parses to.
({String id, int? captured}) _ageOf(EnhancementSubject r) =>
    (id: r.id, captured: DateTime.tryParse(r.capturedDate)?.microsecondsSinceEpoch);

/// How two stored records relate as merge candidates.
///
/// An exact duplicate ([CharaDetailRecord.isSameChara]) is [EnhancementRelation.identical] whatever
/// its self factors hold: [kEnhancementMinPreWhites] and the known-id rule guard against a sparse or
/// misread self list matching an unrelated uma, and a pair that also agrees on the parents, status,
/// aptitudes, skills, rank and evaluation is not such a match. Every other pair is decided by
/// [compareEnhancement] on the self factors alone, which needs the colour of each factor; with no
/// [classifier] (the factor table has not loaded, or failed to) such a pair is unrelated.
EnhancementRelation relateRecords(EnhancementSubject a, EnhancementSubject b, FactorClassifier? classifier) {
  if (a.chara == b.chara) {
    return EnhancementRelation.identical;
  }
  if (classifier == null) {
    return EnhancementRelation.unrelated;
  }
  return compareEnhancement(a.chara.factors.self, b.chara.factors.self, classifier);
}

/// What [findEnhancementCandidates] works out of each record once, so that a pair only compares them.
///
/// [identity] numbers the records' [CharaIdentity] values: two records carry the same number exactly
/// when their identities are `==`, so it decides [EnhancementRelation.identical] as [relateRecords]
/// does. It is only meaningful within one call of [findEnhancementCandidates].
typedef _Prepared = ({EnhancementSubject subject, SplitFactors? split, ({String id, int? captured}) age, int identity});

/// Every pair of [records] that [relateRecords] relates, except the pairs in [dismissed].
///
/// With no [classifier] only the exact duplicates are found, as [relateRecords] relates nothing else.
///
/// What a single record decides — its split self factors, its age and which identity it has — is
/// worked out once per record ([_Prepared]); each pair relates them as [relateRecords] would relate
/// the two records.
///
/// Records are compared only within the same set of coloured factor kinds, or, for an exact
/// duplicate, within the same factors; the card is not a term, because the green factor already
/// differs per card.
List<EnhancementCandidate> findEnhancementCandidates(
  Iterable<EnhancementSubject> records,
  FactorClassifier? classifier, {
  Set<RecordIdPair> dismissed = const {},
}) {
  // Two partitions, because each relation is only possible within one: an enhancement pair shares
  // its coloured kinds, and an exact duplicate shares its whole factor set — including a record
  // whose self list [SplitFactors.of] cannot split. A pair can sit in both; [seen] offers it once.
  //
  // The identity numbers are given within the factor-set partition, by comparing each record with the
  // first record of every identity already seen there. That finds every exact duplicate because
  // `CharaIdentity.==` is an equivalence relation, and identities that are `==` have equal factors, so
  // they always share a factor-set partition; numbers run across partitions, so records in different
  // ones never share one.
  final byColouredKinds = <String, List<_Prepared>>{};
  final byFactors = <String, List<_Prepared>>{};
  final representatives = <String, List<_Prepared>>{};
  var identities = 0;
  for (final record in records) {
    final split = classifier == null ? null : SplitFactors.of(record.chara.factors.self, classifier);
    final key = _factorsKey(record.chara.factors);
    final known = representatives.putIfAbsent(key, () => []);
    final same = known.firstWhereOrNull((r) => r.subject.chara == record.chara);
    final prepared = (subject: record, split: split, age: _ageOf(record), identity: same?.identity ?? identities++);
    if (same == null) {
      known.add(prepared);
    }
    if (split != null) {
      byColouredKinds.putIfAbsent(split.colouredKey, () => []).add(prepared);
    }
    byFactors.putIfAbsent(key, () => []).add(prepared);
  }
  final seen = <RecordIdPair>{...dismissed};
  final candidates = <EnhancementCandidate>[];
  for (final bucket in [...byColouredKinds.values, ...byFactors.values]) {
    for (var i = 0; i < bucket.length; i++) {
      for (var j = i + 1; j < bucket.length; j++) {
        final pa = bucket[i];
        final pb = bucket[j];
        final a = pa.subject;
        final b = pb.subject;
        final pair = RecordIdPair(a.id, b.id);
        if (seen.contains(pair)) {
          continue;
        }
        final relation = pa.identity == pb.identity ? EnhancementRelation.identical : _relateSplits(pa.split, pb.split);
        if (relation == EnhancementRelation.unrelated) {
          continue;
        }
        seen.add(pair);
        final aOlder = syncCompareAge(pa.age, pb.age) <= 0;
        candidates.add(
          EnhancementCandidate(
            olderId: aOlder ? a.id : b.id,
            newerId: aOlder ? b.id : a.id,
            enhancedId: switch (relation) {
              EnhancementRelation.firstEnhanced => a.id,
              EnhancementRelation.secondEnhanced => b.id,
              _ => null,
            },
          ),
        );
      }
    }
  }
  return candidates;
}

/// [factors] as a string equal exactly when the sets are equal ([FactorSet]'s hash is by identity).
String _factorsKey(FactorSet factors) =>
    factors.toList().map((list) => list.map((f) => '${f.id}:${f.star}').join(',')).join('|');
