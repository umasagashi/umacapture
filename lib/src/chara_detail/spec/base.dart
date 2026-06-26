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
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

part 'base.mapper.dart';

// ignore: constant_identifier_names
const tr_common = "pages.chara_detail.column_predicate.common";

typedef LabelMap = Map<String, List<String>>;
typedef OnSpecChanged = void Function(ColumnSpec);

/// Whether table cells grow their row to fit the wrapped text (true) or keep a
/// fixed row height and ellipsize at two lines (false). A global display toggle,
/// persisted in settings and watched by [CellText] and the row-height pass, so a
/// narrowed column either reflows into taller rows or truncates cleanly instead
/// of clipping its third line.
final charaDetailAutoRowHeightProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.autoRowHeight.name, defaultValue: false);
});

/// Renders a text-based cell, switching between auto-grow (full wrap, no line
/// cap) and fixed-height (two lines + ellipsis) per [charaDetailAutoRowHeightProvider].
///
/// Every text column renderer uses this instead of a bare [Text] so the
/// row-height toggle is honored consistently; the row-height pass measures the
/// same text at the same width so a grown row exactly fits the wrapped lines.
class CellText extends ConsumerWidget {
  const CellText(this.data, {super.key, this.textAlign, this.style, this.opacity});

  final String data;
  final TextAlign? textAlign;
  final TextStyle? style;

