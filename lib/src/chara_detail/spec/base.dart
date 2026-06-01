import 'dart:convert';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/core/callback.dart';
import '/src/core/json_adapter.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

part 'base.mapper.dart';

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

  static String get recordType => "record_type.name";
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

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Tag extends JsonEquatable with TagMappable {
  final String id;
  final String name;

  const Tag(this.id, this.name);

  @override
  List<Object?> properties() => [id, name];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class SkillInfo with SkillInfoMappable {
  final int sid;
  final int sortKey;
  final List<String> names;
  final List<String> descriptions;
  final Set<String> tags;

  SkillInfo(this.sid, this.sortKey, this.names, this.descriptions, this.tags);

  String get label => names.first;

  String get tooltip => descriptions.first;
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class FactorInfo with FactorInfoMappable {
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

  String get label => names.first;

  String get tooltip {
    String text = descriptions.first;
    if (skillInfo != null) {
      text += "\n${"$tr_common.selector.skill_prefix".tr()}${skillInfo!.descriptions.first}";
    }
    return text;
  }
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class CharaCardInfo with CharaCardInfoMappable {
  final int sid;
  final int sortKey;
  final List<String> names;

  CharaCardInfo(this.sid, this.sortKey, this.names);
}

@MappableEnum()
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

@MappableClass(discriminatorKey: 'type')
abstract class ColumnSpec<T> with ColumnSpecMappable<T> {
  String get type => runtimeType.toString();

  String get id;

  String get title;

  ColumnSpecCellAction get cellAction;

  List<T> parse(RefBase ref, List<CharaDetailRecord> records);

  List<bool> evaluate(RefBase ref, List<T> values);

  TrinaCell plutoCell(RefBase ref, T value);

  TrinaColumn plutoColumn(RefBase ref);

  String tooltip(RefBase ref);

  Widget label();

  Widget selector(ChangeNotifier onDecided);
}

class ColumnSpecSelection extends AsyncNotifier<List<ColumnSpec>> {
  late StorageEntry<String> entry;

  @override
  List<ColumnSpec> build() {
    entry = StorageBox(StorageBoxKey.columnSpec).entry<String>("current_column_specs");
    final raw = entry.pull();
    final data = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>);
    final specs = <ColumnSpec>[];
    bool failed = false;
    for (final d in data) {
      try {
        specs.addIfNotNull(ColumnSpecMapper.fromMap(d as Map<String, dynamic>));
      } catch (e) {
        // If the specification of the column spec is changed, it may not be able to load.
        logger.w("Failed to deserialize column spec: error=$e, data=$d");
        failed = true;
      }
    }
    if (failed) {
      Toaster.show(ToastData.warning(description: "pages.chara_detail.error.loading_spec".tr()));
    }
    return specs;
  }

  List<ColumnSpec> get _specs => state.requireValue;

  ColumnSpec? getById(String id) {
    return _specs.firstWhereOrNull((e) => e.id == id);
  }

  bool contains(String id) {
    return _specs.firstWhereOrNull((e) => e.id == id) != null;
  }

  void add(ColumnSpec spec) {
    assert(!contains(spec.id));
    _commit([..._specs, spec]);
  }

  void addOrUpdate(ColumnSpec spec) {
    _commit(contains(spec.id) ? [..._specs] : [..._specs, spec]);
  }

  void remove(String id) {
    assert(contains(id));
    _commit(_specs.where((e) => e.id != id).toList());
  }

  void removeIfExists(String id) {
    if (contains(id)) {
      _commit(_specs.where((e) => e.id != id).toList());
    }
  }

  void moveTo(ColumnSpec obj, ColumnSpec target) {
    final specs = [..._specs];
    assert(specs.contains(obj));
    assert(specs.contains(target));
    if (obj == target) {
      return;
    }
    final moveRight = specs.indexOf(obj) < specs.indexOf(target);
    specs.remove(obj);
    specs.insert(specs.indexOf(target) + (moveRight ? 1 : 0), obj);
    _commit(specs);
  }

  void replaceById(ColumnSpec spec) {
    final specs = [..._specs];
    final index = specs.indexWhere((e) => e.id == spec.id);
    if (index != -1) {
      specs[index] = spec;
    } else {
      specs.add(spec);
    }
    _commit(specs);
  }

  // Re-persist the current selection (e.g. after mutating a spec's internal
  // state in place). Builds a fresh list so the new AsyncData never shares its
  // backing list with the previous state.
  void rebuild() {
    _commit([..._specs]);
  }

  void clear() {
    _commit(<ColumnSpec>[]);
  }

  // Publish [specs] as the new state and write it back to storage. Callers must
  // pass a freshly-built list (never state.requireValue) so we don't mutate the
  // list held by the live AsyncData, which would defeat riverpod's
  // identity-based change detection and corrupt the previous state value.
  void _commit(List<ColumnSpec> specs) {
    state = AsyncData(specs);
    entry.push(MapperContainer.globals.toJson<List<ColumnSpec>>(specs));
  }
}

extension TrinaGridStateManagerExtension on TrinaGridStateManager {
  void autoFitColumnPrecise(BuildContext context, TrinaColumn column) {
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

    EdgeInsets cellPadding = column.cellPadding ?? configuration.style.defaultCellPadding;

    resizeColumn(
      column,
      maxWidth - column.width + (cellPadding.left + cellPadding.right) + 8,
    );
  }

  void autoFitColumns() {
    if (refRows.isEmpty) {
      return;
    }
    final context = gridKey.currentContext!;
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

  TrinaColumn? getColumn(String field) {
    return columns.firstWhereOrNull((e) => e.field == field);
  }

  void sortColumn(TrinaColumn col, TrinaColumnSort order) {
    if (order == TrinaColumnSort.ascending) {
      sortAscending(col);
    } else {
      sortDescending(col);
    }
  }

  void sortColumnByField(String columnField, TrinaColumnSort sortOrder) {
    final col = getColumn(columnField);
    if (col != null) {
      sortColumn(col, sortOrder);
    }
  }

  Iterable<CharaDetailRecord> getSortedRecords() {
    return refRows.map((e) => e.getUserData<CharaDetailRecord>()).nonNulls;
  }
}

extension TrinaCellExtension on TrinaCell {
  static final _userData = Expando();

  T? getUserData<T>() => _userData[this] as T?;

  void setUserData<T>(T value) => _userData[this] = value;
}

extension TrinaRowWithRawData on TrinaRow {
  static final _userData = Expando();

  T? getUserData<T>() => _userData[this] as T?;

  void setUserData<T>(T value) => _userData[this] = value;
}

extension TrinaColumnWithUserData on TrinaColumn {
  static final _userData = Expando();

  T? getUserData<T>() => _userData[this] as T?;

  void setUserData<T>(T value) => _userData[this] = value;
}

abstract class CellData implements Exportable {
  Predicate<TrinaGridOnSelectedEvent>? get onSelected;
}
