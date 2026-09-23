// A store outage's two sentences must not swap remedies.
//
// `_StoreOutageBanner` picks between `<key>.busy` and `<key>.blocked` on one
// bit: `RecordStoreUnavailable.transient`, which is true for exactly one cause
// — `RecordMutationLockBusy`, i.e. an operation of this app is holding the lock
// right now. Everything else is `blocked`. So "an operation is still running" is
// the *busy* branch's explanation, the records are still on disk, and the remedy
// is to wait for it. The blocked branch has neither: its cause is not going to
// finish on its own, so prescribing the wait there would be advice for a cause it
// has already ruled out, and the one branch where retrying unchanged reproduces
// the same failure. What it can actually offer is its own action button — the
// startup banner's retry re-runs the interrupted recovery, the store banner's
// rescan re-lists the store — which is what those sentences say.
//
// The pairs are discovered by walking the shipped locale files rather than
// listed here, so a fourth busy/blocked pair added later is held to the same
// rule without anyone remembering to add it.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/store_outage_remedy_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'support/localization.dart';

/// The two phrases only a transient outage may carry. Kept as constants because
/// the test asserts each on both sides: present in every `busy` sentence, absent
/// from every `blocked` one. A marker only checked for absence goes stale
/// silently — reword the busy sentences and it would pass by matching nothing at
/// all.
///
/// [_transientCause] is the cause the busy branch states — something is still
/// running, which is why waiting is the remedy. [_transientReassurance] is what
/// only that branch may promise: the records are still on disk. Two markers
/// rather than one because either alone is satisfiable by a sentence that has
/// lost the other half of the statement.
const _transientCause = '実行中';
const _transientReassurance = '記録は失われていません';

/// Every `{busy, blocked}` pair in [json], as dotted keys to their parent.
List<String> _outagePairs(Map<String, dynamic> json) {
  final found = <String>[];
  void walk(Map<String, dynamic> node, String path) {
    if (node['busy'] is String && node['blocked'] is String) found.add(path);
    for (final entry in node.entries) {
      final child = entry.value;
      if (child is Map<String, dynamic>) walk(child, path.isEmpty ? entry.key : '$path.${entry.key}');
    }
  }

  walk(json, '');
  return found;
}

void main() {
  test('every shipped locale states a blocked outage without the busy branch remedy', () {
    final locales = appLocaleFiles();
    expect(locales, isNotEmpty, reason: 'the locale scan found no files to check');

    for (final locale in locales) {
      final json = localeJson(locale);
      final pairs = _outagePairs(json);
      // A floor, not the list under test: the rule below applies to whatever the
      // walk finds, and this only stops a walk that found nothing from passing
      // by vacuum. These three are the pairs `_StoreOutageBanner` renders today.
      expect(
        pairs,
        containsAll(<String>[
          'app.record_store_startup',
          'pages.chara_detail.store_outage',
          'pages.chara_detail.store_outage.archive',
        ]),
        reason: '$locale: the walk did not reach the pairs the outage banner renders',
      );

      for (final pair in pairs) {
        // Read out of this locale's own map rather than through the ja-only
        // helper, so a second locale file is really checked against itself.
        final sentences = mapAt(json, pair);
        final busy = sentences?['busy'] as String? ?? '';
        final blocked = sentences?['blocked'] as String? ?? '';
        for (final marker in const [_transientCause, _transientReassurance]) {
          expect(
            busy,
            contains(marker),
            reason:
                '$locale: "$pair.busy" is the branch whose cause is an operation still running; '
                'if it no longer says so, this test can no longer tell the two apart',
          );
          expect(
            blocked,
            isNot(contains(marker)),
            reason:
                '$locale: "$pair.blocked" is reached only when the cause is not a busy lock, '
                'so it must not prescribe the busy branch remedy',
          );
        }
      }
    }
  });
}
