import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';

import '/src/app/providers.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/json_adapter.dart';
import '/src/core/platform_controller.dart';
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

    final previous = skillSet.length;
    skillSet.addAll(record.skills.map((e) => e.id));
    if (previous != skillSet.length) {
      _updateSkillSetNotifier();
    }
  }

  void _updateIconMapNotifier() {
    final iconMap = charaCardMap.map((k, v) => MapEntry(k, "$directory/${v.metadata.recordId.self}/trainee.jpg"));
    ref.read(charaCardIconMapProvider.notifier).update((e) => Map.from(iconMap));
  }

  void _updateSkillSetNotifier() {
    ref.read(availableSkillSetProvider.notifier).update((e) => Set.from(skillSet));
  }

  void add(CharaDetailRecord record) {
    if (state.firstWhereOrNull((e) => record.isSameChara(e)) != null) {
      Directory("$directory/${record.metadata.recordId.self}").delete(recursive: true);
      _duplicatedCharaEventController.sink.add(record.metadata.recordId.self);
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
    return state.firstWhereOrNull((e) => e.metadata.recordId.self == id);
  }

  String recordPathOf(CharaDetailRecord record) {
    return "$directory/${record.metadata.recordId.self}";
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
}

Future<List<CharaDetailRecord>> _loadCharaDetailRecords(Directory directory) {
  initializeJsonReflectable();
  final files = directory
      .listSync(recursive: false, followLinks: false)
      .map((e) => CharaDetailRecord.readFromDirectory(Directory(e.path)));
  return Future.wait(files).then((e) => e.whereNotNull().toList());
}

final charaDetailRecordStorageLoader = FutureProvider<CharaDetailRecordStorage>((ref) async {
  return ref.watch(pathInfoLoader.future).then((info) async {
    final directory = Directory(info.charaDetail);
    final List<CharaDetailRecord> records = [];
    if (directory.existsSync()) {
      records.addAll(await compute(_loadCharaDetailRecords, directory));
    }
    final storage = CharaDetailRecordStorage(ref: ref, directory: info.charaDetail, records: records);
    ref.watch(charaDetailRecordCapturedEventProvider.stream).listen((e) => storage.addFromFile(e));
    return storage;
  });
});

final charaDetailRecordStorageProvider =
    StateNotifierProvider<CharaDetailRecordStorage, List<CharaDetailRecord>>((ref) {
  return ref.watch(charaDetailRecordStorageLoader).value!;
});
