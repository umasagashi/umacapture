import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recase/recase.dart';
import 'package:umacapture/src/core/fs/record_recovery_reason.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
// Re-exports `storage_delete_report.dart`, whose `StorageDeleteFailure*` types this file also names.
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/localization.dart';

/// Two of the view's wording requirements, as machine checks.
///
/// The first is the safety rule that no implementation vocabulary reaches the
/// screen. The second is that a
/// sentence naming *why* something survived a delete names every condition the
/// reason it was given actually covers, rather than picking one of them and
/// stating it as the cause.
///
/// **Scope: `pages.storage.*`, the namespace settled on for this view.** Two
/// neighbouring namespaces are visible while the view is open and are deliberately
/// *not* enforced here, because neither belongs to this view:
///
///  * `app.record_store_startup.*` — `RecordStoreStartupOutageBanner` is mounted
///    app-wide in `app_widget.dart`, above every page. Its text does carry jargon
///    ("Web Locks API", "HTTPS"); it predates this view and is owned by the record
///    store, so putting it under this rule would be this file quietly taking over
///    another screen's wording.
///  * `toast.clipboard.*` — the copy button routes through `ClipboardAlt`, whose
///    toasts are shared with the image-copy callers.
///
/// Everything else the view renders resolves inside `pages.storage.*`:
/// `StoragePage` builds only `StorageTreeView`, and every `.tr()` reachable from
/// it, from `storage_file_preview.dart`, `storage_delete_action.dart`,
/// `storage_action_blocker.dart` and `lib/src/core/storage/` names a key in that
/// namespace.
void main() {
  late Map<String, String> storageStrings;

  setUpAll(() {
    final root = jsonDecode(File(_translationFile).readAsStringSync()) as Map<String, dynamic>;
    storageStrings = _leavesUnder(root['pages']['storage'], _storagePrefix);
  });

  group('every string under pages.storage.* is one a general user can read', () {
    setUpAll(loadAppTranslations);

    test('the detector fires on text that carries the jargon', () {
      // The negative control this whole group rests on. Green below means "no
      // forbidden term is present"; without this it could equally mean "the
      // matcher never matches anything", and the two are indistinguishable from
      // a passing run.
      expect(jargonIn('OPFS に保存されています'), contains('OPFS'));
      expect(jargonIn('decode に失敗しました'), contains('decode'));
      expect(jargonIn('隔離されました'), contains('隔離'));
      expect(jargonIn('バイナリのため表示できません'), contains('バイナリ'));
      // The machine-derived half: an internal enum spelling, in either casing.
      expect(jargonIn('quarantine を削除します'), contains('quarantine'));
      expect(jargonIn('column_spec を削除します'), contains('column_spec'));
      expect(jargonIn('dataRootConfig を削除します'), contains('dataRootConfig'));
    });

    test('the detector does not fire on the words this view deliberately keeps', () {
      // The other half of the control: a list broad enough to be useless would
      // also pass the check above. These four are shipped strings (or fragments
      // of them) that must stay legal, and each is a term the list was
      // deliberately not given.
      //
      //  * `.json` — a file extension the user reads off the tree itself. No
      //    `pages.storage.*` sentence spells it out any more — the 2026-08-30
      //    rewrite shortened `download.needs_extension` — but the row names the
      //    tree draws are file names, not translations, and still carry it.
      //  * `キャッシュ` — an ordinary Japanese loanword; `font_cache.description`
      //    and `summary.browser_total_note` both ship it. (The label itself was
      //    「フォントキャッシュ」 until the 2026-08-30 rewrite shortened it to 「フォント」.)
      //  * `アーカイブ` — the user-facing name of a group, and the ASCII `archive`
      //    it transliterates contains `hive`, which the boundary rule must not
      //    catch.
      expect(jargonIn('record.json'), isEmpty);
      expect(jargonIn('ブラウザ自身のキャッシュを含みます'), isEmpty);
      expect(jargonIn('アーカイブ archive に移動しました'), isEmpty);
      expect(jargonIn('約 10 MB'), isEmpty);
    });

    test('no shipped string carries any of them', () {
      // Non-vacuity: an empty map would satisfy the loop below without reading a
      // single sentence.
      expect(storageStrings, hasLength(greaterThan(50)));
      expect(storageStrings.keys, contains('pages.storage.title'));
      final offenders = <String, List<String>>{};
      for (final entry in storageStrings.entries) {
        final found = jargonIn(entry.value);
        if (found.isNotEmpty) {
          offenders[entry.key] = found;
        }
      }
      expect(offenders, isEmpty);
    });

    test('the one translated sentence this view shows from outside the namespace is held to the rule too', () {
      // `app.long_read_busy` is what the tree's copy, zip, save and delete controls say when a
      // long reader holds what they would touch — so it reaches this screen — but its key is not
      // under `pages.storage.*` and the walk above therefore never sees it. It is the refusal
      // every one of those surfaces shows, so this audit has to name it to cover them.
      //
      // Named one by one rather than by widening the walk to all of `app.*`: that namespace also
      // holds `record_store_startup.*`, whose jargon this view deliberately does not own (see the
      // scope note at the top of this file). A second *translated* sentence arriving here from
      // outside has to be added by hand, which is the cost of the exclusion above being deliberate.
      //
      // It is not the only sentence that reaches this screen from outside the walk: the delete
      // result panel's survivor rows are built by `core/storage/storage_delete.dart`. Those are
      // held by the cases below, which find the field's producers by parsing instead of naming them.
      expect(jargonIn(longReadBusyMessage()), isEmpty);
      // And it resolved: `.tr()` renders an unknown key as the key, and a key carries no jargon
      // either, so an unresolved one would pass the line above by being the wrong thing entirely.
      expect(longReadBusyMessage(), isNot(contains(longReadBusyKey)));
    });

    test('a survivor row shows the platform error or the recovery clause, and nothing else', () {
      // `storage_delete_action.dart` renders `StorageDeleteFailure.detail` verbatim in the survivor
      // rows, so whatever a producer puts there reaches the user with no key, no translation and
      // nothing for the walk over `pages.storage.*` to see. The field is a sealed type with no
      // `String` in it; this pins what each of its two kinds renders to, and that the platform kind
      // refuses a `String` passed off as a thrown error. What the platform kind is built *from* is the
      // next case's to hold, and which kind a real recovery failure produces is held by
      // `expectRecoveryIncompleteFailure`, over the reports the recovery suites' deletes return.
      const refusal = FileSystemException('The process cannot access the file');
      expect(storageDeleteFailureDetailText(const StorageDeletePlatformDetail(refusal)), refusal.toString());
      for (final recordId in ['レコード', null]) {
        expect(
          storageDeleteFailureDetailText(
            StorageDeleteRecoveryIncompleteDetail(
              recordId: recordId,
              reason: RecordRecoveryIncompleteReason.unreadableManifest,
            ),
          ),
          storageRecoveryIncompleteDetail(
            recordId: recordId,
            reason: RecordRecoveryIncompleteReason.unreadableManifest,
          ),
          reason: 'recordId: $recordId',
        );
      }
      final Object written = 'Recovery did not finish, so this was kept.';
      expect(() => StorageDeletePlatformDetail(written), throwsA(isA<AssertionError>()));
    });

    test('every reason the survivor row can carry renders as a shipped Japanese clause', () {
      // The recovery-incomplete rendering, exercised over the machine's own enumeration rather
      // than over a value written here, so every jargon and placeholder check reads a sentence
      // the app actually shows.
      //
      // `.values` and not a list, so a twentieth reason is rendered the moment it is added.
      expect(
        RecordRecoveryIncompleteReason.values,
        hasLength(greaterThan(10)),
        reason: 'the enumeration is too small to be the set of things recovery can fail at',
      );
      for (final reason in RecordRecoveryIncompleteReason.values) {
        final shown = storageRecoveryIncompleteDetail(recordId: null, reason: reason);
        expect(jargonIn(shown), isEmpty, reason: '$reason');
        // The clause the brackets carry must not be the English one the log uses. `clause` is on
        // the enum, so this compares the row against recovery's own words.
        expect(shown, isNot(contains(reason.clause)), reason: '$reason');
        // And nothing else in Latin letters either — a key `.tr()` could not resolve renders as
        // the key, and a reason mapped to a missing key would come through as
        // `pages.storage.delete.recovery_reason.…` with no other check noticing.
        expect(
          RegExp(r'[A-Za-z]{3,}').hasMatch(shown),
          isFalse,
          reason: '$reason renders Latin text into the survivor row: $shown',
        );
        // A placeholder with no argument stands verbatim, and `{reason}` is the one this sentence
        // has.
        expect(shown, isNot(contains('{')), reason: '$reason');
      }
    });

    test('the derived half of the list is the enums themselves, not a copy of them', () {
      // The guard on the guard. `forbiddenTerms` is partly hand-written — the
      // requirement named five words and nothing can derive the sixth — but the part that
      // *can* be counted is counted: every group id and every settings-store key,
      // in both spellings. A thirteenth group would otherwise ship its internal
      // name with nothing to notice.
      for (final id in StorageGroupId.values) {
        expect(forbiddenTerms, contains(id.name));
        expect(forbiddenTerms, contains(id.name.snakeCase));
      }
      for (final key in StorageBoxKey.values) {
        expect(forbiddenTerms, contains(key.name));
        expect(forbiddenTerms, contains(key.name.snakeCase));
      }
      // And the five the safety rule spells out are named by hand, so a rewrite of
      // the list cannot drop the ones the rule itself wrote down.
      expect(forbiddenTerms, containsAll(<String>['OPFS', 'Hive', 'quarantine', '隔離', 'decode']));
    });
  });

  group('a remedy a sentence offers is one this view actually has', () {
    setUpAll(loadAppTranslations);

    /// Whether [sentence] tells the user to refresh something and try again.
    bool sendsTheUserToARefresh(String sentence) => sentence.contains('更新して') || sentence.contains('一覧を更新');

    test('the detector fires on the sentence that sent them to one', () {
      // The negative control, written as the defect itself: `reveal.failed` shipped as
      // 「フォルダを開けませんでした。一覧を更新して、もう一度お試しください。」 and this view has no
      // refresh — `FreshStorageTree` re-reads on mount and nothing else drops the providers, so the
      // list updates by leaving and coming back and by no other act. Without this line the
      // assertion below would read the same whether the remedy is nameable or the predicate matches
      // nothing at all.
      expect(sendsTheUserToARefresh('フォルダを開けませんでした。一覧を更新して、もう一度お試しください。'), isTrue);
      expect(sendsTheUserToARefresh('フォルダを開けませんでした。この画面を開き直してから、もう一度お試しください。'), isFalse);
    });

    test('no sentence sends the user to a refresh this view has no control for', () {
      // Non-vacuity, as everywhere else in this file: an empty map would satisfy the loop
      // without reading a sentence.
      expect(storageStrings, hasLength(greaterThan(50)));
      final offenders = {
        for (final entry in storageStrings.entries)
          if (sendsTheUserToARefresh(entry.value)) entry.key,
      };
      expect(offenders, isEmpty);
      // And the one this was written for still names the remedy that does exist. Read through
      // `.tr()` so an entry deleted outright fails here: an unresolved key renders as the key,
      // which carries no remedy either and would pass the emptiness above.
      expect('pages.storage.reveal.failed'.tr(), contains('この画面を開き直して'));
    });
  });

  group('a delete warning says what is lost, not only that it is irreversible', () {
    setUpAll(loadAppTranslations);

    /// The paragraphs of [warning], as the confirm dialog's card draws them.
    List<String> paragraphsOf(String warning) => warning.split('\n\n');

    test('the detector fires on a warning that is only the shared first sentence', () {
      // The negative control, written as the defect itself: `quarantine` shipped as
      // 「この操作は取り消せません。」 and nothing else — a `doubleConfirm` group, so that one
      // sentence was promoted into a `WarningCard`, a loud box saying only what the acknowledge
      // checkbox beside it already said. It is the one group whose files are the user's own
      // records that the app could not read, moved rather than copied, and re-created by nothing.
      expect(paragraphsOf('この操作は取り消せません。'), hasLength(1));
      expect(paragraphsOf('この操作は取り消せません。\n\nこれは…データそのもので。'), hasLength(2));
    });

    test('every group that offers a delete warns in two paragraphs', () {
      // Enumerated off `storageGroups` rather than listed here: a twelfth group, or a group that
      // gains a delete, is held to this without anybody adding a line. Non-vacuity first — a
      // filter that started matching nothing would satisfy the loop below in silence.
      final warned = storageGroups.where((group) => group.deleteWarningKey != null).toList();
      expect(warned, hasLength(greaterThan(1)));
      for (final group in warned) {
        final key = group.deleteWarningKey ?? '';
        final warning = key.tr();
        // The key resolved: `.tr()` renders an unknown key as the key, which is one paragraph
        // and would fail below for the wrong reason.
        expect(warning, isNot(key), reason: '${group.id.name} has no translated warning');
        final paragraphs = paragraphsOf(warning);
        expect(paragraphs, hasLength(2), reason: '${group.id.name} renders as "$warning"');
        // The first is the sentence every group shares; the second is what THIS group loses, and
        // it has to say something of its own rather than repeat the first.
        expect(paragraphs.first, 'この操作は取り消せません。', reason: group.id.name);
        expect(paragraphs.last.trim(), isNotEmpty, reason: group.id.name);
        expect(paragraphs.last, isNot(paragraphs.first), reason: group.id.name);
      }
    });

    test('metadata delete warning names the merge-dismissal effect', () {
      // Deleting metadata deletes recorded merge dismissals too, so the
      // warning has to say a dismissed pair reappears as a candidate.
      final group = storageGroups.firstWhere((g) => g.id == StorageGroupId.metadata);
      final warning = (group.deleteWarningKey ?? '').tr();
      expect(
        warning,
        'この操作は取り消せません。\n\n'
        'メモやレーティングの削除は、通常は「殿堂入り管理」テーブル内で行えます。'
        '「統合しない」の記録を削除すると、その統合候補が再び表示されます。',
      );
    });
  });

  group('every {…} placeholder is filled in by the code that ships the sentence', () {
    // The gap this closes: the *names* of the placeholders were checked by
    // nothing. `storage_group_test.dart` compares the set of keys that carry a
    // `{…}`, which a rename leaves unchanged, and the sentence assertions in
    // `storage_delete_action_test.dart` interpolate `ja.json` with the same
    // names the production call site passes — so renaming `{name}` to `{title}`
    // in `ja.json` made both sides of those comparisons the identical
    // *un*substituted string and stayed green, while the app rendered
    // 「{title}を削除します。」 to the user.
    //
    // So the assertion here is on the rendered output of the production
    // function, not on an interpolation this file performs: `.tr()` leaves a
    // placeholder it was given no matching `namedArgs` for standing verbatim,
    // and a surviving `{` is exactly what the user would have seen.
    setUpAll(loadAppTranslations);

    /// Each placeholder-carrying key, rendered the way the app renders it.
    ///
    /// The map is compared against the keys walked out of `ja.json` below, so a
    /// new sentence with a placeholder cannot be added without a renderer: the
    /// enumeration is the machine's, and only the wiring is written here.
    final renderers = <String, String Function()>{
      'pages.storage.blocked.template': () =>
          storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.delete),
      'pages.storage.delete.target': () => storageDeleteTargetSentence('レコード'),
      // The survivor row, both halves of it. The id is absent whenever the sweep could not read
      // the slot's manifest, and the two keys exist so that neither branch renders a blank; a
      // renderer for only one of them would leave the other's placeholders unchecked.
      //
      // **The reason is a real one, and every one of them is rendered by the case further down**,
      // so the placeholders checked here are the ones the shipped row fills.
      'pages.storage.delete.recovery_incomplete': () =>
          storageRecoveryIncompleteDetail(recordId: 'レコード', reason: RecordRecoveryIncompleteReason.unreadableManifest),
      'pages.storage.delete.recovery_incomplete_unidentified': () =>
          storageRecoveryIncompleteDetail(recordId: null, reason: RecordRecoveryIncompleteReason.unreadableManifest),
      'pages.storage.delete.completed': () => storageDeleteOutcomeMessage(
        const StorageDeleteReport(deleted: [StorageDeletePathSubject('a'), StorageDeletePathSubject('b')]),
      ).description,
      'pages.storage.delete.none': () => storageDeleteOutcomeMessage(
        StorageDeleteReport.wholeRequest(
          subject: StorageDeletePathSubject('a'),
          reason: StorageDeleteFailureReason.lockBusy,
          detail: StorageDeletePlatformDetail(FileSystemException('busy')),
        ),
      ).description,
      'pages.storage.delete.partial': () => storageDeleteOutcomeMessage(
        StorageDeleteReport(
          deleted: const [StorageDeletePathSubject('a')],
          failed: [
            StorageDeleteFailure(
              subject: StorageDeletePathSubject('b'),
              reason: StorageDeleteFailureReason.lockBusy,
              detail: StorageDeletePlatformDetail(FileSystemException('busy')),
            ),
          ],
        ),
      ).description,
    };

    test('the detector fires on a sentence nobody filled in', () {
      // The negative control. Green below has to mean "the substitution ran",
      // not "no sentence carries a placeholder any more" — so the raw shipped
      // strings are shown to still carry the braces this looks for.
      for (final key in renderers.keys) {
        expect(appSentenceAt(key), contains('{'), reason: key);
      }
      expect('pages.storage.delete.target'.tr(), contains('{'));
    });

    test('the renderers cover exactly the keys ja.json gives a placeholder to', () {
      final placeholder = RegExp(r'\{[^}]*\}');
      final carriers = {
        for (final entry in storageStrings.entries)
          if (placeholder.hasMatch(entry.value)) entry.key,
      };
      expect(renderers.keys.toSet(), carriers);
    });

    test('no brace survives into the sentence the user is shown', () {
      for (final entry in renderers.entries) {
        final shown = entry.value();
        expect(
          shown,
          isNot(contains('{')),
          reason:
              '${entry.key} renders as "$shown": a placeholder in ja.json has a name '
              'the call site does not pass, so the braces reach the screen',
        );
        expect(shown, isNot(contains('}')), reason: entry.key);
        // And the key itself did resolve: `.tr()` renders an unresolved key as
        // the key, which carries no braces and would pass the two above.
        expect(shown, isNot(contains('pages.storage')), reason: entry.key);
      }
    });
  });

  group('a cause clause names every condition its reason covers', () {
    setUpAll(loadAppTranslations);

    test('the detector fires on a clause that names only one of them', () {
      // The negative control, written as the defect itself: `cause_in_use`
      // shipped as 「使用中のため」, which named one of the two conditions
      // `refused` covers and stated it as *the* cause. Without this line, the
      // assertion below would read the same whether the clause names both
      // conditions or the predicate matches everything.
      expect(_conditionsMissingFrom('使用中のため削除できませんでした。', StorageDeleteFailureReason.refused), ['読み取り専用']);
      expect(_conditionsMissingFrom('使用中または読み取り専用のため削除できませんでした。', StorageDeleteFailureReason.refused), isEmpty);
      // And the table is not empty: a reason with no conditions listed would
      // satisfy the loop below without reading a sentence.
      expect(_conditionsCoveredBy(StorageDeleteFailureReason.refused), hasLength(greaterThan(1)));
    });

    /// Every outcome whose sentence embeds a cause clause, for [reason].
    ///
    /// **Both, because the clause reaches the screen through two templates and a
    /// check on one says nothing about the other.** `delete.partial` could lose
    /// its `{cause}` with `delete.none` still carrying it, and the sentence the
    /// user reads would go back to naming no cause at all. The partial one is not
    /// the rarer branch either: the delete this wording was corrected for failed
    /// *partly* — 423 of 440 — which is exactly the outcome that renders through
    /// `delete.partial`.
    ///
    /// `delete.completed` is absent because it embeds no cause: a delete that
    /// left nothing behind has no survivor to explain.
    Map<String, StorageDeleteReport> outcomesFor(StorageDeleteFailureReason reason) => {
      'none': StorageDeleteReport.wholeRequest(
        subject: StorageDeletePathSubject('a'),
        reason: reason,
        detail: StorageDeletePlatformDetail(FileSystemException('detail')),
      ),
      'partial': StorageDeleteReport(
        deleted: const [StorageDeletePathSubject('a')],
        failed: [
          StorageDeleteFailure(
            subject: StorageDeletePathSubject('b'),
            reason: reason,
            detail: StorageDeletePlatformDetail(FileSystemException('detail')),
          ),
        ],
      ),
    };

    test('every reason renders a clause that names all of them', () {
      for (final reason in StorageDeleteFailureReason.values) {
        for (final outcome in outcomesFor(reason).entries) {
          // Rendered through the production function rather than interpolated
          // here, for the reason the placeholder group above gives: an assertion
          // that builds the sentence itself agrees with `ja.json` by
          // construction.
          final shown = storageDeleteOutcomeMessage(outcome.value).description;
          final where = '${outcome.key}/${reason.name}';
          // The key resolved: `.tr()` renders an unresolved key as the key, which
          // carries none of the conditions and would fail below for the wrong
          // reason.
          expect(shown, isNot(contains('pages.storage')), reason: where);
          expect(_conditionsMissingFrom(shown, reason), isEmpty, reason: '$where renders as "$shown"');
        }
      }
    });
  });

  group('the cause clause is derived from both surviving lists, and by how many it finds', () {
    setUpAll(loadAppTranslations);

    // The gap this group closes. Every case above hands the message function a
    // report with **exactly one** failure reason in it, so the two branches that
    // do not have exactly one clause — none, and more than one — were rendered by
    // nothing in this repository. The first of them is the one that shipped: a
    // delete whose only survivors were *retained* arrived with an empty set and
    // was announced with the clause that restates the question.
    StorageDeleteReport retainedOnly(StorageDeleteRetentionReason reason) => StorageDeleteReport(
      retained: [StorageDeleteRetention(subject: const StorageDeletePathSubject('a'), reason: reason)],
    );

    String clause(String name) => appSentenceAt('pages.storage.delete.$name');

    test('the shipped clauses are distinguishable, so the assertions below can tell them apart', () {
      // The negative control. Each assertion here is `contains` over a rendered
      // sentence, and that reads the same whether the clause is the right one or
      // every clause is a prefix of every other.
      final clauses = {
        for (final name in ['cause_unknown', 'cause_set_aside', 'cause_in_use', 'cause_busy']) clause(name),
      };
      expect(clauses, hasLength(4));
      for (final one in clauses) {
        expect(clauses.where((other) => other.contains(one)), hasLength(1), reason: one);
      }
    });

    test('no clause at all falls back, rather than rendering an empty cause', () {
      // Zero clauses. No producer builds this today — `_deleteOne` marks an
      // ancestor blocked only once it has put the blocker into `failed`, so an
      // empty `failed` and a blocked retention cannot occur together — and it is
      // asserted all the same, because "cannot occur" is exactly what the empty
      // set was taken to be for as long as it was reachable and unrendered.
      final shown = storageDeleteOutcomeMessage(
        retainedOnly(StorageDeleteRetentionReason.blockedBySurvivor),
      ).description;
      expect(shown, contains(clause('cause_unknown')));
      expect(shown, isNot(contains('{')));
      expect(shown, isNot(contains('pages.storage')));
    });

    test('one clause, taken from the retained list alone, names what was set aside', () {
      // The defect, in the shape it reached the user: the drain moved a slot's
      // staging onto the shelf the delete was pointed at, nothing failed, and the
      // whole sentence was 「削除できない状態だったため削除できませんでした。」
      final shown = storageDeleteOutcomeMessage(
        retainedOnly(StorageDeleteRetentionReason.setAsideByThisDelete),
      ).description;
      expect(shown, contains(clause('cause_set_aside')));
      expect(shown, isNot(contains(clause('cause_unknown'))));
      expect(shown, isNot(contains('{')));
      expect(shown, isNot(contains('pages.storage')));
    });

    test('the partial sentence embeds the same clause the whole-request one does', () {
      // `delete.partial` and `delete.none` are two templates, and a clause that
      // reaches one says nothing about the other — the reason the group above
      // renders both for every failure reason.
      final shown = storageDeleteOutcomeMessage(
        StorageDeleteReport(
          deleted: const [StorageDeletePathSubject('b')],
          retained: [
            StorageDeleteRetention(
              subject: const StorageDeletePathSubject('a'),
              reason: StorageDeleteRetentionReason.setAsideByThisDelete,
            ),
          ],
        ),
      ).description;
      expect(shown, contains(clause('cause_set_aside')));
      expect(shown, isNot(contains(clause('cause_unknown'))));
      expect(shown, isNot(contains('{')));
    });

    test('one clause still, because a blocked ancestor contributes none of its own', () {
      // The ordinary partial delete: one file refused, its parent retained
      // underneath it. If a blocked retention carried a clause, this — the
      // commonest failing delete there is — would become a mixture and would go
      // back to naming no cause at all.
      final shown = storageDeleteOutcomeMessage(
        StorageDeleteReport(
          deleted: const [StorageDeletePathSubject('a/one')],
          failed: [
            StorageDeleteFailure(
              subject: const StorageDeletePathSubject('a/two'),
              reason: StorageDeleteFailureReason.refused,
              detail: StorageDeletePlatformDetail(FileSystemException('held')),
            ),
          ],
          retained: [
            StorageDeleteRetention(
              subject: const StorageDeletePathSubject('a'),
              reason: StorageDeleteRetentionReason.blockedBySurvivor,
            ),
          ],
        ),
      ).description;
      expect(shown, contains(clause('cause_in_use')));
      expect(shown, isNot(contains(clause('cause_unknown'))));
    });

    test('two clauses claim neither of them', () {
      final shown = storageDeleteOutcomeMessage(
        StorageDeleteReport(
          failed: [
            StorageDeleteFailure(
              subject: const StorageDeletePathSubject('b'),
              reason: StorageDeleteFailureReason.lockBusy,
              detail: StorageDeletePlatformDetail(FileSystemException('busy')),
            ),
          ],
          retained: [
            StorageDeleteRetention(
              subject: const StorageDeletePathSubject('a'),
              reason: StorageDeleteRetentionReason.setAsideByThisDelete,
            ),
          ],
        ),
      ).description;
      expect(shown, contains(clause('cause_unknown')));
      expect(shown, isNot(contains(clause('cause_busy'))));
      expect(shown, isNot(contains(clause('cause_set_aside'))));
    });
  });
}

