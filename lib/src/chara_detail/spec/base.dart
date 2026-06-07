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
  script,
  logic,
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

enum ColumnBuilderType { normal, filter, add }

abstract class ColumnBuilder {
  String get title;

  ColumnCategory get category;

  ColumnBuilderType get type => ColumnBuilderType.normal;

  /// Optional explanatory tooltip shown on the builder chip in the add-column
  /// dialog. Null means no tooltip (the default for data columns).
  String? get tooltip => null;

  /// Optional truth table rendered beneath [tooltip] in the add-column dialog.
  /// The first row is the header; remaining rows are the cells. Null means no
  /// table (the default). The dialog turns this data into a `Table` widget.
  List<List<String>>? get truthTable => null;

  /// Whether this builder participates in the category's "add all" shortcut.
  /// Logic columns opt out so the shortcut never bulk-adds empty operators.
  bool get includeInAddAll => true;

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

  FactorInfo copyWith({SkillInfo? skillInfo}) {
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
enum ColumnSpecCellAction { openSkillPreview, openFactorPreview, openCampaignPreview }

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

  /// Whether this spec was saved against an incompatible contract version and
  /// should be surfaced as broken until the user re-validates it.
  ///
  /// Checked at load alongside [isSpecMapIncomplete]. Defaults to compatible;
  /// specs that carry a versioned contract (e.g. the script column) override it.
  bool get isObsolete => false;

  /// Child specs nested under this column. Only container columns (logic columns)
  /// have children; leaf columns return an empty list. Used by the tree-aware
  /// selection operations and the recursive chip UI.
  List<ColumnSpec> get children => const [];

  /// Returns a copy of this spec with its [children] replaced. Leaf columns ignore
  /// the argument and return themselves, so generic tree walks can call this
  /// unconditionally.
  ColumnSpec withChildren(List<ColumnSpec> children) => this;

  /// Whether this column can hold child columns at all (i.e. is a container).
  bool get acceptsChildren => false;

  /// Whether this container still has room for another child. Containers with a
  /// fixed arity (e.g. a NOT logic column) return false once full.
  bool get acceptsMoreChildren => false;

  List<T> parse(RefBase ref, List<CharaDetailRecord> records);

  List<bool> evaluate(RefBase ref, List<T> values);

  TrinaCell plutoCell(RefBase ref, T value);

  TrinaColumn plutoColumn(RefBase ref);

  String tooltip(RefBase ref);

  Widget label();

  Widget selector(ChangeNotifier onDecided);
}

// Translation prefix for the "broken column" UI (chip tooltip, placeholder text).
// ignore: constant_identifier_names
const tr_broken = "pages.chara_detail.column_predicate.broken";

// Returns true if [raw] (a spec map loaded from storage) is missing any key that
// a freshly-encoded spec of the same type ([full] == spec.toMap()) contains.
// It compares key PRESENCE only, recursively, and never compares values — so
// Set/List ordering or value differences can never produce a false positive.
// dart_mappable's encoder always writes every field (ignoreNull == false), so a
// spec saved by the current code carries every key and is therefore never
// flagged; only legacy data persisted before a field existed is missing keys and
// is thus reported as broken. Extra keys present in [raw] but absent from [full]
// (fields removed in a newer version) are intentionally ignored.
bool isSpecMapIncomplete(Object? raw, Object? full) {
  if (full is Map) {
    if (raw is! Map) return true;
    for (final entry in full.entries) {
      if (!raw.containsKey(entry.key)) return true;
      if (isSpecMapIncomplete(raw[entry.key], entry.value)) return true;
    }
    return false;
  }
  if (full is List) {
    if (raw is! List) return true;
    // Only compare the structural overlap; a list length mismatch is a value
    // difference (e.g. a different number of selected ids), not a missing field.
    final length = raw.length < full.length ? raw.length : full.length;
    for (var i = 0; i < length; i++) {
      if (isSpecMapIncomplete(raw[i], full[i])) return true;
    }
    return false;
  }
  return false;
}

// A column whose stored JSON could not be decoded into any known concrete spec
// (e.g. an unknown discriminator `type`, or a value that still fails the tolerant
// decode). Rather than drop it — which would erase the user's saved column from
// storage — the original map is kept verbatim, rendered as a benign,
// non-interactive placeholder column, and re-serialized unchanged so no data is
// lost. It is always flagged broken so the user is prompted to review (and can
// delete it via the existing right-click affordance).
class BrokenPlaceholderSpec extends ColumnSpec<Null> {
  final Map<String, dynamic> rawMap;

