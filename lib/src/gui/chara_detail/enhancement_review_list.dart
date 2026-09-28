// The list of pending enhancement candidates the user walks through, folded into the settings
// "resolve inheritance" button, whose Confirm runs the resolution after the merges.
//
// The list holds no claim of its own. Every row's Merge watches the same long-read question the
// settings tile does, so a capture, an import or the reload barrier of the merge started one row
// above disables all of them at once.
import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/enhancement_merge.dart';
import '/src/chara_detail/factor_enhancement.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/enhancement_merge_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';

// ignore: constant_identifier_names
const tr_review = "pages.settings.about.resolve_inheritance.review";

/// Shows the pending-candidate list.
///
/// [onConfirm] is the step the caller runs once the user is done with the list, and its presence
/// decides the buttons: with one, the list offers Cancel and Confirm, and only Confirm runs it;
/// without one, the list offers a single Close. Closing never runs anything - every merge done in
/// the list is already committed when its own dialog closes, so leaving the list loses nothing.
/// [onConfirm] is evaluated when it is pressed, not when the list opened: a merge done inside the
/// list is exactly the thing that can be holding the store by then.
///
/// The list has no title-bar cross and refuses the barrier, so each way out is a labelled button.
///
/// [capturedRecordId] is the record the capture card opened this list for; see
/// [EnhancementReviewList.capturedRecordId]. The settings tile has none.
void showEnhancementReviewList(RefBase ref, {void Function()? onConfirm, String? capturedRecordId}) {
  late final int token;
  token = CardDialog.show(
    ref,
    (_) => EnhancementReviewList(onConfirm: onConfirm, token: token, capturedRecordId: capturedRecordId),
    barrierDismissible: false,
  );
}

class EnhancementReviewList extends ConsumerStatefulWidget {
  const EnhancementReviewList({super.key, this.onConfirm, this.token, this.capturedRecordId});

  /// What Confirm runs after closing the list, or null for a list that only offers Close.
  final void Function()? onConfirm;

  /// The dialog token, so the bottom buttons shut this list and not a dialog opened over it.
  final int? token;

  /// The record that was just captured, when the capture card opened this list, and null otherwise.
  ///
  /// A record the app captured a moment ago carries no memo and no rating of its own, so a pair it
  /// belongs to keeps the *other* side's - the capture-card route - while every other pair in the
  /// list takes the settings route's default. The list is shown for the whole pending set, so this
  /// is a property of the row and not of the list, and it has to be decided per row from the pair's
  /// own ids rather than from which surface happened to open the list.
  final String? capturedRecordId;

  @override
  ConsumerState<EnhancementReviewList> createState() => _EnhancementReviewListState();
}

class _EnhancementReviewListState extends ConsumerState<EnhancementReviewList> {
  /// The refusal note that stays on a row until the list is re-derived.
  ///
  /// On the row and not only in the toast: a toast scrolls away while the user is still reading
  /// which folder it named, and the refusal's whole value is the folder and the remedy.
  final _notes = <RecordIdPair, EnhancementMergeResult>{};

  /// The record [id] names and the store it lives in, which is where its trainee icon is read from.
  (CharaDetailRecord, RecordSource)? _recordOf(List<(CharaDetailRecord, RecordSource)> records, String id) =>
      records.firstWhereOrNull((e) => e.$1.id == id);

