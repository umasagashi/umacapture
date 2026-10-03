import 'dart:convert';
import 'dart:math';
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
import '/src/core/json_adapter.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

part 'base.mapper.dart';

// ignore: constant_identifier_names
const tr_common = "pages.chara_detail.column_predicate.common";

// ignore: constant_identifier_names
const tr_columns = "pages.chara_detail.columns";

/// What a column is for: the add-column dialog shows it as the tooltip of the chip that creates the column, and the
/// column dialog heads the column with it. [truthTable], when present, is shown beneath [text]; its first row is the
/// header and the remaining rows are the cells.
typedef ColumnDescription = ({String text, List<List<String>>? truthTable});

typedef LabelMap = Map<String, List<String>>;
typedef OnSpecChanged = void Function(ColumnSpec);

/// Builds the cell of one row's value. [ColumnSpec.cellBuilder] makes it once per column per grid build; it holds
/// the data the cells need, never a ref.
///
/// A class rather than a function type: the grid build holds its columns as `ColumnSpec<dynamic>`, and a function
/// taking `T` does not pass as one taking `dynamic`, while a method's `T` parameter is checked per call.
final class CellBuilder<T> {
  final TrinaCell Function(T value) _build;

  const CellBuilder(this._build);

  TrinaCell call(T value) => _build(value);
}

/// How table rows size themselves to their text. A global display preference,
/// persisted in settings and watched by [CellText] and the row-height pass.
///
/// - [wrap]: every row is fixed at the minimum height; text wraps up to the
///   minimum line count and then ellipsizes (the former "auto off" behavior,
///   now with a configurable line count).
/// - [autoPerRow]: each row grows to fit its own wrapped text, floored at the
///   minimum height (the former "auto on" behavior, now with a floor).
/// - [autoUniform]: every row takes the height of the tallest row's wrapped
///   text, floored at the minimum height, so the grid stays visually even.
@MappableEnum(caseStyle: CaseStyle.snakeCase)
enum RowHeightMode { wrap, autoPerRow, autoUniform }

/// The current row-height mode, persisted across launches. Migrates the legacy
/// boolean [SettingsEntryKey.autoRowHeight] on first read: a user who had
/// auto-grow on lands on [RowHeightMode.autoPerRow], everyone else on the
/// default [RowHeightMode.wrap].
final charaDetailRowHeightModeProvider = ExclusiveItemsNotifierProvider<RowHeightMode>(() {
  return _RowHeightModeNotifier();
});

class _RowHeightModeNotifier extends ExclusiveItemsNotifier<RowHeightMode> {
  _RowHeightModeNotifier()
    : super(
        entryKey: SettingsEntryKey.rowHeightMode.name,
        values: RowHeightMode.values,
        defaultValue: RowHeightMode.wrap,
      );

  @override
  RowHeightMode build() {
    final stored = super.build();
    final box = ref.read(storageBoxProvider);
    if (box.pull<RowHeightMode>(SettingsEntryKey.rowHeightMode.name) != null) {
      return stored;
    }
    // No new-style value yet: honor the retired auto-row-height toggle once.
    final legacy = box.pull<bool>(SettingsEntryKey.autoRowHeight.name);
    return legacy == true ? RowHeightMode.autoPerRow : stored;
  }
}

/// The minimum row height in text lines (default two). Acts as the fixed height
/// in [RowHeightMode.wrap] and as the floor in the auto modes.
final charaDetailMinRowLinesProvider = IntNotifierProvider(() {
  return IntNotifier(entryKey: SettingsEntryKey.minRowLines.name, defaultValue: 2, min: 1, max: 20);
});

/// Whether the table draws its row borders in a stronger colour (default off).
/// Only the colour changes; the border width stays the same.
final charaDetailStrongRowBordersProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.strongRowBorders.name, defaultValue: false);
});

/// The range the table settings offer for the default width of a skill or factor column, in logical pixels: from
/// trina's minimum column width to the bound a pinned width is sanitised to.
const itemColumnDefaultWidthMin = 80;
const itemColumnDefaultWidthMax = 2000;

/// The range the table settings offer for the two bounds given as a percentage of the table's visible size.
const itemBoundPercentMin = 10;
const itemBoundPercentMax = 200;

/// The width a skill or factor column auto-fits to at most, in logical pixels (default 300). A column the user has
/// sized by dragging keeps its width.
final charaDetailItemColumnDefaultWidthProvider = IntNotifierProvider(() {
  return IntNotifier(
    entryKey: SettingsEntryKey.itemColumnDefaultWidth.name,
    defaultValue: 300,
    min: itemColumnDefaultWidthMin,
    max: itemColumnDefaultWidthMax,
  );
});

/// The widest a skill or factor column becomes, by auto-fit or by dragging, as a percentage of the table's visible
/// width (default 50).
final charaDetailItemColumnMaxWidthPercentProvider = IntNotifierProvider(() {
  return IntNotifier(
    entryKey: SettingsEntryKey.itemColumnMaxWidthPercent.name,
    defaultValue: 50,
    min: itemBoundPercentMin,
    max: itemBoundPercentMax,
  );
});

/// The tallest a skill or factor cell lays its items out, as a percentage of the table's visible height (default
/// 50). Items past it are left to the omission counter, in every row-height mode.
final charaDetailItemCellMaxHeightPercentProvider = IntNotifierProvider(() {
  return IntNotifier(
    entryKey: SettingsEntryKey.itemCellMaxHeightPercent.name,
    defaultValue: 50,
    min: itemBoundPercentMin,
    max: itemBoundPercentMax,
  );
});

