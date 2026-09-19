// Verifies CharaDetailCaptureState.status and .switchSafety, which drive the capture-tab guidance and
// the "safe to switch character" indicator shown during continuous capture (navigating to an adjacent
// character without closing the detail screen).
//
// Native detects a character switch on the factor tab (the 継承タブ) only: Rule 3's content diff, which
// keeps watching that tab after it is captured and after the session completes. No rule watches the skill
// or 育成情報 tabs, during capture or after it. A switch made there is seen only if the record type changes
// with it. So a switch is safe only while the factor tab is shown (factorTabShown), during capture and
// after completion alike, at any scroll position: a record switch returns the game to the head of the
// list, which is where Rule 3 judges, so the position before the switch is not a condition (the premise is
// stated at switchSafety's doc comment). And on the factor tab it is safe only once
// the tab has LATCHED ITS HEAD: Rule 3's diff is taken against a reference that head latch installs (the
// frame the duplicate probe is handed), so before the latch the screen looks exactly like the safe
// moment and is not one. The core states whether it holds that reference (`onFactorSwitchArmed`, kept
// as factorSwitchArmed), and switchSafety reads that level rather than inferring it from the settle
// wait: on a page that scrolls the two coincide, but on a factor page with no scroll bar the latch
// comes first and the wait lasts until the tab is read. The "armed" cases below pin that the arrows
// follow the level and nothing else.
//
// "Detect" is not "tell every pair of records apart": Rule 3's diff only nominates a switch, and native
// keeps the session when both frames' visible self-factor prefixes read the same. A switch between two
// records with identical visible prefixes is therefore not reset, and nothing this state sees can tell.
// switchSafety's doc comment states that limit; these tests pin where Rule 3 is armed, not that case.
//
// The scroll position (at top vs scrolled) is a single fact reported by native via the scroll-position
// event (scrollPosition), kept separate from capture progress (the ring value set by progress()).
// "capturing" and the duplicate hint's gate (factorAtTop) derive from that one fact, so they can never
// disagree; "safe to switch" does not read it at all, only the tab shown and the armed level.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/switch_safety_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_controller.dart';

