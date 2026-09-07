// The sentences the app's author approved word for word, pinned as the words.
//
//   .fvm/flutter_sdk/bin/flutter test test/approved_wording_test.dart
//
// WHY A PIN AND NOT A RULE. `storage_wording_test.dart` holds the *rules* the
// storage view's wording has to satisfy — no implementation vocabulary, no remedy
// the view does not offer, two paragraphs in a delete warning, no placeholder left
// unfilled. Every one of those is a property a rewrite may satisfy in a new way,
// and that is the point of writing them as properties.
//
// These are not properties. They are the exact sentences the author settled on
// after reading the alternatives, and three of them are the *only* record that a
// particular decision was taken: that the quarantine group holds interrupted saves
// as well as unreadable records, that the module row distinguishes "still checking"
// from "waiting for another job", and that a survivor row names the record it could
// not recover. A property test would stay green through a reword that quietly
// dropped any of them, because a reword that drops a clause is still two paragraphs
// and still carries no jargon.
//
// So this file asserts the strings. A failure here is not a defect: it means
// somebody changed a sentence the author fixed, and the answer is to ask them, not
// to update the expectation. That is the whole of what this file is for, and it is
// why the sentences are written out rather than read from anywhere.
//
// WHAT IT DOES NOT COVER. That the sentences reach a screen. `storage_wording_test`
// and `module_version_deferred_display_test` do that from the other side — the
// first by requiring every `pages.storage.*` key to be named by the code and every
// key the code names to exist, the second by driving the module row through a real
// park. This file only pins what the keys say.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/localization.dart';

/// The sentence [key] resolves to, asserted to have resolved at all.
///
/// `.tr()` renders an unknown key as the key itself, so a deleted entry would
/// otherwise fail the comparison below with a message that reads like a reword.
void expectSentence(String key, String sentence) {
  final resolved = key.tr();
  expect(resolved, isNot(key), reason: '$key resolves to nothing: the entry is gone, not reworded');
  expect(resolved, sentence, reason: '$key was reworded; the author fixed this sentence');
}

void main() {
  setUpAll(loadAppTranslations);

  group('the sentences approved on 2026-09-06, verbatim', () {
    test('the pin fires on a sentence that is nearly right', () {
      // The negative control. Green below has to mean "the strings match", not
      // "the comparison is loose": these differ from the approved quarantine
      // description by one clause and by one character respectively, and both
      // are the kind of drift a property test would pass.
      expect(
        () => expectSentence('pages.storage.group.quarantine.description', '読み込めなくなったウマ娘のデータの退避先'),
        throwsA(isA<TestFailure>()),
      );
      expect(() => expectSentence('pages.settings.about.version.checking', '確認中…'), throwsA(isA<TestFailure>()));
      // And an absent key fails as an absent key rather than as a reword.
      expect(
        () => expectSentence('pages.storage.group.quarantine.no_such_entry', 'anything'),
        throwsA(isA<TestFailure>()),
      );
    });

    test('the quarantine group says what it holds', () {
      expectSentence('pages.storage.group.quarantine.description', '読み込めなくなったウマ娘のデータや、保存の途中で残ったデータの退避先');
    });

    test('the quarantine delete warning names both kinds, in the second paragraph only', () {
      const first = 'この操作は取り消せません。';
      const second =
          'これは読み込めなくなったウマ娘のデータや、保存の途中で残ったデータそのもので、'
          '削除するとアプリでは元に戻せません。必要なデータでないか確認してください。';
      expectSentence('pages.storage.group.quarantine.delete_warning', '$first\n\n$second');
      // Spelled out as well as embedded above: the approval was of the second
      // paragraph, and the first is the sentence every group shares and was
      // explicitly left alone. Split here so a change to either one names which.
      final paragraphs = 'pages.storage.group.quarantine.delete_warning'.tr().split('\n\n');
      expect(paragraphs, hasLength(2));
      expect(paragraphs.first, first);
      expect(paragraphs.last, second);
    });

    test('the quarantine banner counts both kinds', () {
      expectSentence('pages.chara_detail.quarantine_banner.message', '読み込めない記録や保存途中のデータが {count} 件 隔離フォルダに退避されています。');
    });

    test('the survivor row says what could not be recovered', () {
      expectSentence('pages.storage.delete.recovery_incomplete', '{record} の保存途中のデータを回収できませんでした（{reason}）。');
      // The half used when the sweep could not read the slot's manifest: the
      // approved sentence with the clause it cannot fill left out, rather than
      // that clause filled with a placeholder name.
      expectSentence('pages.storage.delete.recovery_incomplete_unidentified', '保存途中のデータを回収できませんでした（{reason}）。');
    });

    test('the version row says which of the two waits it is in', () {
      expectSentence('pages.settings.about.version.checking', '確認中...');
      expectSentence('pages.settings.about.version.waiting', '他の処理の完了を待っています...');
    });
  });

  group('the sentences approved on 2026-09-07, verbatim', () {
    // WHY THESE TWO WERE REWORDED. Both used to describe a *load error*, and
    // neither could ever be true. `_CapturePageLoaderLayer` routes a thrown load
    // to `loader.when(error:)`, which replaces the whole card; the only way to
    // reach the capture card with no controller is a loader that **succeeded**
    // and answered null, which `moduleVersionLoader` does exactly when there is
    // no usable module set. So the old sentences were not merely vague about the
    // cause — they named a cause that is unreachable from where they are shown.
    //
    // They are pinned as a pair because they appear on the same card at the same
    // time: the tooltip explains the dead toggle, the status line above it labels
    // the same state. A rewrite of one alone puts two different causes on one
    // screen, which is the failure neither sentence read on its own would show.
    test('the disabled toggle names the real cause and a remedy the user can act on', () {
      expectSentence(
        'pages.capture.capture_control.disabled_tooltip',
        '認識モジュールを読み込めていないため、キャプチャを開始・停止できません。設定から認識モジュールを更新するか、アプリを再起動してください。',
      );
    });

    test('the status line beside it labels the same state the same way', () {
      expectSentence('pages.capture.capture_control.message.load_error.status', '認識モジュールを読み込めていません');
      // The `action` half of the same message was left alone deliberately: the
      // approval covered the status clause only. Pinned here so "left alone"
      // is a statement this file makes rather than an omission.
      expectSentence('pages.capture.capture_control.message.load_error.action', 'キャプチャ機能は利用できません。');
    });
  });
}