/// Renders a text-based cell, capping the line count only in
/// [RowHeightMode.wrap] (minimum lines + ellipsis) and otherwise wrapping
/// freely so the row-height pass can grow the row to fit.
///
/// Every text column renderer uses this instead of a bare [Text] so the
/// row-height mode is honored consistently; the row-height pass measures the
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
    final clamp = ref.watch(charaDetailRowHeightModeProvider) == RowHeightMode.wrap;
    final minLines = ref.watch(charaDetailMinRowLinesProvider);
    final text = Text(
      data,
      textAlign: textAlign,
      style: style,
      softWrap: true,
      maxLines: clamp ? minLines : null,
      overflow: clamp ? TextOverflow.ellipsis : null,
    );
    return opacity == null ? text : Opacity(opacity: opacity!, child: text);
  }
}

enum ColumnCategory { trainee, status, aptitude, skill, factor, campaign, metadata, script, logic }

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

  /// Stable identifier for a builder that produces a non-default filter, stamped
  /// onto the spec it builds so the column can later regenerate its default filter
  /// by re-running this builder (see `builderSpecOf`). Null for plain builders
  /// whose default is "accept every row"; filter-bearing builders override it with
  /// a stored value. The column dialog also finds this builder's [description]
  /// through it (see `columnDescriptionOf`).
  String? get builderId => null;

  /// What a column of the type [build] creates is for, decided only from data that column stores and never edits
  /// (its parser, whether it selects by tag, its operator). [ColumnSpec.typeDescription] of the built column is the
  /// same, because both are computed by one function from the same values.
  ColumnDescription get typeDescription;

  /// The sentence of a chip whose column says more than its type does (a preset filter, such as "rank B or lower").
  /// It counts only alongside a [builderId]: the column records that id, and the id is the only way its column
  /// dialog finds this sentence again.
  String? get presetDescription => null;

  /// What the column this builder creates is for: the chip's tooltip in the add-column dialog, and the heading of
  /// the column dialog of every column it creates (`columnDescriptionOf`). It is [presetDescription] when this builder
  /// has a [builderId] and one, else [typeDescription]. Overridden only by a builder whose chip creates storage as well
  /// as a column, so that chip states the creation while the created column keeps [typeDescription].
  ColumnDescription get description {
    final preset = builderId == null ? null : presetDescription;
    return preset == null ? typeDescription : (text: preset, truthTable: null);
  }

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

@MappableClass(caseStyle: CaseStyle.snakeCase)
class RaceTitleInfo with RaceTitleInfoMappable {
  final int sid;
  final int sortKey;
  final List<String> names;
  final List<String> descriptions;
  final Set<String> tags;

  RaceTitleInfo(this.sid, this.sortKey, this.names, this.descriptions, this.tags);

  String get label => names.isEmpty ? "" : names.first;

  String get tooltip => names.isEmpty ? "" : names.first;
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

/// Upper bound for a pinned column width. Generous on purpose: it only guards
/// against corrupted/absurd persisted values, not legitimately wide columns.
const _maxPinnedColumnWidth = 2000.0;

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
  /// visible column, yet a column that filters rows (see [ColumnSpec.filtersRows]) still participates
  /// in row filtering and the pass-count badge — so it acts as an invisible
  /// filter. Defaults to false (shown); legacy
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
  /// column auto-fits to its content. A non-null value makes [autoFitColumns] leave
  /// the column unmeasured, shown at this width — held within the table's maximum
  /// column width for a skill or factor column ([ItemColumnBounds.maxWidth]), with
  /// this value left as stored — so the user's chosen width survives data and
  /// layout changes; null
  /// (the default, and what legacy specs saved before this field existed decode to)
  /// keeps the content-driven auto-fit. Every editable concrete spec overrides this
  /// with a stored field and implements [withWidth].
  double? get width => null;

  /// The pinned [width] sanitized for rendering, or null when unpinned. trina
  /// only enforces [TrinaGridSettings.minColumnWidth] during interactive resize,
  /// not at column construction, so a corrupted or hand-edited persisted value
  /// (negative, zero, NaN, infinity, or absurdly large) would otherwise render a
  /// broken layout. A non-finite value falls back to the default width.
  double? get clampedWidth {
    final value = width;
    if (value == null) {
      return null;
    }
    if (!value.isFinite) {
      return TrinaGridSettings.columnWidth;
    }
    return value.clamp(TrinaGridSettings.minColumnWidth, _maxPinnedColumnWidth);
  }

  /// Returns a copy of this spec with its pinned [width] replaced (null clears it,
  /// reverting the column to auto-fit). Like [withHidden], every editable concrete
  /// spec must override this via copyWith; the base throws rather than silently
  /// no-op'ing so a spec that forgets to override fails loudly. The undecodable
  /// placeholder, which is never editable, overrides this back to a no-op.
  ColumnSpec withWidth(double? width) => throw UnsupportedError('Concrete specs must override withWidth');

  /// Whether this column renders wrapping content (text or item boxes, and so can grow a
  /// row's height when narrowed). Columns that render a fixed-height widget or icon (character
  /// portrait, logic mark, rating stars, family-registration badge) override this
  /// to false so the auto row-height pass never inflates a row from their
  /// width-measurement placeholder text. Defaults to true.
  bool get wrapsText => true;

  /// Whether the table's bounds on skill and factor columns ([ItemColumnBounds]) apply to this column: its auto-fit
  /// width, its dragged width and the height its cells lay items out in.
  bool get takesItemColumnBounds => false;

  /// The text the cell actually paints, which [measuredContent] measures by default.
  /// Defaults to the trina-formatted cell value; specs whose renderer
  /// substitutes text (e.g. memo's null placeholder, the family-registration
  /// all-slots label) override this so the measured size matches what is shown.
  String measuredText(TrinaCell? cell, String formatted) => formatted;