  /// Dims the text (e.g. the memo placeholder) without a separate Opacity widget
  /// that would change the cell's measured height.
  final double? opacity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expand = ref.watch(charaDetailAutoRowHeightProvider);
    final text = Text(
      data,
      textAlign: textAlign,
      style: style,
      softWrap: true,
      maxLines: expand ? null : 2,
      overflow: expand ? null : TextOverflow.ellipsis,
    );
    return opacity == null ? text : Opacity(opacity: opacity!, child: text);
  }
}

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

  /// Whether this column is hidden from the grid. A hidden column contributes no
  /// visible column, yet still participates in row filtering and the pass-count
  /// badge — so it acts as an invisible filter. Defaults to false (shown); legacy
  /// specs saved before this field existed therefore decode as shown.
  bool get hidden;

  /// User-provided free-text note shown on the column chip's tooltip (above the
  /// filter condition). Null/empty means "no note". Defaults to null so specs that
  /// do not store one — and legacy specs saved before the field existed — decode
  /// as having none. Every editable concrete spec overrides this with a stored
  /// field and implements [withDescription]; the central tooltip composition reads
  /// it generically here.
  String? get description => null;

  /// User-pinned display width for this column in logical pixels, or null when the
  /// column auto-fits to its content. A non-null value makes [autoFitColumns] skip
  /// the column so the user's chosen width survives data and layout changes; null
  /// (the default, and what legacy specs saved before this field existed decode to)
  /// keeps the content-driven auto-fit. Every editable concrete spec overrides this
  /// with a stored field and implements [withWidth].
  double? get width => null;

  /// Returns a copy of this spec with its pinned [width] replaced (null clears it,
  /// reverting the column to auto-fit). Like [withHidden], every editable concrete
  /// spec must override this via copyWith; the base throws rather than silently
  /// no-op'ing so a spec that forgets to override fails loudly. The undecodable
  /// placeholder, which is never editable, overrides this back to a no-op.
  ColumnSpec withWidth(double? width) => throw UnsupportedError('Concrete specs must override withWidth');

  /// Whether this column renders wrapping text (and so can grow a row's height
  /// when narrowed). Columns that render a fixed-height widget or icon (character
  /// portrait, logic mark, rating stars, family-registration badge) override this
  /// to false so the auto row-height pass never inflates a row from their
  /// width-measurement placeholder text. Defaults to true.
  bool get wrapsText => true;

  /// Returns a copy of this spec with its [hidden] flag replaced. Every concrete,
  /// editable spec must override this via copyWith. Unlike [withChildren] (which
  /// leaf columns legitimately no-op on), the base throws rather than silently
  /// returning [this]: the toggle has exactly one caller (the visibility switch in
  /// the column dialog), so a subclass that forgets to override would otherwise
  /// fail silently with no compile error. The undecodable placeholder, which is
  /// never editable, overrides this back to a no-op.
  ColumnSpec withHidden(bool hidden) => throw UnsupportedError('Concrete specs must override withHidden');

  /// Returns a copy of this spec with its [description] replaced (null clears it).
  /// Like [withHidden], every editable concrete spec must override this via
  /// copyWith; the base throws rather than silently no-op'ing so a spec that
  /// forgets to override fails loudly instead of dropping the user's note. The
  /// undecodable placeholder, which is never editable, overrides this to a no-op.
  ColumnSpec withDescription(String? description) =>
      throw UnsupportedError('Concrete specs must override withDescription');

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

  // Read straight from the preserved raw map (and round-trips through toMap),
  // so a broken column keeps whatever hidden flag it was saved with. A broken
  // map may hold anything, so a non-bool 'hidden' degrades to false rather than
  // throwing a CastError that would collapse the whole grid via _buildGrid.
  @override
  bool get hidden {
    final value = rawMap["hidden"];
    return value is bool && value;
  }

  // A broken placeholder is not editable (its selector is a plain message with no
  // visibility switch), so the toggle is intentionally inert here rather than
  // throwing like the base. The raw map's hidden flag is preserved verbatim.
  @override
  ColumnSpec withHidden(bool hidden) => this;

  // Read the note straight from the preserved raw map so the central tooltip can
  // still surface it for a broken column; a non-String value degrades to null.
  @override
  String? get description {
    final value = rawMap["description"];
    return value is String ? value : null;
  }

  // Inert for the same reason as [withHidden]: a broken column is never edited.
  @override
  ColumnSpec withDescription(String? description) => this;

  // Inert like [withHidden]/[withDescription]: a broken column is never resized.
  // Its width getter inherits the base default (null), so it always auto-fits.
  @override
  ColumnSpec withWidth(double? width) => this;

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

  // Serialized field name of the per-spec hidden flag. Excluded from the
  // incompleteness check so legacy specs (saved before the field existed) are
  // not flagged broken merely for lacking it. Must match the dart_mappable
  // field name emitted by concrete specs.
  //
  // Note the per-spec `description` note needs no equivalent here: every spec
  // carrying it is annotated `ignoreNull: true`, so a null description is omitted
  // from the encoded map entirely (a legacy spec lacking the key and a freshly
  // encoded null-description spec therefore produce the same shape).
  static const _hiddenKey = 'hidden';

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
      // 'hidden' was added after specs already existed on disk; a missing key
      // decodes to the default (false), so its absence must not flag a spec as
      // broken. Excluded here (like _childrenKey) rather than in the generic
      // isSpecMapIncomplete, since this is the only spec-level entry point.
      if (entry.key == _hiddenKey) continue;
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

// Above this many rows to (re)insert, [reconcileRows] abandons the per-row diff
// and replaces the whole row set in one pass. Each incremental insertRows is O(n)
// in trina (it rescans the original list and rebuilds the filtered view), so a
// large diff (e.g. a filter/search change that swaps most rows) would otherwise
// be O(n^2); a wholesale removeAllRows + appendRows is O(n). Small edits stay
// incremental so scroll offset and row identity are preserved.
const _bulkReconcileThreshold = 32;

