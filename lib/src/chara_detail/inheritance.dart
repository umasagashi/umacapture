import '/src/chara_detail/chara_detail_record.dart';

/// Resolves parent/child inheritance links between captured records.
///
/// Each record carries two parent record-id slots in [RecordId] (`parent1` /
/// `parent2`). The native recognizer cannot know the parents' record ids, so it
/// leaves them null; this resolver fills them by matching a record against the
/// parent slots that other records recorded.
///
/// A stored record `parent` occupies child `child`'s slot `N` (1 or 2) when both
/// hold:
///
/// * `parent.trainee.card == child.family.parentN.self.card` (the card matches), and
/// * `parent.factors.self == child.factors.parentN` (the parent's own factors match
///   the factor list the child recorded for that parent).
///
/// The factor list order is guaranteed by the recognizer, so the lists are
/// compared as-is (no sorting). Matching is keyed on a `card|factors` string.
///
/// Deleting a record does not clean up links that point at it: a child keeps the
/// deleted id in its `parentN` slot. That dangling id is harmless — it resolves
/// to "no parent" in `resolveRegisteredAncestors` — and is cleared the next time
/// the authoritative [resolveAll] (manual re-resolution) runs. This holds for
/// both the active and archive sets; a deletion in either leaves the other's
/// links to be reconciled on the next manual pass.
class InheritanceResolver {
  const InheritanceResolver._();

  /// Authoritatively recomputes every record's parent links across [records].
  ///
  /// This is idempotent: it both sets newly-resolvable links and clears links
  /// that no longer resolve (or became ambiguous). Use it for the manual,
  /// whole-storage re-resolution. Returns only the records whose links changed.
  static InheritanceResolution resolveAll(List<CharaDetailRecord> records) {
    final index = _selfKeyIndex(records);
    final changed = <CharaDetailRecord>[];
    final ambiguities = <AmbiguousMatch>[];
    for (final child in records) {
      String? resolved(int slot) {
        final candidates = (index[_childKey(child, slot)] ?? const <CharaDetailRecord>[])
            .where((p) => p.id != child.id)
            .toList();
        if (candidates.length == 1) {
          return candidates.first.id;
        }
        if (candidates.length > 1) {
          ambiguities.add(AmbiguousMatch(child.id, slot, candidates.length));
        }
        return null;
      }

      final parent1 = resolved(1);
      final parent2 = resolved(2);
      if (parent1 != child.metadata.recordId.parent1 || parent2 != child.metadata.recordId.parent2) {
        changed.add(_withParents(child, parent1: parent1, parent2: parent2));
      }
    }
    return InheritanceResolution(changed, ambiguities);
  }

  /// Resolves links touched by a newly captured [newRecord] against [existing].
  ///
  /// This is additive and narrow: it only sets [newRecord]'s own parents and
  /// fills [existing] children's slots that [newRecord] uniquely satisfies. It
  /// never clears or re-evaluates unrelated links, so each capture rewrites at
  /// most a handful of records. [existing] must not contain [newRecord].
  ///
  /// The returned [InheritanceResolution.changed] holds the updated [newRecord]
  /// (when it gained parents) and any updated children, each identifiable by its
  /// [CharaDetailRecord.id].
  static InheritanceResolution resolveForNewRecord(CharaDetailRecord newRecord, List<CharaDetailRecord> existing) {
    final changed = <CharaDetailRecord>[];
    final ambiguities = <AmbiguousMatch>[];

    // Index [existing] by self key once so both directions resolve candidates in
    // O(1) lookups instead of a full scan per slot/child. [existing] excludes
    // newRecord, so no self-exclusion is needed here.
    final index = _selfKeyIndex(existing);

    // Direction A: treat newRecord as a child and find its parents.
    var parent1 = newRecord.metadata.recordId.parent1;
    var parent2 = newRecord.metadata.recordId.parent2;
    for (final slot in const [1, 2]) {
      final key = _childKey(newRecord, slot);
      final candidates = index[key] ?? const <CharaDetailRecord>[];
      if (candidates.length == 1) {
        if (slot == 1) {
          parent1 = candidates.first.id;
        } else {
          parent2 = candidates.first.id;
        }
      } else if (candidates.length > 1) {
        ambiguities.add(AmbiguousMatch(newRecord.id, slot, candidates.length));
      }
    }
    if (parent1 != newRecord.metadata.recordId.parent1 || parent2 != newRecord.metadata.recordId.parent2) {
      changed.add(_withParents(newRecord, parent1: parent1, parent2: parent2));
    }

    // Direction B: treat newRecord as a parent and find existing children.
    final newSelfKey = _selfKey(newRecord);
    final sameSelf = index[newSelfKey] ?? const <CharaDetailRecord>[];
    final childUpdates = <String, CharaDetailRecord>{};
    for (final child in existing) {
      for (final slot in const [1, 2]) {
        if (_childKey(child, slot) != newSelfKey) {
          continue;
        }
        // Any other stored record that also satisfies this slot makes the match
        // ambiguous (the child should already be linked to it), so skip linking.
        final others = sameSelf.where((p) => p.id != child.id);
        if (others.isNotEmpty) {
          ambiguities.add(AmbiguousMatch(child.id, slot, others.length + 1));
          continue;
        }
        final current = childUpdates[child.id] ?? child;
        if (_parentLink(current, slot) == newRecord.id) {
          continue;
        }
        childUpdates[child.id] = _withParents(
          current,
          parent1: slot == 1 ? newRecord.id : current.metadata.recordId.parent1,
          parent2: slot == 2 ? newRecord.id : current.metadata.recordId.parent2,
        );
      }
    }
    changed.addAll(childUpdates.values);

    return InheritanceResolution(changed, ambiguities);
  }

