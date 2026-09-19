import '/src/chara_detail/chara_detail_record.dart';
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
  final a = SplitFactors.of(first, classifier);
  final b = SplitFactors.of(second, classifier);
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
  String get colouredKey => (coloured.keys.toList()..sort()).join(',');

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

/// Orders records by how long their id has existed: earlier `capturedDate` first, an unparseable date
/// after every parseable one, and the lexicographically smaller id on a tie.
///
/// This decides only which id survives a merge; which side is enhanced is decided by factor content
/// alone, because a pre-enhancement record can be captured again later.
int compareRecordAge(CharaDetailRecord a, CharaDetailRecord b) {
  final dateA = DateTime.tryParse(a.metadata.capturedDate);
  final dateB = DateTime.tryParse(b.metadata.capturedDate);
  final byDate = switch ((dateA, dateB)) {
    (null, null) => 0,
    (null, _) => 1,
    (_, null) => -1,
    (final x?, final y?) => x.compareTo(y),
  };
  return byDate != 0 ? byDate : a.id.compareTo(b.id);
}

/// How two stored records relate as merge candidates.
///
/// Records are compared only within the same set of coloured factor kinds; the card is not a term,
/// because the green factor already differs per card.
List<EnhancementCandidate> findEnhancementCandidates(
  Iterable<CharaDetailRecord> records,
  FactorClassifier classifier, {
  Set<RecordIdPair> dismissed = const {},
}) {
  final buckets = <String, List<(CharaDetailRecord, SplitFactors)>>{};
  for (final record in records) {
    final split = SplitFactors.of(record.factors.self, classifier);
    if (split != null) {
      buckets.putIfAbsent(split.colouredKey, () => []).add((record, split));
    }
  }
  final candidates = <EnhancementCandidate>[];
  for (final bucket in buckets.values) {
    for (var i = 0; i < bucket.length; i++) {
      for (var j = i + 1; j < bucket.length; j++) {
        final (a, splitA) = bucket[i];
        final (b, splitB) = bucket[j];
        final relation = splitA.relateTo(splitB);
        if (relation == EnhancementRelation.unrelated || dismissed.contains(RecordIdPair(a.id, b.id))) {
          continue;
        }
        final aOlder = compareRecordAge(a, b) <= 0;
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
