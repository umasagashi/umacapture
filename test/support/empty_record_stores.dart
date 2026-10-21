import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';

/// Both record stores, holding no record and opening nothing.
///
/// For a container that never opens the record stores for anything but the list a metadata delete in the storage view
/// reads — the records a column storage's removal writes none for — so the delete runs without building a store a case
/// has no use for.
final emptyRecordStoreOverrides = [
  charaDetailRecordStorageLoaderProvider.overrideWith(_EmptyRecordStorage.new),
  charaDetailArchiveStorageLoaderProvider.overrideWith(_EmptyArchiveStorage.new),
];

class _EmptyRecordStorage extends CharaDetailRecordStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

class _EmptyArchiveStorage extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}
