import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/utils.dart';
import '/src/preference/storage_box.dart';

typedef LabelMap = Map<String, List<String>>;
typedef OnSpecChanged = void Function(ColumnSpec);

enum ColumnCategory {
  trainee,
  status,
  aptitude,
  skill,
  factor,
  supportCard,
  family,
  campaign,
  race,
}

abstract class ColumnBuilder {
  String get title;

  ColumnCategory get category;

  ColumnSpec build();
}

@jsonSerializable
class Tag {
  final String id;
  final String name;

  Tag(this.id, this.name);
}

@jsonSerializable
class SkillInfo {
  final int sid;
  final int sortKey;
  final List<String> names;
  final List<String> descriptions;
  final Set<String> tags;

  SkillInfo(this.sid, this.sortKey, this.names, this.descriptions, this.tags);
}

@jsonSerializable
class FactorInfo {
  final int sid;
  final int sortKey;
  final List<String> names;
  final List<String> descriptions;
  final Set<String> tags;
  final int? skillSid;
  final SkillInfo? skillInfo;

  FactorInfo({
    required this.sid,
    required this.sortKey,
    required this.names,
    required this.descriptions,
    required this.tags,
    this.skillSid,
    this.skillInfo,
  });

  FactorInfo copyWith({
    SkillInfo? skillInfo,
  }) {
    return FactorInfo(
      sid: sid,
      sortKey: sortKey,
      names: names,
      descriptions: descriptions,
      tags: tags,
      skillSid: skillSid,
      skillInfo: skillInfo ?? this.skillInfo,
    );
  }
}

@jsonSerializable
class CharaCardInfo {
  final int sid;
  final int sortKey;
  final List<String> names;

  CharaCardInfo(this.sid, this.sortKey, this.names);
}

class BuildResource {
  final LabelMap labelMap;
  final List<SkillInfo> skillInfo;
  final List<CharaCardInfo> charaCardInfo;
  final String recordRootDirectory;
  final List<int> charaRankBorder;

  BuildResource({
    required this.labelMap,
    required this.skillInfo,
    required this.charaCardInfo,
    required this.recordRootDirectory,
    required this.charaRankBorder,
  });
}

@jsonSerializable
enum ColumnSpecType {
  rangedInteger,
  rangedLabel,
  characterRank,
  characterCard,
  skill,
  factor,
}

@jsonSerializable
@Json(discriminatorProperty: 'type')
abstract class ColumnSpec<T> {
  ColumnSpecType get type;

  String get id;

  String get title;

  @JsonProperty(ignore: true)
  int get tabIdx => 0;

  List<T> parse(BuildResource resource, List<CharaDetailRecord> records);

  List<bool> evaluate(BuildResource resource, List<T> values);

  PlutoCell plutoCell(BuildResource resource, T value);

  PlutoColumn plutoColumn(BuildResource resource);

  String tooltip(BuildResource resource);

  Widget tag(BuildResource resource);

  Widget selector({required BuildResource resource, required OnSpecChanged onChanged});
}

class ColumnSpecSelection extends StateNotifier<List<ColumnSpec>> {
  final StorageEntry<String> entry;

  ColumnSpecSelection(this.entry) : super([]) {
    final data = entry.pull();
    state = data == null ? [] : JsonMapper.deserialize<List<ColumnSpec>>(data) ?? [];
  }

  void update(ColumnSpec spec) {
    assert(state.contains(spec));
    rebuild();
  }

  void add(ColumnSpec spec) {
    assert(!state.contains(spec));
    state.add(spec);
    rebuild();
  }

  void addOrUpdate(ColumnSpec spec) {
    if (!state.contains(spec)) {
      state.add(spec);
    }
    rebuild();
  }

  void remove(ColumnSpec spec) {
    assert(state.contains(spec));
    state.remove(spec);
    rebuild();
  }

  void removeIfExists(ColumnSpec spec) {
    if (state.contains(spec)) {
      state.remove(spec);
      rebuild();
    }
  }

  void moveTo(ColumnSpec obj, ColumnSpec target) {
    assert(state.contains(obj));
    assert(state.contains(target));
    if (obj == target) {
      return;
    }
    final moveRight = state.indexOf(obj) < state.indexOf(target);
    state.remove(obj);
    state.insert(state.indexOf(target) + (moveRight ? 1 : 0), obj);
    rebuild();
  }

  void replaceById(ColumnSpec spec) {
    final index = state.indexWhere((e) => e.id == spec.id);
    if (index != -1) {
      state.removeAt(index);
      state.insert(index, spec);
    } else {
      state.add(spec);
    }
    rebuild();
  }

  void rebuild() {
    state = [...state];
    entry.push(JsonMapper.serialize(state));
  }

  void saveState(String path) {
    logger.d(JsonMapper.serialize(state));
  }
}

extension PlutoCellWithUserData on PlutoCell {
  static final _userData = Expando();

  T? getUserData<T>() => _userData[this] as T?;

  void setUserData<T>(T value) => _userData[this] = value;
}

extension PlutoRowWithRawData on PlutoRow {
  static final _userData = Expando();

  T? getUserData<T>() => _userData[this] as T?;

  void setUserData<T>(T value) => _userData[this] = value;
}

extension PlutoColumnWithUserData on PlutoColumn {
  static final _userData = Expando();

  T? getUserData<T>() => _userData[this] as T?;

  void setUserData<T>(T value) => _userData[this] = value;
}