const _translationFile = 'assets/translations/ja.json';
const _storagePrefix = 'pages.storage';

/// Words that must not reach the screen: this view is written for a general user,
/// so implementation vocabulary is banned from it.
///
/// Three sources, deliberately separated:
///
///  1. **The five the requirement writes out** — `OPFS`, `Hive`, `quarantine`,
///     `隔離`, `decode`. It ends in 「等」, so the list is wider than this.
///  2. **The substrate those five are examples of.** Every term here is one this
///     view's own sources use as an implementation word: the browser storage
///     backends, the exclusion primitive, the zip worker, the settings file
///     extensions. `バイナリ` is here because stage 4 already decided against it —
///     `preview.unsupported` says only 「このファイルは中身を表示できません。」 and
///     names no format at all — and a decision nothing enforces is one the next
///     hint will not know about.
///  3. **The app's own identifiers, counted rather than copied** — see
///     [_internalIdentifierSpellings].
///
/// Words deliberately *not* here, because each is something a general user reads
/// rather than jargon: `.json` (an extension shown in the tree),
/// `キャッシュ` (an ordinary loanword, and the shipped name of a group),
/// `ロック`/`排他` (absent today, and the shipped refusals already say
/// 「使用中」 instead — banning them would be guessing at wording nobody wrote),
/// and `API`/`HTTP`, which exist only in `app.record_store_startup.*`, a
/// namespace this view does not own.
final List<String> forbiddenTerms = [
  // 1. The five the safety rule spells out, verbatim.
  'OPFS', 'Hive', 'quarantine', '隔離', 'decode',
  // 2. The same class of word.
  'Origin Private File System', 'IndexedDB', 'hivec', 'Web Locks', 'WebAssembly', 'wasm', 'Blob',
  'isolate', 'アイソレート', 'mutex', 'ミューテックス', 'encode', 'デコード', 'エンコード', 'バイナリ',
  // 3. Derived.
  ..._internalIdentifierSpellings,
];