  /// What the cell actually lays out, which the row-height pass and the
  /// column-width auto-fit measure. Defaults to [measuredText] as wrapping text;
  /// a spec whose cell lays out something other than one wrapping string (the
  /// item boxes of a skill or factor cell) overrides this so the measured size
  /// matches what is shown.
  MeasuredContent measuredContent(TrinaCell? cell, String formatted) =>
      TextMeasuredContent(measuredText(cell, formatted));

  /// The height of [lines] lines of this column's content in [cell], cell padding excluded: what the row-height
  /// floor keeps visible of this column in the cell's row. Defaults to [lines] lines of text; a spec whose cell
  /// lays out something taller than a text line per line (the item boxes of a skill or factor cell) overrides
  /// this, reading what [cell] draws the same way [measuredContent] does.
  double minContentHeight(int lines, CellMeasurement m, {TrinaCell? cell}) => m.preferredLineHeight * lines;

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

  /// Whether this column carries a resettable row filter (predicate). Filtering
  /// leaf columns override this to true so the column dialog offers a "reset
  /// filter" button; containers (logic) and non-filtering columns leave it false
  /// and the button stays hidden. Pairs with [withFilterReset].
  bool get hasFilter => false;

  /// Identifier of the column builder (the "add column" template) this column was
  /// created from, or null when it carries no such origin (a plain column, or one
  /// added before this field existed). Used by the dialog to regenerate the
  /// column's default filter on reset (see `builderSpecOf` in builder.dart), and to
  /// head the dialog with that builder's description (see `columnDescriptionOf`).
  /// Builder-default-capable leaf specs override this with a stored field;
  /// everything else has none.
  String? get builderId => null;

  /// What a column of this type is for, decided only from data this column stores and never edits. The builder that
  /// creates it computes its [ColumnBuilder.typeDescription] with the same function from the same values, so a
  /// column whose [builderId] finds no builder is still described the way its chip is, unless that chip has a
  /// [ColumnBuilder.presetDescription].
  ColumnDescription get typeDescription;

  /// Returns a copy of this spec with its filter (predicate) reset to its default,
  /// preserving the display settings (title, width, hidden, description).
  ///
  /// [defaultSpec] is the freshly rebuilt spec for this column's [builderId]
  /// (resolved by the caller via builder.dart's `builderSpecOf`), or null when the
  /// column has no builder origin — in which case the default is "accept every
  /// row". Filtering leaf columns override this and adopt `defaultSpec`'s predicate
  /// when it is the same spec type, else fall back to accept-all. Unlike
  /// [withHidden] the base default is a no-op (not a throw) so containers, the
  /// script column, and the undecodable placeholder — none of which expose a
  /// resettable filter — are safe to call unconditionally. The dialog only surfaces
  /// the reset action when [hasFilter].
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => this;

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

  /// Whether this column's [evaluate] decides which rows are listed. A column that does not filter neither hides a
  /// row nor carries a pass count, and no container accepts it as a child: a container combines its children's row
  /// conditions, and this column has none to give. Unrelated to [hasFilter], which only offers the dialog's reset.
  bool get filtersRows => true;

  /// Whether [child] may be inserted among this column's children now. Only a container with room for another
  /// child accepts one, and only a [child] that [filtersRows].
  bool acceptsChild(ColumnSpec child) => false;

  List<T> parse(RefBase ref, List<CharaDetailRecord> records);

  List<bool> evaluate(RefBase ref, List<T> values);

