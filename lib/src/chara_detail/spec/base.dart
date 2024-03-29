import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/core/callback.dart';
import '/src/core/json_adapter.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

// ignore: constant_identifier_names
const tr_common = "pages.chara_detail.column_predicate.common";

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
  metadata,
}

class LabelKeys {
  static String get aptitude => "aptitude.name";

  static String get skill => "skill.name";

  static String get factor => "factor.name";

  static String get charaRank => "character_rank.name";

  static String get raceStrategy => "race_strategy.name";

  static String get campaignScenario => "scenario.name";
}

enum ColumnBuilderType {
  normal,
  filter,
  add,
}

abstract class ColumnBuilder {
  String get title;

  ColumnCategory get category;

  ColumnBuilderType get type => ColumnBuilderType.normal;

  ColumnSpec build(RefBase ref);
}

@jsonSerializable
class Tag extends JsonEquatable {
  final String id;
  final String name;

  const Tag(this.id, this.name);

  @override
  List<Object?> properties() => [id, name];
}

@jsonSerializable
class SkillInfo {
  final int sid;
  final int sortKey;
  final List<String> names;
  final List<String> descriptions;
  final Set<String> tags;

  SkillInfo(this.sid, this.sortKey, this.names, this.descriptions, this.tags);

  @JsonProperty(ignore: true)
  String get label => names.first;

  @JsonProperty(ignore: true)
  String get tooltip => descriptions.first;
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

  @JsonProperty(ignore: true)
  String get label => names.first;

  @JsonProperty(ignore: true)
  String get tooltip {
    String text = descriptions.first;
    if (skillInfo != null) {
      text += "\n${"$tr_common.selector.skill_prefix".tr()}${skillInfo!.descriptions.first}";
    }
    return text;
  }
}

@jsonSerializable
class CharaCardInfo {
  final int sid;
  final int sortKey;
  final List<String> names;

  CharaCardInfo(this.sid, this.sortKey, this.names);
}

@jsonSerializable
enum ColumnSpecCellAction {
  openSkillPreview,
  openFactorPreview,
  openCampaignPreview,
}

extension ColumnSpecCellActionExtension on ColumnSpecCellAction {
  int? get tabIdx {
    switch (this) {
      case ColumnSpecCellAction.openSkillPreview:
        return 0;
      case ColumnSpecCellAction.openFactorPreview:
        return 1;
      case ColumnSpecCellAction.openCampaignPreview:
        return 2;
    }
  }
}

@jsonSerializable
@Json(discriminatorProperty: 'type')
abstract class ColumnSpec<T> {
  String get type => runtimeType.toString();

  String get id;

  String get title;

  ColumnSpecCellAction get cellAction;

  List<T> parse(RefBase ref, List<CharaDetailRecord> records);

  List<bool> evaluate(RefBase ref, List<T> values);

  PlutoCell plutoCell(RefBase ref, T value);

  PlutoColumn plutoColumn(RefBase ref);

  String tooltip(RefBase ref);

  Widget label();

  Widget selector(ChangeNotifier onDecided);
}

class ColumnSpecSelection extends StateNotifier<List<ColumnSpec>> {
  final StorageEntry<String> entry;

  ColumnSpecSelection(this.entry) : super([]) {
    final data = JsonMapper.deserialize<List<dynamic>>(entry.pull()) ?? [];
    bool failed = false;
    for (final d in data) {
      try {
        state.addIfNotNull(JsonMapper.deserialize<ColumnSpec>(d));
      } catch (e) {
        // If the specification of the column spec is changed, it may not be able to load.
        logger.w("Failed to deserialize column spec: error=$e, data=$d");
        failed = true;
      }
    }
    if (failed) {
      Toaster.show(ToastData.warning(description: "pages.chara_detail.error.loading_spec".tr()));
    }
    state = [...state];
  }

  ColumnSpec? getById(String id) {
    return state.firstWhereOrNull((e) => e.id == id);
  }

  bool contains(String id) {
    return state.firstWhereOrNull((e) => e.id == id) != null;
  }

  void update(ColumnSpec spec) {
    assert(contains(spec.id));
    rebuild();
  }

  void add(ColumnSpec spec) {
    assert(!contains(spec.id));
    state.add(spec);
    rebuild();
  }

  void addOrUpdate(ColumnSpec spec) {
    if (!contains(spec.id)) {
      state.add(spec);
    }
    rebuild();
  }

  void remove(String id) {
    assert(contains(id));
    state.removeWhere((e) => e.id == id);
    rebuild();
  }

  void removeIfExists(String id) {
    if (contains(id)) {
      state.removeWhere((e) => e.id == id);
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

  void clear() {
    state = [];
    rebuild();
  }
}

extension PlutoGridStateManagerExtension on PlutoGridStateManager {
  void autoFitColumnPrecise(BuildContext context, PlutoColumn column) {
    if (refRows.isEmpty) {
      return;
    }
    final values = refRows.map((e) => column.formattedValueForDisplay(e.cells[column.field]?.value));
    final maxWidth = values.toSet().map((value) {
      TextSpan textSpan = TextSpan(
        style: DefaultTextStyle.of(context).style,
        text: value,
      );
      TextPainter textPainter = TextPainter(
        text: textSpan,
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout();
      return textPainter.width;
    }).max;

    EdgeInsets cellPadding = column.cellPadding ?? configuration!.style.defaultCellPadding;

    resizeColumn(
      column,
      maxWidth - column.width + (cellPadding.left + cellPadding.right) + 8,
    );
  }

  void autoFitColumns() {
    if (refRows.isEmpty) {
      return;
    }
    final context = gridKey!.currentContext!;
    for (final col in columns) {
      final enabled = col.enableDropToResize;
      col.enableDropToResize = true; // If this flag is false, col will ignore any resizing operations.
      autoFitColumnPrecise(context, col);
      if (maxWidth != null && col.width > maxWidth!) {
        resizeColumn(col, -(col.width / 2 - 24));
      }
      col.enableDropToResize = enabled;
    }
  }

  PlutoColumn? getColumn(String field) {
    return columns.firstWhereOrNull((e) => e.field == field);
  }

  void sortColumn(PlutoColumn col, PlutoColumnSort order) {
    if (order == PlutoColumnSort.ascending) {
      sortAscending(col);
    } else {
      sortDescending(col);
    }
  }

  void sortColumnByField(String columnField, PlutoColumnSort sortOrder) {
    final col = getColumn(columnField);
    if (col != null) {
      sortColumn(col, sortOrder);
    }
  }

  Iterable<CharaDetailRecord> getSortedRecords() {
    return refRows.map((e) => e.getUserData<CharaDetailRecord>()).whereNotNull();
  }
}

extension PlutoCellExtension on PlutoCell {
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

abstract class CellData implements Exportable {
  Predicate<PlutoGridOnSelectedEvent>? get onSelected;
}
