/// What a transaction-journal recovery could not finish, as a value.
///
/// **A value and not a sentence, because two readers need different words for
/// the same fact.** The log and the exception text want the developer's clause
/// — the one that has been in the log since these journals were written, and
/// that a Sentry breadcrumb search matches on — and the delete result panel
/// wants a sentence a Japanese-speaking user can act on. A `String` carried
/// only the first, so the panel showed it: 「… の保存途中のデータを回収できません
/// でした（its manifest could not be read）。」 reached the screen with no key, no
/// translation, and nothing for the walk over `pages.storage.*` to see.
///
/// The set is shared by both journals rather than split one enum per producer.
/// [UndrainedSlot.reason] is one field with one reader, so two enums would need
/// a sum type at that seam; and the two producers' reasons already overlap —
/// [strayEntry] and [unresumableManifest] are each raised, in the same words, by
/// both.
///
/// Every value carries [RecordRecoveryReasonClause.clause], which is the English
/// the site used to write out inline, byte for byte. Nothing renders the name of
/// a value to a user: `storageRecoveryIncompleteDetail` switches over this enum
/// and answers with a shipped key.
enum RecordRecoveryIncompleteReason {
  /// A file sitting directly under a journal root, which is no slot of
  /// anyone's. Raised by both journals in the same words.
  strayEntry,

  /// A write-journal slot whose name does not round-trip through this build's
  /// derivation, so some other version minted it.
  foreignSlotName,

  /// The archive journal's answer to the same question. A separate value and
  /// not a shared one: the two journals word it differently in the log, and
  /// this enum's contract is that the log does not change.
  foreignArchiveSlotName,

  /// A record id this version would not write, so no slot name can be derived
  /// for it.
  ///
  /// Never reaches the result panel: the only site that raises it reports a
  /// recovery with no slot, and the store-wide sweep drops those before they
  /// become an [UndrainedSlot]. It is a value all the same, because the field
  /// it fills is typed and required — a site allowed to answer `null` there is
  /// a site that hands a delete a slot it cannot describe.
  unmintableSlotName,

  /// A manifest that will not parse, or that names a transaction this build
  /// cannot resume. Raised by both journals in the same words.
  unresumableManifest,

  /// The archive journal could not read the manifest at all.
  unreadableManifest,

  /// A `ready` manifest names a staged tree that is no longer on disk.
  stagedTreeGone,

  /// A manifest in a state the resume has no step for.
  unresumableState,

  /// The copy of the version a resume was replacing could not be carried to the
  /// shelf that holds the only copy of a record.
  supersededCopyNotSaved,

  /// The staged tree of a slot being given up on could not be published.
  stagedTreeNotPublished,

  /// That slot's staging could not be carried aside.
  stagingNotSetAside,

  /// A resume could not park the record it was replacing.
  replacedRecordNotMovedAside,

  /// A resume could not copy the staged tree over `active/<id>/`.
  ///
  /// One word apart from [stagedTreeNotPublished] in the log, and a separate
  /// value for exactly that reason: the clause is what the log has said all
  /// along, and collapsing the two would rewrite one of the two lines.
  publishedCopyFailed,

  /// The bytes that landed in `active/<id>/` are not the ones that were staged.
  publishedTreeMismatch,

  /// Discarding a slot threw.
  discardThrew,

  /// Setting a slot aside threw.
  setAsideThrew,

  /// Resuming a transaction threw.
  resumeThrew,

  /// An archive move that stopped short of committing.
  ///
  /// The clause names `incomplete` outright rather than interpolating the
  /// result: the site raising it is behind an `isCommitted` filter, and
  /// `RecordTransactionResult` has exactly one value that filter lets through.
  /// Interpolating made that a fact about today's enum that nothing checked;
  /// writing it out makes a fourth result value a compile-time decision here.
  archiveMoveIncomplete,

  /// A recovery reported no reason for a slot it did not commit.
  ///
  /// Unreachable at the time of writing — every construction site of both
  /// recovery types states a reason whenever the result is uncommitted — and
  /// present because the seam that collects undrained slots must not answer a
  /// missing reason by dropping the slot. A dropped slot is a delete that
  /// proceeds over the only copy of a record.
  unspecified,
}

extension RecordRecoveryReasonClause on RecordRecoveryIncompleteReason {
  /// The English clause the log and the exception text use.
  ///
  /// Byte-for-byte what each site wrote inline before this enum existed, so a
  /// breadcrumb or a log search written against those lines keeps matching.
  /// **Not shown to a user**: the delete result panel goes through
  /// `storageRecoveryIncompleteDetail`, which maps this enum onto shipped keys.
  String get clause => switch (this) {
    RecordRecoveryIncompleteReason.strayEntry => 'it is not a transaction slot',
    RecordRecoveryIncompleteReason.foreignSlotName => 'its slot name is not one of ours',
    RecordRecoveryIncompleteReason.foreignArchiveSlotName => 'its name is not one any version of this app writes',
    RecordRecoveryIncompleteReason.unmintableSlotName =>
      'no slot name is derivable from a record id this version would not write',
    RecordRecoveryIncompleteReason.unresumableManifest => 'its manifest names no transaction this version can resume',
    RecordRecoveryIncompleteReason.unreadableManifest => 'its manifest could not be read',
    RecordRecoveryIncompleteReason.stagedTreeGone => 'the tree its manifest stages is gone',
    RecordRecoveryIncompleteReason.unresumableState => 'its manifest is in an unresumable state',
    RecordRecoveryIncompleteReason.supersededCopyNotSaved => 'the version it was replacing could not be saved',
    RecordRecoveryIncompleteReason.stagedTreeNotPublished => 'its staged tree could not be published',
    RecordRecoveryIncompleteReason.stagingNotSetAside => 'its staging could not be set aside',
    RecordRecoveryIncompleteReason.replacedRecordNotMovedAside => 'the record it replaces could not be moved aside',
    RecordRecoveryIncompleteReason.publishedCopyFailed => 'the staged tree could not be published',
    RecordRecoveryIncompleteReason.publishedTreeMismatch => 'the published tree does not match the staged one',
    RecordRecoveryIncompleteReason.discardThrew => 'discarding its slot threw',
    RecordRecoveryIncompleteReason.setAsideThrew => 'setting its slot aside threw',
    RecordRecoveryIncompleteReason.resumeThrew => 'resuming its transaction threw',
    RecordRecoveryIncompleteReason.archiveMoveIncomplete => 'its archive move stopped at incomplete',
    RecordRecoveryIncompleteReason.unspecified => 'recovery gave no reason',
  };
}