  /// Reads through [ref], once, what this column's cells depend on, and returns the builder of its cells. The grid
  /// build calls it once per visible column, so a watch here is one dependency of the grid whatever the row count.
  CellBuilder<T> cellBuilder(RefBase ref);

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
  /// (a pass/fail cell), in place of a leaf column's parsed-value [cellBuilder].
  TrinaCell conditionCell(bool passed);
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

// Serialized discriminator values of the two specs whose notation carries the
// legacy `max == 0` overload. Must match the dart_mappable discriminator (the
// class name, see ColumnSpec's `discriminatorKey: 'type'`); string literals
// because base.dart cannot import factor.dart/skill.dart (they import it).
const _factorSpecType = 'FactorColumnSpec';
const _skillSpecType = 'SkillColumnSpec';

// Serialized name of the unmet-rows choice ([UnmetRows]).
const _unmetRowsKey = 'unmetRows';

// Legacy factor notation `mode` values mapped to their current replacements, as
// `[withName, valueOnly]` — the second is used when the legacy `max` was 0 (the
// old "value only, no name" switch). See [_upgradeLegacyFactorNotation].
const _legacyFactorNotationModes = <String, List<String>>{
  'sumOnly': ['nameStarTotal', 'starTotal'],
  'traineeAndParents': ['nameStarTotal', 'starTotal'],
  'each': ['nameStarEach', 'starEach'],
};

// Rewrites a legacy factor `notation` sub-map to the current format, in place.
// A legacy factor map carries a `mode` that is no longer a valid enum value (so
// it would fail to decode). Idempotent: a map already in the current format —
// or with a missing/unknown `mode`, which is left to decode into a broken
// placeholder — is untouched. A legacy `max == 0` marks the value-only form, which
// the `mode` now states.
void _upgradeLegacyFactorNotation(Map<String, dynamic> notation) {
  final mapping = _legacyFactorNotationModes[notation['mode']];
  if (mapping == null) {
    return;
  }
  notation['mode'] = notation['max'] == 0 ? mapping[1] : mapping[0];
}

// Rewrites a legacy skill `notation` sub-map to the current format, in place.
// A legacy skill map has no `mode` at all (so it would be flagged broken for
// the missing key). A legacy `max == 0` marks the count form, which the `mode`
// now states. Idempotent: a map that already carries a `mode` is untouched.
void _upgradeLegacySkillNotation(Map<String, dynamic> notation) {
  if (notation.containsKey('mode')) {
    return;
  }
  notation['mode'] = notation['max'] == 0 ? 'count' : 'names';
}

// Upgrades legacy notation payloads throughout a stored spec map, recursing into
// nested container children. Runs on the raw JSON before decode so the healed
// map both decodes cleanly and matches the freshly encoded spec (avoiding a
// spurious broken flag), and is then re-persisted in the current format.
//
// Gated by the spec's `type` discriminator: only factor and skill specs ever
// carried the legacy notation shape, and a future spec type with its own
// `notation` map must not be silently mutated on load.
// A stored display count (`max` in a notation) counted items; nothing reads it,
// and the next save drops it.
void migrateLegacyColumnSpecMap(Map<String, dynamic> specMap) {
  final type = specMap['type'];
  if (type == _factorSpecType || type == _skillSpecType) {
    final predicate = specMap['predicate'];
    if (predicate is Map<String, dynamic>) {
      final notation = predicate['notation'];
      if (notation is Map<String, dynamic>) {
        if (type == _factorSpecType) {
          _upgradeLegacyFactorNotation(notation);
        } else {
          _upgradeLegacySkillNotation(notation);
        }
      }
    }
  }
  final children = specMap['children'];
  if (children is List) {
    for (final child in children) {
      if (child is Map<String, dynamic>) {
        migrateLegacyColumnSpecMap(child);
      }
    }
  }
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
  CellBuilder<Null> cellBuilder(RefBase ref) => CellBuilder((_) => TrinaCell(value: ""));

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

  // The column dialog heads every column with its description, so the explanation of a broken column is all the
  // dialog shows: there is nothing to edit.
  @override
  ColumnDescription get typeDescription => (text: "$tr_broken.description".tr(), truthTable: null);

  @override
  Widget selector(ChangeNotifier onDecided) => const SizedBox.shrink();

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

  // Serialized field name of the skill/factor "select by tag" flag. Like
  // [_hiddenKey], it is a non-null bool (default false) added after specs already
  // existed on disk, so it is always emitted yet absent from legacy maps. Excluded
  // from the incompleteness check so those legacy specs are not flagged broken
  // merely for lacking it.
  static const _selectByTagKey = 'selectByTag';

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
      // Heal pre-content-mode notation payloads in place so they decode cleanly,
      // are not flagged broken for legacy shape, and re-persist in current form.
      migrateLegacyColumnSpecMap(map);
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
      // 'selectByTag' was likewise added after specs existed on disk; its absence
      // decodes to the default (false) and must not flag a spec as broken.
      if (entry.key == _selectByTagKey) continue;
      // The skill/factor unmet-rows choice likewise decodes to its default
      // (filter out) when absent.
      if (entry.key == _unmetRowsKey) continue;
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
    // Reject illegal targets (a full NOT, a non-container, or a container that refuses this column) so the model
    // never builds a tree the UI's slot suppression would have forbidden. Evaluated against the detached tree, so
    // reordering a container's sole child within it (the container is momentarily empty) still passes.
    if (parentId != null) {
      final parent = findInForest(detached, parentId);
      if (parent == null || !parent.acceptsChild(removed)) {
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
// incremental: the rows left unchanged keep their identity.
const _bulkReconcileThreshold = 32;

/// What one measuring pass (the row-height pass, the column-width auto-fit) lays
/// cell content out with: a text style and the pass's text scaler. It owns a
/// painter [TextMeasuredContent] reuses across the pass and a memo that lives as
/// long as the pass; [dispose] it when the pass ends.
class CellMeasurement {
  CellMeasurement({required this.style, required this.textScaler});

  final TextStyle style;
  final TextScaler textScaler;

  TextPainter? _painter;
  double? _preferredLineHeight;
  final _memo = <Object, Object>{};
  final _disposers = <void Function()>[];

  /// The painter text content lays out with. Only [TextMeasuredContent] uses it:
  /// content that sets other painter properties (such as `maxLines`) keeps a
  /// painter of its own, since those properties would carry over to the text
  /// measured after it.
  TextPainter get painter => _painter ??= TextPainter(textDirection: ui.TextDirection.ltr, textScaler: textScaler);

  /// The height of one line of text in [style] under [textScaler].
  double get preferredLineHeight => _preferredLineHeight ??= _measurePreferredLineHeight();

  double _measurePreferredLineHeight() {
    final painter = TextPainter(
      text: TextSpan(style: style, text: 'X'),
      textDirection: ui.TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final height = painter.preferredLineHeight;
    painter.dispose();
    return height;
  }

  /// The object stored under [key] for this pass, made by [create] on first use.
  /// [dispose], when given, runs on it when the pass ends.
  T memo<T extends Object>(Object key, T Function() create, {void Function(T)? dispose}) {
    final existing = _memo[key];
    if (existing != null) {
      return existing as T;
    }
    final value = create();
    _memo[key] = value;
    if (dispose != null) {
      _disposers.add(() => dispose(value));
    }
    return value;
  }

  void dispose() {
    _painter?.dispose();
    for (final dispose in _disposers) {
      dispose();
    }
  }
}

/// The bounds the table settings put on skill and factor columns, resolved against the size of the table's visible
/// area: [defaultWidth] and [maxWidth] bound the width of such a column, [maxCellHeight] the height its cells lay
/// their items out in. A cell drawn outside a table (the theme gallery) gets [unbounded].
@immutable
class ItemColumnBounds {
  const ItemColumnBounds({required this.defaultWidth, required this.maxWidth, required this.maxCellHeight});

  static const unbounded = ItemColumnBounds(
    defaultWidth: double.infinity,
    maxWidth: double.infinity,
    maxCellHeight: double.infinity,
  );

  /// The bounds of a table whose visible area is [tableSize], from the settings; [unbounded] when the area is not
  /// finite. Whole pixels, so a resize that moves the area by a fraction of a pixel does not count as a change; the
  /// maximum column width never goes below trina's minimum column width, which a drag cannot go below either.
  factory ItemColumnBounds.resolve(
    Size tableSize, {
    required int defaultWidth,
    required int maxWidthPercent,
    required int maxCellHeightPercent,
  }) {
    if (!tableSize.isFinite) {
      return unbounded;
    }
    return ItemColumnBounds(
      defaultWidth: defaultWidth.toDouble(),
      maxWidth: max(_trinaMinColumnWidth, (tableSize.width * maxWidthPercent / 100).floorToDouble()),
      maxCellHeight: (tableSize.height * maxCellHeightPercent / 100).floorToDouble(),
    );
  }

  /// `TrinaGridSettings.minColumnWidth`, the narrowest trina lets a column be.
  static const _trinaMinColumnWidth = 80.0;

  /// The default width setting: the widest auto-fit makes such a column, unless [maxWidth] is narrower.
  final double defaultWidth;

  /// The maximum column width: the widest such a column becomes, by auto-fit, by dragging, or shown at a width
  /// the user chose.
  final double maxWidth;

  /// The cell height cap: the tallest such a cell lays its items out; items past it are left to the omission
  /// counter.
  final double maxCellHeight;

  /// The widest auto-fit makes such a column: the narrower of [defaultWidth] and [maxWidth].
  double get autoFitWidth => min(defaultWidth, maxWidth);

  @override
  bool operator ==(Object other) =>
      other is ItemColumnBounds &&
      other.defaultWidth == defaultWidth &&
      other.maxWidth == maxWidth &&
      other.maxCellHeight == maxCellHeight;

  @override
  int get hashCode => Object.hash(defaultWidth, maxWidth, maxCellHeight);

  @override
  String toString() =>
      'ItemColumnBounds(defaultWidth: $defaultWidth, maxWidth: $maxWidth, maxCellHeight: $maxCellHeight)';
}

/// Hands the table's [ItemColumnBounds] to the item cells drawn under it; a cell outside any scope is unbounded. The
/// table passes the same value its auto-fit and row-height passes measure with, so a cell draws under the cap it
/// was measured with.
class ItemColumnBoundsScope extends InheritedWidget {
  const ItemColumnBoundsScope({super.key, required this.bounds, required super.child});

  final ItemColumnBounds bounds;

  static ItemColumnBounds of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ItemColumnBoundsScope>()?.bounds ?? ItemColumnBounds.unbounded;

  @override
  bool updateShouldNotify(ItemColumnBoundsScope oldWidget) => bounds != oldWidget.bounds;
}

/// Hands the table's theme to the item cells drawn under it. The table keeps one instance per theme value, so a cell
/// tells an unchanged theme by identity; [Theme.of] can return a new, equal instance on any rebuild. A cell outside
/// any scope draws with [Theme.of].
class ItemCellThemeScope extends InheritedWidget {
  const ItemCellThemeScope({super.key, required this.theme, required super.child});

  final ThemeData theme;

  static ThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ItemCellThemeScope>()?.theme ?? Theme.of(context);

  @override
  bool updateShouldNotify(ItemCellThemeScope oldWidget) => !identical(theme, oldWidget.theme);
}

/// What a cell lays out, compared by value so a pass measures equal contents once.
@immutable
abstract class MeasuredContent {
  const MeasuredContent();

  /// The size the content takes laid out within [maxWidth]; on one line when [maxWidth] is infinite. Content that
  /// can leave part of itself out to fit (item boxes, which then show the omission counter) also keeps within
  /// [maxHeight]; text cannot, and ignores it.
  Size measure(CellMeasurement m, {double maxWidth = double.infinity, double maxHeight = double.infinity});
}

/// A string in the pass's text style, wrapped at the width it is given: the
/// content of every text column.
class TextMeasuredContent extends MeasuredContent {
  const TextMeasuredContent(this.text);

  final String text;

  @override
  Size measure(CellMeasurement m, {double maxWidth = double.infinity, double maxHeight = double.infinity}) {
    if (text.isEmpty || maxWidth <= 0) {
      return Size.zero;
    }
    m.painter
      ..text = TextSpan(style: m.style, text: text)
      ..layout(maxWidth: maxWidth);
    return m.painter.size;
  }

  @override
  bool operator ==(Object other) => other is TextMeasuredContent && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'TextMeasuredContent($text)';
}

// A wrapping ([ColumnSpec.wrapsText]) column paired with its per-pass layout:
// the content max-width its content wraps within, the height it lays its content
// out in at most (the table's cell height cap for a skill or factor column), and
// the vertical cell padding added to the wrapped height. Constant across rows
// within one row-height pass.
typedef _WrapColumn = ({TrinaColumn col, ColumnSpec spec, double maxWidth, double maxHeight, double verticalPadding});

// Measures wrapped row heights for one [applyRowHeights] pass. Built once from
// the wrapping columns' fixed layout so the per-row scan does no repeated
// column-metadata lookups, and measures every cell through one
// [CellMeasurement], so a single painter serves every text cell instead of one
// per measurement. Call [dispose] when the pass ends.
class _RowHeightMeasurer {
  _RowHeightMeasurer({required this._columns, required TextStyle style, required TextScaler textScaler})
    : _measurement = CellMeasurement(style: style, textScaler: textScaler);

  final List<_WrapColumn> _columns;
  final CellMeasurement _measurement;

  // The rendered height of [row]'s wrapped content ([ColumnSpec.measuredContent])
  // across its wrapping columns, or 0 when none wrap. Content wider than its
  // column wraps and grows the row, a skill or factor cell up to the table's cell
  // height cap; content that fits stays one line.
  double contentHeight(TrinaRow row) {
    var maxHeight = 0.0;
    for (final column in _columns) {
      final cell = row.cells[column.col.field];
      final content = column.spec.measuredContent(cell, column.col.formattedValueForDisplay(cell?.value));
      final height =
          content.measure(_measurement, maxWidth: column.maxWidth, maxHeight: column.maxHeight).height +
          column.verticalPadding;
      if (height > maxHeight) {
        maxHeight = height;
      }
    }
    // The 2px buffer absorbs sub-pixel rounding so the last wrapped line is never clipped.
    return maxHeight > 0 ? maxHeight + 2 : 0;
  }

  void dispose() => _measurement.dispose();
}

// Parsed [Metadata.capturedDate] per record, filled lazily. The tiebreak
// comparator below runs O(N log N) times per sort, so parsing the date string
// inside it would repeat the work (and, for a malformed date, the error log)
// on every comparison; record objects are stable across sorts, so one parse per
// record suffices. Comparing the raw strings instead is not an option: the
// native side formats them with a timezone offset (`%FT%T%z`), which breaks
// lexicographic order across differing offsets.
final _capturedDateTimeCache = Expando<DateTime>();

DateTime? _capturedDateTimeOf(TrinaRow row) {
  final record = row.getUserData<CharaDetailRecord>();
  if (record == null) {
    return null;
  }
  return _capturedDateTimeCache[record] ??= record.metadata.capturedDate.toDateTime();
}

extension TrinaGridStateManagerExtension on TrinaGridStateManager {
  // Single-pass auto-fit: size the column to max(title, widest cell). Replaces the
  // built-in autoFitColumn (which measures the title precisely but estimates cells
  // by character count) plus a separate cell pass, so the rows are scanned once.
  // The title is measured the same way the built-in does (columnTextStyle + title
  // padding), while cells are measured by true rendered width over distinct values.
  // A column that takes the table's bounds on skill and factor columns
  // ([ColumnSpec.takesItemColumnBounds]) is bounded by [ItemColumnBounds.autoFitWidth]:
  // its cells are measured wrapped within that width and within the cell height cap,
  // as they are drawn, and its title is clipped at it too.
  void autoFitColumnPrecise(BuildContext context, TrinaColumn column, ItemColumnBounds bounds) {
    if (refRows.isEmpty) {
      return;
    }
    final spec = column.getUserData<ColumnSpec>();
    final itemBounds = spec?.takesItemColumnBounds == true ? bounds : null;
    final cap = itemBounds?.autoFitWidth ?? double.infinity;
    final maxContentHeight = itemBounds?.maxCellHeight ?? double.infinity;
    final cellPadding = column.cellPadding ?? configuration.style.defaultCellPadding;
    final contents = refRows.map((e) {
      final cell = e.cells[column.field];
      final formatted = column.formattedValueForDisplay(cell?.value);
      // Measure what the cell actually paints, not just the raw value: e.g. the
      // family-registration cell renders all six slot labels even though its
      // value lists only the registered subset.
      return spec?.measuredContent(cell, formatted) ?? TextMeasuredContent(formatted);
    });
    // Both measurements lay out under the grid's text scaler, as the cells and the title (a plain `Text.rich`)
    // are drawn.
    final textScaler = MediaQuery.textScalerOf(context);
    final cellMeasurement = CellMeasurement(style: DefaultTextStyle.of(context).style, textScaler: textScaler);
    final titleMeasurement = CellMeasurement(style: configuration.style.columnTextStyle, textScaler: textScaler);
    // The widest line of the cells laid out within the cap, so a column with few items stays narrow.
    final contentMaxWidth = cap - cellPadding.horizontal - 8;
    final cellWidth = contents
        .toSet()
        .map((c) => c.measure(cellMeasurement, maxWidth: contentMaxWidth, maxHeight: maxContentHeight).width)
        .max;

    final titlePadding = column.titlePadding ?? configuration.style.defaultColumnTitlePadding;
    final titleWidth = TextMeasuredContent(column.title).measure(titleMeasurement).width;
    cellMeasurement.dispose();
    titleMeasurement.dispose();

    final cellTarget = cellWidth + cellPadding.horizontal + 8;
    // Mirrors the built-in's title term. The checkbox-column width (enableRowChecked)
    // is intentionally omitted since this grid has no checkbox columns; if one were
    // added the title could under-fit slightly, but a roomy title never clips.
    final titleTarget =
        titleWidth + titlePadding.horizontal + (column.isShowRightIcon ? configuration.style.iconSize : 0) + 8;

    // The title is clipped at the cap like the cells: the cap is absolute.
    final target = min(max(cellTarget, titleTarget), cap);
    resizeColumn(column, target - column.width);
  }

  /// Sizes every column for [bounds], the table's bounds on skill and factor columns.
  void autoFitColumns(ItemColumnBounds bounds) {
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
      final spec = col.getUserData<ColumnSpec>();
      final columnMaxWidth = spec?.takesItemColumnBounds == true ? bounds.maxWidth : double.infinity;
      final pinned = spec?.clampedWidth;
      final enabled = col.enableDropToResize;
      col.enableDropToResize = true; // If this flag is false, col will ignore any resizing operations.
      if (pinned != null) {
        // A width the user chose by dragging (spec.width != null) is not measured, so it survives data and layout
        // changes; it is shown as chosen, held within the table's maximum column width. The stored width is left as it is.
        resizeColumn(col, min(pinned, columnMaxWidth) - col.width);
      } else {
        // autoFitColumnPrecise sizes the column to max(title, widest cell) in one
        // row scan, bounded by the table's bounds on skill and factor columns
        // ([ItemColumnBounds]) when the column takes them.
        autoFitColumnPrecise(context, col, bounds);
        // A column wider than the grid is halved, unless the table bounds it: its cap is the bound it declares.
        if (columnMaxWidth.isInfinite && maxWidth != null && col.width > maxWidth!) {
          resizeColumn(col, -(col.width / 2 - 24));
        }
      }
      col.enableDropToResize = enabled;
    }
  }

  // The text-rendering ([ColumnSpec.wrapsText]) columns paired with their fixed
  // per-pass layout (content max-width, content max-height and vertical padding),
  // computed once so the per-row height scan in [_RowHeightMeasurer] does no
  // repeated column-metadata lookups. A column that takes [bounds]
  // ([ColumnSpec.takesItemColumnBounds]) lays its content out within the cell
  // height cap. Widget/icon columns render at a fixed height and a column without
  // a spec (the checkbox column) is excluded.
  List<_WrapColumn> _wrappingColumns(ItemColumnBounds bounds) {
    final result = <_WrapColumn>[];
    for (final col in columns) {
      final spec = col.getUserData<ColumnSpec>();
      if (spec == null || !spec.wrapsText) {
        continue;
      }
      final cellPadding = col.cellPadding ?? configuration.style.defaultCellPadding;
      result.add((
        col: col,
        spec: spec,
        maxWidth: col.width - cellPadding.horizontal,
        maxHeight: spec.takesItemColumnBounds ? bounds.maxCellHeight : double.infinity,
        verticalPadding: cellPadding.vertical,
      ));
    }
    return result;
  }

  // The pixel height of [minLines] lines of the content [row] shows in every shown wrapping column
  // ([ColumnSpec.minContentHeight]) plus its cell padding, at least [minLines] text lines plus the default cell
  // padding; serving as the fixed height in wrap mode and the floor in the auto modes. Read from the row's cells,
  // since what a cell draws is decided where the grid is built: the cells of one column all draw the same kind of
  // content, so every row gets the same floor.
  double _minRowHeight(TrinaRow row, List<_WrapColumn> columns, CellMeasurement measurement, int minLines) {
    var height = measurement.preferredLineHeight * minLines + configuration.style.defaultCellPadding.vertical;
    for (final column in columns) {
      final cell = row.cells[column.col.field];
      height = max(height, column.spec.minContentHeight(minLines, measurement, cell: cell) + column.verticalPadding);
    }
    return height;
  }

  // Sizes every row for [mode], flooring at [minLines] lines ([_minRowHeight]): wrap fixes all
  // rows at the floor, autoPerRow grows each to its own text, autoUniform grows
  // all to the tallest row's text — a skill or factor cell's text counted only up
  // to the table's cell height cap. trina's setRowHeight rebuilds the row, dropping
  // its attached record and notifying per row, so rows are replaced here in one
  // pass — carrying over cells, key, flags, and the record user-data — and the
  // caller notifies once. Returns whether anything changed. [bounds] holds the
  // measured content of a skill or factor cell to the table's cell height cap.
  bool applyRowHeights({required RowHeightMode mode, required int minLines, required ItemColumnBounds bounds}) {
    final context = gridKey.currentContext;
    if (context == null) {
      return false;
    }
    final style = DefaultTextStyle.of(context).style;
    final textScaler = MediaQuery.textScalerOf(context);
    final columns = _wrappingColumns(bounds);
    final floorMeasurement = CellMeasurement(style: style, textScaler: textScaler);
    double floor(TrinaRow row) => _minRowHeight(row, columns, floorMeasurement, minLines);
    // The auto modes measure wrapped text; wrap fills the floor without measuring.
    final measurer = mode == RowHeightMode.wrap
        ? null
        : _RowHeightMeasurer(columns: columns, style: style, textScaler: textScaler);
    final List<double> targets;
    try {
      switch (mode) {
        case RowHeightMode.wrap:
          targets = [for (final row in refRows) floor(row)];
        case RowHeightMode.autoPerRow:
          targets = [for (final row in refRows) max(floor(row), measurer!.contentHeight(row))];
        case RowHeightMode.autoUniform:
          final tallest = refRows.fold<double>(0, (h, row) => max(h, max(floor(row), measurer!.contentHeight(row))));
          targets = List.filled(refRows.length, tallest);
      }
    } finally {
      measurer?.dispose();
      floorMeasurement.dispose();
    }
    var changed = false;
    for (var i = 0; i < refRows.length; i++) {
      final row = refRows[i];
      final target = targets[i];
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
    applyCaptureDateTiebreak(col, order);
  }

  /// Breaks ties in the current column sort by the record's capture date.
  ///
  /// trina compares only a single column's cell value, so rows trina considers
  /// equal (e.g. same trained date, which is stored at day granularity) keep an
  /// undefined relative order — its comparator returns 0 on ties and Dart's
  /// [List.sort] is not stable. This re-sorts [refRows] reusing [col]'s own
  /// comparator as the primary key (so the visible ordering is unchanged) and
  /// disambiguates ties by [Metadata.capturedDate], mirroring [order] so a
  /// descending sort reverses the tie order too. A no-op for
  /// [TrinaColumnSort.none], which restores the canonical insertion order.
  void applyCaptureDateTiebreak(TrinaColumn col, TrinaColumnSort order) {
    if (order == TrinaColumnSort.none) {
      return;
    }
    final field = col.field;
    final descending = order == TrinaColumnSort.descending;
    int compareRows(TrinaRow a, TrinaRow b) {
      final primary = col.type.compare(a.cells[field]!.valueForSorting, b.cells[field]!.valueForSorting);
      final signedPrimary = descending ? -primary : primary;
      if (signedPrimary != 0) {
        return signedPrimary;
      }
      final aDate = _capturedDateTimeOf(a);
      final bDate = _capturedDateTimeOf(b);
      if (aDate == null || bDate == null) {
        return 0;
      }
      final tie = aDate.compareTo(bDate);
      return descending ? -tie : tie;
    }

    refRows.sort(compareRows);
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

  /// Copies the renderer, title, and [ColumnSpec] user data from each freshly
  /// built column onto the matching live column (by field), so columns whose
  /// renderer captured a provider snapshot (e.g. ratings) repaint with current
  /// data — and columns whose title is provider-derived (e.g. a renamed
  /// rating/label set, whose field is the stable spec id) show the new header —
  /// without a structural replace that would drop their width and sort indicator.
  ///
  /// Re-seating the spec keeps the live column's user data in sync with the
  /// current spec after a non-structural edit (e.g. a column's description).
  /// Width-persisting callers read the spec back off the live column, so
  /// a stale spec here would let a later resize/reset overwrite that edit. The
  /// rebuilt spec carries the current pinned width (every spec mutation also
  /// persists it), so re-seating never loses a width. The checkbox column has no
  /// spec and is left untouched.
  ///
  /// Cell-driven columns (e.g. memo, which reads the cell's user data) are
  /// refreshed by [reconcileRows] replacing their row instead; copying their
  /// stateless renderer here is harmless.
  ///
  /// Swapping a renderer alone does not repaint a row whose cell values are
  /// unchanged: [reconcileRows] keeps that row as it is. A cell whose rendering
  /// depends on more than its value carries [RenderedCellData], whose
  /// [RenderedCellData.paintState] [reconcileRows] compares to replace the row.
  ///
  /// Returns whether a column's title changed, which the auto-fit measures but no
  /// cell shows, so [reconcileRows] does not report it.
  bool refreshColumnRenderers(List<TrinaColumn> nextColumns) {
    final nextByField = {for (final column in nextColumns) column.field: column};
    var titlesChanged = false;
    for (final live in columns) {
      final next = nextByField[live.field];
      if (next != null) {
        final nextSpec = next.getUserData<ColumnSpec>();
        if (live.title != next.title) {
          titlesChanged = true;
        }
        live.renderer = next.renderer;
        live.title = next.title;
        if (nextSpec != null) {
          live.setUserData(nextSpec);
        }
      }
    }
    return titlesChanged;
  }

  /// Whether two rows for the same record render identically: same pinned state,
  /// same value in every cell, and, for a cell carrying [RenderedCellData] on
  /// either side, the same [RenderedCellData.paintState]. Drives
  /// [reconcileRows]'s decision to leave a row untouched (keeping its identity)
  /// or replace it.
  bool _rowContentEquals(TrinaRow a, TrinaRow b) {
    if (a.frozen != b.frozen || a.cells.length != b.cells.length) {
      return false;
    }
    for (final entry in b.cells.entries) {
      final live = a.cells[entry.key];
      if (live?.value != entry.value.value || !_paintStateEquals(live, entry.value)) {
        return false;
      }
    }
    return true;
  }

  // Cells whose user data is not [RenderedCellData] on either side paint from
  // their value alone, so they compare equal here.
  bool _paintStateEquals(TrinaCell? a, TrinaCell b) {
    final aData = a?.getUserData<Object>();
    final bData = b.getUserData<Object>();
    if (aData is! RenderedCellData && bData is! RenderedCellData) {
      return true;
    }
    return aData is RenderedCellData && bData is RenderedCellData && aData.paintState == bData.paintState;
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
  /// unchanged rows keep their identity. Assumes the column set is unchanged
  /// (the caller handles structural column changes with a full rebuild).
  ///
  /// When the diff is large (more than [_bulkReconcileThreshold] rows to
  /// reinsert) the per-row insert would be O(n^2), so it falls back to
  /// [replaceAllRows]: every row object is replaced and the current cell is
  /// cleared; the caller restores the selection by record afterwards.
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

/// Handles a cell selection (tap), given a live [RefBase] supplied by the table
/// at call time and the trina select event. Returns whether it consumed the tap.
///
/// The ref is passed in rather than captured because a long-lived cell closure
/// must not hold the grid-build ref: that ref is disposed whenever
/// [currentGridProvider] rebuilds (e.g. a column resize persists its width, or a
/// memo/rating is saved), after which a kept cell would read through a dead ref.
typedef CellSelectedCallback = bool Function(RefBase ref, TrinaGridOnSelectedEvent event);

abstract class CellData implements Exportable {
  CellSelectedCallback? get onSelected;
}

/// Cell data whose rendering depends on more than [TrinaCell.value].
///
/// [TrinaGridStateManagerExtension.reconcileRows] replaces a row when the
/// [paintState] of such a cell changes, even if every value is unchanged.
abstract interface class RenderedCellData implements CellData {
  /// A value-comparable snapshot of everything the cell paints beyond its value.
  Object get paintState;
}