  @override
  final String id;

  @override
  final String title;

  BrokenPlaceholderSpec(this.rawMap)
    : id = (rawMap["id"] as String?) ?? "broken:${rawMap["type"] ?? "unknown"}",
      title = (rawMap["title"] as String?) ?? (rawMap["type"] as String?) ?? "Unknown";

  @override
  String get type => (rawMap["type"] as String?) ?? runtimeType.toString();

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  @override
  List<Null> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<Null>.filled(records.length, null);
  }

  @override
  List<bool> evaluate(RefBase ref, List<Null> values) {
    // Never filter rows out for a column we cannot understand.
    return List<bool>.filled(values.length, true);
  }

  @override
  TrinaCell plutoCell(RefBase ref, Null value) {
    return TrinaCell(value: "");
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    // Must not read any async-loaded provider here: this runs inside _buildGrid,
    // and a throw would trip the grid-failure path for every column.
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.text(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) => "$tr_broken.tooltip".tr();

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) => Text("$tr_broken.description".tr());

  @override
  Map<String, dynamic> toMap() => rawMap;

  @override
  String toJson() => jsonEncode(rawMap);
}

class ColumnSpecSelection extends AsyncNotifier<List<ColumnSpec>> {
  late StorageEntry<String> entry;

  // Ids of specs loaded from incomplete/undecodable data. Surfaced to the UI so
  // the user is prompted to review them. Cleared when the user updates a spec via
  // the settings dialog (replaceById) or removes it.
  final Set<String> _brokenIds = {};

  // Original stored map for each broken id. Re-serialized verbatim by _commit so
  // that, until the user explicitly fixes a broken column, its incomplete data is
  // preserved on disk and the broken flag re-appears on the next load. Never
  // silently healed.
  final Map<String, Map<String, dynamic>> _rawById = {};

  Set<String> get brokenIds => {..._brokenIds};

  void _clearBroken(String id) {
    _brokenIds.remove(id);
    _rawById.remove(id);
  }

