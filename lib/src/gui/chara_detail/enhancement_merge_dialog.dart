// The merge-approval surface for factor-enhancement candidates.
//
// The dialog is the only place a merge is started from, so it is also the only place that has to
// know what a merge can answer: every outcome of [EnhancementMergeOutcome] is turned into a
// sentence here, and the refusal that names directories carries them to the row that opened it.
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/enhancement_merge.dart';
import '/src/chara_detail/factor_enhancement.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/preview_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/hold_to_confirm_button.dart';
import '/src/gui/record_image.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_merge = "pages.chara_detail.enhancement_merge";

typedef EnhancementMergeActions = ({
  Future<EnhancementMergeResult> Function(
    EnhancementCandidate candidate, {
    String? keptContentId,
    EnhancementMergeChoices choices,
  })
  merge,
  Future<bool> Function(EnhancementCandidate candidate) dismiss,
  Future<void> Function() resolveInheritance,
  Future<MergedIds?> Function(String recordId) readMerged,
});

final enhancementMergeActionsProvider = Provider<EnhancementMergeActions>((ref) {
  return (
    merge: (candidate, {keptContentId, choices = const EnhancementMergeChoices()}) =>
        ref.read(enhancementMergeProvider).merge(candidate, keptContentId: keptContentId, choices: choices),
    dismiss: (candidate) => ref.read(enhancementDismissalStoreProvider).dismiss(candidate),
    resolveInheritance: () => ref.read(charaDetailRecordStorageLoaderProvider.notifier).resolveAllInheritance(),
    readMerged: (recordId) async {
      final directory = recordDirectoryOf(ref, recordId);
      return directory == null ? (ids: const <String>[], metadataDefaults: null) : await readMergedIds(directory);
    },
  );
});

/// Where [recordId]'s directory is, or null when no store holds it.
///
/// Both stores are asked in the order the merge itself asks them, so a record that moved to the
/// archive is found where it now is rather than where it was captured.
DirectoryPath? recordDirectoryOf(Ref ref, String recordId) {
  for (final store in <CharaDetailRecordMergeSurface>[
    ref.read(charaDetailRecordStorageLoaderProvider.notifier),
    ref.read(charaDetailArchiveStorageLoaderProvider.notifier),
  ]) {
    if (store.getBy(id: recordId) != null) {
      return store.rootDirectory / recordId;
    }
  }
  return null;
}

/// The claim that makes a merge action inert, or null when none does.
///
/// The same question the inheritance tile asks, about the same path: a capture, a video import, an
/// archive, a resolution and another merge all claim the record store root, so one containment test
/// covers every one of them and a kind added later is covered without an edit here.
LongReadKind? enhancementMergeBlockedBy(WidgetRef ref) {
  final layout = ref.watch(pathLayoutProvider);
  final claims = ref.watch(longReadRegistryProvider).values;
  return storageDeleteBlockedBy(layout == null ? null : StorageDeletePathsRequest([layout.charaDetailDir]), claims);
}

/// The **full** translation key for [outcome]'s toast sentence.
///
/// Exhaustive and explicit rather than `outcome.name`, for the reason every other blocker table in
/// this app gives: easy_localization renders a key it cannot find as the key itself, so a typo
/// ships `app.` into a toast instead of failing anywhere.
String enhancementMergeOutcomeKey(EnhancementMergeOutcome outcome) => switch (outcome) {
  EnhancementMergeOutcome.merged => "app.enhancement_merge.merged",
  EnhancementMergeOutcome.refusedBusy => "app.enhancement_merge.refused_busy",
  EnhancementMergeOutcome.refusedStoreRecovered => "app.enhancement_merge.refused_store_recovered",
  EnhancementMergeOutcome.refusedStoreIncomplete => "app.enhancement_merge.refused_store_incomplete",
  EnhancementMergeOutcome.refusedMissing => "app.enhancement_merge.refused_missing",
  EnhancementMergeOutcome.refusedUnsupportedId => "app.enhancement_merge.refused_unsupported_id",
  EnhancementMergeOutcome.refusedStorageUnreadable => "app.enhancement_merge.refused_storage_unreadable",
  EnhancementMergeOutcome.refusedRetiredContent => "app.enhancement_merge.refused_retired_content",
  EnhancementMergeOutcome.failedPublish => "app.enhancement_merge.failed_publish",
  EnhancementMergeOutcome.failed => "app.enhancement_merge.failed",
  EnhancementMergeOutcome.failedDelete => "app.enhancement_merge.failed_delete",
};