extension TrinaGridStateManagerExtension on TrinaGridStateManager {
  double _visualTextWidth(BuildContext context, String text, TextStyle style) {
    if (text.isEmpty) {
      return 0;
    }
    final textPainter = TextPainter(
      text: TextSpan(style: style, text: text),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return textPainter.width;
  }

  // Single-pass auto-fit: size the column to max(title, widest cell). Replaces the
  // built-in autoFitColumn (which measures the title precisely but estimates cells
  // by character count) plus a separate cell pass, so the rows are scanned once.
  // The title is measured the same way the built-in does (columnTextStyle + title
  // padding), while cells are measured by true rendered width over distinct values.
  void autoFitColumnPrecise(BuildContext context, TrinaColumn column) {
    if (refRows.isEmpty) {
      return;
    }
    final values = refRows.map((e) => column.formattedValueForDisplay(e.cells[column.field]?.value));
    final cellWidth = values
        .toSet()
        .map((value) => _visualTextWidth(context, value, DefaultTextStyle.of(context).style))
        .max;

    final cellPadding = column.cellPadding ?? configuration.style.defaultCellPadding;
    final titlePadding = column.titlePadding ?? configuration.style.defaultColumnTitlePadding;
    final titleWidth = _visualTextWidth(context, column.title, configuration.style.columnTextStyle);

    final cellTarget = cellWidth + cellPadding.horizontal + 8;
    // Mirrors the built-in's title term. The checkbox-column width (enableRowChecked)
    // is intentionally omitted since this grid has no checkbox columns; if one were
    // added the title could under-fit slightly, but a roomy title never clips.
    final titleTarget =
        titleWidth + titlePadding.horizontal + (column.isShowRightIcon ? configuration.style.iconSize : 0) + 8;

    resizeColumn(column, [cellTarget, titleTarget].max - column.width);
  }

  void autoFitColumns() {
    if (refRows.isEmpty) {
      return;
    }
    final context = gridKey.currentContext!;
    for (final col in columns) {
      // The checkbox column carries no text, so the text-based precise autofit
      // would shrink it below the checkbox's intrinsic width and clip it. Leave
      // its fixed width untouched.
      if (col.enableRowChecked) {
        continue;
      }
      // A column the user has pinned to an explicit width (spec.width != null) is
      // intentionally excluded so its chosen width survives data/layout changes.
      // Its width was applied at plutoColumn build time and must not be remeasured.
      if (col.getUserData<ColumnSpec>()?.width != null) {
        continue;
      }
      final enabled = col.enableDropToResize;
      col.enableDropToResize = true; // If this flag is false, col will ignore any resizing operations.
      // autoFitColumnPrecise sizes the column to max(title, widest cell) in one
      // row scan, so the header title is never clipped and the cell width is exact.
      autoFitColumnPrecise(context, col);
      if (maxWidth != null && col.width > maxWidth!) {
        resizeColumn(col, -(col.width / 2 - 24));
      }
      col.enableDropToResize = enabled;
    }
  }

  // Measures the rendered height of [text] wrapped to [maxWidth] in [style],
  // matching how [CellText] lays the same text out so a grown row fits exactly.
  double _wrappedTextHeight(BuildContext context, String text, TextStyle style, double maxWidth) {
    if (text.isEmpty || maxWidth <= 0) {
      return 0;
    }
    final textPainter = TextPainter(
      text: TextSpan(style: style, text: text),
      textDirection: ui.TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    return textPainter.height;
  }

  // The height a row needs to fully show its pinned columns' wrapped text, or null
  // when the fixed grid height already suffices. Only pinned ([width] != null),
  // text-rendering ([wrapsText]) columns can wrap — auto-fit columns are sized to
  // their widest cell, and widget/icon columns render at a fixed height — so the
  // scan is bounded to those.
  double? _expandedRowHeight(BuildContext context, TrinaRow row, TextStyle style, double base) {
    var maxHeight = base;
    for (final col in columns) {
      final spec = col.getUserData<ColumnSpec>();
      if (spec == null || spec.width == null || !spec.wrapsText) {
        continue;
      }
      final cellPadding = col.cellPadding ?? configuration.style.defaultCellPadding;
      final text = col.formattedValueForDisplay(row.cells[col.field]?.value);
      final height =
          _wrappedTextHeight(context, text, style, col.width - cellPadding.horizontal) + cellPadding.vertical;
      if (height > maxHeight) {
        maxHeight = height;
      }
    }
    // The 2px buffer absorbs sub-pixel rounding so the last wrapped line is never
    // clipped. null leaves the row at the grid default (no growth needed).
    return maxHeight > base ? maxHeight + 2 : null;
  }

  // Sets each row's height to fit wrapped text in pinned columns ([expand]), or
  // clears it back to the fixed grid height (!expand). trina's setRowHeight
  // rebuilds the row, dropping its attached record and notifying per row, so rows
  // are replaced here in one pass — carrying over cells, key, flags, and the
  // record user-data — and the caller notifies once. Returns whether anything
  // changed.
  bool applyAutoRowHeights({required bool expand}) {
    final context = gridKey.currentContext;
    if (context == null) {
      return false;
    }
    final style = DefaultTextStyle.of(context).style;
    final base = configuration.style.rowHeight;
    var changed = false;
    for (var i = 0; i < refRows.length; i++) {
      final row = refRows[i];
      final target = expand ? _expandedRowHeight(context, row, style, base) : null;
      if (row.height == target) {
        continue;
      }
      final record = row.getUserData<CharaDetailRecord>();
      final newRow =
          TrinaRow(
              cells: row.cells,
              type: row.type,
              sortIdx: row.sortIdx,
              data: row.data,
              checked: row.checked ?? false,
              key: row.key,
              frozen: row.frozen,
              height: target,
              metadata: row.metadata,
            )
            ..setParent(row.parent)
            ..setState(row.state);
      if (record != null) {
        newRow.setUserData(record);
      }
      refRows[i] = newRow;
      changed = true;
    }
    return changed;
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

  /// The record of the currently highlighted (current) row, or null when no row
  /// is selected. Captured before a reconcile so the highlight can be restored
  /// onto the same record afterwards via [restoreCurrentRecord].
  ///
  /// Resolved from [currentCell] (the actually-selected cell's own row), not from
  /// `currentRow` (== `refRows[currentRowIdx]`). With pinned (frozen) rows present
  /// a tap stores a *display* index in `currentRowIdx` (frozen rows render in a
  /// separate top block, shifting the scrollable rows' display indices) while
  /// `refRows` keeps its own order, so `refRows[currentRowIdx]` resolves to the
  /// wrong record. `currentCell.row` is always the tapped row — the same
  /// unambiguous path trina's own [currentColumn]/[currentColumnField] use.
  CharaDetailRecord? get currentRecord => currentCell?.row.getUserData<CharaDetailRecord>();

  /// The record id carried by [row], or null when the row has no record attached.
  String? recordIdOf(TrinaRow row) => row.getUserData<CharaDetailRecord>()?.id;

  /// Whether [row] is the currently highlighted row, matched by record id.
  ///
  /// Index comparison is unsafe here: with pinned (frozen) rows present a tap
  /// stores a *display* index in [currentRowIdx] (frozen rows render in a
  /// separate top block) while a reconcile recomputes it against refRows, so the
  /// two index spaces disagree. Matching [currentRecord] (resolved from the live
  /// [currentCell]) by id sidesteps both.
  bool isCurrentRecord(TrinaRow row) {
    final id = currentRecord?.id;
    return id != null && recordIdOf(row) == id;
  }

  /// Indexes [rows] by record id, skipping rows with no record (last id wins).
  Map<String, TrinaRow> _rowsById(Iterable<TrinaRow> rows) => {for (final row in rows) ?recordIdOf(row): row};

  /// Snapshots each row's current [TrinaRow.sortIdx] keyed by record id.
  ///
  /// Captured as plain ints *before* an insert/append mutates the rows in place,
  /// so the canonical order can be reapplied afterwards via [applyCanonicalSortIdx].
  Map<String, int> _sortIdxById(Iterable<TrinaRow> rows) => {for (final row in rows) ?recordIdOf(row): row.sortIdx};

  /// Re-selects the row for [record] so the row highlight survives a rebuild that
  /// dropped the current cell (e.g. a structural column change clears it). No-op
  /// when the record is already current or no longer present (filtered out).
  ///
  /// Prefers the cell in [preferField] (the column the user had selected) so the
  /// current cell stays in the same column; falls back to the first cell whose
  /// key is not [ignoreField] (e.g. the checkbox) when that column is gone.
  void restoreCurrentRecord(CharaDetailRecord? record, {String? preferField, String? ignoreField}) {
    if (record == null || currentRecord?.id == record.id) {
      return;
    }
    for (var rowIdx = 0; rowIdx < refRows.length; rowIdx++) {
      final row = refRows[rowIdx];
      if (recordIdOf(row) != record.id) {
        continue;
      }
      TrinaCell? cell;
      if (preferField != null && preferField != ignoreField) {
        cell = row.cells[preferField];
      }
      if (cell == null) {
        for (final entry in row.cells.entries) {
          if (entry.key != ignoreField) {
            cell = entry.value;
            break;
          }
        }
      }
      if (cell != null) {
        setCurrentCell(cell, rowIdx, notify: false);
      }
      return;
    }
  }

  /// Copies the renderer and title from each freshly built column onto the
  /// matching live column (by field), so columns whose renderer captured a
  /// provider snapshot (e.g. ratings) repaint with current data — and columns
  /// whose title is provider-derived (e.g. a renamed rating/label set, whose
  /// field is the stable spec id) show the new header — without a structural
  /// replace that would drop their width and sort indicator.
  ///
  /// Cell-driven columns (e.g. memo, which reads the cell's user data) are
  /// refreshed by [reconcileRows] replacing their row instead; copying their
  /// stateless renderer here is harmless.
  void refreshColumnRenderers(List<TrinaColumn> nextColumns) {
    final nextByField = {for (final column in nextColumns) column.field: column};
    for (final live in columns) {
      final next = nextByField[live.field];
      if (next != null) {
        live.renderer = next.renderer;
        live.title = next.title;
      }
    }
  }

  /// Whether two rows for the same record render identically: same pinned state
  /// and same value in every cell. Drives [reconcileRows]'s decision to leave a
  /// row untouched (preserving scroll and identity) or replace it.
  bool _rowContentEquals(TrinaRow a, TrinaRow b) {
    if (a.frozen != b.frozen || a.cells.length != b.cells.length) {
      return false;
    }
    for (final entry in b.cells.entries) {
      if (a.cells[entry.key]?.value != entry.value.value) {
        return false;
      }
    }
    return true;
  }

  /// Reapplies the canonical [TrinaRow.sortIdx] captured in [sortIdxById]
  /// (keyed by record id) onto the live rows.
  ///
  /// trina's insert/append paths overwrite a touched row's sortIdx with a
  /// neighbour-derived sequential value, so after incremental (or appendRows)
  /// updates the app-assigned default order (`-capturedDate`, set in
  /// `_buildGrid`) drifts. trina's "reset sort" (the third sort toggle) reorders
  /// by sortIdx, so without this the default order would come back wrong.
  ///
  /// The snapshot must be taken (via [_sortIdxById]) *before* the insert/append
  /// runs: trina mutates `row.sortIdx` in place, and an inserted row is the very
  /// fresh object, so reading sortIdx back off it afterwards would just echo the
  /// already-overwritten value.
  void applyCanonicalSortIdx(Map<String, int> sortIdxById) {
    for (final row in refRows.originalList) {
      final id = recordIdOf(row);
      final sortIdx = id == null ? null : sortIdxById[id];
      if (sortIdx != null) {
        row.sortIdx = sortIdx;
      }
    }
  }

  /// Replaces the whole live row set with [nextRows] in one O(n) pass, preserving
  /// the canonical sort order and keeping the current cell position in sync.
  ///
  /// Shared by [reconcileRows]'s bulk-diff fallback and the widget's structural
  /// column-change path. Snapshots the canonical sortIdx before append (see
  /// [applyCanonicalSortIdx]) so a later "reset sort" reproduces the default order.
  void replaceAllRows(List<TrinaRow> nextRows, {String? sortColumn, TrinaColumnSort sortOrder = TrinaColumnSort.none}) {
    final sortIdxById = _sortIdxById(nextRows);
    removeAllRows(notify: false);
    appendRows(nextRows);
    applyCanonicalSortIdx(sortIdxById);
    if (sortColumn != null) {
      sortColumnByField(sortColumn, sortOrder);
    }
    updateCurrentCellPosition(notify: false);
  }

  /// Applies [nextRows] to the live grid by record id, touching only the rows
  /// that actually changed.
  ///
  /// Rows whose record vanished or whose content/pinned state changed are
  /// removed and the fresh row is reinserted at its position in [nextRows];
  /// unchanged rows keep their identity so the scroll offset and current cell
  /// survive a single cell edit. Assumes the column set is unchanged (the caller
  /// handles structural column changes with a full rebuild).
  ///
  /// When the diff is large (more than [_bulkReconcileThreshold] rows to
  /// reinsert) the per-row insert would be O(n^2), so it falls back to a
  /// wholesale replace: cheaper, at the cost of resetting scroll and selection
  /// (the caller restores the selection by record afterwards).
  ///
  /// Returns whether any row was actually added, removed, or replaced, so the
  /// caller can skip a column re-fit on a selection/sort-only reconcile.
  bool reconcileRows(
    List<TrinaRow> nextRows, {
    String? sortColumn,
    TrinaColumnSort sortOrder = TrinaColumnSort.none,
    bool notify = true,
  }) {
    // The incremental insert below uses indices into nextRows (the desired,
    // unfiltered order). trina's insertRows interprets its index against the
    // filtered refRows view, so the two only coincide while no trina-level
    // column filter is active. The app filters upstream (in _buildGrid) and
    // never enables trina's own filter, keeping refRows == originalList.
    assert(
      refRows.length == refRows.originalList.length,
      'reconcileRows assumes no active trina-level filter (refRows == originalList).',
    );

    final nextById = _rowsById(nextRows);

    // Rows to keep as-is. Everything else (gone, changed, or pinned-state
    // changed) is removed below and reinserted fresh from nextRows.
    final unchangedIds = <String>{};
    final toRemove = <TrinaRow>[];
    for (final row in refRows.originalList) {
      final id = recordIdOf(row);
      final next = id == null ? null : nextById[id];
      if (next != null && _rowContentEquals(row, next)) {
        unchangedIds.add(id!);
      } else {
        toRemove.add(row);
      }
    }

    final insertCount = nextRows.length - unchangedIds.length;
    final changed = toRemove.isNotEmpty || insertCount > 0;
    if (insertCount > _bulkReconcileThreshold) {
      // Large diff: the incremental path buys nothing (most rows are reinserted)
      // yet pays O(n^2). Replace the whole row set in one O(n) pass instead.
      // replaceAllRows snapshots/restores the canonical sortIdx and syncs the
      // current cell position itself.
      replaceAllRows(nextRows, sortColumn: sortColumn, sortOrder: sortOrder);
    } else {
      // Snapshot the canonical sortIdx as plain ints before any insert mutates
      // the rows in place; an inserted row is the fresh object itself, so reading
      // its sortIdx back afterwards would echo the overwritten value.
      final sortIdxById = _sortIdxById(nextRows);
      if (toRemove.isNotEmpty) {
        removeRows(toRemove, notify: false);
      }
      // Reinsert added/changed rows at their slot in the desired order.
      // Processing ascending keeps each index valid: unchanged rows already sit
      // at their final position once all earlier inserts have landed.
      for (var position = 0; position < nextRows.length; position++) {
        final row = nextRows[position];
        final id = recordIdOf(row);
        if (id == null || !unchangedIds.contains(id)) {
          insertRows(position, [row], notify: false);
        }
      }
      // insert overwrote the canonical sortIdx of the touched rows; restore it
      // from the pre-insert snapshot so a later "reset sort" reproduces the
      // default order.
      applyCanonicalSortIdx(sortIdxById);

      if (sortColumn != null) {
        sortColumnByField(sortColumn, sortOrder);
      }
      // removeRows/insertRows keep the current cell position in sync, but
      // sortColumnByField reorders refRows without touching it — leaving the row
      // highlight (driven by currentRowIdx) stranded on a stale index (often the
      // top row). Recompute the position from the still-correct current cell so
      // the highlight stays on the selected record.
      updateCurrentCellPosition(notify: false);
    }

    if (notify) {
      notifyListeners();
    }
    return changed;
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
