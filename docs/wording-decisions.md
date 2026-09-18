# Approved wording

Sentences in `assets/translations/ja.json` that the app's author settled on after reading the
alternatives, and the reason each one reads the way it does. A JSON asset cannot carry a comment, so
the reasons live here. Three of these sentences are the only record that a particular decision was
taken at all.

**Change an approved sentence only after confirming the change with the app's author.** No machine
check enforces this. `test/storage_wording_test.dart` checks the `pages.storage.*` wording's
*properties* (no implementation vocabulary, no remedy the view does not offer, two paragraphs in a
delete warning, no unfilled placeholder, keys and code naming each other in both directions), and a
property holds through a reword that quietly drops a clause — a reword that drops a clause is still
two paragraphs and still carries no jargon. That is why the clauses are written out below.

## Storage and quarantine

- **`pages.storage.group.quarantine.description`** names two kinds of content — records that can no
  longer be read, and data left behind partway through a save. This sentence is the only record of
  the decision that the quarantine group holds interrupted saves as well as unreadable records.
- **`pages.storage.group.quarantine.delete_warning`** is two paragraphs, and names both kinds in the
  second paragraph only. The approval covers the second paragraph; the first is the sentence every
  group's warning shares and was explicitly left as it stands.
- **`pages.chara_detail.quarantine_banner.message`** counts both kinds.
- **`pages.storage.delete.recovery_incomplete`** names the record whose in-progress data could not
  be recovered. This sentence is the only record of the decision that a survivor row names the
  record it could not recover. **`…_unidentified`** is the half used when the sweep could not read
  the slot's manifest: the approved sentence with the clause it cannot fill left out, rather than
  that clause filled with a placeholder name.

## Settings — the module version row

- **`pages.settings.about.version.checking`** and **`…waiting`** distinguish "still checking" from
  "waiting for another job". These two sentences are the only record of the decision that the row
  makes that distinction. `test/module_version_deferred_display_test.dart` asserts that the right one
  reaches the row.

## Capture card — no recognition module

- **`pages.capture.capture_control.disabled_tooltip`** and
  **`…message.load_error.status`** are approved as a pair, because they appear on the same card at
  the same time: the tooltip explains the dead toggle and the status line above it labels the same
  state. A rewrite of one alone puts two different causes on one screen, which is the failure
  neither sentence read on its own would show. Neither names a *load error*, because a load error
  cannot be the cause from where they are shown: `_CapturePageLoaderLayer` routes a thrown load to
  `loader.when(error:)`, which replaces the whole card. The only way to reach the capture card with
  no controller is a loader that **succeeded** and answered null, which `moduleVersionLoader` does
  exactly when there is no usable module set.
- **`…message.load_error.action`** was left as it stands deliberately: the approval covered the
  status clause only. Recorded so that "left alone" is a statement rather than an omission.

## Capture card — the tab that refused

- **`…message.tab_refused.status`** and **`…action`** are approved as a pair: both lines render on
  the same card for the same event, so a reword of one alone risks a status and a remedy that no
  longer agree with each other.
- The action line names one cause only: starting to scroll too early. The detector behind the card
  fires both when the user starts scrolling before the ready chime and on the tab-switch path (a tab
  reopened while already mid-scroll), and the two causes are indistinguishable from where the card
  is shown. Naming only the early-scroll cause is **the user's own decision**, not a claim that the
  tab-switch path does not apply: naming a cause the card cannot single out is accepted in exchange
  for a shorter, more actionable line. **Do not restore the two-cause wording on the theory that it
  is more correct**; the trade-off was made deliberately and is not to be second-guessed.
  Recovering also requires scrolling back up first, which does not fit in one line, so the action
  line asks for a retry instead of walking the user through that.

## Capture card — the settle wait

- **`…message.waiting_for_ready.status`** and **`…action`** are both imperative, unlike every other
  `status` line in this file, which describes a state. Here the state itself is an instruction not
  to act: the settle wait exists only because scrolling during it is indistinguishable, from the
  user's side, from scrolling once the cue has sounded, so there is no passive way to describe "not
  yet" that is not also a command. The two lines were therefore approved together, as one two-line
  instruction, rather than as a description plus a remedy.