  @override
  List<ColumnSpec> build() {
    entry = StorageBox(StorageBoxKey.columnSpec).entry<String>("current_column_specs");
    _brokenIds.clear();
    _rawById.clear();
    final raw = entry.pull();
    final data = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>);
    final specs = <ColumnSpec>[];
    bool broken = false;
    for (final d in data) {
      final map = d as Map<String, dynamic>;
      try {
        final spec = ColumnSpecMapper.fromMap(map);
        if (spec.isObsolete || isSpecMapIncomplete(map, spec.toMap())) {
          _brokenIds.add(spec.id);
          _rawById[spec.id] = map;
          broken = true;
        }
        specs.add(spec);
      } catch (e) {
        // Could not decode into any known spec. Keep the original map verbatim as
        // a placeholder so the user's saved column is never erased.
        logger.w("Failed to deserialize column spec; keeping as broken placeholder: error=$e, data=$d");
        final placeholder = BrokenPlaceholderSpec(map);
        _brokenIds.add(placeholder.id);
        _rawById[placeholder.id] = map;
        specs.add(placeholder);
        broken = true;
      }
    }
    if (broken) {
      Toaster.show(ToastData.warning(description: "pages.chara_detail.error.loading_spec".tr()));
    }
    return specs;
  }

  List<ColumnSpec> get _specs => state.requireValue;

  // ---- Tree helpers ---------------------------------------------------------
  // The selection is a forest: top-level specs may be logic columns whose
  // children are themselves specs (recursively). These pure helpers operate on a
  // list of roots and return freshly built lists so _commit never aliases the
  // live AsyncData backing list (see _commit's contract).

  static ColumnSpec? _findInList(List<ColumnSpec> list, String id) {
    for (final spec in list) {
      if (spec.id == id) return spec;
      final found = _findInList(spec.children, id);
      if (found != null) return found;
    }
    return null;
  }

  // Removes [id] from anywhere in the tree, returning (newList, removedSpec).
  // removedSpec is null when [id] was not found (newList is then unchanged).
  static (List<ColumnSpec>, ColumnSpec?) _detach(List<ColumnSpec> list, String id) {
    final result = <ColumnSpec>[];
    ColumnSpec? removed;
    for (final spec in list) {
      if (spec.id == id) {
        removed = spec;
        continue;
      }
      final (newChildren, childRemoved) = _detach(spec.children, id);
      if (childRemoved != null) {
        removed = childRemoved;
        result.add(spec.withChildren(newChildren));
      } else {
        result.add(spec);
      }
    }
    return (result, removed);
  }

  // Inserts [child] at [index] within [targetId]'s children (targetId == null
  // inserts into the top-level list itself). [index] is clamped to the valid
  // range. Returns a freshly built list; the unmatched branches are returned
  // verbatim so only the affected sibling list is rebuilt.
  static List<ColumnSpec> _insertAt(List<ColumnSpec> list, String? targetId, int index, ColumnSpec child) {
    if (targetId == null) {
      final result = [...list];
      result.insert(index.clamp(0, result.length), child);
      return result;
    }
    return list.map((spec) {
      if (spec.id == targetId) {
        final children = [...spec.children];
        children.insert(index.clamp(0, children.length), child);
        return spec.withChildren(children);
      }
      return spec.withChildren(_insertAt(spec.children, targetId, index, child));
    }).toList();
  }

  // Removes [id] and lifts its children into the slot it occupied (logic columns
  // dissolve back into normal columns). Returns null when [id] is not found.
  static List<ColumnSpec>? _removeLifting(List<ColumnSpec> list, String id) {
    var changed = false;
    final result = <ColumnSpec>[];
    for (final spec in list) {
      if (spec.id == id) {
        changed = true;
        result.addAll(spec.children);
        continue;
      }
      final newChildren = _removeLifting(spec.children, id);
      if (newChildren != null) {
        changed = true;
        result.add(spec.withChildren(newChildren));
      } else {
        result.add(spec);
      }
    }
    return changed ? result : null;
  }

  // Replaces the spec with the same id, anywhere in the tree. Returns null when
  // no spec with that id exists.
  static List<ColumnSpec>? _replaceInList(List<ColumnSpec> list, ColumnSpec replacement) {
    var changed = false;
    final result = <ColumnSpec>[];
    for (final spec in list) {
      if (spec.id == replacement.id) {
        changed = true;
        result.add(replacement);
        continue;
      }
      final newChildren = _replaceInList(spec.children, replacement);
      if (newChildren != null) {
        changed = true;
        result.add(spec.withChildren(newChildren));
      } else {
        result.add(spec);
      }
    }
    return changed ? result : null;
  }

  // Reorders [objId] relative to [targetId] within whichever sibling list holds
  // both. Returns null when they are not siblings anywhere in the tree.
  static List<ColumnSpec>? _reorderSiblings(List<ColumnSpec> list, String objId, String targetId) {
    final ids = list.map((e) => e.id).toList();
    if (ids.contains(objId) && ids.contains(targetId)) {
      final newList = [...list];
      final obj = newList.firstWhere((e) => e.id == objId);
      final moveRight = newList.indexWhere((e) => e.id == objId) < newList.indexWhere((e) => e.id == targetId);
      newList.removeWhere((e) => e.id == objId);
      final targetIndex = newList.indexWhere((e) => e.id == targetId);
      newList.insert(targetIndex + (moveRight ? 1 : 0), obj);
      return newList;
    }
    var changed = false;
    final result = list.map((spec) {
      final newChildren = _reorderSiblings(spec.children, objId, targetId);
      if (newChildren != null) {
        changed = true;
        return spec.withChildren(newChildren);
      }
      return spec;
    }).toList();
    return changed ? result : null;
  }

  // ---- Public API -----------------------------------------------------------

  ColumnSpec? getById(String id) {
    return _findInList(_specs, id);
  }

  bool contains(String id) {
    return _findInList(_specs, id) != null;
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
    removeIfExists(id);
  }

  void removeIfExists(String id) {
    final result = _removeLifting(_specs, id);
    if (result != null) {
      _clearBroken(id);
      _commit(result);
    }
  }

  void moveTo(ColumnSpec obj, ColumnSpec target) {
    if (obj.id == target.id) {
      return;
    }
    final result = _reorderSiblings(_specs, obj.id, target.id);
    if (result != null) {
      _commit(result);
    }
  }

  // Detaches [draggedId] from anywhere in the tree, then reinserts it at [index]
  // within [parentId]'s children ([parentId] == null reinserts at the top level).
  // No-op when [draggedId] is not present. This is the single primitive behind
  // the live drag reorder: it subsumes sibling reorder, injection into a logic
  // column and extraction to the top level. [index] is interpreted against the
  // tree *after* detachment, matching the slot model in reorder_slots.dart.
  void moveToSlot(String draggedId, String? parentId, int index) {
    final (detached, removed) = _detach(_specs, draggedId);
    if (removed == null) {
      return;
    }
    _commit(_insertAt(detached, parentId, index, removed));
  }

  void replaceById(ColumnSpec spec) {
    final result = _replaceInList(_specs, spec) ?? [..._specs, spec];
    // The user has reviewed/updated this column via the settings dialog, so the
    // broken flag is cleared and the next _commit persists the healed spec.
    _clearBroken(spec.id);
    _commit(result);
  }

  // Re-persist the current selection (e.g. after mutating a spec's internal
  // state in place). Builds a fresh list so the new AsyncData never shares its
  // backing list with the previous state.
  void rebuild() {
    _commit([..._specs]);
  }

  void clear() {
    _brokenIds.clear();
    _rawById.clear();
    _commit(<ColumnSpec>[]);
  }

  // Publish [specs] as the new state and write it back to storage. Callers must
  // pass a freshly-built list (never state.requireValue) so we don't mutate the
  // list held by the live AsyncData, which would defeat riverpod's
  // identity-based change detection and corrupt the previous state value.
  void _commit(List<ColumnSpec> specs) {
    state = AsyncData(specs);
    // Build the JSON array entry-by-entry (symmetric with build()'s manual
    // jsonDecode loop): broken entries are re-serialized from their original raw
    // map to preserve the incomplete data verbatim, everything else via toMap().
    final encoded = specs.map(_encodeForStorage).toList();
    entry.push(jsonEncode(encoded));
  }

  // Encode a spec for storage, preserving any broken/raw map verbatim at every
  // depth. A broken id re-emits its stored raw (whole subtree included); a healthy
  // container re-emits itself but recurses into its children so a nested broken
  // child keeps its raw map instead of being re-encoded (and silently healed) by
  // the mapper. Without the recursion, dragging a broken column under a logic
  // column would heal it on the next save.
  Map<String, dynamic> _encodeForStorage(ColumnSpec spec) {
    final raw = _rawById[spec.id];
    if (raw != null) {
      return raw;
    }
    if (spec.children.isEmpty) {
      return spec.toMap();
    }
    return {...spec.toMap(), 'children': spec.children.map(_encodeForStorage).toList()};
  }
}

extension TrinaGridStateManagerExtension on TrinaGridStateManager {
  void autoFitColumnPrecise(BuildContext context, TrinaColumn column) {
    if (refRows.isEmpty) {
      return;
    }
    final values = refRows.map((e) => column.formattedValueForDisplay(e.cells[column.field]?.value));
    final maxWidth = values.toSet().map((value) {
      TextSpan textSpan = TextSpan(style: DefaultTextStyle.of(context).style, text: value);
      TextPainter textPainter = TextPainter(text: textSpan, textDirection: ui.TextDirection.ltr);
      textPainter.layout();
      return textPainter.width;
    }).max;

    EdgeInsets cellPadding = column.cellPadding ?? configuration.style.defaultCellPadding;

    resizeColumn(column, maxWidth - column.width + (cellPadding.left + cellPadding.right) + 8);
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