/// Every internal name the view's two enumerated levels carry, in both spellings.
///
/// `settings_boxes.dart` states the rule this enforces — `column_spec` and
/// `data_migration` are 「アプリの内部の綴り」 and a general user has no way to read
/// them — and the same holds for the group ids one level up. Derived from
/// `.values` so a new member is covered on the day it is added; a transcribed
/// list is exactly the thing that would not be.
Iterable<String> get _internalIdentifierSpellings => <String>{
  for (final id in StorageGroupId.values) ...[id.name, id.name.snakeCase],
  for (final key in StorageBoxKey.values) ...[key.name, key.name.snakeCase],
};

/// The forbidden terms [text] contains, in the order [forbiddenTerms] lists them.
///
/// A term written in ASCII matches on word boundaries, so `archive` does not read
/// as `Hive` and `アーカイブ`'s romanisation stays legal; a term written in kana or
/// kanji matches as a substring, because Japanese has no boundary to anchor to.
List<String> jargonIn(String text) {
  final result = <String>[];
  for (final term in forbiddenTerms) {
    final escaped = RegExp.escape(term);
    final pattern = RegExp(
      term.codeUnits.every((c) => c < 128) ? '(?<![A-Za-z])$escaped(?![A-Za-z])' : escaped,
      caseSensitive: false,
    );
    if (pattern.hasMatch(text)) {
      result.add(term);
    }
  }
  return result;
}

