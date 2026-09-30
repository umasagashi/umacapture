# Writing tests

This file decides, for a test someone is about to add, whether it is written at all and, if it is, the
shape that makes it cost the least run time for what it guards. The metric is time: the wall clock until
CI's required checks finish, and the local full run of the final pre-PR check (`pre-pr-test`). Line counts
and test counts are not the metric.

## Whether to write it

Whether a behaviour gets a test, and how heavy a guard it may get, is decided by the user-level rule on
proportionate defence (reachability × harm, and its cap table). Reachability is read against
`supported-scope.md`. Neither is restated here, and **nothing below overrides them**: every "not written" in
this file is a default for harm that rates temporary or none, and yields to the permanent-harm exception at
the end of that list.

### Harm, as this product reads it

These are the readings that are easy to get wrong.

Permanent:

- **The web app unusable until the page is reloaded.** A reload is this product's restart.
- **A wrong recognised value in a record.** The record keeps it. That a re-recognition could repair it does
  not make it temporary.
- **A claim, lock or busy mark that is never released**, so the operation stays refused until a restart.
- **A verifier of what is shipped** (dependency pins, source digests, the licence disclosure, the golden
  judges) that lets a wrong input through.
- **A filter that changes which rows are listed** — a predicate, a combination of predicates, a reset. The
  listed rows feed select-all → bulk delete, whose only confirmation is a count and which has no undo, and CSV
  export.
- **The user's data reaching an external transmission** — file names, paths, record content, memos, in a
  Sentry event, a report upload or a webhook.
- **Stale state that becomes the input of a later write.** "The screen shows old data" is temporary only if
  nothing writes the old data back. A controller that saves its whole map on the next edit brings back what was
  deleted.
- **A derived value that is persisted** (written into a record). A derived value recomputed on every read is
  temporary.
- **The announcement that something was lost** — a capture that must be retaken. Without it the user does not
  retake, so it rates with the loss. An announcement that an operation was refused, when nothing was lost, is
  temporary.
- **A component whose job is to keep a destructive action from firing by accident** (hold-to-confirm), even
  when tested on its own: it rates with the action it guards.

Temporary: a duplicated record (it can be deleted); a setting's default, and saving and reading back one
setting. A migration or decode that can drop settings the user built (column presets, notation migrations) is
permanent.

None: the shape of a developer-facing diagnostic that carries no user data — which fields a Sentry context
has, whether a breadcrumb exists, how many events are sent.

### What is not written

- **A test of a unit whose claim an entry-driven test already asserts.** "Already asserts" means an existing or
  same-change test that drives an entry and whose assertion is that claim — not a test that could be extended
  to. In Dart an entry is a message from native (`handleNativeMessage`), a command to native over the platform
  channel, an interaction with a real widget, a real store, real bytes, or a user's script source. Building a
  notifier or a state object by hand and reading a derived value from it is not an entry. `design-priorities.md`
  asks for a test that asserts an invariant directly; an entry-driven test whose assertion *is* the invariant
  meets that — "directly" is about what is asserted, not about calling the unit.
- **Combinations** (entry × blocker × item × timing): one case per entry.
- **Twins** — the same test once per path or per field: one representative path.
- **Exhaustiveness of wording and translations** (every enum value has a sentence, sentences are distinct),
  and no aggregate sentinel in its place.
- **Visual detail in automated tests**: colour, alignment, hover, focus ring, widths, font scaling.
- **Developer-facing diagnostics** as defined above. The privacy of what is sent is written.
- **Facts about the environment** — what a browser or a library does.
- **Tests of the test infrastructure**, including guards against a test hanging. A positive control that shows a
  kept verifier still refuses a wrong input belongs to that verifier and stays with it
  (`native/test/integration/test_run_check.py` is one).
- **A structure test** — one that reads the code's shape (source text, tables, keys, pinned translations) or
  peeks at internal state (claims, locks, caches, counters, call shapes). Whether a test is structural is decided
  by what it observes, not by its name: feeding a real message into a real store and reading the result is an
  entry test. A source-scanning sentinel is the top tier in the proportionate-defence rule and follows its cap.
- **An internal unit that is the only way to reach some code** (web-only code the VM cannot compile).

**The permanent-harm exception applies to every item above.** When the harm the test would catch rates
permanent and no entry-driven test asserts the same claim, the test is written even though its form is on this
list — a unit, a combination, a twin, an environment fact the protection rests on, a structure test whose
breakage no other test would turn red, a web-only unit — up to the cap that proportionate defence gives its
rating. This asks for no duplicate: if an entry test does assert the claim, the exception does not apply.