  static Map<String, List<CharaDetailRecord>> _selfKeyIndex(List<CharaDetailRecord> records) {
    final index = <String, List<CharaDetailRecord>>{};
    for (final record in records) {
      index.putIfAbsent(_selfKey(record), () => []).add(record);
    }
    return index;
  }

  /// Matching key for a record viewed as a parent: its card and own factors.
  static String _selfKey(CharaDetailRecord record) {
    return '${record.trainee.card}|${_factorsKey(record.factors.self)}';
  }

  /// Matching key for [child]'s parent [slot]: the recorded parent card and factors.
  static String _childKey(CharaDetailRecord child, int slot) {
    final parent = slot == 1 ? child.family.parent1 : child.family.parent2;
    final factors = slot == 1 ? child.factors.parent1 : child.factors.parent2;
    return '${parent.self.card}|${_factorsKey(factors)}';
  }

  /// Order-preserving serialization of a factor list (order is recognizer-guaranteed).
  static String _factorsKey(List<Factor> factors) {
    return factors.map((f) => '${f.id}:${f.star}').join(',');
  }

  static String? _parentLink(CharaDetailRecord record, int slot) {
    return slot == 1 ? record.metadata.recordId.parent1 : record.metadata.recordId.parent2;
  }

  /// Returns a copy of [record] with its parent record-id slots replaced.
  ///
  /// The models opt out of generated `copyWith` (build.yaml limits dart_mappable
  /// to decode/encode), so the record is rebuilt through its constructors.
  static CharaDetailRecord _withParents(CharaDetailRecord record, {String? parent1, String? parent2}) {
    final metadata = record.metadata;
    final recordId = RecordId(metadata.recordId.self, parent1, parent2);
    final newMetadata = Metadata(
      metadata.formatVersion,
      metadata.region,
      recordId,
      metadata.trainerId,
      metadata.capturedDate,
      metadata.recognizerVersion,
      metadata.stage,
      metadata.strategy,
      metadata.relationBonus,
      metadata.recordType,
    );
    return CharaDetailRecord(
      newMetadata,
      record.trainee,
      record.evaluationValue,
      record.status,
      record.aptitudes,
      record.skills,
      record.factors,
      record.supportCards,
      record.family,
      record.fans,
      record.scenario,
      record.foreignAptitude,
      record.uafWins,
      record.trainedDate,
      record.races,
    );
  }
}

/// A child slot that matched more than one candidate parent and was left unlinked.
class AmbiguousMatch {
  /// The child record whose slot could not be resolved.
  final String recordId;

  /// The parent slot (1 or 2) that was ambiguous.
  final int slot;

  /// How many stored records matched the slot.
  final int candidateCount;

  const AmbiguousMatch(this.recordId, this.slot, this.candidateCount);
}

/// The outcome of an inheritance resolution pass.
class InheritanceResolution {
  /// Records whose parent links changed, in their updated form.
  final List<CharaDetailRecord> changed;

  /// Slots left unlinked because multiple candidate parents matched.
  final List<AmbiguousMatch> ambiguities;

  const InheritanceResolution(this.changed, this.ambiguities);

  bool get isEmpty => changed.isEmpty && ambiguities.isEmpty;
}
