# Choosing between designs

When two or more ways of doing something are on the table — in a design, a review, or a question put
to the user — rank them in this order:

1. **Which one leaves the codebase in a more appropriate state.**
2. **Which one respects the parity contracts** (see `.claude/rules/platform-parity.md`).
3. Everything else, including how big the change is.

## Size of the diff is not an argument

"Fewer files touched", "no new parameter", "does not modify the shared function" are **not reasons to
prefer a design**. They are costs to state, not criteria to decide by. A design that is right and
touches twelve call sites beats a design that is expedient and touches one.

Measure the cost before quoting it. "Touching this would be risky" is a claim about the number and
nature of the call sites; count them first. A named parameter with a default that preserves current
behaviour is not a regression risk, and calling it one to avoid the work is a bad trade dressed up
as a safe one.

## "It works today" is not the same as "it is represented"

Prefer the design where the fact the code depends on **exists as data**, over one where the same
outcome falls out of timing, ordering, or a global state that happens to be set at the right moment.
The second kind works until someone makes an unrelated function async, and then it fails silently.

If behaviour rests on an invariant rather than on data, the invariant needs a test that asserts it
directly — not a test that would merely happen to fail if it broke.

## An unexplained divergence is never the cheaper option

Two platforms may carry the same concept differently when a platform constraint forces it, and that
constraint has to be named at the point of divergence. But **omitting a concept on one platform
because you can get away with it there is not a divergence with a reason — it is a gap.** No amount
of saved work justifies it.

## When presenting options to the user

Lead with what each option leaves behind: what the code will mean afterwards, what a future change
would break, what is represented and what is merely implied. State size and effort afterwards, as
information. Do not build the recommendation on them.
