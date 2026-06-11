import 'dart:convert';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/preset.dart';
import '/src/chara_detail/spec/spec_tree.dart';
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

  /// Which preview tab a cell of this column opens, or null when the column has
  /// no meaningful preview (container/placeholder columns). Leaf data columns
  /// override this with the relevant [ColumnSpecCellAction].
  ColumnSpecCellAction? get cellAction => null;

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

/// Capability of a column that nests other columns (a logic column) and derives
/// its own per-row condition/cell from theirs. Kept off [ColumnSpec] so leaf
/// columns cannot be asked to combine children at all; the grid builder reaches
/// these via an `is ContainerColumnSpec` test rather than a runtime throw.
mixin ContainerColumnSpec<T> on ColumnSpec<T> {
  /// Combines the resolved per-row conditions of this container's children into
  /// this column's own per-row condition.
  List<bool> combineChildren(List<List<bool>> childConditions, int rowCount);

  /// Builds the cell for this container from its combined per-row condition
  /// (a pass/fail cell), in place of a leaf column's parsed-value [plutoCell].
  TrinaCell conditionCell(RefBase ref, bool passed);
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

  // Storage key holding a container spec's nested children. Must match the
  // dart_mappable field name serialized by container specs (see LogicColumnSpec's
  // `children`); the encode/decode broken-preservation paths below depend on it.
  static const _childrenKey = 'children';

  Set<String> get brokenIds => {..._brokenIds};

  void _clearBroken(String id) {
    _brokenIds.remove(id);
    _rawById.remove(id);
  }

  @override
  List<ColumnSpec> build() {
    // Bind to the selected preset's spec entry. Watching the key makes preset
    // switching re-run build() against the new entry, swapping the columns the
    // grid shows. The broken-id bookkeeping below is per-entry and reset here,
    // so it always reflects the preset currently loaded.
    final entryKey = ref.watch(selectedColumnSpecEntryKeyProvider);
    entry = StorageBox(StorageBoxKey.columnSpec).entry<String>(entryKey);
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
        if (_registerBroken(spec, map)) {
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

  // Registers every node in [spec]'s subtree whose own stored fields are
  // incomplete (or which is obsolete), pairing each decoded spec with its raw
  // map so a nested broken child is flagged at its OWN id rather than its
  // container's. A healthy container is therefore kept out of [_rawById], letting
  // _encodeForStorage re-emit its live children (so drag edits persist), while a
  // genuinely broken leaf still keeps its raw map verbatim. Returns true when any
  // node in the subtree was registered broken.
  bool _registerBroken(ColumnSpec spec, Map<String, dynamic> rawMap) {
    var anyBroken = false;
    if (spec.isObsolete || _nodeFieldsIncomplete(rawMap, spec.toMap())) {
      _brokenIds.add(spec.id);
      _rawById[spec.id] = rawMap;
      anyBroken = true;
    }
    final rawChildren = rawMap[_childrenKey];
    if (rawChildren is List) {
      for (final (i, child) in spec.children.indexed) {
        if (i < rawChildren.length && rawChildren[i] is Map) {
          if (_registerBroken(child, (rawChildren[i] as Map).cast<String, dynamic>())) {
            anyBroken = true;
          }
        }
      }
    }
    return anyBroken;
  }

  // Like [isSpecMapIncomplete] but ignores the 'children' key: nested children
  // are validated by recursing on the decoded child specs (each flagged at its
  // own id), not by deep-comparing the container's whole subtree map.
  bool _nodeFieldsIncomplete(Map<String, dynamic> raw, Map<String, dynamic> full) {
    for (final entry in full.entries) {
      if (entry.key == _childrenKey) continue;
      if (!raw.containsKey(entry.key)) return true;
      if (isSpecMapIncomplete(raw[entry.key], entry.value)) return true;
    }
    return false;
  }

  List<ColumnSpec> get _specs => state.requireValue;

  // ---- Public API -----------------------------------------------------------
  // The selection is a forest (top-level specs may be logic columns whose
  // children are themselves specs). The pure tree algebra lives in spec_tree.dart
  // and is shared with the reorder-slot geometry; the methods below wrap it with
  // the broken-id bookkeeping and _commit's fresh-list contract.

  ColumnSpec? getById(String id) {
    return findInForest(_specs, id);
  }

  bool contains(String id) {
    return getById(id) != null;
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
    final result = removeLifting(_specs, id);
    if (result != null) {
      _clearBroken(id);
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
    final (detached, removed) = detachFromForest(_specs, draggedId);
    if (removed == null) {
      return;
    }
    // Reject illegal targets (a full NOT, or a non-container) so the model never
    // builds a tree the UI's slot suppression would have forbidden. Evaluated
    // against the detached tree, so reordering a container's sole child within it
    // (the container is momentarily empty) still passes.
    if (parentId != null) {
      final parent = findInForest(detached, parentId);
      if (parent == null || !parent.acceptsChildren || !parent.acceptsMoreChildren) {
        return;
      }
    }
    _commit(insertIntoForest(detached, parentId, index, removed));
  }

  void replaceById(ColumnSpec spec) {
    final result = replaceInForest(_specs, spec) ?? [..._specs, spec];
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

  // Encode a spec for storage, preserving any broken/raw fields verbatim at every
  // depth while still persisting live child edits. The node's OWN fields come from
  // its stored raw map when broken (so the incomplete data is never healed by the
  // mapper), otherwise from toMap(). A container then overrides its children with
  // the live, recursively-encoded subtree, so a nested broken child keeps its raw
  // map AND a child added/removed/reordered under a broken container still saves.
  // A spec with no live children (a leaf, or a fully undecodable BrokenPlaceholder
  // whose raw subtree must stay verbatim) returns its base map untouched.
  Map<String, dynamic> _encodeForStorage(ColumnSpec spec) {
    final base = _rawById[spec.id] ?? spec.toMap();
    if (spec.children.isEmpty) {
      return base;
    }
    return {...base, _childrenKey: spec.children.map(_encodeForStorage).toList()};
  }
}

// Storage entry holding the column preset index (the ordered preset list plus
// the selected key). A plain JSON string in the same box as the specs, so no
// Hive type adapter is needed.
const _presetIndexKey = "preset_index";

// Legacy single-configuration entry key. Read once during migration into the
// first preset, then never again (kept on disk as a safety net).
const _legacyColumnSpecsKey = "current_column_specs";

// Fixed key for the preset created by migrating the legacy single configuration.
// Deterministic (rather than a uuid) so the migrated specs always land at a
// predictable entry; user-created presets use uuids and never collide with it.
const _migratedPresetKey = "default";

// Holds the column preset index and persists it. Selecting/creating/renaming/
// deleting a preset goes through here; ColumnSpecSelection watches the derived
// selected-key provider, so the grid follows the selection automatically.
class ColumnPresetIndexNotifier extends Notifier<ColumnPresetIndex> {
  late StorageBox _box;
  late StorageEntry<String> _entry;

  @override
  ColumnPresetIndex build() {
    _box = StorageBox(StorageBoxKey.columnSpec);
    _entry = _box.entry<String>(_presetIndexKey);
    return _migrateAndLoad();
  }

  // Load the persisted index, migrating the legacy single configuration on first
  // run. Idempotent: once the index entry exists the legacy branch is skipped.
  ColumnPresetIndex _migrateAndLoad() {
    final raw = _entry.pull();
    if (raw != null) {
      return ColumnPresetIndexMapper.fromJson(raw);
    }
    // Copy (never move) the legacy specs verbatim so a crash mid-migration can
    // never lose them, and so broken specs are preserved for re-flagging.
    final legacy = _box.entry<String>(_legacyColumnSpecsKey).pull();
    if (legacy != null) {
      _box.entry<String>(ColumnPresetIndex.specEntryKey(_migratedPresetKey)).push(legacy);
    }
    final index = ColumnPresetIndex(
      presets: [ColumnPresetEntry(key: _migratedPresetKey, title: "pages.chara_detail.preset.default_title".tr())],
      selectedKey: _migratedPresetKey,
    );
    _entry.push(index.toJson());
    return index;
  }

  void _persist() {
    _entry.push(state.toJson());
  }

  /// Applies the preset identified by [key]. No-op when already selected or
  /// when [key] is not present.
  void select(String key) {
    if (key == state.selectedKey || state.presets.every((e) => e.key != key)) {
      return;
    }
    state = state.copyWith(selectedKey: key);
    _persist();
  }

  /// Creates a new empty preset titled [title] and selects it. Its spec entry is
  /// created lazily on the first column edit (ColumnSpecSelection._commit).
  String create(String title) {
    final key = const Uuid().v4();
    state = state.copyWith(
      presets: [
        ...state.presets,
        ColumnPresetEntry(key: key, title: title),
      ],
      selectedKey: key,
    );
    _persist();
    return key;
  }

  /// Duplicates [sourceKey]'s columns into a new preset titled [title] and
  /// selects it. The specs are copied verbatim, so broken specs carry over.
  String duplicate(String sourceKey, String title) {
    final key = const Uuid().v4();
    final raw = _box.entry<String>(ColumnPresetIndex.specEntryKey(sourceKey)).pull();
    if (raw != null) {
      _box.entry<String>(ColumnPresetIndex.specEntryKey(key)).push(raw);
    }
    state = state.copyWith(
      presets: [
        ...state.presets,
        ColumnPresetEntry(key: key, title: title),
      ],
      selectedKey: key,
    );
    _persist();
    return key;
  }

  /// Renames the preset identified by [key].
  void rename(String key, String title) {
    state = state.copyWith(presets: [for (final p in state.presets) p.key == key ? p.copyWith(title: title) : p]);
    _persist();
  }

  /// Deletes the preset identified by [key]. The last preset cannot be deleted.
  /// Deleting the selected preset falls back to the first remaining one.
  void delete(String key) {
    if (state.presets.length <= 1) {
      return;
    }
    final remaining = state.presets.where((e) => e.key != key).toList();
    final selectedKey = key == state.selectedKey ? remaining.first.key : state.selectedKey;
    state = state.copyWith(presets: remaining, selectedKey: selectedKey);
    _persist();
    _box.entry<String>(ColumnPresetIndex.specEntryKey(key)).delete();
  }
}

final columnPresetIndexProvider = NotifierProvider<ColumnPresetIndexNotifier, ColumnPresetIndex>(
  ColumnPresetIndexNotifier.new,
);

// The selected preset's spec-entry key. ColumnSpecSelection.build watches this,
// so selecting a preset rebuilds the selection (and therefore the grid).
final selectedColumnSpecEntryKeyProvider = Provider<String>((ref) {
  final index = ref.watch(columnPresetIndexProvider);
  return ColumnPresetIndex.specEntryKey(index.selectedKey);
});

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

    // Grow-only: never shrink below the current width. autoFitColumns() runs the
    // built-in autoFitColumn first to size the column for its title, so this
    // precise cell-based pass must only widen it further when the body needs more
    // room, otherwise it would clip a title that is wider than the cells.
    final preciseTarget = maxWidth + (cellPadding.left + cellPadding.right) + 8;
    resizeColumn(column, [0.0, preciseTarget - column.width].max);
  }

  void autoFitColumns() {
    if (refRows.isEmpty) {
      return;
    }
    final context = gridKey.currentContext!;
    for (final col in columns) {
      final enabled = col.enableDropToResize;
      col.enableDropToResize = true; // If this flag is false, col will ignore any resizing operations.
      // Built-in autoFitColumn sizes the column to max(title, cell) so the header
      // title is never clipped. autoFitColumnPrecise then widens it further if the
      // cells' true rendered width needs more room (grow-only, see above).
      autoFitColumn(context, col);
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