void main() {
  group('CharaDetailCaptureState.switchSafety', () {
    test('is null before a detail session is active', () {
      expect(CharaDetailCaptureState().switchSafety, isNull);
    });

    test('is unsafe on a non-factor tab, even at its top', () {
      // Skill is the default tab on open; no rule watches it for switches, so switching is unsafe.
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 0,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {0: false},
      );
      expect(state.switchSafety, isFalse);
    });

    test('is safe at the factor-tab top once Rule 3 is armed', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {1: false},
        factorSwitchArmed: true,
      );
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe on the factor tab while Rule 3 holds no reference, even with the wait over', () {
      // ROW A. The settle wait being over is not the same fact as Rule 3 holding its reference, so a
      // settled factor tab with no reference must not show the arrows. The core's statement that the
      // detector is armed decides this, not the wait.
      for (final position in TopOfContent.values) {
        final notArmed = CharaDetailCaptureState(
          detailOpened: true,
          currentTab: 1,
          topOfContent: position,
          tabsAwaitingHead: {1: false},
        );
        expect(notArmed.status, isNot(CharaDetailCaptureStatus.waitingForReady), reason: '$position');
        expect(notArmed.switchSafety, isFalse, reason: '$position: shown, not armed');
        expect(notArmed.factorSwitchArmedChanged(true).switchSafety, isTrue, reason: '$position: armed');
      }
    });

    test('during capture, is safe on the factor tab scrolled off its top, and unsafe on the other tabs', () {
      // The switch does not depend on the factor tab's scroll position: the user need not scroll back
      // up before switching. A record switch returns the list to its head, which is where Rule 3
      // judges, so the position before the switch is not a condition.
      CharaDetailCaptureState scrolledOn(int tab) => CharaDetailCaptureState(
        detailOpened: true,
        currentTab: tab,
        topOfContent: TopOfContent.scrolled,
        tabsAwaitingHead: {tab: false},
        factorSwitchArmed: true,
      );
      expect(scrolledOn(1).status, CharaDetailCaptureStatus.capturing);
      expect(scrolledOn(1).switchSafety, isTrue, reason: 'the 継承タブ is shown; its position is not asked');
      expect(scrolledOn(0).status, CharaDetailCaptureStatus.capturing);
      expect(scrolledOn(0).switchSafety, isFalse, reason: 'skill: no rule watches it');
      expect(scrolledOn(2).status, CharaDetailCaptureStatus.capturing);
      expect(scrolledOn(2).switchSafety, isFalse, reason: '育成情報: no rule watches it');
    });

    test('during capture, a factor tab whose position nobody could read is still safe', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.unknown,
        tabsAwaitingHead: {1: false},
        factorSwitchArmed: true,
      );
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe while the displayed tab has not latched its head, even at the factor top', () {
      // NOT `factorAtTop` being conservative. Rule 3 diffs the factor list against a reference the
      // head latch installs, and that reference does not exist until the latch, so a switch made
      // while the tab still awaits its head is undetectable however at-the-top the screen looks. The
      // core states that absence (`factorSwitchArmed` false, the default of a fresh session).
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 1, topOfContent: TopOfContent.atTop);
      expect(state.status, CharaDetailCaptureStatus.waitingForReady);
      expect(state.switchSafety, isFalse, reason: 'not null: the answer is "not yet", not "no idea"');
      // The factor tab being shown does not override the wait, at any position.
      for (final position in TopOfContent.values) {
        final waiting = CharaDetailCaptureState(detailOpened: true, currentTab: 1, topOfContent: position);
        expect(waiting.status, CharaDetailCaptureStatus.waitingForReady, reason: '$position');
        expect(waiting.switchSafety, isFalse, reason: '$position: the factor tab is shown and still not safe');
      }
    });

    test('during the settle wait, follows the armed level rather than the wait', () {
      // The arm does not infer "not armed" from the wait. On a factor page with no scroll bar the latch
      // arms Rule 3 while the wait (which lasts until the tab is read) still stands, and a switch made
      // then IS detected. Answering false here from the status alone would be that inference.
      final waitingArmed = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {1: true},
        tabsScrollBar: {1: false},
        factorSwitchArmed: true,
      );
      expect(waitingArmed.status, CharaDetailCaptureStatus.waitingForReady);
      expect(waitingArmed.switchSafety, isTrue);
      expect(
        waitingArmed.scrollPosition(0, TopOfContent.atTop).switchSafety,
        isFalse,
        reason: 'the same level on another tab: not the 継承タブ',
      );
    });

    test('is unsafe when some but not all tabs are complete', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        skillTabProgress: 1,
        factorTabProgress: 1,
        campaignTabProgress: 0,
        currentTab: 2,
        topOfContent: TopOfContent.scrolled,
        tabsAwaitingHead: {2: false},
      );
      expect(state.switchSafety, isFalse);
    });

    test('after success, is safe on the factor tab at any position, and unsafe on the other tabs', () {
      // Completion does not make every tab safe, and the position does not decide the switch. No rule
      // watches the other tabs of a completed session, so it is safe to switch from the 継承タブ only,
      // at any position -- the same answer as during capture.
      for (final position in TopOfContent.values) {
        final onFactor = CharaDetailCaptureState(currentTab: 1, topOfContent: position, factorSwitchArmed: true)
          ..link = CharaDetailLink(id: 'x');
        expect(onFactor.status, CharaDetailCaptureStatus.succeeded);
        expect(onFactor.switchSafety, isTrue, reason: 'factor tab, $position');
      }
      for (final tab in [0, 2]) {
        final elsewhere = CharaDetailCaptureState(currentTab: tab, topOfContent: TopOfContent.atTop)
          ..link = CharaDetailLink(id: 'x');
        expect(elsewhere.status, CharaDetailCaptureStatus.succeeded);
        expect(elsewhere.switchSafety, isFalse, reason: 'tab $tab at its top: no rule watches it');
      }
    });

    test('success keeps the tab and position the core stated before it', () {
      // The core states the position on edges only and does not restate it on completion, so a success
      // that dropped the pair would leave the 継承タブ looking unsafe until the user moved.
      final completed = CharaDetailCaptureState()
          .started('rec-1')
          .tabAwaitingHead(1, false)
          .factorSwitchArmedChanged(true)
          .scrollPosition(1, TopOfContent.scrolled)
          .success(id: 'x');
      expect(completed.status, CharaDetailCaptureStatus.succeeded);
      expect(completed.currentTab, 1);
      expect(completed.topOfContent, TopOfContent.scrolled);
      expect(completed.factorSwitchArmed, isTrue, reason: 'the core does not restate the level on completion');
      expect(completed.switchSafety, isTrue, reason: 'no position message after the success, and still safe');

      // The control: a session reset does drop the pair and the level, because the core restates them
      // after its own reset.
      final restarted = completed.started('rec-2');
      expect(restarted.currentTab, 0);
      expect(restarted.topOfContent, TopOfContent.unknown);
      expect(restarted.factorSwitchArmed, isFalse);
    });

    test('after completion, a factor tab whose detector is not armed is unsafe', () {
      // ROW B's arrow, independent of the attempt check: a completion is kept on the 継承タブ, but if the
      // core says the detector holds nothing (a new session has not latched yet), the arrows stay off.
      final completed = CharaDetailCaptureState(currentTab: 1, topOfContent: TopOfContent.atTop)
        ..link = CharaDetailLink(id: 'x');
      expect(completed.status, CharaDetailCaptureStatus.succeeded);
      expect(completed.switchSafety, isFalse);
    });

    test('is safe when the duplicate probe flagged the character at the factor top', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {1: false},
        factorSwitchArmed: true,
      )..error = 'duplicated_character_probe';
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe when a lingering duplicate probe is no longer at the factor top', () {
      // Moved to another tab at its top: not the factor top, so the stale probe gives no safe switch.
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 0,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {0: false},
      )..error = 'duplicated_character_probe';
      expect(state.switchSafety, isFalse);
    });

    test('while a tab is refused, still answers, and the answer is false wherever the user is', () {
      // THE POINT OF NOT ROUTING A REFUSAL TO `fail`. A refused tab is a live in-detail phase, so
      // `failed`'s null is still the wrong answer -- it would blank the indicator during exactly the
      // moment the user is being told to move around the tabs. But the answer is not
      // `factorAtTop` either: a refused factor tab never fired the probe Rule 3 needs (the refusal
      // happens INSTEAD of `startScrolling` accepting the head), so being AT the factor top proves
      // nothing here, same as during the settle wait. See the `switchSafety` doc comment.
      // Armed, so the false below is the refusal's policy and not the missing reference.
      final atFactorTop = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        factorSwitchArmed: true,
      ).tabRefused(0, true, 'scrolled');
      expect(atFactorTop.status, CharaDetailCaptureStatus.tabRefused);
      expect(atFactorTop.switchSafety, isFalse, reason: 'not null: the answer is "not yet", not "no idea"');
      final scrolledFactor = atFactorTop.scrollPosition(1, TopOfContent.scrolled);
      expect(scrolledFactor.status, CharaDetailCaptureStatus.tabRefused);
      expect(scrolledFactor.switchSafety, isFalse, reason: 'the factor tab is shown, scrolled, and still not safe');

      final elsewhere = atFactorTop.scrollPosition(0, TopOfContent.atTop);
      expect(elsewhere.status, CharaDetailCaptureStatus.tabRefused);
      expect(
        elsewhere.switchSafety,
        isFalse,
        reason: 'false wherever the user is, so moving off the factor top changes nothing',
      );
    });

    test('on a completed tab, is safe on the armed factor tab and unsafe elsewhere', () {
      // `tabCompleted` joins the phase arm: a completed factor tab always holds the reference, and the
      // other tabs are watched by nothing, completed or not.
      CharaDetailCaptureState completedOn(int tab) => CharaDetailCaptureState(
        detailOpened: true,
        currentTab: tab,
        topOfContent: TopOfContent.scrolled,
        tabsAwaitingHead: {tab: false},
        tabsCompleted: {tab},
        factorSwitchArmed: true,
      );
      expect(completedOn(1).status, CharaDetailCaptureStatus.tabCompleted);
      expect(completedOn(1).switchSafety, isTrue);
      for (final tab in [0, 2]) {
        expect(completedOn(tab).status, CharaDetailCaptureStatus.tabCompleted);
        expect(completedOn(tab).switchSafety, isFalse, reason: 'tab $tab: no rule watches it');
      }
    });

    test('shows no guidance for a hard error', () {
      final state = CharaDetailCaptureState(detailOpened: true)..error = 'closed_before_completed';
      expect(state.switchSafety, isNull);
    });
  });

  group('CharaDetailCaptureState.status', () {
    test('is waitingForDetail before a detail screen is detected', () {
      expect(CharaDetailCaptureState().status, CharaDetailCaptureStatus.waitingForDetail);
    });

    test('is detailReady when the screen is open and the tab is at its top', () {
      final state = CharaDetailCaptureState(detailOpened: true, tabsAwaitingHead: {0: false});
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('a factor progress update alone does not mark the factor top', () {
      // Progress and scroll position are independent: a ring update on the factor tab does not, by
      // itself, place the current tab at the factor top -- that needs the scroll-position event.
      final state = CharaDetailCaptureState().started('rec-1').tabAwaitingHead(0, false).progress(1, 0.3);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isFalse);
    });

    test('the scroll-position event marks the factor top as a safe switch point', () {
      final state = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(1, TopOfContent.atTop)
          .tabAwaitingHead(1, false)
          .factorSwitchArmedChanged(true);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('scrolling the factor tab off its top switches to capturing in one step', () {
      final state = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(1, TopOfContent.atTop)
          .tabAwaitingHead(1, false)
          .factorSwitchArmedChanged(true)
          .scrollPosition(1, TopOfContent.scrolled);
      expect(state.factorAtTop, isFalse);
      expect(state.status, CharaDetailCaptureStatus.capturing);
      // Leaving the head does not withdraw the switch; the tab shown decides it.
      expect(state.switchSafety, isTrue);
    });

    test('progress does not change the scroll position (kept independent)', () {
      // Completing the factor tab (a progress update) must not flip the at-top fact on its own.
      final state = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(1, TopOfContent.atTop)
          .tabAwaitingHead(1, false)
          .progress(1, 1);
      expect(state.factorAtTop, isTrue);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('is capturing while the current tab is scrolled', () {
      final state = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(0, TopOfContent.scrolled)
          .tabAwaitingHead(0, false)
          .progress(0, 1);
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('returning to the factor top is a safe switch point even after another tab was scrolled', () {
      // Scroll skill, then move to the factor tab and settle at its top. Per the two-state model the
      // current tab is now at its top, so the banner is detailReady and switching is safe, while the
      // skill ring keeps its progress.
      final state = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(0, TopOfContent.scrolled)
          .tabAwaitingHead(0, false)
          .progress(0, 0.6)
          .scrollPosition(1, TopOfContent.atTop)
          .tabAwaitingHead(1, false)
          .factorSwitchArmedChanged(true);
      expect(state.skillTabProgress, 0.6);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('is succeeded when a record link is set', () {
      final state = CharaDetailCaptureState()..link = CharaDetailLink(id: 'x');
      expect(state.status, CharaDetailCaptureStatus.succeeded);
    });

    test('success pins every tab at 100% so the completed rings stay visible', () {
      final state = CharaDetailCaptureState().success(id: 'x');
      expect(state.status, CharaDetailCaptureStatus.succeeded);
      expect(state.skillTabProgress, 1);
      expect(state.factorTabProgress, 1);
      expect(state.campaignTabProgress, 1);
      // Completion does not make every tab safe. Nothing stated a tab here, so the default (skill) is
      // on screen, and that tab is not watched.
      expect(state.switchSafety, isFalse);
    });

    test('is duplicateHint for the duplicate probe while at the factor top', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {1: false},
      )..error = 'duplicated_character_probe';
      expect(state.status, CharaDetailCaptureStatus.duplicateHint);
    });

    test('a lingering duplicate probe left off the factor top degrades to detailReady', () {
      // The probe fired at the factor top, then the user navigated to another tab (still at its top).
      // The stale probe error must not stay a hint once the factor top is no longer displayed.
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {1: false},
      )..error = 'duplicated_character_probe';
      // The new tab settles first -- that is the settle wait asserted in its own case below; this
      // one is about the probe, so it is taken past the wait rather than stopping inside it.
      final after = state.scrollPosition(0, TopOfContent.atTop).tabAwaitingHead(0, false);
      expect(after.factorAtTop, isFalse);
      expect(after.status, CharaDetailCaptureStatus.detailReady);
    });

    test('downgrades the duplicate probe to capturing once the user scrolls', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.scrolled,
        tabsAwaitingHead: {1: false},
        factorSwitchArmed: true,
      )..error = 'duplicated_character_probe';
      expect(state.status, CharaDetailCaptureStatus.capturing);
      expect(state.switchSafety, isTrue, reason: 'the hint is gone, but the factor tab is still shown');
    });

    test('is alreadyCaptured for a confirmed duplicate, safe to switch on the factor tab only', () {
      // Every tab being captured does not make every tab safe: only the factor tab is watched.
      final onFactor = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.scrolled,
        factorSwitchArmed: true,
      )..error = 'duplicated_character';
      expect(onFactor.status, CharaDetailCaptureStatus.alreadyCaptured);
      expect(onFactor.switchSafety, isTrue);

      final onCampaign = CharaDetailCaptureState(detailOpened: true, currentTab: 2, topOfContent: TopOfContent.atTop)
        ..error = 'duplicated_character';
      expect(onCampaign.status, CharaDetailCaptureStatus.alreadyCaptured);
      expect(onCampaign.switchSafety, isFalse);
    });

    test('fail carries the duplicate record id for focusing it in the table', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
      ).fail(message: 'duplicated_character', duplicateRecordId: 'rec-123');
      expect(state.status, CharaDetailCaptureStatus.alreadyCaptured);
      expect(state.duplicateRecordId, 'rec-123');
    });

    test('is tabRefused while any tab holds a refusal, and returns when it is withdrawn', () {
      final refused = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(1, TopOfContent.atTop)
          .tabAwaitingHead(1, false)
          .tabRefused(0, true, 'scrolled');
      expect(refused.status, CharaDetailCaptureStatus.tabRefused);
      // Ranked above the three phase statuses: at the factor top, settled, this state would
      // otherwise read `detailReady`, which says the screen is fine.
      expect(refused.tabRefused(0, false, '').status, CharaDetailCaptureStatus.detailReady);
    });

    test('a refusal outranks a scrolled tab but not a terminal outcome', () {
      final scrolled = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(1, TopOfContent.scrolled)
          .tabRefused(1, true, 'scrolled');
      expect(scrolled.status, CharaDetailCaptureStatus.tabRefused, reason: 'above capturing');
      expect(scrolled.fail(message: 'closed_before_completed').status, CharaDetailCaptureStatus.failed);
      expect(scrolled.success(id: 'x').status, CharaDetailCaptureStatus.succeeded);
      expect(
        CharaDetailCaptureState().tabRefused(0, true, 'scrolled').status,
        CharaDetailCaptureStatus.waitingForDetail,
        reason: 'a refusal cannot outlive the detail screen it was about',
      );
    });

    test('a refusal outranks the duplicate hint, whose instruction would contradict it', () {
      // LOAD-BEARING ORDER, and a RULING WITH A COST — chosen by weighing the cost of each direction
      // against the other.
      //
      // The hint's line is 「詳細画面を検出しました／スクロールしてキャプチャを開始してください」 with the
      // green "safe to switch" arrows beside it. Shown while a tab stands refused, that is a wrong
      // instruction delivered at the moment the user is deciding whether to move on, seconds after
      // an error chime whose only on-screen explanation it has just displaced. The refusal wins for
      // that reason and no other.
      //
      // WHAT IT COSTS, asserted next door in `capture_event_test.dart` rather than only written
      // here: `duplicateHint` is recorded as a `CaptureEvent` on the transition INTO it, so a probe
      // that fires while a tab is refused records nothing then, and on the path the refusal's own
      // remedy puts the user on it is never recorded at all. Accepted: the duplicate is caught again
      // at the end of the capture, the unseen rows are not.
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {1: false},
      ).tabRefused(0, true, 'scrolled').fail(message: 'duplicated_character_probe');
      expect(state.status, CharaDetailCaptureStatus.tabRefused);
      // The probe error is still held, and still means what it meant: withdraw the refusal and the
      // hint is the status, so the ranking SUPPRESSES the hint rather than discarding the fact.
      expect(state.tabRefused(0, false, '').status, CharaDetailCaptureStatus.duplicateHint);
      // Which is what makes the loss above a real one and not a bookkeeping detail: by the time the
      // hint could be the status, the user has left the factor top to do what the refusal asked, and
      // then it is not a hint any more either.
      expect(
        state.tabRefused(0, false, '').scrollPosition(1, TopOfContent.scrolled).status,
        CharaDetailCaptureStatus.capturing,
      );
    });

    test('is failed for any other error', () {
      final state = CharaDetailCaptureState(detailOpened: true)..error = 'closed_before_completed';
      expect(state.status, CharaDetailCaptureStatus.failed);
    });
  });

  // THE SETTLE WAIT. Between the detail screen (or a tab) being detected and the core declaring it
  // ready to scroll, the picture is still moving and the recognizer cannot accept the head of the
  // list. Scrolling inside that window loses the rows above the first fragment for good.
  //
  // A card that is the same on both sides of that boundary -- `detailReady`, blue, and the action
  // line 「スクロールしてキャプチャを開始してください」 -- would tell the user to do the one thing
  // that breaks the capture, at the one moment doing it breaks the capture.
  group('CharaDetailCaptureState -- the settle wait', () {
    test('a freshly opened detail screen is waiting, not ready', () {
      // What `onCharaDetailStarted` leaves behind, verbatim. No readiness has been stated yet.
      final state = CharaDetailCaptureState().started('rec-1');
      expect(state.status, CharaDetailCaptureStatus.waitingForReady);
      expect(state.currentTabAwaitingHead, isTrue);
    });

    test('the readiness statement for the displayed tab ends the wait', () {
      final state = CharaDetailCaptureState().started('rec-1').tabAwaitingHead(0, false);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('a readiness statement about another tab does not end the displayed tab wait', () {
      final state = CharaDetailCaptureState()
          .started('rec-1')
          .tabAwaitingHead(0, false)
          .scrollPosition(1, TopOfContent.atTop);
      expect(state.status, CharaDetailCaptureStatus.waitingForReady);
    });

    test('every tab switch re-enters the wait, which is the retry the core performs', () {
      // Arriving on a tab the core has said nothing about is a wait, which is what makes a switch
      // re-enter one without this side having to notice the switch at all.
      final settled = CharaDetailCaptureState().started('rec-1').tabAwaitingHead(0, false);
      expect(settled.status, CharaDetailCaptureStatus.detailReady);
      final switched = settled.scrollPosition(1, TopOfContent.atTop);
      expect(switched.status, CharaDetailCaptureStatus.waitingForReady);
      expect(switched.tabAwaitingHead(1, false).status, CharaDetailCaptureStatus.detailReady);
    });

    test('the position event does not decide the wait, in either order', () {
      // Order-independence, deliberately. The level and the position are two facts the core states
      // separately, so neither ordering may change the answer -- which is what stops this side from
      // re-deriving a re-opened wait from a change of index and disagreeing with the core for a
      // frame. The RE-OPENING is the core's own statement; see the test below.
      final levelFirst = CharaDetailCaptureState()
          .started('rec-1')
          .tabAwaitingHead(1, false)
          .scrollPosition(1, TopOfContent.atTop);
      final positionFirst = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(1, TopOfContent.atTop)
          .tabAwaitingHead(1, false);
      expect(levelFirst.status, CharaDetailCaptureStatus.detailReady);
      expect(positionFirst.status, CharaDetailCaptureStatus.detailReady);
    });

    test('a refusal outranks the wait', () {
      // A refusal is the report that the head is already lost, which needs an action the instruction
      // to preserve it does not. The core also states `awaiting: false` on a refused tab -- the wait
      // is genuinely over there, badly -- so the two do not in fact stand together; the ranking
      // covers a refusal and a rebuild racing within one frame.
      final state = CharaDetailCaptureState().started('rec-1').tabRefused(0, true, 'scrolled');
      expect(state.status, CharaDetailCaptureStatus.tabRefused);
      expect(
        state.tabAwaitingHead(0, false).status,
        CharaDetailCaptureStatus.tabRefused,
        reason: 'the level the core actually states alongside a refusal must not demote it',
      );
    });

    test('coming BACK to an unfinished tab waits again, on the core statement that says so', () {
      // THE CASE THE FORWARD DIRECTION DOES NOT COVER: leaving a tab whose capture is in progress
      // rebuilds it in the core, so returning to it finds a fresh interpreter that has to latch all
      // over again, and the user must be made to wait again rather than told the tab is ready.
      //
      // WHERE THAT COMES FROM. The rebuild is the core's, and the core restates `awaiting: true`
      // for that index on the very frame it rebuilds -- while another tab is displayed. This side
      // does not re-derive it from the change of index: an inference here would be a second copy of
      // a fact the wire already carries, and the two would disagree for whichever frame arrived
      // first. So the assertion below is that the level is what re-opens the wait, and that a
      // position event alone does NOT.
      final bounced = CharaDetailCaptureState()
          .started('rec-1')
          .tabAwaitingHead(0, false)
          .scrollPosition(0, TopOfContent.scrolled)
          .progress(0, 0.4)
          .scrollPosition(1, TopOfContent.atTop)
          .scrollPosition(0, TopOfContent.atTop);
      expect(bounced.skillTabProgress, 0.4, reason: 'the ring is untouched: this is about the wait only');
      expect(
        bounced.status,
        CharaDetailCaptureStatus.detailReady,
        reason: 'the core has not yet said the rebuilt tab is waiting; this side must not guess it',
      );

      final returned = bounced.tabAwaitingHead(0, true);
      expect(returned.status, CharaDetailCaptureStatus.waitingForReady);
      expect(returned.skillTabProgress, 0.4);
      expect(returned.tabAwaitingHead(0, false).status, CharaDetailCaptureStatus.detailReady);
    });

    test('a completed tab is not waiting, however it was arrived at', () {
      // THE OTHER WAY THIS COULD HANG. A completed tab is not rebuilt when it is left, so the core
      // never restates `awaiting: true` for it, and the `false` it stated when the tab started
      // capturing still stands when the user comes back. No progress-based escape hatch is needed on
      // this side -- and the ring value below is deliberately NOT what answers the question.
      final state = CharaDetailCaptureState()
          .started('rec-1')
          .scrollPosition(0, TopOfContent.scrolled)
          .tabAwaitingHead(0, false)
          .progress(0, 1)
          .scrollPosition(1, TopOfContent.atTop)
          .tabAwaitingHead(1, false)
          .scrollPosition(0, TopOfContent.scrolled);
      expect(state.currentTabAwaitingHead, isFalse, reason: 'the level the core stated for tab 0 still stands');
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('a tab index the core has not levelled asserts a wait', () {
      // FAIL-CLOSED. Answering "ready" for an unknown index would only be needed if an instruction could otherwise
      // become unwithdrawable; the withdrawal exists by construction, because the core walks the same `kAllTabPages`
      // for the level as for the position event -- an index that can appear in one can appear in the other. With that
      // guaranteed, the safe default is the one that costs a moment rather than the head of a list.
      final state = CharaDetailCaptureState().started('rec-1').scrollPosition(7, TopOfContent.atTop);
      expect(state.currentTabAwaitingHead, isTrue);
      expect(state.status, CharaDetailCaptureStatus.waitingForReady);
      expect(
        state.tabAwaitingHead(7, false).status,
        CharaDetailCaptureStatus.detailReady,
        reason: 'and it is withdrawable: nothing here is special-cased to the three known indices',
      );
    });

    test('a success is not held up by the wait', () {
      // `success()` resets, so no readiness stands -- and the terminal statuses rank above this one.
      expect(CharaDetailCaptureState().success(id: 'x').status, CharaDetailCaptureStatus.succeeded);
    });
  });

  group('CharaDetailCaptureState -- a frame no sensor could read', () {
    // THE WHOLE REASON THE WIRE IS THREE-VALUED. The core states `unknown` for a frame whose scroll bar
    // was unmeasurable, or a tab not yet built -- a page with no scroll bar at all never reaches this,
    // it reads `at_top` from its structure instead -- and the two consumers of
    // that fact on this side must resolve it in OPPOSITE directions:
    //
    //   * the phase resolves it optimistically: a tab nobody could read is not "capturing".
    //   * the duplicate-probe hint gate (factorAtTop) resolves it pessimistically, the way Rule 3's own
    //     gate does: the hint stands only at a MEASURED factor top, where the probe fired.
    //
    // The switch arrows are not a consumer: they read the tab shown and the armed level, not the
    // position, which the second case below pins so that the position cannot creep back into them
    // unnoticed.
    //
    // Nothing else in this file pins either direction: every other case states a MEASURED verdict, and
    // both directions therefore stay green if one of them is flipped. Without this group the wire could
    // be flattened back to a bool and the suite would not notice.
    CharaDetailCaptureState unreadableFactorTop(TopOfContent verdict) => CharaDetailCaptureState(
      detailOpened: true,
      currentTab: 1,
      tabsAwaitingHead: {1: false},
      factorSwitchArmed: true,
    ).scrollPosition(1, verdict);

    test('withholds the duplicate hint, where a measured top shows it', () {
      expect(
        unreadableFactorTop(TopOfContent.unknown).fail(message: 'duplicated_character_probe').status,
        CharaDetailCaptureStatus.detailReady,
        reason: 'fail-closed: absent evidence is not the factor top the hint fired at',
      );
      expect(
        unreadableFactorTop(TopOfContent.atTop).fail(message: 'duplicated_character_probe').status,
        CharaDetailCaptureStatus.duplicateHint,
        reason: 'the control: the same state with a MEASURED top does show it',
      );
    });

    test('does not decide the switch arrows, which read the tab shown and the armed level', () {
      // An unreadable factor top does not withhold the switch arrows. Rule 3 resolves an unreadable frame as scrolled,
      // but it judges the first frame of the new record, which the game puts at the head; the frame before the switch
      // is not what it reads.
      for (final verdict in TopOfContent.values) {
        expect(unreadableFactorTop(verdict).switchSafety, isTrue, reason: '$verdict');
      }
    });

    test('does not move the card into its capturing phase, where a measured scroll does', () {
      expect(
        unreadableFactorTop(TopOfContent.unknown).status,
        CharaDetailCaptureStatus.detailReady,
        reason: 'fail-open: a tab nobody could read has nothing to have scrolled away from',
      );
      expect(
        unreadableFactorTop(TopOfContent.scrolled).status,
        CharaDetailCaptureStatus.capturing,
        reason: 'the control: a MEASURED scroll is what the capturing phase means',
      );
    });

    test('is what an absent or unrecognised wire word reads as', () {
      // Not `atTop`, and not a dropped message either: an unparseable payload lands on the side each
      // consumer already chose for missing evidence, and still displaces whatever the previous frame
      // said. Dropping it would leave a stale "at top" standing on screen.
      expect(TopOfContent.fromWire(null), TopOfContent.unknown);
      expect(TopOfContent.fromWire('at_the_top'), TopOfContent.unknown);
      expect(TopOfContent.fromWire(true), TopOfContent.unknown, reason: 'the retired bool spelling is not a word');
      expect(TopOfContent.fromWire('at_top'), TopOfContent.atTop);
      expect(TopOfContent.fromWire('scrolled'), TopOfContent.scrolled);
      expect(TopOfContent.fromWire('unknown'), TopOfContent.unknown);
    });
  });
}
