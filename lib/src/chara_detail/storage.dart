import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// TODO(riverpod3): remove once CharaDetailRecord{Storage,RegenerationController}
// are migrated to (Async)Notifier in Phase 2/3 of the riverpod 3 migration.
import 'package:flutter_riverpod/legacy.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/capture.dart';
import '/src/gui/toast.dart';

part 'storage.mapper.dart';

StreamController<String> _duplicatedCharaEventController = StreamController();
final duplicatedCharaEventProvider = StreamProvider<String>((ref) {
  if (_duplicatedCharaEventController.hasListener) {
    _duplicatedCharaEventController = StreamController();
  }
  return _duplicatedCharaEventController.stream;
});

class CharaCardIconMap extends Notifier<Map<int, FilePath>> {
  @override
  Map<int, FilePath> build() => {};

  void set(Map<int, FilePath> value) => state = value;
}

final charaCardIconMapProvider = NotifierProvider<CharaCardIconMap, Map<int, FilePath>>(CharaCardIconMap.new);

class CharaDetailRecordRegenerationController extends StateNotifier<Progress> {
  final Ref ref;

  CharaDetailRecordRegenerationController(this.ref) : super(Progress.none);

  Future<void> start(List<CharaDetailRecord> records) async {
    final platformController = await ref.read(platformControllerLoader.future);
    for (final record in records) {
      platformController!.updateRecord(record.id);
    }
    logger.d("Start regenerating ${records.length} chara detail records.");
    state = Progress(total: records.length);
  }

  Future<void> updated(String id) async {
    await ref.read(charaDetailRecordStorageProvider.notifier).reload(id);
    state = state.increment();
    if (state.isCompleted) {
      Future.delayed(const Duration(milliseconds: 200), () {
        ref.read(charaDetailRecordStorageProvider.notifier).forceRebuild();
        Toaster.show(ToastData(
            type: ToastType.success,
            description: "pages.capture.regenerate.success".tr(namedArgs: {
              "count": state.total.toString(),
            })));
        state = Progress.none;
      });
    }
    return Future.value();
  }
}

final charaDetailRecordRegenerationControllerProvider =
    StateNotifierProvider<CharaDetailRecordRegenerationController, Progress>((ref) {
  return CharaDetailRecordRegenerationController(ref);
});

@MappableEnum()
enum CharaDetailRecordImageMode {
  none,
  skillPlain,
  factorPlain,
  campaignPlain,
}

extension CharaDetailRecordImageModeExtension on CharaDetailRecordImageMode {
  String get fileName {
    switch (this) {
      case CharaDetailRecordImageMode.none:
        throw UnimplementedError();
      case CharaDetailRecordImageMode.skillPlain:
        return "skill.png";
      case CharaDetailRecordImageMode.factorPlain:
        return "factor.png";
      case CharaDetailRecordImageMode.campaignPlain:
        return "campaign.png";
    }
  }
}

class CharaDetailRecordStorage extends StateNotifier<List<CharaDetailRecord>> {
  final Ref ref;
  final DirectoryPath rootDirectory;
  final Map<int, CharaDetailRecord> charaCardMap = {};

  CharaDetailRecordStorage({
    required this.ref,
    required this.rootDirectory,
    required List<CharaDetailRecord> records,
  }) : super(records) {
    for (var e in records) {
      _updateRecordInfo(e);
    }
  }

  int get length => state.length;

  bool get isEmpty => state.isEmpty;

  void _updateRecordInfo(CharaDetailRecord record) {
    if (record.evaluationValue > (charaCardMap[record.trainee.card]?.evaluationValue ?? -1)) {
      charaCardMap[record.trainee.card] = record;
      ref.read(charaCardIconMapProvider.notifier).set(Map.from(charaCardIconMap));
    }
  }

  Map<int, FilePath> get charaCardIconMap {
    return charaCardMap.map((k, v) => MapEntry(k, (rootDirectory / v.id).filePath("trainee.jpg")));
  }