  _PairSide _sideOf(List<(CharaDetailRecord, RecordSource)> records, String id) {
    final found = _recordOf(records, id);
    if (found == null) {
      return _PairSide(label: id, iconPath: null);
    }
    final (record, source) = found;
    final dir = recordDirOf(ref.watch(pathInfoProvider), source, record);
    return _PairSide(label: record.evaluationValueLabel, iconPath: traineeIconPathIn(dir));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = ref.watch(pendingEnhancementCandidatesProvider);
    final active = ref.watch(charaDetailRecordStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
    final archive = ref.watch(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
    final records = [
      for (final record in active) (record, RecordSource.active),
      for (final record in archive) (record, RecordSource.archive),
    ];
    final enhanced = candidates.where((e) => !e.identical).toList();
    final identical = candidates.where((e) => e.identical).toList();
    final blocker = enhancementMergeBlockedBy(ref);
    // One flat list with two headings rather than two lists: the rows scroll together, so the last
    // row of the second section is reachable with the same drag as the first section's.
    final rows = <Widget>[
      if (enhanced.isNotEmpty)
        _Heading(text: "$tr_review.section_enhanced".tr(namedArgs: {"count": "${enhanced.length}"})),
      for (final candidate in enhanced) _row(candidate, records, blocker, candidates),
      if (identical.isNotEmpty)
        _Heading(text: "$tr_review.section_identical".tr(namedArgs: {"count": "${identical.length}"})),
      for (final candidate in identical) _row(candidate, records, blocker, candidates),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
      child: CardDialog(
        dialogTitle: "$tr_review.title".tr(),
        usePageView: false,
        content: Expanded(
          child: rows.isEmpty
              ? Center(child: Text("$tr_review.empty".tr(), style: theme.textTheme.bodyMedium))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Outside the list, so it stays in view while the rows scroll.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        "$tr_review.intro".tr(),
                        key: const Key('enhancement_review_intro'),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(itemCount: rows.length, itemBuilder: (context, index) => rows[index]),
                    ),
                  ],
                ),
        ),
        bottom: Row(mainAxisAlignment: MainAxisAlignment.end, children: _buttons()),
      ),
    );
  }

  void _close() => CardDialog.dismiss(ref.base, widget.token);

  List<Widget> _buttons() {
    final onConfirm = widget.onConfirm;
    if (onConfirm == null) {
      return [
        FilledButton.icon(
          key: const Key('enhancement_review_close'),
          icon: const Icon(Symbols.close_rounded),
          label: Text("$tr_review.close".tr()),
          onPressed: _close,
        ),
      ];
    }
    return [
      OutlinedButton.icon(
        key: const Key('enhancement_review_cancel'),
        icon: const Icon(Symbols.cancel_rounded),
        label: Text("$tr_review.cancel".tr()),
        onPressed: _close,
      ),
      const SizedBox(width: 8),
      FilledButton.icon(
        key: const Key('enhancement_review_confirm'),
        icon: const Icon(Symbols.check_circle_rounded),
        label: Text("$tr_review.confirm".tr()),
        onPressed: () {
          _close();
          onConfirm();
        },
      ),
    ];
  }

  Widget _row(
    EnhancementCandidate candidate,
    List<(CharaDetailRecord, RecordSource)> records,
    LongReadKind? blocker,
    List<EnhancementCandidate> all,
  ) {
    final others = all.where((e) => e.pair != candidate.pair && _shares(e, candidate)).length;
    final note = _notes[candidate.pair];
    return _ReviewRow(
      key: Key('enhancement_review_${candidate.pair.first}_${candidate.pair.second}'),
      candidate: candidate,
      older: _sideOf(records, candidate.olderId),
      newer: _sideOf(records, candidate.newerId),
      others: others,
      note: note,
      blocked: blocker != null,
      onMerge: () => showEnhancementMergeDialog(
        ref.base,
        candidate: candidate,
        route: _routeFor(candidate),
        over: true,
        onResult: (result) => setState(() {
          if (result.outcome == EnhancementMergeOutcome.merged) {
            _notes.remove(candidate.pair);
          } else {
            _notes[candidate.pair] = result;
          }
        }),
      ),
      onRescan: () {
        ref.invalidate(charaDetailRecordStorageLoaderProvider);
        ref.invalidate(charaDetailArchiveStorageLoaderProvider);
        setState(() => _notes.remove(candidate.pair));
      },
    );
  }

  /// Which set of memo/rating defaults [candidate] opens with; see
  /// [EnhancementReviewList.capturedRecordId].
  EnhancementMergeRoute _routeFor(EnhancementCandidate candidate) {
    final captured = widget.capturedRecordId;
    final involved = captured != null && (candidate.olderId == captured || candidate.newerId == captured);
    return involved ? EnhancementMergeRoute.captureCard : EnhancementMergeRoute.settings;
  }

  /// Whether [other] involves either record of [candidate] - the "N other candidates involve this
  /// record" count, which is what tells the user a chain is being worked through one link at a time.
  bool _shares(EnhancementCandidate other, EnhancementCandidate candidate) {
    return {other.pair.first, other.pair.second}.intersection({candidate.pair.first, candidate.pair.second}).isNotEmpty;
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

/// One record of a row's pair as the list shows it: its chara icon and its evaluation value.
class _PairSide {
  const _PairSide({required this.label, required this.iconPath});

  /// The evaluation value, or the record ID when the record is not in either store.
  final String label;

  /// Null when the record is not in either store, so there is no folder to read an icon from.
  final FilePath? iconPath;
}

class _PairSideView extends StatelessWidget {
  const _PairSideView({required this.side, required this.sideKey});

  final _PairSide side;
  final String sideKey;

  @override
  Widget build(BuildContext context) {
    final iconPath = side.iconPath;
    return Row(
      key: Key('enhancement_review_side_$sideKey'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 40, height: 40, child: iconPath == null ? null : TraineeIcon(iconPath, placeholderSize: 40)),
        const SizedBox(width: 8),
        Text(side.label, style: Theme.of(context).textTheme.titleSmall),
      ],
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    super.key,
    required this.candidate,
    required this.older,
    required this.newer,
    required this.others,
    required this.note,
    required this.blocked,
    required this.onMerge,
    required this.onRescan,
  });

  final EnhancementCandidate candidate;
  final _PairSide older;
  final _PairSide newer;
  final int others;
  final EnhancementMergeResult? note;
  final bool blocked;
  final VoidCallback onMerge;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = note;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _PairSideView(side: older, sideKey: 'older'),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text("/", style: theme.textTheme.titleSmall),
                          ),
                          _PairSideView(side: newer, sideKey: 'newer'),
                        ],
                      ),
                      if (others > 0)
                        Text(
                          "$tr_review.other_candidates".tr(namedArgs: {"count": "$others"}),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                Tooltip(
                  message: blocked ? longReadBusyKey.tr() : "",
                  child: FilledButton.tonalIcon(
                    key: Key('enhancement_review_merge_${candidate.pair.first}_${candidate.pair.second}'),
                    icon: const Icon(Symbols.merge_rounded),
                    label: Text("$tr_review.merge".tr()),
                    onPressed: blocked ? null : onMerge,
                  ),
                ),
              ],
            ),
            if (result != null) _RefusalNote(result: result, onRescan: onRescan),
          ],
        ),
      ),
    );
  }
}

/// What one refusal left on the row: its sentence, and the rescan when an incomplete store view is
/// what refused.
class _RefusalNote extends StatelessWidget {
  const _RefusalNote({required this.result, required this.onRescan});

  final EnhancementMergeResult result;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            enhancementMergeOutcomeKey(result.outcome).tr(),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
          if (result.outcome == EnhancementMergeOutcome.refusedStoreIncomplete)
            TextButton.icon(
              key: const Key('enhancement_review_rescan'),
              icon: const Icon(Symbols.refresh_rounded),
              label: Text("$tr_review.rescan".tr()),
              onPressed: onRescan,
            ),
        ],
      ),
    );
  }
}
