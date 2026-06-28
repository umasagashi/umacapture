import '/src/chara_detail/chara_detail_record.dart';

/// Resolves parent/child inheritance links between captured records, and (when
/// race-grade data is supplied) recomputes each record's graded-race relation
/// bonus from the resolved lineage.
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
///
/// ## Relation bonus
///
/// When [resolveAll] / [resolveForNewRecord] are given the set of G1 race title
/// sids, they also write [Metadata.relationBonus] with the game's graded-race
/// compatibility bonus computed over the resolved lineage (see [relationBonus]).
/// This is the *graded-race* portion of in-game compatibility only — the fixed
/// character-affinity term is not derivable (its table is not shipped with the
/// app), so the stored value is not the full on-screen compatibility number.
/// Because it depends on linked ancestors' race data, an unlinked or
/// not-yet-captured ancestor simply contributes nothing; the value can grow as
/// more of the lineage is captured, so the authoritative figure is the one left
/// by a manual full [resolveAll]. (Re-recognizing a record resets the field to
/// null on the native side; the next resolution pass recomputes it.)
class InheritanceResolver {
  const InheritanceResolver._();

  /// Sentinel for [_rebuild] meaning "leave relationBonus unchanged", so the
  /// field can be set to a new value (including null) when a real one is passed.
  static const Object _keepBonus = Object();

  /// Authoritatively recomputes every record's parent links across [records].
  ///
  /// This is idempotent: it both sets newly-resolvable links and clears links
  /// that no longer resolve (or became ambiguous). Use it for the manual,
  /// whole-storage re-resolution. Returns only the records whose links changed.
  ///
  /// When [g1RaceSids] is non-empty, each record's [Metadata.relationBonus] is
  /// also recomputed from the freshly resolved lineage, and a record whose bonus
  /// changed is returned even if its links did not. An empty set (the default)
  /// leaves the bonus untouched, preserving the link-only behaviour.
  static InheritanceResolution resolveAll(List<CharaDetailRecord> records, {Set<int> g1RaceSids = const {}}) {
    final index = _selfKeyIndex(records);
    final ambiguities = <AmbiguousMatch>[];

    // Phase 1: resolve every record's parent links.
    final resolvedLinks = <String, _Links>{};
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

      resolvedLinks[child.id] = (parent1: resolved(1), parent2: resolved(2));
    }

    // Phase 2: build a record-by-id map with the resolved links applied so the
    // bonus lookups (which walk two generations of parent ids) see the new
    // lineage, then emit any record whose links or bonus changed.
    final byId = <String, CharaDetailRecord>{};
    for (final record in records) {
      final links = resolvedLinks[record.id]!;
      byId[record.id] = _rebuild(record, parent1: links.parent1, parent2: links.parent2);
    }