/// Flattens the translation subtree at [prefix] into `dotted key -> sentence`.
Map<String, String> _leavesUnder(Object? node, String prefix) {
  final result = <String, String>{};
  void walk(Object? value, String path) {
    if (value is Map<String, dynamic>) {
      for (final entry in value.entries) {
        walk(entry.value, '$path.${entry.key}');
      }
    } else if (value is String) {
      result[path] = value;
    }
  }

  walk(node, prefix);
  return result;
}

/// The conditions one [StorageDeleteFailureReason] lumps together, as the words
/// the clause shipped for it has to carry.
///
/// Hand-written, like the five terms [forbiddenTerms] spells out and for the same
/// reason: nothing in the app can derive that `refused` covers two unrelated
/// refusals. The enum's own doc names them and says it will deliberately not
/// subdivide — `ERROR_SHARING_VIOLATION` (32), and `ERROR_ACCESS_DENIED` (5),
/// which is what a read-only entry on Windows is refused with — so the clause is
/// the only place a user is told that a read-only entry can land there too. A
/// clause naming the first condition alone would tell a user whose entry is merely
/// read-only that something is holding it open, while `File.delete` on a
/// read-only file fails with errno 5 and nothing holding it.
///
/// A plain read-only *file* does not reach this reason: the delete retries one
/// with the attribute cleared and removes it (`_deletedByClearingReadOnly` in
/// `core/storage/storage_delete.dart`). The clause still owes the condition a
/// word, because that retry is narrower than the code
/// it fires on. It is gated on `isFile`, so a read-only *directory* is still
/// refused and still survives; and errno 5 is not the attribute's alone, so an
/// ACL that denies the delete — or denies the attribute write the retry depends
/// on — arrives here unchanged. Which of those a failure was is exactly what the
/// enum declines to derive, so the clause covers the condition instead of
/// diagnosing it.
///
/// The rule this encodes is *cover*, not *phrasing*: a reword may say these two
/// conditions any way it likes, and only a reword that stops naming one of them
/// has to come back here and argue the case.
///
/// A `switch` with no `default`, so a fourth reason cannot be added without
/// someone deciding what its clause owes. An empty list is a real answer, and the
/// two lock reasons give it: each is raised by one recognisable condition — this
/// app's own lock, by type — so its clause has nothing to disambiguate.
List<String> _conditionsCoveredBy(StorageDeleteFailureReason reason) => switch (reason) {
  StorageDeleteFailureReason.refused => const ['使用中', '読み取り専用'],
  StorageDeleteFailureReason.lockBusy => const [],
  StorageDeleteFailureReason.lockUnavailable => const [],
  // Also raised by one recognisable condition: the app declining to remove a
  // transaction slot recovery could not empty. Which slot, and what recovery
  // could not do with it, is carried per entry in `StorageDeleteFailure.detail`
  // rather than by this clause.
  StorageDeleteFailureReason.recoveryIncomplete => const [],
};

/// The conditions [reason] covers that [sentence] does not name.
List<String> _conditionsMissingFrom(String sentence, StorageDeleteFailureReason reason) => [
  for (final condition in _conditionsCoveredBy(reason))
    if (!sentence.contains(condition)) condition,
];
