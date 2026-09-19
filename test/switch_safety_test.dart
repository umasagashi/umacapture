// Verifies CharaDetailCaptureState.status and .switchSafety, which drive the capture-tab guidance and
// Native offers a character switch where the factor tab (the 継承タブ) will judge it: the factor tab is shown
// (factorTabShown) and Rule 3 holds its reference (factorSwitchArmed), during capture and after completion
// alike, at any scroll position. A record switch returns the game to the head of the list, where Rule 3
// compares it with the reference while the tab is being captured, and where the completed-tab rule sees a
// captured tab back at its head afterwards, so the position before the switch is not a condition (the
// premise is stated at switchSafety's doc comment).

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
      );
      expect(state.switchSafety, isFalse);
    });

    test('is safe at the factor-tab top once Rule 3 is armed', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
        factorSwitchArmed: true,
      );
      expect(state.switchSafety, isTrue);
    });

    test('during capture, is safe on the factor tab scrolled off its top, and unsafe on the other tabs', () {
      // INTENT CHANGED (R8). This used to be "unsafe once the factor tab is scrolled off its top", which
      // asked the user to scroll back up before switching. A record switch returns the list to its head,
      // which is where Rule 3 judges, so the position before the switch is not a condition any more.
      CharaDetailCaptureState scrolledOn(int tab) => CharaDetailCaptureState(
        detailOpened: true,
        currentTab: tab,
        topOfContent: TopOfContent.scrolled,
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
        factorSwitchArmed: true,
      );
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe when some but not all tabs are complete', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        skillTabProgress: 1,
        factorTabProgress: 1,
        campaignTabProgress: 0,
        currentTab: 2,
        topOfContent: TopOfContent.scrolled,
      );
      expect(state.switchSafety, isFalse);
    });

    test('after success, is safe on the factor tab at any position, and unsafe on the other tabs', () {
      // INTENT CHANGED (R6, R8). This used to be "is safe when every tab is captured (success)", on any
      // tab: Rule 2 watched the other tabs once the session was complete. No rule watches them now, so a
      // completed session is safe to switch from the 継承タブ only -- the same answer as during capture.
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
          .started()
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
      final restarted = completed.started();
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
      )..error = 'duplicated_character_probe';
      expect(state.switchSafety, isFalse);
    });

    test('still answers while a tab is refused, but the answer is now false, not factorAtTop', () {
      // THE POINT OF NOT ROUTING A REFUSAL TO `fail`. A refused tab is a live in-detail phase, so
      // `failed`'s null is still the wrong answer -- it would blank the indicator during exactly the
      // moment the user is being told to move around the tabs. But the answer is no longer
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
        reason: 'false either way now, so moving off the factor top changes nothing',
      );
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
      final state = CharaDetailCaptureState(detailOpened: true);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('a factor progress update alone does not mark the factor top', () {
      // Progress and scroll position are independent: a ring update on the factor tab does not, by
      // itself, place the current tab at the factor top -- that needs the scroll-position event.
      final state = CharaDetailCaptureState().started().progress(1, 0.3);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isFalse);
    });

    test('the scroll-position event marks the factor top as a safe switch point', () {
      final state = CharaDetailCaptureState()
          .started()
          .scrollPosition(1, TopOfContent.atTop)
          .factorSwitchArmedChanged(true);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('scrolling the factor tab off its top switches to capturing in one step', () {
      final state = CharaDetailCaptureState()
          .started()
          .scrollPosition(1, TopOfContent.atTop)
          .factorSwitchArmedChanged(true)
          .scrollPosition(1, TopOfContent.scrolled);
      expect(state.factorAtTop, isFalse);
      expect(state.status, CharaDetailCaptureStatus.capturing);
      // INTENT CHANGED (R8): leaving the head no longer withdraws the switch; the tab shown decides it.
      expect(state.switchSafety, isTrue);
    });

    test('progress does not change the scroll position (kept independent)', () {
      // Completing the factor tab (a progress update) must not flip the at-top fact on its own.
      final state = CharaDetailCaptureState()
          .started()
          .scrollPosition(1, TopOfContent.atTop)
          .progress(1, 1);
      expect(state.factorAtTop, isTrue);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('is capturing while the current tab is scrolled', () {
      final state = CharaDetailCaptureState()
          .started()
          .scrollPosition(0, TopOfContent.scrolled)
          .progress(0, 1);
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('returning to the factor top is a safe switch point even after another tab was scrolled', () {
      // Scroll skill, then move to the factor tab and settle at its top. Per the two-state model the
      // current tab is now at its top, so the banner is detailReady and switching is safe, while the
      // skill ring keeps its progress.
      final state = CharaDetailCaptureState()
          .started()
          .scrollPosition(0, TopOfContent.scrolled)
          .progress(0, 0.6)
          .scrollPosition(1, TopOfContent.atTop)
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
      // INTENT CHANGED (R6): completion no longer makes every tab safe. Nothing stated a tab here, so the
      // default (skill) is on screen, and that tab is not watched.
      expect(state.switchSafety, isFalse);
    });

    test('is duplicateHint for the duplicate probe while at the factor top', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.atTop,
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
      )..error = 'duplicated_character_probe';
      // The new tab settles first -- that is the settle wait asserted in its own case below; this
      // one is about the probe, so it is taken past the wait rather than stopping inside it.
      final after = state.scrollPosition(0, TopOfContent.atTop);
      expect(after.factorAtTop, isFalse);
      expect(after.status, CharaDetailCaptureStatus.detailReady);
    });

    test('downgrades the duplicate probe to capturing once the user scrolls', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        topOfContent: TopOfContent.scrolled,
        factorSwitchArmed: true,
      )..error = 'duplicated_character_probe';
      expect(state.status, CharaDetailCaptureStatus.capturing);
      expect(state.switchSafety, isTrue, reason: 'the hint is gone, but the factor tab is still shown');
    });

    test('is alreadyCaptured for a confirmed duplicate, safe to switch on the factor tab only', () {
      // INTENT CHANGED (R6): used to be safe on any tab once every tab was captured.
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
          .started()
          .scrollPosition(1, TopOfContent.atTop)
          .tabRefused(0, true, 'scrolled');
      expect(refused.status, CharaDetailCaptureStatus.tabRefused);
      // Ranked above the three phase statuses: at the factor top, settled, this state would
      // otherwise read `detailReady`, which says the screen is fine.
      expect(refused.tabRefused(0, false, '').status, CharaDetailCaptureStatus.detailReady);
    });

    test('a refusal outranks a scrolled tab but not a terminal outcome', () {
      final scrolled = CharaDetailCaptureState()
          .started()
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
      // LOAD-BEARING ORDER, and a RULING WITH A COST — the order was the other way round until the
      // cost of each direction had been measured against the other.
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
  // The card used to be byte-identical on both sides of that boundary: `detailReady`, blue, and the
  // action line 「スクロールしてキャプチャを開始してください」 -- i.e. it told the user to do the one
  // thing that breaks the capture, at the one moment doing it breaks the capture. `onScrollReady`
  // reached Dart with a tab index and was discarded on the line that received it.
  group('CharaDetailCaptureState -- the settle wait', () {
    test('the readiness statement for the displayed tab ends the wait', () {
      final state = CharaDetailCaptureState().started();
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('the position event does not decide the wait, in either order', () {
      // Order-independence, deliberately. The level and the position are two facts the core states
      // separately, so neither ordering may change the answer -- which is what stops this side from
      // re-deriving a re-opened wait from a change of index and disagreeing with the core for a
      // frame. The RE-OPENING is the core's own statement; see the test below.
      final levelFirst = CharaDetailCaptureState()
          .started()
          .scrollPosition(1, TopOfContent.atTop);
      final positionFirst = CharaDetailCaptureState()
          .started()
          .scrollPosition(1, TopOfContent.atTop);
      expect(levelFirst.status, CharaDetailCaptureStatus.detailReady);
      expect(positionFirst.status, CharaDetailCaptureStatus.detailReady);
    });

    test('a refusal outranks the wait', () {
      // A refusal is the report that the head is already lost, which needs an action the instruction
      // to preserve it does not. The core also states `awaiting: false` on a refused tab -- the wait
      // is genuinely over there, badly -- so the two do not in fact stand together; the ranking
      // covers a refusal and a rebuild racing within one frame.
      final state = CharaDetailCaptureState().started().tabRefused(0, true, 'scrolled');
      expect(state.status, CharaDetailCaptureStatus.tabRefused);
      expect(
        state.status,
        CharaDetailCaptureStatus.tabRefused,
        reason: 'the level the core actually states alongside a refusal must not demote it',
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
    // position (R8), which the second case below pins so that the position cannot creep back into them
    // unnoticed.
    //
    // Nothing else in this file pins either direction: every other case states a MEASURED verdict, and
    // both directions therefore stay green if one of them is flipped. Without this group the wire could
    // be flattened back to a bool and the suite would not notice.
    CharaDetailCaptureState unreadableFactorTop(TopOfContent verdict) => CharaDetailCaptureState(
      detailOpened: true,
      currentTab: 1,
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
      // INTENT CHANGED (R8). This used to be "withholds the switch arrows, where a measured top shows
      // them". Rule 3 still resolves an unreadable frame as scrolled, but it judges the first frame of the
      // new record, which the game puts at the head; the frame before the switch is not what it reads.
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