    final changed = <CharaDetailRecord>[];
    for (final record in records) {
      final withLinks = byId[record.id]!;
      final newBonus = g1RaceSids.isEmpty ? record.metadata.relationBonus : relationBonus(withLinks, byId, g1RaceSids);
      _appendIfChanged(changed, record, withLinks, newBonus);
    }
    return InheritanceResolution(changed, ambiguities);
  }

  /// Resolves links touched by a newly captured [newRecord] against [existing].
  ///
  /// This is additive and narrow for links: it only sets [newRecord]'s own
  /// parents and fills [existing] children's slots that [newRecord] uniquely
  /// satisfies. It never clears or re-evaluates unrelated links. [existing] must
  /// not contain [newRecord].
  ///
  /// When [g1RaceSids] is non-empty, [Metadata.relationBonus] is also recomputed
  /// for [newRecord] and for every stored record whose lineage now reaches
  /// [newRecord] (its newly-linked children, and their children — [newRecord]'s
  /// grandchildren — which gain it as a grandparent without their own links
  /// changing). The rescan is O([existing]), matching the duplicate scan the
  /// caller already runs per capture.
  ///
  /// The returned [InheritanceResolution.changed] holds the updated [newRecord]
  /// (when it gained parents or a bonus) and any updated descendants, each
  /// identifiable by its [CharaDetailRecord.id].
  static InheritanceResolution resolveForNewRecord(
    CharaDetailRecord newRecord,
    List<CharaDetailRecord> existing, {
    Set<int> g1RaceSids = const {},
  }) {
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

    // Direction B: treat newRecord as a parent and find existing children,
    // collecting their new parent links (applied to byId below).
    final newSelfKey = _selfKey(newRecord);
    final sameSelf = index[newSelfKey] ?? const <CharaDetailRecord>[];
    final childLinks = <String, _Links>{};
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
        final current =
            childLinks[child.id] ??
            (parent1: child.metadata.recordId.parent1, parent2: child.metadata.recordId.parent2);
        if ((slot == 1 ? current.parent1 : current.parent2) == newRecord.id) {
          continue;
        }
        childLinks[child.id] = (
          parent1: slot == 1 ? newRecord.id : current.parent1,
          parent2: slot == 2 ? newRecord.id : current.parent2,
        );
      }
    }

    // Build a record-by-id map with all resolved links applied, so relation-bonus
    // lookups see the new lineage (newRecord's parents and the children's new
    // parent that turns newRecord into a grandparent).
    final updatedNewRecord = _rebuild(newRecord, parent1: parent1, parent2: parent2);
    final byId = <String, CharaDetailRecord>{updatedNewRecord.id: updatedNewRecord};
    for (final record in existing) {
      final links = childLinks[record.id];
      byId[record.id] = links == null ? record : _rebuild(record, parent1: links.parent1, parent2: links.parent2);
    }

    // Emit newRecord and every record whose links or bonus changed. Links change
    // only for newRecord and Direction-B children; the bonus can also change for
    // grandchildren that now reach newRecord, so it is rescanned across existing.
    final changed = <CharaDetailRecord>[];
    void consider(CharaDetailRecord original) {
      final withLinks = byId[original.id]!;
      final newBonus = g1RaceSids.isEmpty
          ? original.metadata.relationBonus
          : relationBonus(withLinks, byId, g1RaceSids);
      _appendIfChanged(changed, original, withLinks, newBonus);
    }

    consider(newRecord);
    for (final record in existing) {
      consider(record);
    }
    return InheritanceResolution(changed, ambiguities);
  }

  /// The graded-race (G1) relation bonus for [record] over its resolved lineage.
  ///
  /// Implements the in-game graded-race compatibility term:
  /// `bonus = (A + B + C + D + E) * 3`, where each of the five pair terms is the
  /// number of distinct G1 races *both* members of the pair won. The pairs are
  /// parent1×parent2, parent1×each-of-its-parents, and parent2×each-of-its-parents
  /// (the trainee itself is not a member of any pair). Ancestors are looked up in
  /// [byId] via the parent record-id links; a missing/unlinked ancestor drops its
  /// pair to zero. A race title counts once regardless of how many times it was
  /// won, and only titles in [g1RaceSids] (the G1 grade set) are considered.
  ///
  /// Returns null when [record] has no linked parent at all (lineage unknown);
  /// otherwise an integer (which may be 0 when nothing is shared). Same-character
  /// pairs are intentionally not excluded — the current game rule scores them too,
  /// and this computation is purely race-based.
  static int? relationBonus(CharaDetailRecord record, Map<String, CharaDetailRecord> byId, Set<int> g1RaceSids) {
    final parent1 = _linked(record.metadata.recordId.parent1, byId);
    final parent2 = _linked(record.metadata.recordId.parent2, byId);
    if (parent1 == null && parent2 == null) {
      return null;
    }
    final grandparent11 = parent1 == null ? null : _linked(parent1.metadata.recordId.parent1, byId);
    final grandparent12 = parent1 == null ? null : _linked(parent1.metadata.recordId.parent2, byId);
    final grandparent21 = parent2 == null ? null : _linked(parent2.metadata.recordId.parent1, byId);
    final grandparent22 = parent2 == null ? null : _linked(parent2.metadata.recordId.parent2, byId);
    final pairs =
        _sharedG1Wins(parent1, parent2, g1RaceSids) +
        _sharedG1Wins(parent1, grandparent11, g1RaceSids) +
        _sharedG1Wins(parent1, grandparent12, g1RaceSids) +
        _sharedG1Wins(parent2, grandparent21, g1RaceSids) +
        _sharedG1Wins(parent2, grandparent22, g1RaceSids);
    return pairs * 3;
  }

  static CharaDetailRecord? _linked(String? id, Map<String, CharaDetailRecord> byId) {
    return id == null ? null : byId[id];
  }

  /// Count of distinct G1 race titles both [a] and [b] won; 0 if either is null.
  static int _sharedG1Wins(CharaDetailRecord? a, CharaDetailRecord? b, Set<int> g1RaceSids) {
    if (a == null || b == null) {
      return 0;
    }
    final winsA = _g1WinTitles(a, g1RaceSids);
    if (winsA.isEmpty) {
      return 0;
    }
    return winsA.intersection(_g1WinTitles(b, g1RaceSids)).length;
  }

  static Set<int> _g1WinTitles(CharaDetailRecord record, Set<int> g1RaceSids) {
    return {
      for (final race in record.races)
        if (race.won && g1RaceSids.contains(race.title)) race.title,
    };
  }

  /// Appends to [changed] the final form of [original] (its [updatedLinks] plus
  /// [newBonus]) when either its parent links or its relation bonus differ.
  static void _appendIfChanged(
    List<CharaDetailRecord> changed,
    CharaDetailRecord original,
    CharaDetailRecord updatedLinks,
    int? newBonus,
  ) {
    final linksChanged =
        updatedLinks.metadata.recordId.parent1 != original.metadata.recordId.parent1 ||
        updatedLinks.metadata.recordId.parent2 != original.metadata.recordId.parent2;
    final bonusChanged = newBonus != original.metadata.relationBonus;
    if (!linksChanged && !bonusChanged) {
      return;
    }
    changed.add(
      _rebuild(
        original,
        parent1: updatedLinks.metadata.recordId.parent1,
        parent2: updatedLinks.metadata.recordId.parent2,
        relationBonus: newBonus,
      ),
    );
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

  /// Returns a copy of [record] with its parent record-id slots replaced, and
  /// optionally its [Metadata.relationBonus] (left untouched unless a value,
  /// including null, is passed).
  ///
  /// The models opt out of generated `copyWith` (build.yaml limits dart_mappable
  /// to decode/encode), so the record is rebuilt through its constructors.
  static CharaDetailRecord _rebuild(
    CharaDetailRecord record, {
    required String? parent1,
    required String? parent2,
    Object? relationBonus = _keepBonus,
  }) {
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
      identical(relationBonus, _keepBonus) ? metadata.relationBonus : relationBonus as int?,
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

/// Resolved parent record-id slots for a single record.
typedef _Links = ({String? parent1, String? parent2});

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
  /// Records whose parent links or relation bonus changed, in their updated form.
  final List<CharaDetailRecord> changed;

  /// Slots left unlinked because multiple candidate parents matched.
  final List<AmbiguousMatch> ambiguities;

  const InheritanceResolution(this.changed, this.ambiguities);

  bool get isEmpty => changed.isEmpty && ambiguities.isEmpty;
}