/// Shows the merge dialog for [candidate] and hands its result to [onResult].
///
/// The barrier never dismisses it, so a stray tap outside cannot drop a typed memo or rating. The
/// title-bar cross and the labelled Cancel both close it and perform nothing.
///
/// [onResult] is null for the capture card, whose notice disappears on its own once the candidate
/// list re-derives; the review list passes one so a refusal can leave its note on the row.
void showEnhancementMergeDialog(
  RefBase ref, {
  required EnhancementCandidate candidate,
  required EnhancementMergeRoute route,
  void Function(EnhancementMergeResult result)? onResult,
  bool over = false,
}) {
  CardDialog.show(
    ref,
    (_) => EnhancementMergeDialog(candidate: candidate, route: route, onResult: onResult),
    barrierDismissible: false,
    over: over,
  );
}

/// One side of the pair, as the dialog renders it.
class _Side {
  _Side(this.record, this.source, this.split);

  final CharaDetailRecord record;

  /// The store the record was found in, which is what its directory is derived from.
  final RecordSource source;
  final SplitFactors? split;

  String get id => record.id;
}

/// One self factor as a record column lists it.
typedef _FactorEntry = ({int id, int star, bool highlighted});

/// Which value a memo or rating row keeps: one side's, or what the user types.
enum EnhancementMergePick { older, newer, free }

/// Which card is selected: the record whose content the merge keeps, or none, which confirms as
/// "not the same uma". The record ID kept is the older one whichever card is selected.
enum EnhancementMergeSelection { none, older, newer }

/// What a completed hold on the bottom button does.
enum EnhancementMergeAction { merge, dismiss }

/// What a completed hold would run for [selection], or null while it cannot run.
///
/// A selected card merges: it waits for every long read on the store ([blocked]), for the marker
/// ([unfinished] non-null), and for a rating field that holds a rating ([ratingInvalid]). No
/// selection dismisses the pair: that writes only its own file, so none of those concern it, and it
/// is refused for an unfinished merge, a marker still being read counting as one. The dialog also
/// disables the deselect toggle in that state; this refusal is what holds at the action itself.
EnhancementMergeAction? enhancementMergeConfirmAction({
  required EnhancementMergeSelection selection,
  required bool running,
  required bool? unfinished,
  required bool blocked,
  required bool ratingInvalid,
}) => switch (selection) {
  _ when running => null,
  EnhancementMergeSelection.none => unfinished != false ? null : EnhancementMergeAction.dismiss,
  _ => blocked || unfinished == null || ratingInvalid ? null : EnhancementMergeAction.merge,
};

class EnhancementMergeDialog extends ConsumerStatefulWidget {
  const EnhancementMergeDialog({super.key, required this.candidate, required this.route, this.onResult});

  final EnhancementCandidate candidate;
  final EnhancementMergeRoute route;
  final void Function(EnhancementMergeResult result)? onResult;

  @override
  ConsumerState<EnhancementMergeDialog> createState() => _EnhancementMergeDialogState();
}

class _EnhancementMergeDialogState extends ConsumerState<EnhancementMergeDialog> {
  /// Null while the merge marker is still being read; the dialog cannot decide whether this is an
  /// unfinished merge before it lands, and deciding wrongly would offer a content choice that an
  /// already-applied merge has to refuse.
  bool? _unfinished;

  /// The relation the first run of this unfinished merge resolved its memo and rating defaults
  /// from, as its marker records it; null when there is no such run or the marker carries none.
  ///
  /// The merge re-run resolves its defaults from the same relation, so prefilling from it is what
  /// keeps the fields showing the values the merge writes.
  MergedIds? _marker;

  /// The selection the user made, or null while they made none and [_defaultSelection] applies.
  ///
  /// Held apart from the default rather than initialised to it, so a default that depends on the
  /// marker is derived when the marker lands instead of being latched before it.
  EnhancementMergeSelection? _picked;

  final _memo = <String, String?>{};
  final _rating = <String, double?>{};

  /// The pick the user made, per memo and per rating storage key. A key that is absent shows the
  /// pick its resolved value corresponds to, so the radio cannot disagree with what the merge writes.
  final _memoPick = <String, EnhancementMergePick>{};
  final _ratingPick = <String, EnhancementMergePick>{};

  /// The rating storage keys whose field currently holds text that is not a rating.
  ///
  /// The merge waits while this is non-empty. Merging with the last accepted value instead would
  /// write something other than what the field on screen says, and a field the user is still
  /// correcting is exactly when they are reading it.
  final _ratingErrors = <String>{};

  bool _running = false;

  @override
  void initState() {
    super.initState();
    unawaited(_readMarker());
  }

  Future<void> _readMarker() async {
    final merged = await ref.read(enhancementMergeActionsProvider).readMerged(widget.candidate.olderId);
    if (!mounted) {
      return;
    }
    // An unreadable marker counts as "unfinished": the merge itself refuses such a pair
    // (`refusedStorageUnreadable`), and offering the choice for a state nobody could read is the
    // direction that loses content.
    _moveKeptSide(() {
      _unfinished = merged == null || merged.ids.contains(widget.candidate.newerId);
      _marker = merged;
    });
  }

