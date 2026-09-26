// The factor-enhancement merge UI: the review list folded into the settings "resolve
// inheritance" button, the merge dialog, and the capture card's notice for a candidate the
// just-captured record belongs to.
// Run: .fvm/flutter_sdk/bin/flutter test test/enhancement_merge_ui_test.dart
//
// Every merge-store operation goes through `enhancementMergeActionsProvider`, so these cases drive
// a record of closures and assert what was called and in which order. Nothing here touches a real
// store: the defects these surfaces can have are all about *when* an operation is offered and
// *what* is shown beside it, and a real filesystem would only make that harder to see.
import 'dart:async';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/chara_detail/enhancement_merge_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/enhancement_review_list.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/hold_to_confirm_button.dart';
import 'package:umacapture/src/gui/record_image.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/factor_classifier.dart';
import 'support/localization.dart';
import 'support/records.dart';

ThemeData _theme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final base = dark
      ? FlexThemeData.dark(scheme: FlexScheme.blue, useMaterial3: true)
      : FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      dark ? AppSemanticColors.dark(base.colorScheme) : AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      dark ? CodeHighlightColors.dark() : CodeHighlightColors.light(),
    ],
  );
}

final _layout = PathInfo(
  documentDir: DirectoryPath('/tmp/uma_merge_ui/documents'),
  supportDir: DirectoryPath('/tmp/uma_merge_ui/support'),
  executableDir: DirectoryPath('/tmp/uma_merge_ui/exe'),
  downloadDir: DirectoryPath('/tmp/uma_merge_ui/downloads'),
);

/// What the flow did, in the order it did it.
///
/// One list and not three flags: the flow's whole content is that the merges come before the
/// resolution, and a set of booleans cannot tell "both happened" from "both happened in the right
/// order".
class _Calls {
  final log = <String>[];
  EnhancementMergeResult result = const EnhancementMergeResult(
    outcome: EnhancementMergeOutcome.merged,
    needsReload: false,
  );
  EnhancementDismissOutcome dismissed = EnhancementDismissOutcome.dismissed;
  MergedIds? merged = (ids: const [], metadataDefaults: null);
  EnhancementMergeChoices? lastChoices;
  String? lastKeptContentId;

  /// Holds the merge (or the dismissal) in flight until the case completes it.
  ///
  /// The dialog's lock-out lasts exactly as long as the operation, so a case about it needs an
  /// operation that is still running while the case looks - which an instantly returning fake
  /// never is.
  Completer<void>? gate;

  /// Holds the merge-marker read in flight, so a case can look at the dialog before it lands.
  Completer<void>? markerGate;

  EnhancementMergeActions get actions => (
    merge: (candidate, {keptContentId, choices = const EnhancementMergeChoices()}) async {
      log.add('merge:${candidate.olderId}/${candidate.newerId}');
      lastChoices = choices;
      lastKeptContentId = keptContentId;
      await gate?.future;
      return result;
    },
    dismiss: (candidate) async {
      log.add('dismiss:${candidate.olderId}/${candidate.newerId}');
      return dismissed;
    },
    resolveInheritance: () async => log.add('resolve'),
    readMerged: (recordId) async {
      await markerGate?.future;
      return merged;
    },
  );
}

class _FakeActiveStorage extends CharaDetailRecordStorage {
  _FakeActiveStorage(this.records);

  @override
  final List<CharaDetailRecord> records;

  @override
  Future<List<CharaDetailRecord>> build() async => records;
}

class _FakeArchiveStorage extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

/// The one memo storage key these cases use, with both sides' values already in it.
const _memoKey = 'memo-1';

class _FakeMemoController extends CharaDetailRecordMemoController {
  _FakeMemoController(this.values) : super(_memoKey);

  final Map<String, String> values;

  @override
  Future<MemoData> build() async => MemoData(title: 'memo', data: values);
}

/// The one rating storage key these cases use, read exactly as [_memoKey] is.
const _ratingKey = 'rating-1';

class _FakeRatingController extends CharaDetailRecordRatingController {
  _FakeRatingController(this.values) : super(_ratingKey);

  final Map<String, double> values;

  @override
  Future<RatingData> build() async => RatingData(title: 'rating', data: values);
}

/// A candidate over two synthetic records. [enhanced] null makes it an identical pair.
({EnhancementCandidate candidate, List<CharaDetailRecord> records}) _pair({
  String older = 'older',
  String newer = 'newer',
  String? enhanced = 'newer',
  int olderEvaluation = 0,
  int newerEvaluation = 0,
}) {
  List<Factor> self({required bool enhanced}) => [...coloured(enhanced ? 3 : 1, 1, 1), ...whites(enhanced ? 6 : 5)];
  final olderRecord = makeRecord(
    id: older,
    card: 1,
    self: self(enhanced: enhanced == older),
    evaluationValue: olderEvaluation,
  );
  final newerRecord = makeRecord(
    id: newer,
    card: 1,
    self: self(enhanced: enhanced == newer),
    capturedDate: '2026-02-01T00:00:00+0900',
    evaluationValue: newerEvaluation,
  );
  return (
    candidate: EnhancementCandidate(olderId: older, newerId: newer, enhancedId: enhanced),
    records: [olderRecord, newerRecord],
  );
}

ProviderContainer _container({
  required _Calls calls,
  List<EnhancementCandidate> candidates = const [],
  List<CharaDetailRecord> records = const [],
  List<PathEntity> held = const [],
  LongReadKind kind = LongReadKind.liveCapture,
  Map<String, String>? memo,
  Map<String, double>? rating,
}) {
  final container = ProviderContainer.test(
    overrides: [
      // The metadata key lists come from a directory listing in the app; here they are stated, so
      // a case decides whether the dialog has a memo or rating row at all without touching a
      // filesystem.
      charaDetailRecordRatingStorageDataLoader.overrideWith(
        (ref) => rating == null ? const <RatingStorageData>[] : [RatingStorageData(key: _ratingKey, title: 'rating')],
      ),
      if (rating != null) charaDetailRecordRatingProvider(_ratingKey).overrideWith(() => _FakeRatingController(rating)),
      charaDetailRecordMemoStorageDataLoader.overrideWith(
        (ref) => memo == null ? const <MemoStorageData>[] : [MemoStorageData(key: _memoKey, title: 'memo')],
      ),
      if (memo != null) charaDetailRecordMemoProvider(_memoKey).overrideWith(() => _FakeMemoController(memo)),
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutProvider.overrideWithValue(_layout),
      enhancementMergeActionsProvider.overrideWithValue(calls.actions),
      pendingEnhancementCandidatesProvider.overrideWithValue(candidates),
      factorInfoLoader.overrideWith((ref) async => testFactorInfo),
      charaDetailRecordStorageLoaderProvider.overrideWith(() => _FakeActiveStorage(records)),
      charaDetailArchiveStorageLoaderProvider.overrideWith(() => _FakeArchiveStorage()),
      // No record on disk: a preview opened from the dialog renders its "no image" state.
      imageSizeContainerProvider.overrideWith((ref, path) async => null),
      previewImagePathsProvider.overrideWith((ref, path) async => const PreviewImagePaths()),
      predictionAvailableProvider.overrideWith((ref, path) async => false),
    ],
  );
  if (held.isNotEmpty) {
    container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: kind, paths: held);
  }
  return container;
}

/// Opens the review list the way the app does — through the settings tile — so the dialog a row
/// opens over it is hosted by the same [DialogLayer] the app gives it.
Future<void> _openReview(WidgetTester tester, ProviderContainer container) async {
  await _pump(tester, container, const ResolveInheritanceTile());
  await tester.tap(find.byType(ListTile));
  await tester.pumpAndSettle();
}

/// Every toast raised from the moment this is called until the test ends.
List<ToastData> _collectToasts(ProviderContainer container) {
  final toasts = <ToastData>[];
  final subscription = container.listen(plainToastEventProvider, (_, next) {
    final data = next.value;
    if (data != null) {
      toasts.add(data);
    }
  });
  addTearDown(subscription.close);
  return toasts;
}

const _tr = 'pages.chara_detail.enhancement_merge';

final _confirm = find.byKey(const Key('enhancement_merge_apply'));

/// The bottom button's tooltip: what it will do, then why it cannot yet when it cannot.
String _confirmTooltip(WidgetTester tester) =>
    tester.widget<Tooltip>(find.ancestor(of: _confirm, matching: find.byType(Tooltip)).first).message ?? '';

/// What a completed hold on Confirm would run now, or null while Confirm is inert.
VoidCallback? _confirmAction(WidgetTester tester) => tester.widget<HoldToConfirmButton>(_confirm).onConfirmed;

/// Holds Confirm for the whole hold duration, which is the only way it acts.
Future<void> _holdConfirm(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(_confirm));
  // The gauge's first frame is where its clock starts, and the controller completes on the first frame
  // *past* its duration, so the hold is measured from the pump after the press and runs one frame over.
  await tester.pump();
  await tester.pump(kHoldToConfirmDuration + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pump();
}

/// The 「選択」/「選択解除」 toggle at the end of record [id]'s card.
Finder _toggle(String id) => find.byKey(Key('enhancement_merge_select_$id'));

/// Presses the toggle of record [id]'s card.
Future<void> _toggleCard(WidgetTester tester, String id) async {
  await tester.ensureVisible(_toggle(id));
  await tester.pumpAndSettle();
  await tester.tap(_toggle(id));
  await tester.pumpAndSettle();
}

/// Whether record [id]'s toggle accepts a press.
bool _toggleEnabled(WidgetTester tester, String id) => tester.widget<ButtonStyleButton>(_toggle(id)).enabled;

/// The record whose card reads as selected - its toggle offers 「選択解除」 - or null for none.
///
/// Read off what the user reads, so a card that looks selected while another is the one the merge
/// keeps cannot pass.
String? _selectedShown(WidgetTester tester) {
  final selected = [
    for (final id in ['older', 'newer'])
      if (find.descendant(of: _toggle(id), matching: find.text(appSentenceAt('$_tr.deselect'))).evaluate().isNotEmpty)
        id,
  ];
  expect(selected.length, lessThanOrEqualTo(1), reason: 'at most one card is selected');
  return selected.firstOrNull;
}

/// The card surface of record [id].
Card _card(WidgetTester tester, String id) => tester.widget<Card>(
  find.descendant(of: find.byKey(Key('enhancement_merge_card_$id')), matching: find.byType(Card)),
);

/// The merge dialog's title-bar cross.
final _mergeDialogCross = find.descendant(of: find.byType(EnhancementMergeDialog), matching: find.byType(IconButton));

