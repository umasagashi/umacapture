# UI places and their roles

Every place in the UI that holds explanatory text — a tooltip, a hint, a note, a description under
a heading, the opening text of a dialog — has a role: what it explains, and at what level of detail.

- **Do not create a new place for explanations without the user's approval.** Adding a tooltip to
  an element that had none counts. Propose it instead: where, what it would say, why no existing
  place fits, and what it would take to build.
- **You may add text to an existing place**, after stating its role from what it already holds.
  Do not put text of a different concept or level of detail there. If no existing place matches,
  that is a new place.
- **Keep each text to the minimum its role needs.**
- **Style follows role.** Supplementary-hint styling is for supplementary hints; a main explanation
  is plain body text.
- **Do not persist data just to choose an explanation.** Derive the text from data that already
  exists for other reasons; if that cannot tell two cases apart, ask whether the distinction is
  worth new data.
