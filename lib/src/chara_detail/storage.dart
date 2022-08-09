import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/json_adapter.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/capture.dart';

// ignore: constant_identifier_names
const tr_capture = "pages.capture";

StreamController<String> _duplicatedCharaEventController = StreamController();
final duplicatedCharaEventProvider = StreamProvider<String>((ref) {
  if (_duplicatedCharaEventController.hasListener) {
    _duplicatedCharaEventController = StreamController();
  }
  return _duplicatedCharaEventController.stream;
});

StreamController<String> _clipboardPasteEventController = StreamController();
final clipboardPasteEventProvider = StreamProvider<String>((ref) {
  if (_clipboardPasteEventController.hasListener) {
    _clipboardPasteEventController = StreamController();
  }
  return _clipboardPasteEventController.stream;
});

final charaCardIconMapProvider = StateProvider<Map<int, String>>((ref) {
  return {};
});

final availableSkillSetProvider = StateProvider<Set<int>>((ref) {
  return {};
});

final availableFactorSetProvider = StateProvider<Set<int>>((ref) {
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
  final String directory;
  final Map<int, CharaDetailRecord> charaCardMap = {};
  final Set<int> skillSet = {};
  final Set<int> factorSet = {};

  CharaDetailRecordStorage({required this.ref, required this.directory, required List<CharaDetailRecord> records})
      : super(records) {
    for (var e in records) {
      _updateRecordInfo(e, update: false);
    }
    _updateIconMapNotifier();
    _updateSkillSetNotifier();
  }

  void _updateRecordInfo(CharaDetailRecord record, {bool update = true}) {
    if (record.evaluationValue > (charaCardMap[record.trainee.card]?.evaluationValue ?? -1)) {
      charaCardMap[record.trainee.card] = record;
      if (update) {
        _updateIconMapNotifier();
      }
    }

    if (skillSet.addAllWithSizeCheck(record.skills.map((e) => e.id))) {
      _updateSkillSetNotifier();
    }

    if (factorSet.addAllWithSizeCheck(record.factors.flattened.map((e) => e.id))) {
      _updateFactorSetNotifier();
    }
  }

  void _updateIconMapNotifier() {
    final iconMap = charaCardMap.map((k, v) => MapEntry(k, "$directory/${v.id}/trainee.jpg"));
    ref.read(charaCardIconMapProvider.notifier).update((e) => Map.from(iconMap));
  }

  void _updateSkillSetNotifier() {
    ref.read(availableSkillSetProvider.notifier).update((e) => Set.from(skillSet));
  }

  void _updateFactorSetNotifier() {
    ref.read(availableFactorSetProvider.notifier).update((e) => Set.from(factorSet));
  }

  void add(CharaDetailRecord record) {
    final duplicated = state.firstWhereOrNull((e) => record.isSameChara(e));
    if (duplicated != null && duplicated.id != record.id) {
      Directory("$directory/${record.id}").delete(recursive: true);
      _duplicatedCharaEventController.sink.add(record.id);
      ref
          .watch(charaDetailCaptureStateProvider.notifier)
          .update((state) => state.fail(message: "duplicated_character"));
      return;
    }
    _updateRecordInfo(record);

    state = [...state, record];

    final autoCopy = ref.read(autoCopyClipboardStateProvider);
    if (autoCopy != CharaDetailRecordImageMode.none) {
      copyToClipboard(record, autoCopy);
    }
  }

  void addFromFile(String id) {
    CharaDetailRecord.readFromDirectory(Directory("$directory/$id")).then((e) {
      if (e != null) {
        add(e);
      }
    });
  }

  CharaDetailRecord? getBy({required String id}) {
    return state.firstWhereOrNull((e) => e.id == id);
  }

  void replaceBy(CharaDetailRecord record, {required String id}) {
    final index = state.indexWhere((e) => e.id == id);
    assert(index != -1);
    state[index] = record;
  }

  String recordPathOf(CharaDetailRecord record) {
    return "$directory/${record.id}";
  }

  String imagePathOf(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    return "${recordPathOf(record)}/${image.fileName}";
  }

  void copyToClipboard(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    final imagePath = imagePathOf(record, image);
    Pasteboard.writeFiles([imagePath]).then((_) => _clipboardPasteEventController.sink.add(imagePath));
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
    final record = await compute(_loadCharaDetailRecord, Directory("$directory/$id"));
    replaceBy(record!, id: id);
  }

  void forceRebuild() {
    charaCardMap.clear();
    skillSet.clear();
    factorSet.clear();
    for (var e in state) {
      _updateRecordInfo(e, update: false);
    }
    _updateIconMapNotifier();
    _updateSkillSetNotifier();
    state = [...state];
  }
}

Future<CharaDetailRecord?> _loadCharaDetailRecord(Directory directory) {
  initializeJsonReflectable();
  return CharaDetailRecord.readFromDirectory(Directory(directory.path));
}

Future<List<CharaDetailRecord>> _loadAllCharaDetailRecord(Directory directory) {
  initializeJsonReflectable();
  final files = directory
      .listSync(recursive: false, followLinks: false)
      .map((e) => CharaDetailRecord.readFromDirectory(Directory(e.path)));
  return Future.wait(files).then((e) => e.whereNotNull().toList());
}

final charaDetailRecordStorageLoader = FutureProvider<CharaDetailRecordStorage>((ref) async {
  final pathInfo = await ref.watch(pathInfoLoader.future);
  final directory = Directory(pathInfo.charaDetail);
  final List<CharaDetailRecord> records = [];
  if (directory.existsSync()) {
    records.addAll(await compute(_loadAllCharaDetailRecord, directory));
  }
  final storage = CharaDetailRecordStorage(ref: ref, directory: pathInfo.charaDetail, records: records);
  ref.watch(charaDetailRecordCapturedEventProvider.stream).listen((e) => storage.addFromFile(e));
  storage.checkRecordVersion();
  return storage;
});

final charaDetailRecordStorageProvider =
    StateNotifierProvider<CharaDetailRecordStorage, List<CharaDetailRecord>>((ref) {
  return ref.watch(charaDetailRecordStorageLoader).value!;
});
