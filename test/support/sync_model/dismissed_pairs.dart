// What one side of a round — the device, the server — says of a dismissed pair of the records the round's result
// holds ([R4-4], [R4-7]). The model (`file_core.dart`) and the judge (`judge.dart`) both call it: each reads the
// round in its own terms (what an id is in the result, what the side holds, what it lists), and this is the one
// reading of v7 they share.

/// A record of a side: its id, and the ids it absorbed.
typedef SideRecord = ({String id, Set<String> absorbed});

/// What a side says of the pairs of the base, read as pairs of the result's records: [none] the readings it says
/// are taken out, [asBase] the readings it says nothing of — of them it says what the base does ([R4-4]).
typedef SideSays = ({Set<String> none, Set<String> asBase});

/// Of the pairs of the base [agreed], what the side whose records are [records], and whose own pairs read as pairs
/// of the result's records are [said], says of each reading; where it speaks of none, its own pairs say whether
/// the pair is there.
///
/// An end names a record ([R4-7]). The side's records of an id are its record of that id and each of its own that
/// absorbed it; in the result, an id is the record of that id, else each that absorbed it ([ends], [R4-7] 2), and
/// so is a record of the side, but where [self] says where else it goes (the device's record split off: [R4-7] 1,
/// 4). A pair a+b of the base is gone from the side where the side holds a and b in records of its own apart, and
/// lists no pair those records make — none of them by their own ids ([lists]), none of them read as pairs of the
/// result's records ([said]) — no form its own records give the pair. Nothing but its user's hand on its list
/// (the file deleted, a record deleted and not back with its pairs — [R2-6] (b), [R4-1]) leaves it so: a merge
/// of its own re-keys a pair to the survivor, which its records still give (S-04), and a pair of its own that
/// names an id the result holds no record of is dropped by the round ([R4-7] 3), not taken out by its user. Of a
/// pair that is gone, the side says "none" of every reading of it — each pair of the records that hold a and
/// that hold b in the result: what its own records of the id are there, and each record of the result that
/// absorbed the id ([absorbers]), the other device's merge or split of a record of the side's — its user took
/// a+b out, whatever record holds either end. Not the result's record of the id where the side's own is split
/// off it, which the side never held ([R4-4]); and not a reading it lists itself. A pair it still lists in some
/// form, or holds no two records of, it says nothing of: its "none" is then the absence of a record, a merge of
/// its own, or a re-keying to one survivor, not a pair taken out.
///
/// [asBase] holds the readings of the base's pairs as [ends] gives them, less what the side says "none" of; the
/// caller reads the base the same way, and adds to that reading what either side says "none" of.
///
/// [holds], where given, replaces the test of holding the two records apart, reads the pair as gone whatever the
/// side lists, and reads an id as the result's record of it too, whatever record of its own the side holds of it
/// (the model's mutations); [heldReadingsOnly] has the side say "none" only of the readings it holds — a in a
/// record of its own that is x in the result and b in another that is y; [heldWins] false reads each pair of the
/// base apart, so that one the side does not hold silences what it holds of another read the same;
/// [ownListed] false reads a pair the side lists by its own records' ids as one it does not list.
SideSays sideSays(
  Iterable<String> agreed,
  Iterable<SideRecord> records, {
  required Set<String> Function(String id) ends,
  required Set<String> Function(String id) absorbers,
  required Set<String> said,
  required Set<String> lists,
  Set<String> Function(String id)? self,
  bool Function(Set<String> a, Set<String> b)? holds,
  bool heldReadingsOnly = false,
  bool heldWins = true,
  bool ownListed = true,
}) {
  final list = records.toList();
  Set<String> holders(String id) => {
    for (final r in list)
      if (r.id == id || r.absorbed.contains(id)) r.id,
  };
  final isIn = self ?? ends;
  // The records of the result that hold [id] as the side holds it.
  Set<String> holding(String id) => {
    for (final i in holders(id)) ...isIn(i),
    ...absorbers(id),
    if (holds != null) ...ends(id),
  };
  bool apart(Set<String> a, Set<String> b) => a.any((i) => b.any((j) => j != i));
  bool heldReading(Set<String> a, Set<String> b, String x, String y) =>
      a.any((i) => isIn(i).contains(x) && b.any((j) => j != i && isIn(j).contains(y))) ||
      a.any((i) => isIn(i).contains(y) && b.any((j) => j != i && isIn(j).contains(x)));
  final read = <String>{}, spoken = <String>{}, unspoken = <String>{};
  for (final pair in agreed) {
    if (pair.split('+') case [final a, final b]) {
      final ha = holders(a), hb = holders(b);
      // The pair as the side's own records give it in the result.
      final forms = <String>{
        for (final i in ha)
          for (final j in hb)
            if (i != j)
              for (final x in isIn(i))
                for (final y in isIn(j))
                  if (x != y) _pairOf(x, y),
      };
      // The pair as the side's own records give it by their ids.
      final own = <String>{
        for (final i in ha)
          for (final j in hb)
            if (i != j) _pairOf(i, j),
      };
      final gone =
          (holds ?? apart)(ha, hb) &&
          (holds != null || !(forms.any(said.contains) || (ownListed && own.any(lists.contains))));
      for (final x in ends(a)) {
        for (final y in ends(b)) {
          if (x != y) read.add(_pairOf(x, y));
        }
      }
      for (final x in holding(a)) {
        for (final y in holding(b)) {
          if (x == y) continue;
          final p = _pairOf(x, y);
          (gone && !said.contains(p) && (!heldReadingsOnly || heldReading(ha, hb, x, y)) ? spoken : unspoken).add(p);
        }
      }
    }
  }
  final asBase = heldWins ? read.difference(spoken) : read.intersection(unspoken);
  return (none: spoken, asBase: asBase);
}

String _pairOf(String a, String b) => ([a, b]..sort()).join('+');