/// The merge dialog's own Cancel, told apart from the review list's button of the same wording.
Finder _dialogCancel() => find.descendant(
  of: find.byType(EnhancementMergeDialog),
  matching: find.widgetWithText(TextButton, appSentenceAt('$_tr.cancel')),
);

/// The pick the [kind] (`memo` / `rating`) row shows as selected.
EnhancementMergePick? _pickShown(WidgetTester tester, String kind) {
  final key = kind == 'memo' ? _memoKey : _ratingKey;
  return tester
      .widget<RadioGroup<EnhancementMergePick>>(
        find.ancestor(
          of: find.byKey(Key('enhancement_merge_${kind}_${key}_older')),
          matching: find.byType(RadioGroup<EnhancementMergePick>),
        ),
      )
      .groupValue;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container, Widget child, {ThemeData? theme}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme ?? _theme(),
        home: Scaffold(body: DialogLayer(child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppTranslations);

  group('the resolve-inheritance flow', () {
    testWidgets('with no candidate the button is exactly what it was: the resolution, and no list', (tester) async {
      // The negative control for every case below. Without it a flow that always opened the list
      // would pass them all.
      final calls = _Calls();
      final container = _container(calls: calls);
      await _pump(tester, container, const ResolveInheritanceTile());

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(find.byType(EnhancementReviewList), findsNothing);
      expect(calls.log, ['resolve']);
    });

    testWidgets('the tile shows the number of pending candidates, and no count when there are none', (tester) async {
      Badge badge() => tester.widget<Badge>(find.byType(Badge));

      await _pump(tester, _container(calls: _Calls()), const ResolveInheritanceTile());
      expect(badge().isLabelVisible, isFalse);

      await _pump(
        tester,
        _container(
          calls: _Calls(),
          candidates: const [
            EnhancementCandidate(olderId: 'a', newerId: 'b', enhancedId: null),
            EnhancementCandidate(olderId: 'c', newerId: 'd', enhancedId: 'd'),
          ],
        ),
        const ResolveInheritanceTile(),
      );
      expect(badge().isLabelVisible, isTrue);
      expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets('the pending count reads the primary container roles, not the error roles ($brightness)', (
        tester,
      ) async {
        final theme = _theme(brightness: brightness);
        await _pump(
          tester,
          _container(
            calls: _Calls(),
            candidates: const [EnhancementCandidate(olderId: 'a', newerId: 'b', enhancedId: null)],
          ),
          const ResolveInheritanceTile(),
          theme: theme,
        );
        final badge = tester.widget<Badge>(find.byType(Badge));
        final scheme = theme.colorScheme;
        expect(scheme.primaryContainer, isNot(scheme.error), reason: 'the roles are distinguishable in this theme');
        expect(badge.backgroundColor, scheme.primaryContainer);
        expect(badge.textColor, scheme.onPrimaryContainer);
      });
    }

    testWidgets('cancelling after one merge keeps it; closing with no blocker runs the resolution after the merges', (
      tester,
    ) async {
      // The order is the assertion: resolving first would leave exactly the links the merge
      // was about to make resolvable.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _pump(tester, container, const ResolveInheritanceTile());

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(find.byType(EnhancementReviewList), findsOneWidget);
      expect(calls.log, isEmpty, reason: 'the resolution must not start before the user has seen the list');

      await tester.tap(
        find.byKey(
          Key(
            'enhancement_review_merge_${pair.candidate.pair.first}_'
            '${pair.candidate.pair.second}',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.log, ['merge:older/newer']);

      await tester.tap(find.byKey(const Key('enhancement_review_confirm')));
      await tester.pumpAndSettle();

      expect(calls.log, ['merge:older/newer', 'resolve']);
      expect(find.byType(EnhancementReviewList), findsNothing);
    });

    testWidgets('each record of a row shows its chara icon and evaluation value, and no date', (tester) async {
      final pair = _pair(olderEvaluation: 12000, newerEvaluation: 13000);
      final container = _container(calls: _Calls(), candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);

      final row = find.byKey(Key('enhancement_review_${pair.candidate.pair.first}_${pair.candidate.pair.second}'));
      Finder inRow(Finder f) => find.descendant(of: row, matching: f);
      for (final (side, record) in [('older', pair.records[0]), ('newer', pair.records[1])]) {
        final view = inRow(find.byKey(Key('enhancement_review_side_$side')));
        expect(view, findsOneWidget, reason: side);
        expect(
          find.descendant(of: view, matching: find.byType(TraineeIcon)),
          findsOneWidget,
          reason: side,
        );
        expect(find.descendant(of: view, matching: find.text(record.evaluationValueLabel)), findsOneWidget);
        expect(inRow(find.textContaining(record.metadata.capturedDate)), findsNothing, reason: '$side: no date');
      }
      expect(inRow(find.textContaining('2026-')), findsNothing, reason: 'no date in any spelling');
      expect(inRow(find.text(appSentenceAt('$tr_review.merge'))), findsOneWidget, reason: 'the row keeps its button');
    });

    testWidgets('the settings list offers exactly Cancel and Confirm, and no cross', (tester) async {
      final pair = _pair();
      final container = _container(calls: _Calls(), candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);

      expect(find.byKey(const Key('enhancement_review_cancel')), findsOneWidget);
      expect(find.byKey(const Key('enhancement_review_confirm')), findsOneWidget);
      expect(find.byKey(const Key('enhancement_review_close')), findsNothing);
      expect(find.text(appSentenceAt('$tr_review.cancel')), findsOneWidget);
      // The explanation heads the list, above its first row.
      expect(appSentenceAt('$tr_review.intro'), '以下は同一のウマ娘の可能性があるレコードの組です。確認ボタンから比較・統合ができます。');
      final intro = find.byKey(const Key('enhancement_review_intro'));
      expect(tester.widget<Text>(intro).data, appSentenceAt('$tr_review.intro'));
      final row = find.byKey(Key('enhancement_review_${pair.candidate.pair.first}_${pair.candidate.pair.second}'));
      expect(tester.getRect(intro).bottom, lessThanOrEqualTo(tester.getRect(row).top));
      expect(find.text(appSentenceAt('$tr_review.confirm')), findsOneWidget);
      expect(
        tester
            .widget<CardDialog>(
              find.descendant(of: find.byType(EnhancementReviewList), matching: find.byType(CardDialog)),
            )
            .closeButtonTooltip,
        isNull,
        reason: 'no title-bar cross: every way out is a labelled button',
      );
    });

    testWidgets('Cancel on the settings list keeps the merges done in it and runs no resolution', (tester) async {
      // Merges are committed when their own dialog closes, so leaving the list is safe; running the
      // resolution anyway would make Cancel a second Confirm.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);
      await tester.tap(
        find.byKey(Key('enhancement_review_merge_${pair.candidate.pair.first}_${pair.candidate.pair.second}')),
      );
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('enhancement_review_cancel')));
      await tester.pumpAndSettle();

      expect(calls.log, ['merge:older/newer']);
      expect(find.byType(EnhancementReviewList), findsNothing);
    });

    testWidgets('closing the review list while a long read that began during review is held does not start the '
        'resolution and shows the blocker sentence', (tester) async {
      // The blocker is read *at close*, not at open: a merge run one row above is exactly
      // the thing that can be holding the store by then.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      final toasts = _collectToasts(container);
      await _openReview(tester, container);
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.merge, paths: [_layout.charaDetailDir]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('enhancement_review_confirm')));
      await tester.pumpAndSettle();

      expect(calls.log, isEmpty, reason: 'a whole-store rewrite must not start on top of a held store');
      expect([for (final t in toasts) t.description], [appSentenceAt(longReadBusyKey)]);
    });

    testWidgets('with 40 candidates the last row is reachable and its Merge opens the dialog', (tester) async {
      // A Column would have overflowed long before the fortieth row.
      final candidates = <EnhancementCandidate>[];
      final records = <CharaDetailRecord>[];
      for (var i = 0; i < 40; i++) {
        final pair = _pair(older: 'o$i', newer: 'n$i');
        candidates.add(pair.candidate);
        records.addAll(pair.records);
      }
      final calls = _Calls();
      final container = _container(calls: calls, candidates: candidates, records: records);
      await _pump(tester, container, const ResolveInheritanceTile());
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      final last = find.byKey(const Key('enhancement_review_merge_n39_o39'));
      await tester.scrollUntilVisible(last, 200, scrollable: find.byType(Scrollable).first);
      // scrollUntilVisible stops once any part of the row is in the viewport, which can leave the
      // button under the dialog's bottom bar; bring the whole button in before tapping it.
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pumpAndSettle();

      expect(find.byType(EnhancementMergeDialog), findsOneWidget);
    });

    testWidgets("review rows' Merge is disabled with the long-read tooltip while a claim overlaps chara_detail", (
      tester,
    ) async {
      // `LongReadKind.merge` is the claim a merge holds through its reload barrier, so this
      // is also the case that keeps a second merge out while the first is still reloading.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(
        calls: calls,
        candidates: [pair.candidate],
        records: pair.records,
        held: [_layout.charaDetailDir],
        kind: LongReadKind.merge,
      );
      // Mounted directly: with the store held the settings tile is itself inert, so the app's own
      // route into the list is closed and the question "is the row's Merge inert" has to be asked
      // of the list. Both halves are the point - the entry is gated and so is every row.
      await _pump(tester, container, EnhancementReviewList());

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(appSentenceAt('pages.settings.about.resolve_inheritance.review.merge')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect([
        for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip))) t.message,
      ], contains(appSentenceAt(longReadBusyKey)));
    });

    testWidgets("review rows' Merge is disabled while a video import holds chara_detail", (tester) async {
      // The import leg at the surface the settings route opens. The dialog case asserts the
      // same fact about the button inside the dialog; a row that stayed live would let the user
      // open that dialog over a store an import is still writing into.
      final pair = _pair();
      final container = _container(
        calls: _Calls(),
        candidates: [pair.candidate],
        records: pair.records,
        held: [_layout.charaDetailDir],
        kind: LongReadKind.videoImport,
      );
      await _pump(tester, container, EnhancementReviewList());

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(appSentenceAt('pages.settings.about.resolve_inheritance.review.merge')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect([
        for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip))) t.message,
      ], contains(appSentenceAt(longReadBusyKey)));
    });

    testWidgets('refused_store_recovered and refused_store_incomplete each keep the row', (tester) async {
      // A refusal must not take the row with it: the pair is still pending.
      for (final outcome in [
        EnhancementMergeOutcome.refusedStoreRecovered,
        EnhancementMergeOutcome.refusedStoreIncomplete,
      ]) {
        final pair = _pair();
        final calls = _Calls()..result = EnhancementMergeResult(outcome: outcome, needsReload: true);
        final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
        await _openReview(tester, container);

        await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
        await tester.pumpAndSettle();
        await _holdConfirm(tester);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('enhancement_review_newer_older')), findsOneWidget, reason: '$outcome');
        expect(find.text(appSentenceAt(enhancementMergeOutcomeKey(outcome))), findsOneWidget, reason: '$outcome');
      }
    });

    testWidgets('refused_store_incomplete offers rescan on the row', (tester) async {
      // The refusal's remedy is a store scan that opens every record, so the note carries the
      // button that starts one.
      final pair = _pair();
      final calls = _Calls()
        ..result = const EnhancementMergeResult(
          outcome: EnhancementMergeOutcome.refusedStoreIncomplete,
          needsReload: true,
        );
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);

      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('enhancement_review_rescan')), findsOneWidget);
    });

    testWidgets('failed_delete keeps the row, and the row leaves only when the candidate is gone', (tester) async {
      // The two sub-cases of the retirement: R still listed (the ordinary outcome, re-offered
      // as an unfinished merge) and R gone (the one-file-wide 5.ii window).
      final pair = _pair();
      final calls = _Calls()
        ..result = const EnhancementMergeResult(outcome: EnhancementMergeOutcome.failedDelete, needsReload: true);
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);

      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('enhancement_review_newer_older')), findsOneWidget);
      expect(
        find.text(appSentenceAt(enhancementMergeOutcomeKey(EnhancementMergeOutcome.failedDelete))),
        findsOneWidget,
      );

      // The narrow 5.ii window: R's `record.json` went with the delete, so the pair is no longer
      // derived. Mounted directly, because with no candidate the tile does not open a list at all
      // and the assertion would then be about the tile rather than about the row.
      final gone = _container(calls: _Calls(), candidates: const [], records: pair.records);
      await _pump(tester, gone, EnhancementReviewList());
      expect(find.byKey(const Key('enhancement_review_newer_older')), findsNothing);
    });
  });

  group('the merge dialog', () {
    testWidgets('an identical pair is offered under its own heading and keeps the switch', (tester) async {
      final pair = _pair(enhanced: null);
      final calls = _Calls();
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);

      expect(
        find.text(
          appSentenceAt('pages.settings.about.resolve_inheritance.review.section_identical').replaceAll('{count}', '1'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          appSentenceAt('pages.settings.about.resolve_inheritance.review.section_enhanced').replaceAll('{count}', '1'),
        ),
        findsNothing,
      );
    });

    testWidgets('an unfinished merge selects the older card and shuts both the other card and the deselect', (
      tester,
    ) async {
      // The marker is the record that the user already said they are the same, so the
      // dismissal is gone and the content side is not theirs to move any more.
      final pair = _pair(enhanced: null);
      final unfinished = _Calls()..merged = (ids: ['newer'], metadataDefaults: null);
      final container = _container(calls: unfinished, records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      expect(
        _selectedShown(tester),
        'older',
        reason: 'fixed to the older record, against the identical-pair default of the newer',
      );
      expect(_toggleEnabled(tester, 'older'), isFalse, reason: '選択解除 would be the dismissal');
      expect(_toggleEnabled(tester, 'newer'), isFalse);
      expect(find.byKey(const Key('enhancement_merge_fixed_newer')), findsOneWidget, reason: 'the card says why');
      expect(
        tester.widget<Text>(find.byKey(const Key('enhancement_merge_fixed_newer'))).data,
        appSentenceAt('$_tr.content_unfinished'),
        reason: 'the unfinished merge, and not the pre-enhancement wording',
      );
      expect(find.byKey(const Key('enhancement_merge_unfinished')), findsOneWidget);
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(unfinished.lastKeptContentId, 'older');

      // The control: the same pair with no marker is a free choice and offers the dismissal. The
      // key is load-bearing - without it the element (and its already-resolved marker state) is
      // reused across the two pumps and the control would assert the first case's state.
      final control = _container(calls: _Calls(), records: pair.records);
      await _pump(
        tester,
        control,
        EnhancementMergeDialog(
          key: const ValueKey('control'),
          candidate: pair.candidate,
          route: EnhancementMergeRoute.settings,
        ),
      );
      expect(_toggleEnabled(tester, 'older'), isTrue);
      expect(_toggleEnabled(tester, 'newer'), isTrue);
      expect(find.byKey(const Key('enhancement_merge_fixed_newer')), findsNothing);
    });

    testWidgets('an unfinished enhancement pair whose newer side is enhanced is still fixed to the older card', (
      tester,
    ) async {
      final pair = _pair();
      final calls = _Calls()..merged = (ids: ['newer'], metadataDefaults: null);
      await _pump(
        tester,
        _container(calls: calls, records: pair.records),
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      expect(_selectedShown(tester), 'older');
      expect(_toggleEnabled(tester, 'older'), isFalse);
      expect(_toggleEnabled(tester, 'newer'), isFalse);
    });

    testWidgets('an unfinished merge prefills the memo and rating its first run defaulted to', (tester) async {
      // After the publication the pair reads as identical and fixed to the older card, whichever
      // side's content the first run kept; the marker is what still says which one that was. Each
      // direction: the relation the first run recorded, and the side it defaulted to.
      final directions = <String, (bool, bool, bool, EnhancementMergePick)>{
        'enhancement pair, newer enhanced': (false, false, false, EnhancementMergePick.newer),
        'enhancement pair, older enhanced': (false, true, true, EnhancementMergePick.older),
        'identical pair, kept newer': (true, false, false, EnhancementMergePick.newer),
        'identical pair, kept older': (true, true, false, EnhancementMergePick.older),
      };
      final pair = _pair(enhanced: null);
      for (final MapEntry(key: direction, value: (identical, contentFromOlder, enhancedIsOlder, expected))
          in directions.entries) {
        final calls = _Calls()
          ..merged = (
            ids: ['newer'],
            metadataDefaults: (
              retiredId: 'newer',
              route: EnhancementMergeRoute.settings,
              identical: identical,
              contentFromOlder: contentFromOlder,
              enhancedIsOlder: enhancedIsOlder,
            ),
          );
        await _pump(
          tester,
          _container(
            calls: calls,
            records: pair.records,
            memo: {'older': 'from older', 'newer': 'from newer'},
            rating: {'older': 1.0, 'newer': 4.0},
          ),
          EnhancementMergeDialog(
            key: ValueKey(direction),
            candidate: pair.candidate,
            route: EnhancementMergeRoute.settings,
          ),
        );
        expect(_selectedShown(tester), 'older', reason: direction);
        expect(_pickShown(tester, 'memo'), expected, reason: direction);
        expect(_pickShown(tester, 'rating'), expected, reason: direction);
      }
    });

    testWidgets('an unfinished merge prefills from its first run\'s route, and keeps a value an earlier attempt '
        're-keyed', (tester) async {
      // The first run's relation: an enhancement pair whose newer side is enhanced. Opened from
      // settings, whose own default would be the newer side, in both cases.
      final pair = _pair(enhanced: null);
      final cases = <String, (EnhancementMergeRoute, Map<String, double>, EnhancementMergePick, EnhancementMergePick)>{
        // The first run on the capture card defaulted to the older side.
        'first run on the capture card': (
          EnhancementMergeRoute.captureCard,
          {'older': 1.0, 'newer': 4.0},
          EnhancementMergePick.older,
          EnhancementMergePick.older,
        ),
        // The rating file was finished by an earlier attempt: its newer entry is gone and the older
        // one holds the value moved there. The memo file was not reached.
        'the rating already re-keyed': (
          EnhancementMergeRoute.settings,
          {'older': 4.0},
          EnhancementMergePick.newer,
          EnhancementMergePick.older,
        ),
      };
      for (final MapEntry(key: label, value: (route, rating, memoPick, ratingPick)) in cases.entries) {
        final calls = _Calls()
          ..merged = (
            ids: ['newer'],
            metadataDefaults: (
              retiredId: 'newer',
              route: route,
              identical: false,
              contentFromOlder: false,
              enhancedIsOlder: false,
            ),
          );
        await _pump(
          tester,
          _container(
            calls: calls,
            records: pair.records,
            memo: {'older': 'from older', 'newer': 'from newer'},
            rating: rating,
          ),
          EnhancementMergeDialog(
            key: ValueKey(label),
            candidate: pair.candidate,
            route: EnhancementMergeRoute.settings,
          ),
        );
        expect(_pickShown(tester, 'memo'), memoPick, reason: label);
        expect(_pickShown(tester, 'rating'), ratingPick, reason: label);
      }
    });

    testWidgets('an identical pair selects the newer card by default, either card can be selected, and '
        'the selection reaches the merge', (tester) async {
      final pair = _pair(enhanced: null);
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      expect(_selectedShown(tester), 'newer');
      expect(_toggleEnabled(tester, 'older'), isTrue);
      expect(_toggleEnabled(tester, 'newer'), isTrue);

      await _toggleCard(tester, 'older');
      expect(_selectedShown(tester), 'older', reason: 'selecting one card deselects the other');
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.lastKeptContentId, 'older');
    });

    testWidgets('the toggle reads 選択 / 選択解除, and the card surface and shadow follow the selection', (tester) async {
      final pair = _pair(enhanced: null);
      final calls = _Calls();
      await _pump(
        tester,
        _container(calls: calls, records: pair.records),
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      final scheme = _theme().colorScheme;
      String label(String id) =>
          tester.widget<Text>(find.descendant(of: _toggle(id), matching: find.byType(Text))).data!;
      expect(label('newer'), appSentenceAt('$_tr.deselect'));
      expect(label('older'), appSentenceAt('$_tr.select'));
      expect(appSentenceAt('$_tr.select'), '選択');
      expect(appSentenceAt('$_tr.deselect'), '選択解除');
      // The selected card takes the low container surface; an unselected one has no colour of its own.
      expect(scheme.surfaceContainerLow.a, greaterThan(0), reason: 'the selected surface is visible in this theme');
      expect(_card(tester, 'newer').color, scheme.surfaceContainerLow);
      expect(_card(tester, 'older').color, Colors.transparent);
      expect(_card(tester, 'newer').elevation, greaterThan(_card(tester, 'older').elevation!));
      // The card borders use primary on the selected card and outlineVariant on the other.
      BorderSide border(String id) => (_card(tester, id).shape! as RoundedRectangleBorder).side;
      expect(scheme.primary, isNot(scheme.outlineVariant), reason: 'the border roles are distinguishable');
      expect(border('newer').color, scheme.primary);
      expect(border('older').color, scheme.outlineVariant);

      await _toggleCard(tester, 'newer');
      expect(_selectedShown(tester), isNull, reason: 'none is the third state');
      expect(border('newer').color, scheme.outlineVariant);
      expect(_card(tester, 'newer').color, Colors.transparent);
      expect(_card(tester, 'older').color, Colors.transparent);
      expect(_card(tester, 'newer').elevation, _card(tester, 'older').elevation);
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.log, ['dismiss:older/newer'], reason: 'none + confirm dismisses the pair instead of merging it');
    });

    testWidgets('an enhancement pair selects the enhanced card, and the pre-enhancement card cannot be '
        'selected', (tester) async {
      for (final enhanced in ['newer', 'older']) {
        final pre = enhanced == 'newer' ? 'older' : 'newer';
        final pair = _pair(enhanced: enhanced);
        final calls = _Calls();
        await _pump(
          tester,
          _container(calls: calls, records: pair.records),
          EnhancementMergeDialog(
            key: ValueKey(enhanced),
            candidate: pair.candidate,
            route: EnhancementMergeRoute.settings,
          ),
        );
        expect(_selectedShown(tester), enhanced, reason: 'whether it is older or newer by date');
        expect(_toggleEnabled(tester, pre), isFalse, reason: pre);
        expect(find.byKey(Key('enhancement_merge_fixed_$pre')), findsOneWidget, reason: 'the card says why');

        await _toggleCard(tester, enhanced);
        expect(_selectedShown(tester), isNull);
        expect(_toggleEnabled(tester, pre), isFalse, reason: 'still not selectable with nothing selected');
        await _toggleCard(tester, enhanced);
        expect(_selectedShown(tester), enhanced);
        await _holdConfirm(tester);
        await tester.pumpAndSettle();
        expect(calls.lastKeptContentId, enhanced);
      }
    });

    testWidgets('only the difference is listed: shared factors are left out, and stars read ★N', (tester) async {
      final pair = _pair();
      final container = _container(calls: _Calls(), records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      // Factor 11 is the blue factor starred up from 1 to 3, so both columns list it; 1006 is the
      // added white, listed on the enhanced side only. Red 21, green 31 and whites 1001-1005 are
      // the same on both sides.
      expect(find.byKey(const Key('enhancement_merge_factor_11')), findsNWidgets(2));
      expect(find.byKey(const Key('enhancement_merge_factor_1006')), findsOneWidget);
      for (final id in [21, 31, 1001, 1002, 1003, 1004, 1005]) {
        expect(find.byKey(Key('enhancement_merge_factor_$id')), findsNothing, reason: 'factor $id is shared');
      }
      final lines = [
        for (final e in tester.widgetList<Container>(find.byKey(const Key('enhancement_merge_factor_11'))))
          ((e.child! as Text).data!.split(' ').last, e.decoration != null),
      ];
      expect(lines, [('★1', false), ('★3', true)], reason: 'the enhanced side is the highlighted one');
      final added = tester.widget<Container>(find.byKey(const Key('enhancement_merge_factor_1006')));
      expect(added.decoration, isNotNull, reason: 'the added white is highlighted on the enhanced side');
      expect(find.byKey(const Key('enhancement_merge_no_factor_difference')), findsNothing);
    });

    testWidgets('both kinds of pair carry the one title', (tester) async {
      expect(appSentenceAt('$_tr.title'), '統合対象の選択');
      for (final enhanced in [null, true]) {
        final pair = enhanced == null ? _pair(enhanced: null) : _pair();
        await _pump(
          tester,
          _container(calls: _Calls(), records: pair.records),
          EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
        );
        expect(pair.candidate.identical, enhanced == null, reason: 'positive control: the pair kind is the one meant');
        expect(find.text(appSentenceAt('$_tr.title')), findsOneWidget);
      }
    });

    testWidgets('an identical pair lists no factor and says there is no difference, once', (tester) async {
      final pair = _pair(enhanced: null);
      final container = _container(calls: _Calls(), records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      expect(find.byKey(const Key('enhancement_merge_no_factor_difference')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => '${w.key}'.contains('enhancement_merge_factor_')), findsNothing);
    });

    testWidgets('the intro is verbatim, and each card starts with the icon and evaluation and ends with its '
        'toggle', (tester) async {
      final pair = _pair(olderEvaluation: 12000, newerEvaluation: 12000);
      await _pump(
        tester,
        _container(calls: _Calls(), records: pair.records),
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      expect(appSentenceAt('$_tr.intro'), '以下は同一のウマ娘の可能性があります。残す方を選択してください。');
      expect(find.text(appSentenceAt('$_tr.intro')), findsOneWidget);
      for (final id in ['older', 'newer']) {
        final card = find.byKey(Key('enhancement_merge_card_$id'));
        Finder inCard(Finder f) => find.descendant(of: card, matching: f);
        // Shared or not, the evaluation belongs to each card: there is no common section any more.
        final evaluation = inCard(find.byKey(Key('enhancement_merge_evaluation_$id')));
        expect(evaluation, findsOneWidget, reason: id);
        expect(inCard(find.byType(TraineeIcon)), findsOneWidget, reason: id);
        final top = tester.getRect(inCard(find.byType(TraineeIcon))).top;
        final factor = tester.getRect(inCard(find.byKey(const Key('enhancement_merge_factor_11')))).top;
        final toggle = tester.getRect(inCard(_toggle(id))).top;
        expect(top, lessThan(factor), reason: '$id: the common information comes first');
        expect(tester.getRect(evaluation).top, lessThan(factor), reason: id);
        // The preview sits directly below the evaluation, before everything that tells the
        // records apart.
        final previewRect = tester.getRect(inCard(find.byKey(Key('enhancement_merge_preview_$id'))));
        expect(previewRect.top, greaterThanOrEqualTo(tester.getRect(evaluation).bottom), reason: id);
        expect(previewRect.top - tester.getRect(evaluation).bottom, lessThanOrEqualTo(8), reason: id);
        expect(previewRect.bottom, lessThanOrEqualTo(factor), reason: '$id: the preview comes before the factors');
        expect(factor, lessThan(toggle), reason: '$id: the toggle ends the card');
      }
      expect(find.byType(TraineeIcon), findsNWidgets(2), reason: 'no icon outside the cards');
    });

    testWidgets('no card is headed older / newer; icon, evaluation and preview are centred on lines of '
        'their own, and the toggle spans the card', (tester) async {
      final pair = _pair(olderEvaluation: 12000, newerEvaluation: 12000);
      for (final width in [1000.0, 420.0]) {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pump(
          tester,
          _container(calls: _Calls(), records: pair.records),
          EnhancementMergeDialog(
            key: ValueKey(width),
            candidate: pair.candidate,
            route: EnhancementMergeRoute.settings,
          ),
        );
        for (final id in ['older', 'newer']) {
          final card = find.byKey(Key('enhancement_merge_card_$id'));
          Finder inCard(Finder f) => find.descendant(of: card, matching: f);
          expect(inCard(find.text('古い方')), findsNothing, reason: '$id@$width');
          expect(inCard(find.text('新しい方')), findsNothing, reason: '$id@$width');
          final cardRect = tester.getRect(card);
          final icon = tester.getRect(inCard(find.byType(TraineeIcon)));
          final evaluation = tester.getRect(inCard(find.byKey(Key('enhancement_merge_evaluation_$id'))));
          final preview = tester.getRect(inCard(find.byKey(Key('enhancement_merge_preview_$id'))));
          final toggle = tester.getRect(inCard(_toggle(id)));
          expect(evaluation.top, greaterThanOrEqualTo(icon.bottom), reason: '$id@$width: a line of its own');
          for (final (name, rect) in [('icon', icon), ('evaluation', evaluation), ('preview', preview)]) {
            expect(rect.center.dx, moreOrLessEquals(cardRect.center.dx, epsilon: 0.5), reason: '$id@$width: $name');
          }
          // The card's inner width: its outer width less the 12 px padding on each side.
          expect(toggle.width, moreOrLessEquals(cardRect.width - 24, epsilon: 0.5), reason: '$id@$width');
          expect(toggle.center.dx, moreOrLessEquals(cardRect.center.dx, epsilon: 0.5), reason: '$id@$width');
        }
      }
    });

    testWidgets('the cards sit side by side when wide and stack when narrow', (tester) async {
      final pair = _pair();
      Future<void> at(double width) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        await _pump(
          tester,
          _container(calls: _Calls(), records: pair.records),
          EnhancementMergeDialog(
            key: ValueKey(width),
            candidate: pair.candidate,
            route: EnhancementMergeRoute.settings,
          ),
        );
      }

      addTearDown(tester.view.reset);
      await at(1000);
      var older = tester.getRect(find.byKey(const Key('enhancement_merge_card_older')));
      var newer = tester.getRect(find.byKey(const Key('enhancement_merge_card_newer')));
      expect(newer.left, greaterThan(older.right), reason: 'side by side');
      expect(newer.top, older.top);

      await at(420);
      expect(tester.takeException(), isNull);
      older = tester.getRect(find.byKey(const Key('enhancement_merge_card_older')));
      newer = tester.getRect(find.byKey(const Key('enhancement_merge_card_newer')));
      expect(newer.top, greaterThan(older.bottom), reason: 'stacked');
    });

    testWidgets('a column opens its record preview over the dialog, which keeps what was typed', (tester) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(
        calls: calls,
        candidates: [pair.candidate],
        records: pair.records,
        memo: {'older': 'from older', 'newer': 'from newer'},
      );
      await _openReview(tester, container);
      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_free')));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('enhancement_merge_memo_$_memoKey'));
      await tester.enterText(field, 'typed');
      await tester.pumpAndSettle();
      final dialogs = container.read(dialogBuilderProvider.notifier);
      expect(dialogs.entries, hasLength(2), reason: 'the review list and the merge dialog');

      await tester.tap(find.byKey(const Key('enhancement_merge_preview_older')));
      await tester.pumpAndSettle();
      final preview = tester.widget<CharaDetailPreviewDialog>(find.byType(CharaDetailPreviewDialog));
      expect(
        [for (final d in preview.recordDirs) d.path],
        [recordDirOf(_layout, RecordSource.active, pair.records.first).path],
      );
      expect(dialogs.entries, hasLength(3), reason: 'opened over, not instead of');

      dialogs.dismiss();
      await tester.pumpAndSettle();
      expect(find.byType(CharaDetailPreviewDialog), findsNothing);
      expect(tester.widget<TextField>(field).controller?.text, 'typed');
      expect(_pickShown(tester, 'memo'), EnhancementMergePick.free);
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.lastChoices?.memo, {_memoKey: 'typed'});
      expect(find.byType(EnhancementMergeDialog), findsNothing, reason: 'the merge closes its own dialog');
      expect(dialogs.entries, hasLength(1), reason: 'the review list stays');
    });

    testWidgets('after a preview round trip, deselecting and a held Confirm still close the dialog', (tester) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);
      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();
      final dialogs = container.read(dialogBuilderProvider.notifier);
      await tester.tap(find.byKey(const Key('enhancement_merge_preview_newer')));
      await tester.pumpAndSettle();
      dialogs.dismiss();
      await tester.pumpAndSettle();

      await _toggleCard(tester, 'newer');
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.log, ['dismiss:older/newer']);
      expect(find.byType(EnhancementMergeDialog), findsNothing);
      expect(dialogs.entries, hasLength(1), reason: 'the review list stays');
    });

    testWidgets('a long stored memo wraps inside its option and stays readable', (tester) async {
      final pair = _pair();
      final long = 'long memo ' * 60;
      final container = _container(calls: _Calls(), records: pair.records, memo: {'older': long, 'newer': 'short'});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      expect(tester.takeException(), isNull);
      final label = find.textContaining(long.trim());
      expect(label, findsOneWidget);
      final option = tester.getRect(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_older')));
      final text = tester.getRect(label);
      expect(text.height, greaterThan(option.height), reason: 'wrapped onto several lines');
      expect(text.right, lessThanOrEqualTo(tester.getRect(find.byType(EnhancementMergeDialog)).right));
    });

    testWidgets('no card selected and a held Confirm dismiss the pair, merge nothing, and close the dialog', (
      tester,
    ) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);
      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();

      await _toggleCard(tester, 'newer');
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.log, ['dismiss:older/newer'], reason: 'the persisted dismissal and nothing else');
      expect(find.byType(EnhancementMergeDialog), findsNothing);
    });

    for (final (name, outcome, key) in [
      (
        'an unreadable dismissal file',
        EnhancementDismissOutcome.unreadable,
        'pages.chara_detail.enhancement_merge.dismiss_failed',
      ),
      ('a root lock held elsewhere', EnhancementDismissOutcome.lockBusy, longReadBusyKey),
      (
        'a root lock that cannot be taken',
        EnhancementDismissOutcome.lockUnavailable,
        'pages.chara_detail.enhancement_merge.dismiss_unavailable',
      ),
    ]) {
      testWidgets('a dismissal refused by $name says so and keeps the dialog open', (tester) async {
        final pair = _pair();
        final calls = _Calls()..dismissed = outcome;
        final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
        final toasts = _collectToasts(container);
        await _openReview(tester, container);
        await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
        await tester.pumpAndSettle();

        await _toggleCard(tester, 'newer');
        await _holdConfirm(tester);
        await tester.pumpAndSettle();

        expect(calls.log, ['dismiss:older/newer']);
        expect([for (final t in toasts) t.description], [appSentenceAt(key)]);
        expect(find.byType(EnhancementMergeDialog), findsOneWidget, reason: 'the user can retry from where they were');
      });
    }

    testWidgets('a merge over a pair that is no longer the candidate says so, closes and notes the row', (
      tester,
    ) async {
      final pair = _pair();
      final calls = _Calls()
        ..result = const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedMissing, needsReload: false);
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      final toasts = _collectToasts(container);
      await _openReview(tester, container);
      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();

      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      final sentence = appSentenceAt(enhancementMergeOutcomeKey(EnhancementMergeOutcome.refusedMissing));
      expect(calls.log, ['merge:older/newer']);
      expect([for (final t in toasts) t.description], [sentence]);
      expect(find.byType(EnhancementMergeDialog), findsNothing);
      expect(find.byKey(const Key('enhancement_review_newer_older')), findsOneWidget, reason: 'the row stays');
      expect(find.text(sentence), findsOneWidget, reason: 'the refusal note on the row');
    });

    testWidgets('a selected card and a held Confirm merge and dismiss nothing', (tester) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);
      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();
      expect(_selectedShown(tester), 'newer');

      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.log, ['merge:older/newer']);
      expect(find.byType(EnhancementMergeDialog), findsNothing);
    });

    testWidgets('a tap on Confirm does nothing, with a card selected or none', (tester) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      // The control: Confirm is live, so the silence below is the hold's and not a disabled button's.
      expect(_confirmAction(tester), isNotNull);

      await tester.tap(_confirm);
      await tester.pump(kHoldToConfirmDuration * 2);
      await _toggleCard(tester, 'newer');
      await tester.tap(_confirm);
      await tester.pump(kHoldToConfirmDuration * 2);

      expect(calls.log, isEmpty);
      expect(find.byType(EnhancementMergeDialog), findsOneWidget);
    });

    testWidgets('Cancel performs nothing and closes only the dialog, with a card selected or none', (tester) async {
      for (final decision in ['selected', 'none']) {
        final pair = _pair();
        final calls = _Calls();
        final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
        await _openReview(tester, container);
        await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
        await tester.pumpAndSettle();
        if (decision == 'none') {
          await _toggleCard(tester, 'newer');
        }

        await tester.tap(_dialogCancel());
        await tester.pumpAndSettle();

        expect(calls.log, isEmpty, reason: decision);
        expect(find.byType(EnhancementMergeDialog), findsNothing, reason: decision);
        expect(find.byKey(const Key('enhancement_review_confirm')), findsOneWidget, reason: 'the list stays');
      }
    });

    testWidgets('the bottom button reads 統合する or 統合しない with the selection, and its tooltip says '
        'what it will do', (tester) async {
      final pair = _pair();
      final container = _container(calls: _Calls(), records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      String label() => tester.widget<HoldToConfirmButton>(_confirm).label;

      expect(label(), appSentenceAt('$_tr.merge'), reason: 'the enhanced card is selected by default');
      expect(_confirmTooltip(tester), appSentenceAt('$_tr.merge_tooltip'));
      expect(
        appSentenceAt('$_tr.merge_tooltip'),
        isNot(contains('{')),
        reason: 'the shipped sentence leaves no placeholder unfilled',
      );
      expect(find.text(appSentenceAt('$_tr.cancel')), findsOneWidget);

      await _toggleCard(tester, 'newer');
      expect(label(), appSentenceAt('$_tr.separate'));
      expect(_confirmTooltip(tester), appSentenceAt('$_tr.separate_tooltip'));

      await _toggleCard(tester, 'newer');
      expect(label(), appSentenceAt('$_tr.merge'), reason: 'selecting again restores the merge wording');
    });

    testWidgets('no selection shuts the memo and rating choices, and selecting the card again keeps them', (
      tester,
    ) async {
      final pair = _pair(enhanced: null);
      final calls = _Calls();
      final container = _container(
        calls: calls,
        records: pair.records,
        memo: {'older': 'from older', 'newer': 'from newer'},
        rating: {'older': 1.0, 'newer': 4.0},
      );
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      await _toggleCard(tester, 'older');
      await tester.tap(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_free')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('enhancement_merge_memo_$_memoKey')), 'typed');
      await tester.pumpAndSettle();
      Radio<EnhancementMergePick> pickRadio(String kind, String key, String pick) =>
          tester.widget<Radio<EnhancementMergePick>>(find.byKey(Key('enhancement_merge_${kind}_${key}_$pick')));
      TextField memoField() => tester.widget<TextField>(find.byKey(const Key('enhancement_merge_memo_$_memoKey')));

      await _toggleCard(tester, 'older');
      expect(_selectedShown(tester), isNull);
      expect(pickRadio('memo', _memoKey, 'older').enabled, isFalse);
      expect(pickRadio('rating', _ratingKey, 'older').enabled, isFalse);
      expect(memoField().enabled, isFalse);

      await _toggleCard(tester, 'older');
      expect(pickRadio('memo', _memoKey, 'older').enabled, isTrue);
      expect(pickRadio('rating', _ratingKey, 'older').enabled, isTrue);
      expect(memoField().enabled, isTrue);
      expect(_selectedShown(tester), 'older');
      expect(_pickShown(tester, 'memo'), EnhancementMergePick.free);
      expect(memoField().controller?.text, 'typed');

      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.lastKeptContentId, 'older');
      expect(calls.lastChoices?.memo, {_memoKey: 'typed'});
    });

    testWidgets('the dismissal is not held back by a long read, as the dismiss button never was', (tester) async {
      // The dismissal writes only the dismissal file, not the record store the long read protects.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records, held: [_layout.charaDetailDir]);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      expect(_confirmAction(tester), isNull, reason: 'the control: the merge is held back');

      await _toggleCard(tester, 'newer');
      expect(_confirmAction(tester), isNotNull);
      expect(_confirmTooltip(tester), isNot(contains(appSentenceAt(longReadBusyKey))));
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.log, ['dismiss:older/newer']);
    });

    testWidgets('the dismissal is not held back by a rejected rating, which only concerns the merge', (tester) async {
      final pair = _pair();
      final container = _container(calls: _Calls(), records: pair.records, rating: {'older': 1.0, 'newer': 4.0});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      await tester.tap(find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('enhancement_merge_rating_$_ratingKey')), 'abc');
      await tester.pumpAndSettle();
      expect(_confirmAction(tester), isNull, reason: 'the control: the merge waits for a rating');

      await _toggleCard(tester, 'newer');
      expect(_confirmAction(tester), isNotNull);
    });

    testWidgets('Confirm and the cards wait for the merge marker', (tester) async {
      final pair = _pair();
      final markerGate = Completer<void>();
      final calls = _Calls()..markerGate = markerGate;
      final container = _container(calls: calls, records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      expect(_confirmAction(tester), isNull, reason: 'merge: the marker decides what the merge may do');
      expect(_selectedShown(tester), 'older', reason: 'an unread marker counts as unfinished');
      expect(_toggleEnabled(tester, 'older'), isFalse);
      expect(_toggleEnabled(tester, 'newer'), isFalse);

      markerGate.complete();
      await tester.pumpAndSettle();
      expect(_confirmAction(tester), isNotNull);
      expect(_selectedShown(tester), 'newer', reason: 'the enhanced card becomes the default once the marker lands');
      expect(_toggleEnabled(tester, 'newer'), isTrue);
    });

    testWidgets('the marker landing on another kept side clears a rejected rating', (tester) async {
      // While the marker is read the pair counts as unfinished and resolves from the older side.
      // Its landing moves the kept side to the newer default, which re-resolves the field exactly
      // as picking that card would, so the rejection of the replaced text has to go with it.
      final pair = _pair(enhanced: null);
      final markerGate = Completer<void>();
      final calls = _Calls()..markerGate = markerGate;
      final container = _container(calls: calls, records: pair.records, rating: {'older': 1.0, 'newer': 4.0});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      final field = find.byKey(const Key('enhancement_merge_rating_$_ratingKey'));
      final invalid = appSentenceAt('$_tr.rating_invalid');
      await tester.tap(find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, '1.0', reason: 'the older side while pending');
      await tester.enterText(field, 'abc');
      await tester.pumpAndSettle();
      expect(find.text(invalid), findsOneWidget);

      markerGate.complete();
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field).controller?.text, '4.0', reason: 'the newer default resolves it');
      expect(find.text(invalid), findsNothing, reason: 'the refused text is gone, so the error cannot stand');
      expect(_confirmAction(tester), isNotNull, reason: 'the field holds a rating again');
    });

    testWidgets('the merge button is inert with the long-read tooltip while a capture runs', (tester) async {
      final pair = _pair();
      final container = _container(calls: _Calls(), records: pair.records, held: [_layout.charaDetailDir]);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      expect(_confirmAction(tester), isNull);
      expect(_confirmTooltip(tester), contains(appSentenceAt(longReadBusyKey)));
    });

    testWidgets('the merge button is inert with the long-read tooltip while a video import runs', (tester) async {
      // The import half of the same ruling, and not a second wording of the capture case above: the
      // gate answers one containment question over the record store, so a change that answered it
      // per kind could keep capture out and let an import through. An import writes records into
      // the same store the merge is about to republish into.
      final pair = _pair();
      final container = _container(
        calls: _Calls(),
        records: pair.records,
        held: [_layout.charaDetailDir],
        kind: LongReadKind.videoImport,
      );
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      expect(_confirmAction(tester), isNull);
      expect(_confirmTooltip(tester), contains(appSentenceAt(longReadBusyKey)));
    });

    testWidgets('the route reaches the merge, and the kept-content side with it', (tester) async {
      // What the dialog is *for*: the defaults live in `EnhancementMergeChoices`, and the dialog
      // has to hand the route over for them to apply at all.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.captureCard),
      );

      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.lastChoices?.route, EnhancementMergeRoute.captureCard);
      expect(calls.lastKeptContentId, 'newer', reason: 'the enhanced side owns the content of an enhancement pair');
    });

    testWidgets('the cross is shut and a barrier tap never closes the dialog, while the merge runs', (tester) async {
      // A stray tap outside would drop what was typed, and mid-merge the cross would remove the only
      // surface that can report what the merge did.
      final pair = _pair();
      final gate = Completer<void>();
      final calls = _Calls()..gate = gate;
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      await _openReview(tester, container);
      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();

      CardDialog dialog() => tester.widget<CardDialog>(
        find.ancestor(of: find.byKey(const Key('enhancement_merge_apply')), matching: find.byType(CardDialog)),
      );
      expect(dialog().closeButtonTooltip, appSentenceAt('$_tr.close_tooltip'));
      expect(dialog().closeButtonEnabled, isTrue, reason: 'the control: the cross is open while idle');
      expect(container.read(dialogBuilderProvider)?.barrierDismissible, isFalse);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byType(EnhancementMergeDialog), findsOneWidget, reason: 'a barrier tap leaves it open');

      await _holdConfirm(tester);
      await tester.pump();

      expect(container.read(dialogBuilderProvider)?.barrierDismissible, isFalse, reason: 'nor while the merge runs');
      expect(dialog().closeButtonEnabled, isFalse, reason: 'the cross is shut while the merge runs');
      await tester.tapAt(const Offset(2, 2));
      await tester.tap(_mergeDialogCross, warnIfMissed: false);
      await tester.pump();
      expect(find.byType(EnhancementMergeDialog), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('enhancement_merge_apply')), findsNothing, reason: 'the dialog leaves on its own');
    });

    testWidgets('the cross closes only the dialog and performs nothing, with a card selected or none', (tester) async {
      for (final deselect in [false, true]) {
        final pair = _pair();
        final calls = _Calls();
        final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
        await _openReview(tester, container);
        await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
        await tester.pumpAndSettle();
        if (deselect) {
          await _toggleCard(tester, 'newer');
        }

        await tester.tap(_mergeDialogCross);
        await tester.pumpAndSettle();

        expect(find.byType(EnhancementMergeDialog), findsNothing, reason: 'deselect: $deselect');
        expect(find.byKey(const Key('enhancement_review_confirm')), findsOneWidget, reason: 'the list stays');
        expect(calls.log, isEmpty, reason: 'closing performs nothing (deselect: $deselect)');
      }
    });

    testWidgets('an outcome that lands after the dialog has gone still reaches the user', (tester) async {
      // The guards above are what shuts the dialog's own exits; this is the half that does not
      // depend on them. Whatever takes the widget away mid-merge - a rebuild of the page under it,
      // the window closing - the refusal still has to arrive as a toast and as the row's note.
      const outcome = EnhancementMergeOutcome.refusedMissing;
      final pair = _pair();
      final gate = Completer<void>();
      final calls = _Calls()
        ..gate = gate
        ..result = const EnhancementMergeResult(outcome: outcome, needsReload: false);
      final container = _container(calls: calls, candidates: [pair.candidate], records: pair.records);
      final toasts = _collectToasts(container);
      await _openReview(tester, container);
      await tester.tap(find.byKey(const Key('enhancement_review_merge_newer_older')));
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pump();

      // Closes the top entry only, which is the merge dialog; the review list underneath stays.
      container.read(dialogBuilderProvider.notifier).dismiss();
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();

      expect(
        toasts.map((e) => e.description),
        contains(appSentenceAt(enhancementMergeOutcomeKey(outcome))),
        reason: 'the outcome is the flow\'s, not the dialog widget\'s',
      );
      expect(
        find.text(appSentenceAt(enhancementMergeOutcomeKey(outcome))),
        findsOneWidget,
        reason: 'the row that opened the merge still gets its refusal note',
      );
    });

    testWidgets('memo and rating rows are left out when neither side has a value', (tester) async {
      final pair = _pair();
      final container = _container(
        calls: _Calls(),
        records: pair.records,
        memo: {'someone else': 'x'},
        rating: {'someone else': 2.0},
      );
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      for (final kind in ['memo', 'rating']) {
        final key = kind == 'memo' ? _memoKey : _ratingKey;
        expect(find.byKey(Key('enhancement_merge_${kind}_${key}_older')), findsNothing, reason: kind);
        expect(find.byKey(Key('enhancement_merge_${kind}_same_$key')), findsNothing, reason: kind);
      }
      expect(find.text('memo'), findsNothing);
      expect(find.text('rating'), findsNothing);
    });

    testWidgets('a value both sides share is stated without a choice, and the merge is asked nothing about it', (
      tester,
    ) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(
        calls: calls,
        records: pair.records,
        memo: {'older': 'same memo', 'newer': 'same memo'},
        rating: {'older': 2.5, 'newer': 2.5},
      );
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      expect(find.byKey(const Key('enhancement_merge_memo_same_$_memoKey')), findsOneWidget);
      expect(find.byKey(const Key('enhancement_merge_rating_same_$_ratingKey')), findsOneWidget);
      expect(find.text('same memo'), findsOneWidget);
      expect(find.text('2.5'), findsOneWidget);
      expect(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_older')), findsNothing);
      expect(find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_older')), findsNothing);

      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.lastChoices?.memo, isEmpty);
      expect(calls.lastChoices?.rating, isEmpty);
    });

    testWidgets('the default pick follows the route: the enhanced side on settings, the older on the card', (
      tester,
    ) async {
      // The enhanced side is `newer` here, and the settings route takes its value
      // even when it has none.
      final pair = _pair();
      await _pump(
        tester,
        _container(
          calls: _Calls(),
          records: pair.records,
          memo: {'older': 'from older'},
          rating: {'older': 1.0, 'newer': 4.0},
        ),
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      expect(_pickShown(tester, 'memo'), EnhancementMergePick.newer);
      expect(_pickShown(tester, 'rating'), EnhancementMergePick.newer);
      expect(
        find.text(appSentenceAt('$_tr.pick_newer').replaceAll('{value}', appSentenceAt('$_tr.none'))),
        findsOneWidget,
        reason: 'the side without a value reads as none',
      );

      await _pump(
        tester,
        _container(
          calls: _Calls(),
          records: pair.records,
          memo: {'older': 'from older'},
          rating: {'older': 1.0, 'newer': 4.0},
        ),
        EnhancementMergeDialog(
          key: const ValueKey('card'),
          candidate: pair.candidate,
          route: EnhancementMergeRoute.captureCard,
        ),
      );
      expect(_pickShown(tester, 'memo'), EnhancementMergePick.older);
      expect(_pickShown(tester, 'rating'), EnhancementMergePick.older);
    });

    testWidgets('an identical pair defaults to the side that has a value, and to the kept content when both do', (
      tester,
    ) async {
      // The newer card is the kept side by default, so a value both sides hold differently is the newer's.
      final pair = _pair(enhanced: null);
      final calls = _Calls();
      await _pump(
        tester,
        _container(
          calls: calls,
          records: pair.records,
          memo: {'newer': 'only newer'},
          rating: {'older': 1.0, 'newer': 4.0},
        ),
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      expect(_pickShown(tester, 'memo'), EnhancementMergePick.newer, reason: 'the only side with a memo');
      expect(_pickShown(tester, 'rating'), EnhancementMergePick.newer, reason: 'the kept content is the newer');

      await _toggleCard(tester, 'older');
      expect(_pickShown(tester, 'rating'), EnhancementMergePick.older, reason: 'it follows the kept content');
      expect(_pickShown(tester, 'memo'), EnhancementMergePick.newer, reason: 'still the only side with a memo');
    });

    testWidgets('a memo key offers older, newer and free input, and the typed text is what is written', (tester) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(
        calls: calls,
        records: pair.records,
        memo: {'older': 'from older', 'newer': 'from newer'},
      );
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      final field = find.byKey(const Key('enhancement_merge_memo_$_memoKey'));
      expect(field, findsNothing, reason: 'the field belongs to free input');
      // Both sides' values are on the options, so the user chooses by reading rather than by
      // remembering which column was which.
      await tester.tap(find.text(appSentenceAt('$_tr.pick_older').replaceAll('{value}', 'from older')));
      await tester.pumpAndSettle();
      expect(_pickShown(tester, 'memo'), EnhancementMergePick.older);

      await tester.tap(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_free')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, 'from older', reason: 'free input starts from the pick');

      await tester.enterText(field, 'edited');
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.lastChoices?.memo, {_memoKey: 'edited'}, reason: 'the field the user edited is what is written');
    });

    testWidgets('picking a side after typing replaces the typed memo, in the choice and in the field', (tester) async {
      // The side is picked to undo what was typed, so the merge must not write the typed text, and
      // free input reopened afterwards must not bring it back either.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(
        calls: calls,
        records: pair.records,
        memo: {'older': 'from older', 'newer': 'from newer'},
      );
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      final field = find.byKey(const Key('enhancement_merge_memo_$_memoKey'));
      await tester.tap(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_free')));
      await tester.pumpAndSettle();
      await tester.enterText(field, 'typed by mistake');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_newer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_free')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, 'from newer');

      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.lastChoices?.memo, {_memoKey: 'from newer'});
    });

    testWidgets('a rating typed in free input is prefilled from the pick, and the edited star is what is written', (
      tester,
    ) async {
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records, rating: {'older': 1.0, 'newer': 4.0});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      await tester.tap(find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free')));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('enhancement_merge_rating_$_ratingKey'));
      expect(tester.widget<TextField>(field).controller?.text, '4.0', reason: "the settings route's enhanced side");

      await tester.enterText(field, '2.5');
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.lastChoices?.rating, {_ratingKey: 2.5}, reason: 'a half star is a rating the app can hold');
    });

    testWidgets('an emptied rating field is the deliberate "no rating" and is carried as one', (tester) async {
      // The merge is allowed to end with no rating, and an empty field is the only way to ask for
      // it when both sides have one. It has to stay distinguishable from a typo.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records, rating: {'older': 1.0, 'newer': 4.0});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      await tester.tap(find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('enhancement_merge_rating_$_ratingKey')), '');
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.lastChoices?.rating, {_ratingKey: null});
    });

    testWidgets('text that is not a rating writes nothing: the merge waits and the row says why', (tester) async {
      // A typo reaches neither the store nor the choice: text that does not parse is not a request
      // to delete the rating, and a number that parses but no rating bar could produce is not one
      // either.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records, rating: {'older': 1.0, 'newer': 4.0});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      final free = find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free'));
      final field = find.byKey(const Key('enhancement_merge_rating_$_ratingKey'));
      final invalid = appSentenceAt('$_tr.rating_invalid');
      await tester.tap(free);
      await tester.pumpAndSettle();

      for (final typo in ['3,5', '999', '3.3', '-1', 'abc']) {
        await tester.enterText(field, typo);
        await tester.pumpAndSettle();
        expect(_confirmAction(tester), isNull, reason: typo);
        expect(find.text(invalid), findsOneWidget, reason: typo);
      }

      // A side is a way back out, and it has to replace the text as well as the choice.
      await tester.tap(find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_older')));
      await tester.pumpAndSettle();
      expect(_confirmAction(tester), isNotNull);
      await tester.tap(free);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, '1.0');
      expect(find.text(invalid), findsNothing);

      await tester.enterText(field, '3');
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.lastChoices?.rating, {_ratingKey: 3.0}, reason: 'the corrected value, and never the typo');
    });

    testWidgets('switching the kept side clears a rejected rating along with the text it stood for', (tester) async {
      // The content choice re-resolves every field from the newly kept side. A rejection is a
      // statement about the text the field was holding, so it cannot outlive it: a valid rating on
      // screen under an error message, with Merge inert, is a state the user can only leave by
      // typing again - and nothing tells them that is what is needed.
      final pair = _pair(enhanced: null);
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records, rating: {'older': 1.0, 'newer': 4.0});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      final field = find.byKey(const Key('enhancement_merge_rating_$_ratingKey'));
      final invalid = appSentenceAt('$_tr.rating_invalid');
      await tester.tap(find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, '4.0', reason: 'the newer side by default');

      await tester.enterText(field, 'abc');
      await tester.pumpAndSettle();
      expect(find.text(invalid), findsOneWidget);
      expect(_confirmAction(tester), isNull);

      await _toggleCard(tester, 'older');

      expect(tester.widget<TextField>(field).controller?.text, '1.0', reason: 'the newly kept side resolves it');
      expect(find.text(invalid), findsNothing, reason: 'the refused text is gone, so the error cannot stand');
      expect(_confirmAction(tester), isNotNull, reason: 'the field holds a rating again');

      // The deliberate "no rating" is a choice and not a refusal, so the content choice has to
      // leave it where it is: re-resolving it would put back a rating the user emptied the field
      // to remove.
      await tester.enterText(field, '');
      await tester.pumpAndSettle();
      await _toggleCard(tester, 'newer');
      expect(tester.widget<TextField>(field).controller?.text, '');

      await _holdConfirm(tester);
      await tester.pumpAndSettle();
      expect(calls.lastChoices?.rating, {_ratingKey: null});
    });

    testWidgets('picking a side whose rating is already the resolved one still replaces the typed text', (
      tester,
    ) async {
      // The rating twin of the memo case above, in the one sequence a rebuild cannot repair: '3'
      // and 3.0 are the same rating, so nothing about the resolved value moves and free input would
      // go on showing the shorthand the side was picked to replace.
      final pair = _pair();
      final calls = _Calls();
      final container = _container(calls: calls, records: pair.records, rating: {'older': 1.0, 'newer': 3.0});
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );

      final free = find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free'));
      final field = find.byKey(const Key('enhancement_merge_rating_$_ratingKey'));
      await tester.tap(free);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, '3.0');
      await tester.enterText(field, '3');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller?.text, '3', reason: '3 is already the resolved rating');

      await tester.tap(find.text(appSentenceAt('$_tr.pick_newer').replaceAll('{value}', '3.0')));
      await tester.pumpAndSettle();
      await tester.tap(free);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field).controller?.text, '3.0');
      expect(calls.lastChoices, isNull, reason: 'the pick is not a merge');
    });

    testWidgets('while the merge runs the bottom row and the cards are shut: Cancel, Confirm, the toggle', (
      tester,
    ) async {
      // The only exits [_merge] leaves open. Taken mid-merge, Cancel cancels nothing and removes the
      // only surface that can say what the merge did; the barrier and the cross are the case above.
      final pair = _pair();
      final gate = Completer<void>();
      final calls = _Calls()..gate = gate;
      final container = _container(calls: calls, records: pair.records);
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      final cancel = find.ancestor(
        of: find.text(appSentenceAt('pages.chara_detail.enhancement_merge.cancel')),
        matching: find.byType(TextButton),
      );
      // The negative control: all are live while the dialog is only asking the question.
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      expect(_toggleEnabled(tester, 'newer'), isTrue);

      await _holdConfirm(tester);
      await tester.pump();

      expect(tester.widget<TextButton>(cancel).onPressed, isNull, reason: 'Cancel is shut while it runs');
      expect(_toggleEnabled(tester, 'newer'), isFalse, reason: 'and so is the deselect that would dismiss');
      expect(_confirmAction(tester), isNull, reason: 'and Confirm cannot start a second run');

      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('while the merge runs the metadata picks and their free input are shut', (tester) async {
      // The running merge was handed the choices as they stood. A pick or a keystroke accepted
      // after that would show on screen and never be written, so neither is offered.
      final pair = _pair();
      final gate = Completer<void>();
      final calls = _Calls()..gate = gate;
      final container = _container(
        calls: calls,
        records: pair.records,
        memo: {'older': 'from older', 'newer': 'from newer'},
        rating: {'older': 1.0, 'newer': 4.0},
      );
      await _pump(
        tester,
        container,
        EnhancementMergeDialog(candidate: pair.candidate, route: EnhancementMergeRoute.settings),
      );
      // Free input on both keys, so the fields are on screen to be asked about at all.
      await tester.tap(find.byKey(const Key('enhancement_merge_memo_${_memoKey}_free')));
      await tester.pumpAndSettle();
      final ratingFree = find.byKey(const Key('enhancement_merge_rating_${_ratingKey}_free'));
      await tester.ensureVisible(ratingFree);
      await tester.tap(ratingFree);
      await tester.pumpAndSettle();

      bool? pickEnabled(String prefix, EnhancementMergePick pick) => tester
          .widget<Radio<EnhancementMergePick>>(find.byKey(Key('enhancement_merge_${prefix}_${pick.name}')))
          .enabled;
      bool? fieldEnabled(String key) => tester.widget<TextField>(find.byKey(Key(key))).enabled;

      // The negative control: every one of them is live while the dialog is only asking.
      for (final pick in EnhancementMergePick.values) {
        expect(pickEnabled('memo_$_memoKey', pick), isTrue, reason: 'idle: memo ${pick.name}');
        expect(pickEnabled('rating_$_ratingKey', pick), isTrue, reason: 'idle: rating ${pick.name}');
      }
      expect(fieldEnabled('enhancement_merge_memo_$_memoKey'), isTrue);
      expect(fieldEnabled('enhancement_merge_rating_$_ratingKey'), isTrue);

      await _holdConfirm(tester);
      await tester.pump();

      for (final pick in EnhancementMergePick.values) {
        expect(pickEnabled('memo_$_memoKey', pick), isFalse, reason: 'running: memo ${pick.name}');
        expect(pickEnabled('rating_$_ratingKey', pick), isFalse, reason: 'running: rating ${pick.name}');
      }
      expect(fieldEnabled('enhancement_merge_memo_$_memoKey'), isFalse, reason: 'the memo field is shut');
      expect(fieldEnabled('enhancement_merge_rating_$_ratingKey'), isFalse, reason: 'and so is the rating field');

      gate.complete();
      await tester.pumpAndSettle();
    });
  });

  group('what the rating field accepts', () {
    test('a whole or half star from zero to five, and nothing else', () {
      for (final text in ['0', '0.5', '2.5', '5', '5.0', ' 3.5 ']) {
        expect(parseEnhancementMergeRating(text)?.value, double.parse(text.trim()), reason: text);
      }
      for (final text in ['', '   ']) {
        final parsed = parseEnhancementMergeRating(text);
        expect(parsed, isNotNull, reason: 'an empty field is the absent rating, not a refusal');
        expect(parsed?.value, isNull, reason: text);
      }
      for (final text in ['3,5', '3.3', '999', '5.5', '-0.5', '-1', 'abc', '1e3', 'NaN', 'Infinity']) {
        expect(parseEnhancementMergeRating(text), isNull, reason: text);
      }
    });
  });

  group('the capture card notice', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      required _Calls calls,
      required List<EnhancementCandidate> candidates,
      required List<CharaDetailRecord> records,
      List<PathEntity> held = const [],
      LongReadKind kind = LongReadKind.liveCapture,
      String captured = 'newer',
    }) async {
      final container = _container(calls: calls, candidates: candidates, records: records, held: held, kind: kind);
      // The event provider is lazy: nothing subscribes to the capture state until something reads
      // it, so it is read before the state is seeded rather than after.
      container.read(captureEventProvider);
      container.read(charaDetailCaptureStateProvider.notifier)
        ..started(captured)
        ..success(captured);
      await _pump(tester, container, const CaptureEventView());
    }

    /// Merges one row of the review list and returns once its dialog is gone.
    Future<void> mergeRow(WidgetTester tester, EnhancementCandidate candidate) async {
      await tester.tap(find.byKey(Key('enhancement_review_merge_${candidate.pair.first}_${candidate.pair.second}')));
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('a just-captured record that is part of a pending candidate gets the notice', (tester) async {
      final pair = _pair();
      final calls = _Calls();
      await pumpCard(tester, calls: calls, candidates: [pair.candidate], records: pair.records);

      expect(find.byKey(const Key('capture_enhancement_candidate')), findsOneWidget);
    });

    testWidgets('a record in no candidate gets no notice', (tester) async {
      // The negative control: without it a card that always drew the tile would pass above.
      final pair = _pair();
      await pumpCard(tester, calls: _Calls(), candidates: const [], records: pair.records);

      expect(find.byKey(const Key('capture_enhancement_candidate')), findsNothing);
    });

    testWidgets('the notice is inert while the capture still holds the store', (tester) async {
      final pair = _pair();
      await pumpCard(
        tester,
        calls: _Calls(),
        candidates: [pair.candidate],
        records: pair.records,
        held: [_layout.charaDetailDir],
      );

      final tile = tester.widget<CaptureMessageTile>(find.byKey(const Key('capture_enhancement_candidate')));
      expect(tile.onTap, isNull);
      expect(tile.tooltip, appSentenceAt(longReadBusyKey));
    });

    testWidgets('the notice is inert while a video import holds the store', (tester) async {
      // The import leg at the capture card. The notice is the one merge entry a user meets without
      // opening settings, so the gate has to hold here too and not only where settings opens.
      final pair = _pair();
      await pumpCard(
        tester,
        calls: _Calls(),
        candidates: [pair.candidate],
        records: pair.records,
        held: [_layout.charaDetailDir],
        kind: LongReadKind.videoImport,
      );

      final tile = tester.widget<CaptureMessageTile>(find.byKey(const Key('capture_enhancement_candidate')));
      expect(tile.onTap, isNull);
      expect(tile.tooltip, appSentenceAt(longReadBusyKey));
    });

    testWidgets('the inert notice renders its reason: the tooltip is on the tile, not on the chevron', (tester) async {
      // Holding the sentence in a widget property is not showing it. The chevron the tooltip used
      // to hang from is drawn only for a tile that accepts a tap, so the explanation disappeared
      // in the one state whose explanation the user cannot work out for themselves.
      final pair = _pair();
      List<String?> tooltipsOnNotice() => tester
          .widgetList<Tooltip>(
            find.descendant(of: find.byKey(const Key('capture_enhancement_candidate')), matching: find.byType(Tooltip)),
          )
          .map((e) => e.message)
          .toList();

      await pumpCard(
        tester,
        calls: _Calls(),
        candidates: [pair.candidate],
        records: pair.records,
        held: [_layout.charaDetailDir],
      );
      expect(tooltipsOnNotice(), contains(appSentenceAt(longReadBusyKey)));

      // The negative control, and the case that was already working: a tile that does accept a tap
      // still says what the tap does.
      await pumpCard(tester, calls: _Calls(), candidates: [pair.candidate], records: pair.records);
      expect(
        tooltipsOnNotice(),
        contains(appSentenceAt('pages.capture.capture_control.event.enhancement_candidate.action')),
      );
    });

    testWidgets('the notice opens the merge on the capture-card route, not the settings one', (tester) async {
      // The route is what keeps the older record's memo and rating: the record the notice is about
      // was captured a moment ago and has none of its own. It has to survive the whole way from
      // this tile to the merge, which a dialog built directly in a test never exercises.
      final pair = _pair();
      final calls = _Calls();
      await pumpCard(tester, calls: calls, candidates: [pair.candidate], records: pair.records);

      await tester.tap(find.byKey(const Key('capture_enhancement_candidate')));
      await tester.pumpAndSettle();
      await _holdConfirm(tester);
      await tester.pumpAndSettle();

      expect(calls.lastChoices?.route, EnhancementMergeRoute.captureCard);
    });

    testWidgets('a record in several candidates keeps the capture-card route for its own pairs', (tester) async {
      // A chain of three copies: the captured record is the enhanced side of one pair and the
      // pre-enhancement side of another, so the notice opens the list rather than a dialog. The
      // list is the whole pending set, so the route is a property of the row: a pair holding the
      // captured record is a capture-card merge and every other pair is not.
      final chainA = _pair(older: 'older', newer: 'captured');
      final chainB = _pair(older: 'captured', newer: 'newest');
      final unrelated = _pair(older: 'x', newer: 'y');
      final calls = _Calls();
      await pumpCard(
        tester,
        calls: calls,
        candidates: [chainA.candidate, chainB.candidate, unrelated.candidate],
        records: [...chainA.records, chainB.records.last, ...unrelated.records],
        captured: 'captured',
      );

      await tester.tap(find.byKey(const Key('capture_enhancement_candidate')));
      await tester.pumpAndSettle();
      expect(find.byType(EnhancementReviewList), findsOneWidget, reason: 'more than one candidate opens the list');

      await mergeRow(tester, chainA.candidate);
      expect(
        calls.lastChoices?.route,
        EnhancementMergeRoute.captureCard,
        reason: 'the pair holding the just-captured record keeps the older side\'s memo and rating',
      );

      await mergeRow(tester, unrelated.candidate);
      expect(
        calls.lastChoices?.route,
        EnhancementMergeRoute.settings,
        reason: 'a pair the capture had nothing to do with takes the settings defaults',
      );
    });
  });

  group('the capture card list', () {
    Future<_Calls> openFromCard(WidgetTester tester) async {
      final chainA = _pair(older: 'older', newer: 'captured');
      final chainB = _pair(older: 'captured', newer: 'newest');
      final calls = _Calls();
      final container = _container(
        calls: calls,
        candidates: [chainA.candidate, chainB.candidate],
        records: [...chainA.records, chainB.records.last],
      );
      container.read(captureEventProvider);
      container.read(charaDetailCaptureStateProvider.notifier)
        ..started('captured')
        ..success('captured');
      await _pump(tester, container, const CaptureEventView());
      await tester.tap(find.byKey(const Key('capture_enhancement_candidate')));
      await tester.pumpAndSettle();
      expect(find.byType(EnhancementReviewList), findsOneWidget);
      return calls;
    }

    testWidgets('offers only Close, and no cross', (tester) async {
      await openFromCard(tester);

      // The intro is shown on this route too, not only on the settings one.
      final intro = find.byKey(const Key('enhancement_review_intro'));
      expect(tester.widget<Text>(intro).data, appSentenceAt('$tr_review.intro'));

      expect(find.byKey(const Key('enhancement_review_close')), findsOneWidget);
      expect(find.text(appSentenceAt('$tr_review.close')), findsOneWidget);
      expect(find.byKey(const Key('enhancement_review_cancel')), findsNothing);
      expect(find.byKey(const Key('enhancement_review_confirm')), findsNothing);
      expect(
        tester
            .widget<CardDialog>(
              find.descendant(of: find.byType(EnhancementReviewList), matching: find.byType(CardDialog)),
            )
            .closeButtonTooltip,
        isNull,
      );
    });

    testWidgets('Close runs nothing and closes the list', (tester) async {
      final calls = await openFromCard(tester);

      await tester.tap(find.byKey(const Key('enhancement_review_close')));
      await tester.pumpAndSettle();

      expect(calls.log, isEmpty, reason: 'the capture card has no step after the list');
      expect(find.byType(EnhancementReviewList), findsNothing);
    });
  });

  group('what a completed hold runs', () {
    EnhancementMergeAction? action(
      EnhancementMergeSelection selection, {
      bool running = false,
      bool? unfinished = false,
      bool blocked = false,
      bool ratingInvalid = false,
    }) => enhancementMergeConfirmAction(
      selection: selection,
      running: running,
      unfinished: unfinished,
      blocked: blocked,
      ratingInvalid: ratingInvalid,
    );

    test('no selection never dismisses an unfinished merge, nor one whose marker is still being read', () {
      // The dialog also disables the deselect toggle in both states, so no widget test can reach
      // this; the refusal here is what holds at the action if that toggle ever opens.
      expect(action(EnhancementMergeSelection.none), EnhancementMergeAction.dismiss, reason: 'the control');
      expect(action(EnhancementMergeSelection.none, unfinished: true), isNull);
      expect(action(EnhancementMergeSelection.none, unfinished: null), isNull);
    });

    test('no selection dismisses regardless of what only concerns a merge', () {
      expect(
        action(EnhancementMergeSelection.none, blocked: true, ratingInvalid: true),
        EnhancementMergeAction.dismiss,
      );
    });

    test('a selected card merges only when nothing holds it back, and nothing runs while running', () {
      for (final side in [EnhancementMergeSelection.older, EnhancementMergeSelection.newer]) {
        expect(action(side), EnhancementMergeAction.merge, reason: '$side');
        expect(action(side, unfinished: true), EnhancementMergeAction.merge, reason: '$side unfinished');
        expect(action(side, unfinished: null), isNull, reason: '$side marker pending');
        expect(action(side, blocked: true), isNull, reason: '$side blocked');
        expect(action(side, ratingInvalid: true), isNull, reason: '$side rating');
      }
      for (final selection in EnhancementMergeSelection.values) {
        expect(action(selection, running: true), isNull, reason: '$selection running');
      }
    });
  });

  group('the outcome table', () {
    test('every outcome has a shipped sentence, and none of them is a raw key', () {
      for (final outcome in EnhancementMergeOutcome.values) {
        final key = enhancementMergeOutcomeKey(outcome);
        expect(appSentenceAt(key), isNotEmpty, reason: '$outcome has no shipped sentence');
        expect(appSentenceAt(key), isNot(contains('{')), reason: '$outcome leaves a placeholder unfilled');
      }
    });
  });
}
