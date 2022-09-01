import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/capture.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_capture = "pages.capture";

StreamController<String> _duplicatedCharaEventController = StreamController();
final duplicatedCharaEventProvider = StreamProvider<String>((ref) {
  if (_duplicatedCharaEventController.hasListener) {
    _duplicatedCharaEventController = StreamController();
  }
  return _duplicatedCharaEventController.stream;
});

final charaCardIconMapProvider = StateProvider<Map<int, FilePath>>((ref) {
  return {};
});

class CharaDetailRecordRegenerationController extends StateNotifier<Progress> {
  final Ref ref;

  CharaDetailRecordRegenerationController(this.ref) : super(Progress.none);

  Future<void> start(List<CharaDetailRecord> records) async {
    final platformController = await ref.read(platformControllerLoader.future);
    for (final record in records) {
      platformController!.updateRecord(record.id);
    }
    state = Progress(total: records.length);
  }

  Future<void> updated(String id) async {
    await ref.read(charaDetailRecordStorageProvider.notifier).reload(id);
    state = state.increment();
    if (state.isCompleted) {
      Future.delayed(const Duration(milliseconds: 200), () {
        state = Progress.none;
        ref.read(charaDetailRecordStorageProvider.notifier).forceRebuild();
      });
    }
    return Future.value();
  }
}

final charaDetailRecordRegenerationControllerProvider =
    StateNotifierProvider<CharaDetailRecordRegenerationController, Progress>((ref) {
  return CharaDetailRecordRegenerationController(ref);
});

@jsonSerializable
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
      ref.read(charaCardIconMapProvider.notifier).update((_) => Map.from(charaCardIconMap));
    }
  }

  Map<int, FilePath> get charaCardIconMap {
    return charaCardMap.map((k, v) => MapEntry(k, (rootDirectory / v.id).filePath("trainee.jpg")));
  }

  void add(CharaDetailRecord record) {
    final duplicated = state.firstWhereOrNull((e) => record.isSameChara(e));
    if (duplicated != null && duplicated.id != record.id) {
      (rootDirectory / record.id).deleteSync(recursive: true);
      _duplicatedCharaEventController.sink.add(record.id);
      ref.read(charaDetailCaptureStateProvider.notifier).update((state) => state.fail(message: "duplicated_character"));
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
    CharaDetailRecord.load(rootDirectory / id).then((e) => addIfNotNull(e));
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

  void copyToClipboard(CharaDetailRecord record, CharaDetailRecordImageMode image, {bool memory = false}) {
    assert(image != CharaDetailRecordImageMode.none);
    final imagePath = imagePathOf(record, image);
    if (!imagePath.existsSync()) {
      Toaster.show(ToastData(ToastType.error, description: "$tr_toast.clipboard.file_not_found".tr()));
      return;
    }

    late final Future<bool> result;
    if (memory) {
      final controller = ref.read(platformControllerProvider);
      if (controller == null) {
        Toaster.show(ToastData(ToastType.error, description: "$tr_toast.clipboard.unavailable".tr()));
        return;
      }
      result = controller.copyToClipboardFromFile(imagePath).then((e) => true);
    } else {
      result = Pasteboard.writeFiles([imagePath.path]);
    }

    result.then((result) {
      if (result) {
        Toaster.show(ToastData(ToastType.success, description: "$tr_toast.clipboard.success".tr()));
      } else {
        Toaster.show(ToastData(ToastType.error, description: "$tr_toast.clipboard.failed_result_code".tr()));
      }
    });
  }

  List<CharaDetailRecord> get records => state;

  Future<void> checkRecordVersion() async {
    final moduleVersion = await ref.read(moduleVersionLoader.future);
    if (moduleVersion == null) {
      return Future.value();
    }
    final obsoletedRecords = state.where((r) => r.isObsoleted(moduleVersion)).toList();
    if (obsoletedRecords.isNotEmpty) {
      ref.read(charaDetailRecordRegenerationControllerProvider.notifier).start(obsoletedRecords);
    }
  }

  Future<void> reload(String id) async {
    final record = await compute(_loadCharaDetailRecord, rootDirectory / id);
    replaceBy(record!, id: id);
  }

  void forceRebuild() {
    charaCardMap.clear();
    for (var e in state) {
      _updateRecordInfo(e);
    }
    state = [...state];
  }
}

Future<CharaDetailRecord?> _loadCharaDetailRecord(DirectoryPath directory) {
  initializeJsonReflectable();
  return CharaDetailRecord.load(directory);
}

Future<List<CharaDetailRecord>> _loadAllCharaDetailRecord(DirectoryPath directory) {
  initializeJsonReflectable();
  final records =
      directory.listSync(recursive: false, followLinks: false).map((e) => CharaDetailRecord.load(e.asDirectoryPath));
  return Future.wait(records).then((e) => e.whereNotNull().toList());
}

final charaDetailRecordStorageLoader = FutureProvider<CharaDetailRecordStorage>((ref) async {
  final pathInfo = await ref.watch(pathInfoLoader.future);
  final List<CharaDetailRecord> records = [];
  if (pathInfo.charaDetailActiveDir.existsSync()) {
    records.addAll(await compute(_loadAllCharaDetailRecord, pathInfo.charaDetailActiveDir));
  }
  final storage = CharaDetailRecordStorage(ref: ref, rootDirectory: pathInfo.charaDetailActiveDir, records: records);
  ref.watch(charaDetailRecordCapturedEventProvider.stream).listen((e) => storage.addFromFile(e));
  storage.checkRecordVersion();
  return storage;
});

final charaDetailRecordStorageProvider =
    StateNotifierProvider<CharaDetailRecordStorage, List<CharaDetailRecord>>((ref) {
  return ref.watch(charaDetailRecordStorageLoader).value!;
});
