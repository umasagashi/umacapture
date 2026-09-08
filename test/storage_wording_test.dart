import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recase/recase.dart';
import 'package:umacapture/src/core/fs/record_recovery_reason.dart';
import 'package:umacapture/src/core/storage/settings_boxes.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
// Re-exports `storage_delete_report.dart`, whose `StorageDeleteFailure*` types this file also names.
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/localization.dart';

/// Three of the view's wording requirements, as machine checks.
///
/// The first is the safety rule that no implementation vocabulary reaches the
/// screen. The second is that
/// `pages.storage.*` and the code that names it agree in both directions — no key
/// referenced but absent, no key present but unreferenced. The third is that a
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
  late Set<String> literalReferences;
  late Set<String> derivedReferences;

  setUpAll(() {
    final root = jsonDecode(File(_translationFile).readAsStringSync()) as Map<String, dynamic>;
    storageStrings = _leavesUnder(root['pages']['storage'], _storagePrefix);
    literalReferences = _storageKeyLiteralsInLib();
    derivedReferences = _keysTheCodeBuildsAtRuntime();
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
      // under `pages.storage.*` and the walk above therefore never sees it. It used to be:
      // `pages.storage.extract.long_read_busy_{directory,file}_tooltip` and
      // `pages.storage.delete.extraction_busy_tooltip` were three of the eight per-surface
      // refusals merged into it, and the merge quietly took them out of this audit.
      //
      // Named one by one rather than by widening the walk to all of `app.*`: that namespace also
      // holds `record_store_startup.*`, whose jargon this view deliberately does not own (see the
      // scope note at the top of this file). A second *translated* sentence arriving here from
      // outside has to be added by hand, which is the cost of the exclusion above being deliberate.
      //
      // It is not the only sentence that reaches this screen from outside the walk: the delete
      // result panel's survivor rows are built by `core/storage/storage_delete.dart`. Those are
      // held by the case below, which counts the field's producers instead of naming them.
      expect(jargonIn(longReadBusyMessage()), isEmpty);
      // And it resolved: `.tr()` renders an unknown key as the key, and a key carries no jargon
      // either, so an unresolved one would pass the line above by being the wrong thing entirely.
      expect(longReadBusyMessage(), isNot(contains(longReadBusyKey)));
    });

    test('no second sentence reaches the result panel written out in the source', () {
      // THE OTHER WAY A SENTENCE GETS ONTO THIS SCREEN, and it goes round every check above.
      // `storage_delete_action.dart` renders `StorageDeleteFailure.detail` verbatim in the
      // survivor rows, so whatever a producer puts in that field is shown to the user — with no
      // key, no translation and nothing for the walk over `pages.storage.*` to see. Every
      // producer puts an expression in it — an exception in all but one case, and in that one a
      // call to `storageRecoveryIncompleteDetail`, which resolves the two shipped keys the
      // panel's own sentence goes through.
      //
      // **There used to be an allowance here, granted by name.** One producer wrote its sentence
      // out in English, in a Japanese UI, and this case pinned it rather than failing on it
      // because translating it was a decision this file could not take. That decision has since
      // been taken and the sentence is a key, so the allowance is gone and the bound is zero: a
      // hand-written detail now fails whoever writes it, including the site that used to hold the
      // licence. They are found by counting the field's producers rather than by holding a list
      // of files, so a new producer is counted the moment it is written.
      final arguments = _deleteDetailArguments();
      // Non-vacuity, both halves: the walk has to have found the file that builds the survivor
      // rows' details, and to have found more than the one site it then allows.
      expect(
        arguments.where((site) => site.file.endsWith('storage_delete.dart')),
        isNotEmpty,
        reason: 'the scan found no `detail:` in the file that produces them, so it is bounding nothing',
      );
      expect(
        arguments.length,
        greaterThan(1),
        reason: 'the scan found one site or none, so "no second one" is a statement about nothing',
      );
      final written = arguments.where((site) => site.kind == _DetailKind.writtenOut).toList();
      expect(
        written.map((site) => '${site.file}: ${site.argument}').toList(),
        isEmpty,
        reason:
            'a sentence is written out in the source and shown in the delete result panel, '
            'where no translation walk and no jargon rule can reach it',
      );
    });

    test('every detail argument is one of the three shapes, and none is waved through', () {
      // THE HOLE THE CASE ABOVE USED TO HAVE. It asked one question — does this open with a quote
      // — and treated every other answer as safe on the strength of a sentence in this file
      // saying they were all `error.toString()`. One was not: `storage_delete.dart` calls
      // `storageRecoveryIncompleteDetail`, which passed English prose from the recovery through
      // into the survivor row. A classifier with an implicit "everything else is fine" branch
      // cannot fail, so it never did.
      expect(
        _unclassifiedDeleteDetails(),
        isEmpty,
        reason:
            'a `detail:` argument is neither a written-out sentence, nor the platform words the '
            'field documents, nor a call this file can demand a renderer for — so nothing here '
            'knows what the user is shown',
      );
      // And the composed shape is allowed only for composers this file renders. Literal, so a
      // second composer fails here and has to be given the exhaustive rendering below before it
      // can ship a sentence.
      expect(_deleteDetailComposers(), {'storageRecoveryIncompleteDetail'});
      // Non-vacuity for the other two kinds: an accidentally over-strict pattern would empty them
      // and make the assertions above true about nothing.
      expect(
        _deleteDetailArguments().where((site) => site.kind == _DetailKind.platformWords),
        isNotEmpty,
        reason: 'no site was recognised as carrying the platform words, so that arm bounds nothing',
      );
    });

    test('every reason the survivor row can carry renders as a shipped Japanese clause', () {
      // The composer above, exercised over the machine's own enumeration rather than over a
      // value written here. The defect this replaces was in the renderer, not in the code: the
      // row was rendered with `reason: '中断したため'`, a Japanese stand-in for a parameter that
      // in production held English prose, so every jargon and placeholder check in this file was
      // reading a sentence the app never shows.
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
        // The defect itself, stated as an assertion: the clause the brackets carry must not be
        // the English one the log uses. `clause` is on the enum, so this compares the row against
        // the very words it used to show.
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
  });

  group('pages.storage.* and the code that names it agree in both directions', () {
    test('the scan actually read the source', () {
      // Both assertions below are "a set difference is empty", and an empty scan
      // makes one of them trivially true. This pins the scan itself.
      expect(literalReferences, hasLength(greaterThan(40)));
      expect(literalReferences, contains('pages.storage.title'));
      // Three keys per group, less the one group that offers no delete and so
      // names no delete warning (`data_root_config`), plus one name per store.
      expect(derivedReferences, hasLength(StorageGroupId.values.length * 3 - 1 + StorageBoxKey.values.length));
      expect(derivedReferences, contains('pages.storage.group.quarantine.delete_warning'));
      expect(derivedReferences, contains('pages.storage.store.name.column_spec'));
    });

    test('every key site that builds its key from a variable is one an enumeration covers', () {
      // The reason the two assertions below can use plain string matching. A
      // literal that interpolates, or that is a bare namespace handed to a
      // helper, resolves to keys no text scan can see; each one has to be paired
      // with a runtime enumeration in [_keysTheCodeBuildsAtRuntime] or its keys
      // would read as unused. Literal, so a third site fails here rather than
      // quietly making a group's strings look dead.
      expect(_dynamicKeySitesInLib(), {
        // `settings_boxes.dart`: `'pages.storage.store.name.$name'`, one per
        // `StorageBoxKey` — enumerated through `storageBoxLabelKey`.
        r'pages.storage.store.name.$name',
        // `storage_group.dart`: `_groupKeyPrefix`, joined with a group name and a
        // field suffix — enumerated through `storageGroups`.
        'pages.storage.group',
      });
    });

    test('no key the code names is missing from ja.json', () {
      final referenced = {...literalReferences, ...derivedReferences};
      expect(referenced.difference(storageStrings.keys.toSet()), isEmpty);
    });

    test('no key in ja.json goes unnamed by the code', () {
      final referenced = {...literalReferences, ...derivedReferences};
      expect(storageStrings.keys.toSet().difference(referenced), isEmpty);
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
      // **The reason is a real one, and every one of them is rendered by the case further down.**
      // This used to pass a Japanese stand-in — `reason: '中断したため'` — for a parameter that was
      // then a `String` carrying English prose written at the point of failure. The stand-in made
      // the row look translated to every check in this file while the shipped one read
      // 「…（its manifest could not be read）。」, so the row's own wording went unread for as long
      // as it was wrong.
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
          detail: 'busy',
        ),
      ).description,
      'pages.storage.delete.partial': () => storageDeleteOutcomeMessage(
        StorageDeleteReport(
          deleted: const [StorageDeletePathSubject('a')],
          failed: [
            StorageDeleteFailure(
              subject: StorageDeletePathSubject('b'),
              reason: StorageDeleteFailureReason.lockBusy,
              detail: 'busy',
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
        detail: 'detail',
      ),
      'partial': StorageDeleteReport(
        deleted: const [StorageDeletePathSubject('a')],
        failed: [StorageDeleteFailure(subject: StorageDeletePathSubject('b'), reason: reason, detail: 'detail')],
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
              detail: 'held',
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
              detail: 'busy',
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
///     names no format at all (the second line that used to guess at one has been
///     deleted) — and a decision nothing enforces is one the next hint will not
///     know about.
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

/// Every proper prefix of [keys] — the interior nodes of the translation tree.
Set<String> _namespacesOf(Iterable<String> keys) {
  final result = <String>{};
  for (final key in keys) {
    final parts = key.split('.');
    for (var i = 1; i < parts.length; i++) {
      result.add(parts.take(i).join('.'));
    }
  }
  return result;
}

/// Every `pages.storage…` string literal in `lib/`, comment lines removed.
///
/// Full-line `//` and `///` comments are dropped before matching: a key named in
/// prose is not a use of it, and `storage_group.dart` has one. Trailing comments
/// are left alone, so a key quoted after code on the same line would read as a
/// use — that direction only masks an unused key, never invents a missing one.
List<String> _libLiterals() {
  final pattern = RegExp('[\'"]($_storagePrefix[A-Za-z0-9_.\$]*)[\'"]');
  final found = <String>[];
  for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) {
      continue;
    }
    final body = file.readAsLinesSync().where((line) => !line.trimLeft().startsWith('//')).join('\n');
    for (final match in pattern.allMatches(body)) {
      final literal = match.group(1);
      if (literal != null) {
        found.add(literal);
      }
    }
  }
  return found;
}

/// What a `detail:` argument turns out to be at runtime.
///
/// Three kinds and no fourth, which is the whole point of naming them. The rule
/// here used to be the single question *does this argument open with a quote*,
/// and everything answering no was waved through as "an exception's `toString`,
/// in every case here" — a claim the scan asserted and never checked. It was
/// false the day it was written: `storage_delete.dart` answers no by calling
/// `storageRecoveryIncompleteDetail`, and what that call rendered was English
/// prose the survivor row put on the screen. A `else` branch that means "not the
/// one bad shape I thought of" cannot stop the next writer, so the classifier
/// names every shape it accepts and [_unclassifiedDeleteDetails] fails on
/// anything else.
enum _DetailKind {
  /// A sentence written out in the repository and shown to the user as it
  /// stands. Never allowed.
  writtenOut,

  /// The platform's own account of a refusal, which `StorageDeleteFailure.detail`
  /// documents as a deliberate contract: an OS or browser message, in whatever
  /// language it comes in, is better than this app paraphrasing it.
  platformWords,

  /// A call to something in this repository that composes the sentence. Allowed
  /// only for a composer this file renders exhaustively — see the case that
  /// pins [_deleteDetailComposers].
  composed,

  /// A bare identifier handed on: a relay that forwards a `detail` it was given
  /// rather than deciding one. What it forwards was decided at a call site this
  /// same scan classifies, so the sentence is bounded there and not here.
  forwarded,
}

/// Every `detail:` argument in the sources that construct a `StorageDeleteFailure`.
///
/// The argument is taken as source text, from the colon to the comma that ends
/// it, and sorted into [_DetailKind] by its shape. An argument matching none of
/// the three carries a null [kind], and the case above fails naming it rather
/// than letting it fall through as acceptable.
///
/// **The files are found by what they construct, not listed**, so a new producer
/// of the field is counted from the moment it is written; a list here would have
/// to be remembered. Full-line comments are dropped first, for [_libLiterals]'
/// reason.
List<({String file, String argument, _DetailKind? kind})> _deleteDetailArguments() {
  final pattern = RegExp(r'detail:\s*([\s\S]*?),\r?\n');
  // `error.toString()`, `cleanupError.toString()`, `e.error.toString()`: a
  // receiver of dotted identifiers, and nothing else, so a call taking arguments
  // or an interpolation does not pass as the platform's words.
  final platform = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*\.toString\(\)$');
  final found = <({String file, String argument, _DetailKind? kind})>[];
  for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) {
      continue;
    }
    final body = file.readAsLinesSync().where((line) => !line.trimLeft().startsWith('//')).join('\n');
    if (!body.contains('StorageDeleteFailure(')) {
      continue;
    }
    for (final match in pattern.allMatches(body)) {
      final argument = match.group(1)!.trim();
      found.add((
        file: file.path.replaceAll(r'\', '/'),
        argument: argument,
        kind: switch (argument) {
          _ when argument.startsWith("'") || argument.startsWith('"') => _DetailKind.writtenOut,
          _ when platform.hasMatch(argument) => _DetailKind.platformWords,
          _ when _composerCall.hasMatch(argument) => _DetailKind.composed,
          // Trailing brackets because the scan cuts at the comma that ends the
          // argument list, so a relay inside a collection literal keeps the
          // closers that follow it.
          _ when RegExp(r'^[a-z][A-Za-z0-9_]*[)\]]*$').hasMatch(argument) => _DetailKind.forwarded,
          _ => null,
        },
      ));
    }
  }
  return found;
}

/// A call to a named function, which is the only composed shape this file
/// accepts: the name is what the case below can hold a list of and what a
/// renderer can be demanded for.
final _composerCall = RegExp(r'^([a-z][A-Za-z0-9_]*)\(');

/// The composers the arguments above name.
Set<String> _deleteDetailComposers() => _deleteDetailArguments()
    .where((site) => site.kind == _DetailKind.composed)
    .map((site) => _composerCall.firstMatch(site.argument)!.group(1)!)
    .toSet();

/// The arguments the classifier could not place at all.
List<String> _unclassifiedDeleteDetails() => _deleteDetailArguments()
    .where((site) => site.kind == null)
    .map((site) => '${site.file}: ${site.argument}')
    .toList();

/// The literals that name one key outright.
Set<String> _storageKeyLiteralsInLib() {
  final namespaces = _namespacesOf(
    _leavesUnder(
      (jsonDecode(File(_translationFile).readAsStringSync()) as Map<String, dynamic>)['pages']['storage'],
      _storagePrefix,
    ).keys,
  );
  return _libLiterals().where((literal) => !literal.contains(r'$') && !namespaces.contains(literal)).toSet();
}

/// The literals that do *not*: a template with an interpolation in it, or a bare
/// namespace a helper appends to.
///
/// Classified by what the literal is, not by which file it sits in, so a new one
/// cannot be added without the test that pins this set noticing.
Set<String> _dynamicKeySitesInLib() {
  final namespaces = _namespacesOf(
    _leavesUnder(
      (jsonDecode(File(_translationFile).readAsStringSync()) as Map<String, dynamic>)['pages']['storage'],
      _storagePrefix,
    ).keys,
  );
  return _libLiterals().where((literal) => literal.contains(r'$') || namespaces.contains(literal)).toSet();
}

/// What the two dynamic sites above actually resolve to at runtime.
///
/// Read off the same data the widgets read — `storageGroups` and
/// `StorageBoxKey.values` — rather than transcribed, so the twelve groups' forty
/// keys and the eight stores' names are counted by the machine that builds them.
Set<String> _keysTheCodeBuildsAtRuntime() {
  final result = <String>{};
  for (final group in storageGroups) {
    result.addAll([group.labelKey, group.descriptionKey]);
    // Absent for the one group that offers no delete, which is the same fact as
    // `ja.json` carrying no `delete_warning` for it.
    if (group.deleteWarningKey case final key?) {
      result.add(key);
    }
  }
  for (final key in StorageBoxKey.values) {
    result.add(storageBoxLabelKey(key));
  }
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
/// the only place a user is told that a read-only entry can land there too. It
/// shipped as 「使用中のため」 and named the first condition alone, which told a
/// user whose file was merely read-only that something was holding it open.
/// Measured at the time: nothing held it, and `File.delete` on a read-only file
/// failed with errno 5.
///
/// A plain read-only *file* no longer reaches this reason: the delete retries one
/// with the attribute cleared and removes it (`_deletedByClearingReadOnly` in
/// `core/storage/storage_delete.dart`). The condition did not leave with it, and
/// the clause still owes it a word, because that retry is narrower than the code
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