  /// Whether the pair has to be completed with the older record's content and never disowned. A
  /// marker still being read counts as one.
  bool get _fixedToOlder => _unfinished ?? true;

  /// The card selected while the user has selected none: the enhanced side of an enhancement pair,
  /// and the newer record of a pair whose factors are identical.
  EnhancementMergeSelection get _defaultSelection => widget.candidate.enhancedId == widget.candidate.olderId
      ? EnhancementMergeSelection.older
      : EnhancementMergeSelection.newer;

  /// The card that is selected. An unfinished merge only accepts the older record's content, so
  /// its older card is selected whatever was picked.
  EnhancementMergeSelection get _selection =>
      _fixedToOlder ? EnhancementMergeSelection.older : _picked ?? _defaultSelection;

  /// Whether the memo and rating defaults resolve from the older record's content. With no card
  /// selected they are inert, and resolve from the default card.
  bool get _contentFromOlder => switch (_selection) {
    EnhancementMergeSelection.older => true,
    EnhancementMergeSelection.newer => false,
    EnhancementMergeSelection.none => _defaultSelection == EnhancementMergeSelection.older,
  };

  /// Whether [side]'s card accepts the select toggle (`$tr_merge.select`). The pre-enhancement record of an enhancement pair is
  /// never the content to keep, and an unfinished merge is fixed to the older record.
  bool _selectable(EnhancementMergeSelection side) {
    final enhanced = widget.candidate.enhancedId;
    final id = side == EnhancementMergeSelection.older ? widget.candidate.olderId : widget.candidate.newerId;
    return !_running && !_fixedToOlder && (enhanced == null || enhanced == id);
  }

  void _select(EnhancementMergeSelection selection) => _moveKeptSide(() => _picked = selection);

  /// Applies [change] to what decides the kept side - the picked card or the marker's verdict.
  void _moveKeptSide(void Function() change) => setState(() {
    final before = _contentFromOlder;
    change();
    if (_contentFromOlder != before) {
      // The selection re-resolves every field from the newly kept side, so each rating field
      // replaces the text it is showing. A rejection is a statement about that text, so it cannot
      // outlive it - leaving it behind is what would disable the merge over a value the field no
      // longer holds.
      _ratingErrors.clear();
    }
  });