  void add(CharaDetailRecord record) {
    final duplicated = state.firstWhereOrNull((e) => record.isSameChara(e));
    if (duplicated != null && duplicated.id != record.id) {
      (rootDirectory / record.id).deleteSyncWithCheck(recursive: true);
      _duplicatedCharaEventController.sink.add(record.id);
      ref.read(charaDetailCaptureStateProvider.notifier).fail("duplicated_character");
      return;
    }
    _updateRecordInfo(record);

    state = [...state, record];

    final autoCopy = ref.read(autoCopyClipboardStateProvider);
    if (autoCopy != CharaDetailRecordImageMode.none) {
      copyToClipboard(record, autoCopy);
    }
  }

  void addIfNotNull(CharaDetailRecord? record) {
    if (record != null) {
      add(record);
    }
  }

  void addFromFile(String id) {
    addIfNotNull(CharaDetailRecord.load(rootDirectory / id));
  }

  CharaDetailRecord? getBy({required String id}) {
    return state.firstWhereOrNull((e) => e.id == id);
  }

  void replaceBy(CharaDetailRecord record, {required String id}) {
    final index = state.indexWhere((e) => e.id == id);
    assert(index != -1);
    state[index] = record;
  }

  DirectoryPath recordPathOf(CharaDetailRecord record) {
    return rootDirectory / record.id;
  }

  FilePath imagePathOf(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    return recordPathOf(record).filePath(image.fileName);
  }

  FilePath traineeIconPathOf(CharaDetailRecord record) {
    return rootDirectory.filePath(record.traineeIconPath);
  }

  void copyToClipboard(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    final imagePath = imagePathOf(record, image);
    ClipboardAlt.pasteImage(ref.base, imagePath);
  }

  List<CharaDetailRecord> get records => state;

  Future<void> checkRecordVersion({bool includeCurrentVersion = false}) async {
    final moduleVersion = await ref.read(moduleVersionLoader.future);
    if (moduleVersion == null) {
      return Future.value();
    }
    final obsoletedRecords = state.where((r) {
      return r.isObsoleted(moduleVersion, includeCurrentVersion) && r.isSupported(moduleVersion);
    }).toList();
    if (obsoletedRecords.isEmpty) {
      return Future.value();
    }
    ref.read(charaDetailRecordRegenerationControllerProvider.notifier).start(obsoletedRecords);
  }

  Future<void> reload(String id) async {
    final record = await compute(_loadCharaDetailRecord, rootDirectory / id);
    replaceBy(record!, id: id);
  }

  void delete(String id) {
    final record = getBy(id: id);
    assert(record != null);
    final directory = recordPathOf(record!);
    directory.deleteSyncSafeWithCheck();
    state.remove(record);
    forceRebuild();
  }

  void forceRebuild() {
    charaCardMap.clear();
    for (var e in state) {
      _updateRecordInfo(e);
    }
    state = [...state];
  }
}

CharaDetailRecord? _loadCharaDetailRecord(DirectoryPath directory) {
  initializeMappers();
  return CharaDetailRecord.load(directory);
}

List<CharaDetailRecord> _loadAllCharaDetailRecord(DirectoryPath directory) {
  initializeMappers();
  return directory
      .listSync(recursive: false, followLinks: false)
      .map((e) => CharaDetailRecord.load(e.asDirectoryPath))
      .whereNotNull()
      .toList();
}

final charaDetailRecordStorageLoader = FutureProvider<CharaDetailRecordStorage>((ref) async {
  final pathInfo = await ref.watch(pathInfoLoader.future);
  final List<CharaDetailRecord> records = [];
  if (pathInfo.charaDetailActiveDir.existsSync()) {
    records.addAll(await compute(_loadAllCharaDetailRecord, pathInfo.charaDetailActiveDir));
  }
  final storage = CharaDetailRecordStorage(ref: ref, rootDirectory: pathInfo.charaDetailActiveDir, records: records);
  // riverpod 3 removed StreamProvider.stream; listen to the AsyncValue and react
  // to each newly captured record id.
  ref.listen(charaDetailRecordCapturedEventProvider, (_, next) {
    next.whenData((e) => storage.addFromFile(e));
  });
  storage.checkRecordVersion();
  return storage;
});

final charaDetailRecordStorageProvider =
    StateNotifierProvider<CharaDetailRecordStorage, List<CharaDetailRecord>>((ref) {
  return ref.watch(charaDetailRecordStorageLoader).value!;
});
