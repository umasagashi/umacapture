// Deliberately broken rules (mutants), carried as data into the core, the fake server and the
// device. They are positive controls for the random check: each one breaks a rule a promise depends
// on, and a random run must catch it without being handed a named sequence. `null` everywhere means
// the rules as designed.
//
// The judge does not read this file. Its own positive controls are the accepted outcomes it is built
// with (`Judge(accepted:)`): leaving one out must make a run that reaches that loss report it.

enum Mutation {
  /// Core: `retire_images` never moves a retired record's images to the terminal, so an image that
  /// only the retired record held is deleted with it.
  retireImagesNeverMove,

  /// Fake server: branch (2′a) accepts a merge without checking that the sender saw every id the
  /// survivor has absorbed, so a later merge overwrites another device's accepted merge onto the
  /// same survivor without either device having seen the other's.
  mergeIgnoresAbsorbed,

  /// Core: row 316 (follow the server when the device still holds what it last saw) falls through
  /// to row 317 (fork), so every ordinary merge accepted elsewhere brings back the content the user
  /// discarded, as a new record.
  followBecomesFork,

  /// Fake server: the retire function tombstones a retired id without checking that it is still
  /// what the sender retired (its content and what it absorbed), so a newer choice made on that id
  /// elsewhere is deleted.
  retireWithoutContentCheck,

  /// Core: a tombstone deletes the record without first forking content that may exist only on
  /// this device (predicate L ignored at rows 308 / 309).
  noForkBeforeTombstone,

  /// Core: the device takes the server's memo even when its own unsent edit is newer.
  memoAlwaysTakesServer,
}