  /// [id]'s record and the store holding it, asked in the order [recordDirectoryOf] asks them.
  _Side? _sideOf(String id, FactorClassifier classifier) {
    final stores = [
      (RecordSource.active, ref.watch(charaDetailRecordStorageLoaderProvider).asData?.value),
      (RecordSource.archive, ref.watch(charaDetailArchiveStorageLoaderProvider).asData?.value),
    ];
    for (final (source, records) in stores) {
      final record = records?.firstWhereOrNull((e) => e.id == id);
      if (record != null) {
        return _Side(record, source, SplitFactors.of(record.factors.self, classifier));
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(factorInfoLoader).asData?.value ?? const <FactorInfo>[];
    final classifier = FactorClassifier.fromInfo(info);
    final olderSide = _sideOf(widget.candidate.olderId, classifier);
    final newerSide = _sideOf(widget.candidate.newerId, classifier);
    if (olderSide == null || newerSide == null) {
      // One of the pair left the store while the dialog was open. There is nothing left to approve.
      return const SizedBox.shrink();
    }
    final pathInfo = ref.watch(pathInfoProvider);
    final identical = widget.candidate.identical;
    final unfinished = _fixedToOlder;
    final blocker = enhancementMergeBlockedBy(ref);
    final selection = _selection;
    // The choices below only shape a merge, so they are inert while no card is selected; their
    // values stay, so selecting a card again finds them as they were.
    final merging = selection != EnhancementMergeSelection.none;
    // The metadata choices are what the running merge was handed; once it holds them, a pick or a
    // keystroke here could only change what is on screen, so there is nothing left to offer.
    final metadataEditable = merging && !_running;
    final olderFactors = _factorDifference(olderSide, newerSide);
    final newerFactors = _factorDifference(newerSide, olderSide);
    final noFactorDifference = (olderFactors?.isEmpty ?? false) && (newerFactors?.isEmpty ?? false);
    // Over, so the merge dialog and the review list beneath it stay open with what was typed.
    void preview(_Side side) =>
        CharaDetailPreviewDialog.show(ref.base, [recordDirOf(pathInfo, side.source, side.record)], 0, over: true);
    Widget card(_Side side, EnhancementMergeSelection value, List<_FactorEntry>? factors, {required bool fillHeight}) {
      final selected = selection == value;
      // Deselecting is the dismissal's way in, which an unfinished merge never offers.
      final canToggle = selected ? !_running && !unfinished : _selectable(value);
      return _RecordCard(
        key: Key('enhancement_merge_card_${side.id}'),
        side: side,
        iconPath: traineeIconPathIn(recordDirOf(pathInfo, side.source, side.record)),
        factors: factors,
        selected: selected,
        fillHeight: fillHeight,
        // Why this card cannot be selected, when that is a property of the pair rather than of the
        // moment: an unfinished merge, or the pre-enhancement side.
        fixedReason: selected || _running
            ? null
            : unfinished
            ? "$tr_merge.content_unfinished".tr()
            : canToggle
            ? null
            : "$tr_merge.content_enhanced".tr(),
        onToggle: canToggle ? () => _select(selected ? EnhancementMergeSelection.none : value) : null,
        onPreview: () => preview(side),
      );
    }

    List<Widget> cards({required bool fillHeight}) => [
      card(olderSide, EnhancementMergeSelection.older, olderFactors, fillHeight: fillHeight),
      card(newerSide, EnhancementMergeSelection.newer, newerFactors, fillHeight: fillHeight),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
      child: CardDialog(
        dialogTitle: (identical ? "$tr_merge.title_identical" : "$tr_merge.title").tr(),
        // The cross means Cancel: it closes and performs nothing. It is shut with Cancel while a
        // merge or dismissal runs, so the dialog stays to report the outcome.
        closeButtonTooltip: "$tr_merge.close_tooltip".tr(),
        closeButtonEnabled: !_running,
        usePageView: false,
        content: Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (unfinished)
                  _Note(key: const Key('enhancement_merge_unfinished'), text: "$tr_merge.unfinished".tr()),
                Text("$tr_merge.intro".tr(), key: const Key('enhancement_merge_intro')),
                const SizedBox(height: 12),
                // A pair with no factor difference is stated once for both cards, not once per card.
                if (noFactorDifference)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      "$tr_merge.no_factor_difference".tr(),
                      key: const Key('enhancement_merge_no_factor_difference'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth >= _sideBySideWidth
                      ? IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final (i, c) in cards(fillHeight: true).indexed) ...[
                                if (i > 0) const SizedBox(width: 12),
                                Expanded(child: c),
                              ],
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (i, c) in cards(fillHeight: false).indexed) ...[
                              if (i > 0) const SizedBox(height: 12),
                              c,
                            ],
                          ],
                        ),
                ),
                const SizedBox(height: 16),
                ..._metadataRows(olderSide, newerSide, identical, enabled: metadataEditable),
              ],
            ),
          ),
        ),
        bottom: Row(
          children: [
            const Spacer(),
            TextButton(
              onPressed: _running ? null : () => CardDialog.dismiss(ref.base),
              child: Text("$tr_merge.cancel".tr()),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: _confirmTooltip(merging, blocker),
              child: HoldToConfirmButton(
                key: const Key('enhancement_merge_apply'),
                icon: Icon(merging ? Symbols.merge_rounded : Symbols.link_off_rounded),
                label:
                    (_running
                            ? "$tr_merge.running"
                            : merging
                            ? "$tr_merge.merge"
                            : "$tr_merge.separate")
                        .tr(),
                onConfirmed: _onConfirm(blocker),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The width from which the two cards sit side by side rather than stacked.
  static const _sideBySideWidth = 560.0;

  /// What a completed hold on the bottom button runs, per [enhancementMergeConfirmAction].
  VoidCallback? _onConfirm(LongReadKind? blocker) => switch (enhancementMergeConfirmAction(
    selection: _selection,
    running: _running,
    unfinished: _unfinished,
    blocked: blocker != null,
    ratingInvalid: _ratingErrors.isNotEmpty,
  )) {
    null => null,
    EnhancementMergeAction.merge => _merge,
    EnhancementMergeAction.dismiss => _dismiss,
  };

  /// What the bottom button will do, followed by why the merge cannot run yet when it cannot.
  String _confirmTooltip(bool merging, LongReadKind? blocker) {
    if (!merging) {
      return "$tr_merge.separate_tooltip".tr();
    }
    final action = "$tr_merge.merge_tooltip".tr();
    final blocked = _mergeBlockedReason(blocker);
    return blocked.isEmpty ? action : "$action\n\n$blocked";
  }

  /// Why the merge cannot run, or the empty string when it can.
  ///
  /// The long read comes first: a claim on the store is the reason nothing the user does in this
  /// dialog can clear, while a rating they are still typing is one they can.
  String _mergeBlockedReason(LongReadKind? blocker) {
    if (blocker != null) {
      return longReadBusyKey.tr();
    }
    return _ratingErrors.isEmpty ? "" : "$tr_merge.rating_invalid".tr();
  }

  /// The self factors [side]'s column lists: those whose stars differ from [other]'s, counting a
  /// factor [other] lacks. Null when either side's factors could not be classified, which leaves
  /// nothing to compare against.
  static List<_FactorEntry>? _factorDifference(_Side side, _Side other) {
    final split = side.split;
    final otherSplit = other.split;
    if (split == null || otherSplit == null) {
      return null;
    }
    List<_FactorEntry> differing(Map<int, int> mine, Map<int, int> theirs) => [
      for (final MapEntry(key: id, value: star) in mine.entries.sortedBy<num>((e) => e.key))
        if (theirs[id] != star)
          // More stars here, or a factor only this side has, is the half of the difference an
          // enhancement produces.
          (id: id, star: star, highlighted: star > (theirs[id] ?? 0)),
    ];
    return [...differing(split.coloured, otherSplit.coloured), ...differing(split.white, otherSplit.white)];
  }

  /// One row per memo and per rating storage key that either side holds a value for.
  ///
  /// A key neither side holds is left out: there is nothing to choose, and the merge keeps the
  /// absence without being asked.
  List<Widget> _metadataRows(_Side older, _Side newer, bool identical, {required bool enabled}) {
    final recorded = _marker?.metadataDefaults;
    final defaults = _unfinished == true && recorded != null && recorded.retiredId == newer.id
        ? recorded
        : (
            retiredId: newer.id,
            route: widget.route,
            identical: identical,
            contentFromOlder: _contentFromOlder,
            enhancedIsOlder: widget.candidate.enhancedId == older.id,
          );
    Object? resolve(Map<String, Object?> overrides, String key, Object? olderValue, Object? newerValue) =>
        EnhancementMergeChoices.valueFor(
          overrides: overrides,
          key: key,
          older: olderValue,
          retired: newerValue,
          applied: _unfinished == true,
          route: defaults.route,
          identical: defaults.identical,
          contentFromOlder: defaults.contentFromOlder,
          enhancedIsOlder: defaults.enhancedIsOlder,
        );
    final none = "$tr_merge.none".tr();
    final rows = <Widget>[];
    for (final data in ref.watch(charaDetailRecordMemoStorageDataProvider)) {
      final values = ref.watch(charaDetailRecordMemoProvider(data.key)).value?.data ?? const <String, String>{};
      final olderValue = values[older.id];
      final newerValue = values[newer.id];
      if (olderValue == null && newerValue == null) {
        continue;
      }
      if (olderValue == newerValue) {
        rows.add(
          _SameValueRow(key: Key('enhancement_merge_memo_same_${data.key}'), title: data.title, value: "$olderValue"),
        );
        continue;
      }
      final current = resolve(_memo, data.key, olderValue, newerValue) as String?;
      rows.add(
        _MetadataRow(
          title: data.title,
          optionKey: 'enhancement_merge_memo_${data.key}',
          olderLabel: olderValue ?? none,
          newerLabel: newerValue ?? none,
          pick: _memoPick[data.key] ?? _pickOf(current, olderValue, newerValue),
          onPick: !enabled
              ? null
              : (pick) => setState(() {
                  _memoPick[data.key] = pick;
                  // Free input starts from whatever is resolved now, so choosing it writes nothing yet.
                  if (pick != EnhancementMergePick.free) {
                    _memo[data.key] = pick == EnhancementMergePick.older ? olderValue : newerValue;
                  }
                }),
          field: _MemoField(
            title: data.title,
            storageKey: data.key,
            enabled: enabled,
            current: current,
            onChanged: (value) => setState(() => _memo[data.key] = value),
          ),
        ),
      );
    }
    for (final data in ref.watch(charaDetailRecordRatingStorageDataProvider)) {
      final values = ref.watch(charaDetailRecordRatingProvider(data.key)).value?.data ?? const <String, double>{};
      final olderValue = values[older.id];
      final newerValue = values[newer.id];
      if (olderValue == null && newerValue == null) {
        continue;
      }
      if (olderValue == newerValue) {
        rows.add(
          _SameValueRow(key: Key('enhancement_merge_rating_same_${data.key}'), title: data.title, value: "$olderValue"),
        );
        continue;
      }
      final current = resolve(_rating, data.key, olderValue, newerValue) as double?;
      rows.add(
        _MetadataRow(
          title: data.title,
          optionKey: 'enhancement_merge_rating_${data.key}',
          olderLabel: olderValue == null ? none : "$olderValue",
          newerLabel: newerValue == null ? none : "$newerValue",
          pick: _ratingPick[data.key] ?? _pickOf(current, olderValue, newerValue),
          onPick: !enabled
              ? null
              : (pick) => setState(() {
                  _ratingPick[data.key] = pick;
                  if (pick != EnhancementMergePick.free) {
                    // A side's value is a rating by construction, so a rejection of typed text ends here.
                    _ratingErrors.remove(data.key);
                    _rating[data.key] = pick == EnhancementMergePick.older ? olderValue : newerValue;
                  }
                }),
          field: _RatingField(
            title: data.title,
            storageKey: data.key,
            enabled: enabled,
            rejected: _ratingErrors.contains(data.key),
            current: current,
            onAccepted: (value) => setState(() {
              _ratingErrors.remove(data.key);
              _rating[data.key] = value;
            }),
            onRejected: () => setState(() => _ratingErrors.add(data.key)),
          ),
        ),
      );
    }
    return rows;
  }

  /// The pick [current] corresponds to while the user has made none: the side whose value it is,
  /// or free input for a value neither side holds.
  static EnhancementMergePick _pickOf(Object? current, Object? older, Object? newer) {
    if (current == older) {
      return EnhancementMergePick.older;
    }
    return current == newer ? EnhancementMergePick.newer : EnhancementMergePick.free;
  }

  /// What the merge is asked to apply: the route it was started from, which decides a first run's
  /// defaults, plus whatever the user picked or typed.
  ///
  /// [EnhancementMergeChoices.valueFor] is also what the fields above are prefilled from, and
  /// those fields -- their older/newer/free picks as much as their free input -- are disabled for
  /// as long as a merge is running, so the value the user reads and the value the merge writes
  /// cannot come to disagree.
  EnhancementMergeChoices _choices() =>
      EnhancementMergeChoices(route: widget.route, memo: Map.of(_memo), rating: Map.of(_rating));

  /// Runs the merge and keeps the dialog up until its outcome has been reported.
  ///
  /// **Every way out is shut for the duration.** The barrier never dismisses this dialog, and
  /// [_running] shuts both the title-bar cross and the bottom row. The merge runs
  /// on regardless of an exit, so leaving early cancels nothing - it only takes away the surface
  /// that has to say what happened. These dialogs are entries in [DialogController] and not
  /// navigator routes, so a system back or an Escape has nothing to pop and is not another exit.
  ///
  /// The outcome is reported outside any `mounted` test, for the same reason: the toast and
  /// [EnhancementMergeDialog.onResult] belong to the flow rather than to this widget, and an
  /// outcome that only reached a still-mounted dialog would be exactly the silence the guards
  /// above exist to prevent.
  Future<void> _merge() async {
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    final EnhancementMergeResult result;
    setState(() => _running = true);
    try {
      result = await ref
          .read(enhancementMergeActionsProvider)
          .merge(
            widget.candidate,
            keptContentId: _contentFromOlder ? widget.candidate.olderId : widget.candidate.newerId,
            choices: _choices(),
          );
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
    widget.onResult?.call(result);
    final sentence = enhancementMergeOutcomeKey(result.outcome).tr();
    Toaster.show(
      result.outcome == EnhancementMergeOutcome.merged
          ? ToastData.success(description: sentence)
          : ToastData.error(description: sentence),
    );
    // Token-scoped: the merge can outlive this dialog, and an unqualified dismiss would close
    // whatever is open by then instead.
    dialogs.dismiss(token);
  }

  /// Records that the pair is not the same uma, under the same lock-out as [_merge].
  ///
  /// A write to the dismissal store is as un-cancellable as the merge is, and its failure is the
  /// half the user has to be told about, so the dialog stays put until it has an answer. A refusal
  /// the user can retry keeps it open; a pair that is no longer the candidate ends it the way the
  /// merge's refusal over that pair does.
  Future<void> _dismiss() async {
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    final bool stored;
    setState(() => _running = true);
    try {
      stored = await ref.read(enhancementMergeActionsProvider).dismiss(widget.candidate);
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
    if (!stored) {
      Toaster.show(ToastData.error(description: "$tr_merge.dismiss_failed".tr()));
      return;
    }
    dialogs.dismiss(token);
  }
}

/// One option of a [_HorizontalRadios]: its value, its label, and the key its radio carries.
typedef _RadioOption<T> = ({T value, String label, Key key});

/// A single-line radio group, the dialog's one idiom for "which of these".
///
/// [onChanged] null renders every option inert, keeping the selection readable.
class _HorizontalRadios<T> extends StatelessWidget {
  const _HorizontalRadios({required this.value, required this.options, required this.onChanged});

  final T value;
  final List<_RadioOption<T>> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return RadioGroup<T>(
      groupValue: value,
      onChanged: (value) {
        if (value != null) {
          onChanged?.call(value);
        }
      },
      child: Wrap(
        spacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final option in options)
            InkWell(
              onTap: onChanged == null ? null : () => onChanged(option.value),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Radio<T>(key: option.key, value: option.value, enabled: onChanged != null),
                  // Flexible bounds a long stored memo to the dialog's width so it wraps
                  // instead of running off the option.
                  Flexible(
                    child: Padding(padding: const EdgeInsets.only(right: 8), child: Text(option.label)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One record's card: the chara and its evaluation value, what tells it apart from the other
/// record, a way to look at it, and the toggle that selects it as the content to keep.
///
/// Only the selected card has a surface of its own; an unselected one lets the dialog show through,
/// so which record is kept reads from the cards themselves.
class _RecordCard extends StatelessWidget {
  const _RecordCard({
    super.key,
    required this.side,
    required this.iconPath,
    required this.factors,
    required this.selected,
    required this.fillHeight,
    required this.fixedReason,
    required this.onToggle,
    required this.onPreview,
  });

  final _Side side;
  final FilePath iconPath;

  /// The factors that differ from the other side, or null when they could not be compared.
  final List<_FactorEntry>? factors;
  final bool selected;

  /// Whether the card is laid out beside the other at a shared height, which pushes the toggle to
  /// the bottom so both toggles line up.
  final bool fillHeight;

  /// Why the toggle is shut for this pair, or null when it is not (or only for the moment).
  final String? fixedReason;

  /// Null renders the toggle inert.
  final VoidCallback? onToggle;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final factors = this.factors;
    final fixedReason = this.fixedReason;
    final toggleLabel = Text((selected ? "$tr_merge.deselect" : "$tr_merge.select").tr());
    final toggleKey = Key('enhancement_merge_select_${side.id}');
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? scheme.surfaceContainerLow : Colors.transparent,
      elevation: selected ? 6 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: SizedBox(width: 56, height: 56, child: TraineeIcon(iconPath, placeholderSize: 56))),
            Center(
              child: Text(
                side.record.evaluationValueLabel,
                key: Key('enhancement_merge_evaluation_${side.id}'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            Center(
              child: TextButton.icon(
                key: Key('enhancement_merge_preview_${side.id}'),
                icon: const Icon(Symbols.visibility_rounded),
                label: Text("$tr_merge.preview".tr()),
                onPressed: onPreview,
              ),
            ),
            const SizedBox(height: 8),
            if (factors == null)
              Text("$tr_merge.factors_unknown".tr(), style: theme.textTheme.bodySmall)
            else
              for (final entry in factors) _FactorLine(id: entry.id, star: entry.star, highlighted: entry.highlighted),
            const SizedBox(height: 4),
            Text(side.record.metadata.capturedDate, style: theme.textTheme.bodySmall),
            if (fillHeight) const Spacer(),
            if (fixedReason != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  fixedReason,
                  key: Key('enhancement_merge_fixed_${side.id}'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: selected
                  ? OutlinedButton(key: toggleKey, onPressed: onToggle, child: toggleLabel)
                  : FilledButton.tonal(key: toggleKey, onPressed: onToggle, child: toggleLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _FactorLine extends ConsumerWidget {
  const _FactorLine({required this.id, required this.star, required this.highlighted});

  final int id;
  final int star;
  final bool highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = theme.extension<AppSemanticColors>()?.success ?? theme.colorScheme.primary;
    final info = ref.watch(factorInfoProvider).firstWhereOrNull((e) => e.sid == id);
    final name = info?.names.firstOrNull ?? "$id";
    return Container(
      key: Key('enhancement_merge_factor_$id'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      margin: const EdgeInsets.only(bottom: 2),
      decoration: highlighted
          ? BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6))
          : null,
      child: Text(
        "$name ★$star",
        style: theme.textTheme.bodySmall?.copyWith(
          color: highlighted ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
          fontWeight: highlighted ? FontWeight.bold : null,
        ),
      ),
    );
  }
}

/// The free-input field for one memo storage key, mounted while free input is picked.
class _MemoField extends StatefulWidget {
  const _MemoField({
    required this.title,
    required this.storageKey,
    required this.enabled,
    required this.current,
    required this.onChanged,
  });

  final String title;
  final String storageKey;
  final bool enabled;
  final String? current;
  final ValueChanged<String?> onChanged;

  @override
  State<_MemoField> createState() => _MemoFieldState();
}

class _MemoFieldState extends State<_MemoField> {
  late final TextEditingController _controller = TextEditingController(text: widget.current ?? "");

  @override
  void didUpdateWidget(_MemoField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The field starts from the resolved value and stays editable, so the text is pushed in only
    // when the resolved value actually moved - typing must not be undone by a rebuild.
    if (oldWidget.current != widget.current && _controller.text != (widget.current ?? "")) {
      _controller.text = widget.current ?? "";
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: Key('enhancement_merge_memo_${widget.storageKey}'),
      controller: _controller,
      enabled: widget.enabled,
      decoration: InputDecoration(isDense: true, labelText: widget.title),
      onChanged: (value) => widget.onChanged(value.isEmpty ? null : value),
    );
  }
}

/// The rating scale every rating surface in this app offers: five stars, half stars allowed, and
/// zero is a rating rather than the absence of one.
const _ratingStars = 5.0;
const _ratingStep = 0.5;

/// The rating [text] stands for, or null when [text] is not a rating this app can hold.
///
/// The rating control the rest of the app edits with is a five-star bar with half stars, so a
/// rating is a multiple of 0.5 from 0 to 5; this field is a second way to set the same value and
/// not a licence to write one no other surface could have produced.
///
/// An **empty** field is a rating too - the absent one - because a merge is allowed to end with no
/// rating and the field is the only place to say so. Everything else is refused rather than read as
/// a clearing: a mistyped number is not a request to delete the rating.
({double? value})? parseEnhancementMergeRating(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return (value: null);
  }
  final value = double.tryParse(trimmed);
  // NaN fails every one of these comparisons, which is the answer it should get.
  if (value == null || value < 0 || value > _ratingStars || value % _ratingStep != 0) {
    return null;
  }
  return (value: value);
}

/// The free-input field for one rating storage key, mounted while free input is picked.
class _RatingField extends StatefulWidget {
  const _RatingField({
    required this.title,
    required this.storageKey,
    required this.enabled,
    required this.rejected,
    required this.current,
    required this.onAccepted,
    required this.onRejected,
  });

  final String title;
  final String storageKey;
  final bool enabled;

  /// Whether the text this field is showing has already been refused as a rating.
  ///
  /// Held by the dialog and not by this field: the error message and the merge button are two
  /// readings of one fact, and the dialog is where both the button and the card selection that
  /// voids the rejection live.
  final bool rejected;

  final double? current;

  /// The rating the field now stands for; null is the empty field's "no rating".
  final ValueChanged<double?> onAccepted;

  /// The field holds text that is not a rating: the choice is left as it was and the field says so.
  final VoidCallback onRejected;

  @override
  State<_RatingField> createState() => _RatingFieldState();
}

class _RatingFieldState extends State<_RatingField> {
  late final TextEditingController _controller = TextEditingController(text: _text(widget.current));

  static String _text(double? value) => value == null ? "" : "$value";

  @override
  void didUpdateWidget(_RatingField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The resolved value is pushed into the field when it moved, and also when a rejection was
    // voided while it did not: what is left in the field would otherwise be the refused text under
    // a cleared error, which reads as a rating the merge is not going to write.
    final voided = oldWidget.rejected && !widget.rejected;
    if ((oldWidget.current != widget.current || voided) && _controller.text != _text(widget.current)) {
      _controller.text = _text(widget.current);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _typed(String text) {
    final parsed = parseEnhancementMergeRating(text);
    if (parsed == null) {
      widget.onRejected();
    } else {
      widget.onAccepted(parsed.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: Key('enhancement_merge_rating_${widget.storageKey}'),
      controller: _controller,
      enabled: widget.enabled,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        isDense: true,
        labelText: widget.title,
        errorText: widget.rejected ? "$tr_merge.rating_invalid".tr() : null,
      ),
      onChanged: _typed,
    );
  }
}

/// The shared layout of one metadata key the two sides disagree on: older / newer / free input,
/// and the field while free input is picked.
class _MetadataRow extends StatelessWidget {
  const _MetadataRow({
    required this.title,
    required this.optionKey,
    required this.olderLabel,
    required this.newerLabel,
    required this.pick,
    required this.onPick,
    required this.field,
  });

  final String title;

  /// The prefix of each option's key; the pick's name is appended.
  final String optionKey;
  final String olderLabel;
  final String newerLabel;
  final EnhancementMergePick pick;

  /// Null renders the choice and its field inert, keeping both readable.
  final ValueChanged<EnhancementMergePick>? onPick;
  final Widget field;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String label(EnhancementMergePick pick) => switch (pick) {
      EnhancementMergePick.older => "$tr_merge.pick_older".tr(namedArgs: {"value": olderLabel}),
      EnhancementMergePick.newer => "$tr_merge.pick_newer".tr(namedArgs: {"value": newerLabel}),
      EnhancementMergePick.free => "$tr_merge.pick_free".tr(),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          _HorizontalRadios<EnhancementMergePick>(
            value: pick,
            options: [
              for (final option in EnhancementMergePick.values)
                (value: option, label: label(option), key: Key('${optionKey}_${option.name}')),
            ],
            onChanged: onPick,
          ),
          if (pick == EnhancementMergePick.free) field,
        ],
      ),
    );
  }
}

/// A metadata key both sides hold the same value for: there is nothing to choose, so it is stated.
class _SameValueRow extends StatelessWidget {
  const _SameValueRow({super.key, required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          Text(value),
        ],
      ),
    );
  }
}

/// A one-line standing note inside the dialog or on a review row.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.history_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