### One representative per concept

A concept that the rating gives any test at all has at least one test that drives it from an entry. A concept
whose harm rates none needs none. New behaviour in an existing concept is a new case in that representative, or
next to it, rather than a new unit-level test beside it — subject to the exception above. A test on the output
side that renders the real widget and reads it can represent what the user sees, paired with the entry test for
the input. A web-only concept with no VM entry is represented by its permanent-harm unit test under
`@TestOn('browser')`.

## Where it goes: an existing file

A test file is a fixed cost paid on every run, whatever it holds: `flutter test` compiles each file on its own,
and in CI each file adds about 1.3 s of serial compile to its shard (`compileSeconds` in
`tool/test_selection.dart`, the measured interval between suites starting). A case inside a file costs next to
nothing beside that.

So a new test goes into the file that holds its concept's representative, or the file for the code it
exercises. Different set-up is a `group` with its own `setUp`, not a new file. A new file is justified only when:

- it has to run on another runner — `@TestOn('browser')` applies to a whole library, and the annotation alone
  routes the file to the browser job;
- adding the case would make the existing file the one that ends the run (see "Heavy files");
- no file covers the concept yet.

## How it waits

The contract for waiting — condition waits, which helper under which tester, the timeout, not copying the loop,
and why a negative assertion keeps its window — is the header and doc comments of `test/support/settling.dart`.
Read it; it is not repeated here. In addition:

- **The condition is the fact, held as data.** When the test needs to know a step was reached — a delete held at
  a gate — the fake records it (`entered = true`) and the test waits on that.
- **A condition that is already true before the action lands is a false arrival** ("no spinner" right after a
  tap that has not rebuilt yet). Let one frame pass first, or wait on a positive fact. `settleStorageRows` does
  this for storage-tree rows; use it rather than a tree-specific loop.
- **A notification is an arrival.** Wait until the toast appears, then assert how many there are and what they
  say.
- **A count with a completion to await is asserted after the completion.** When the operation hands back a
  future, or a drain can be awaited, await it (`Future.wait` for several) and then assert how many times the
  effect happened.
- **Only a claim with no arrival and no completion to await gets a window** — something that must not happen,
  or must happen no more than once, when nothing signals that the chance for it is over. Under a `WidgetTester`
  that window is `pumpRealTimeWindow`. When the effect needs real I/O before it can happen at all, wait for the
  first one on a condition, then open the window. A plain `test()` has no fake clock: await the futures the code
  hands back.
- **A window the code or the test documents as deliberate is behaviour.** Do not shorten it to make the test
  faster.

## Real I/O and real time

- Inside `testWidgets`, `dart:io`, image decodes and channel round trips complete only while `runAsync` lets
  real time run, and each turn costs a slice of real time — on the Windows machines measured, a 1 ms delay took
  about 15.5 ms. A fixed loop of N rounds therefore costs N slices whether or not the work has arrived; a
  condition wait costs as long as the work does.
- To control when a step completes, give the fake a gate (a `Completer` the test completes). Do not model timing
  with real-time delays.

## Heavy files

- **Register** a file whose execution reaches the threshold stated on `measuredExecutionSeconds` in
  `tool/test_selection.dart`, measured the way that table's comment says. A missing or stale entry only makes
  the shards less even; it never changes what runs.
- **A file must not be the one that ends the run.** Read it off the logs, not off a guess: in CI, whether the
  file's last test is the last line of its shard's `Run tests` step; locally, whether it is still running after
  every other suite in the `pre-pr-test` full run has finished. On CI, with shards of 107–121 files, files that
  took 61–69 s did not end their shard, and a file that took 198–211 s ended its shard every time. Fewer files
  per shard leave less compile time for a long file to hide behind, so the first figure is not a bound for
  smaller shards; the log is.
- A file that ends the run is changed in this order: first run its independent scenarios over real I/O
  concurrently inside the test — only when they share no mutable state; each gets its own directory, the order
  inside one scenario stays sequential, and they are joined with `Future.wait` left at `eagerError: false`, so a
  failure still waits for every scenario and tear-down does not delete a root under a running writer. Then, if
  it still ends the run, split it along the suite's own axis, with the shared helpers under `test/support/`.
  **A split keeps every test name**: compare the set of names before and after (`flutter test --reporter
  json`), because nothing in CI counts tests.
- A file that does not end the run is not split: splitting only adds the per-file cost.

## Scope

"Whether to write it" applies to every suite — Dart, native doctest, the web `.mjs` harnesses. The rest is about
the Dart suites under `test/`.
