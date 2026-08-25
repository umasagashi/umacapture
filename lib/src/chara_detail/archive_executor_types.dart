/// What to do with a record's recognition images when archiving it.
enum ArchiveImageOption {
  /// Drop the images entirely (smallest result).
  none,

  /// Replace the lossless PNGs with width-clamped JPEGs.
  resizedJpeg,
}

/// Plain archive request data that can cross the native isolate boundary.
class ArchiveRecordArgs {
  final String srcDirPath;
  final String dstDirPath;
  final ArchiveImageOption option;

  const ArchiveRecordArgs(this.srcDirPath, this.dstDirPath, this.option);
}

/// A batch of archive requests. Results always align with [items].
class ArchiveBatchArgs {
  final List<ArchiveRecordArgs> items;

  const ArchiveBatchArgs(this.items);
}
