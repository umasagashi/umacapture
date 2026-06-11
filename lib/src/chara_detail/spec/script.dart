import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/script_facade.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/code_highlight_field.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

part 'script.mapper.dart';

// ignore: constant_identifier_names
const tr_script = "pages.chara_detail.column_predicate.script";

/// The library uri the user's compiled script lives under.
const _scriptLib = 'package:script/script.dart';

/// Current facade API contract version. Persisted with the spec so a future
/// incompatible API change can migrate or warn instead of silently misbehaving.
const scriptApiVersion = 1;

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

// --- Enrichment: CharaDetailRecord -> plain nested Map ----------------------

/// A coded leaf (`{code, name}`). [category] tags the value with its lookup
/// table id so [$Coded.codeOf] / `atLeast` / `atMost` can resolve a target name
/// to a code; omit it for fields without a comparable/identity order.
Map<String, dynamic> _coded(int code, String name, [String? category]) => {
  'code': code,
  'name': name,
  'category': ?category,
};

String _label(LabelMap labels, String key, int index) {
  final list = labels[key];
  if (list == null || index < 0 || index >= list.length) return index.toString();
  return list[index];
}

/// Precomputed lookups shared across all records (built once per grid build).
class _Enricher {
  final LabelMap labels;
  final Map<int, SkillInfo> skillInfo;
  final Map<int, FactorInfo> factorInfo;
  final Map<String, Map<String, double>> ratingsByRecord;
  final Map<String, Map<String, String>> memosByRecord;
  final List<int> charaRankBorder;
  final List<String> charaCardNames;

  _Enricher(
    this.labels,
    this.skillInfo,
    this.factorInfo,
    this.ratingsByRecord,
    this.memosByRecord,
    this.charaRankBorder,
    this.charaCardNames,
  );

  Map<String, dynamic> _aptitudeRank(int level) =>
      _coded(level + 1, _label(labels, LabelKeys.aptitude, level), 'aptitude');

  /// Maps an evaluation value to its rank bucket, mirroring [CharaRankColumnSpec.parse].
  Map<String, dynamic> _charaRank(int evaluation) {
    // indexWhere returns -1 when the evaluation exceeds every border (top bucket);
    // map it to the last rank index so the highest rank stays reachable.
    final index = charaRankBorder.indexWhere((border) => border > evaluation);
    final rank = index < 0 ? charaRankBorder.length : index;
    return _coded(rank, _label(labels, LabelKeys.charaRank, rank), 'charaRank');
  }

  /// A character (trainee or inheritance ancestor) as a coded card index + name.
  /// `card` directly indexes [charaCardNames], matching [CharacterCardColumnSpec.plutoCell].
  Map<String, dynamic> _chara(int card) =>
      _coded(card, card >= 0 && card < charaCardNames.length ? charaCardNames[card] : card.toString(), 'trainee');

  Map<String, dynamic> _parent(Parent p) => {
    'self': _chara(p.self.card),
    'parent1': _chara(p.parent1.card),
    'parent2': _chara(p.parent2.card),
    'rental': p.rental,
  };

  Map<String, dynamic> _family(Family f) => {'parent1': _parent(f.parent1), 'parent2': _parent(f.parent2)};

  Map<String, dynamic> _distance(int meterIndex) {
    final meters = int.tryParse(_label(labels, 'race_place.distance', meterIndex)) ?? 0;
    final (code, key) = meters <= 1400
        ? (0, 'short_range')
        : meters <= 1800
        ? (1, 'mile_range')
        : meters <= 2400
        ? (2, 'middle_range')
        : (3, 'long_range');
    return _coded(code, "pages.chara_detail.columns.aptitude.$key.title".tr(), 'distance');
  }

  Map<String, dynamic> _aptitudes(AptitudeSet a) => {
    'ground': {'turf': _aptitudeRank(a.ground.turf), 'dirt': _aptitudeRank(a.ground.dirt)},
    'distance': {
      'short': _aptitudeRank(a.distance.shortRange),
      'mile': _aptitudeRank(a.distance.mileRange),
      'middle': _aptitudeRank(a.distance.middleRange),
      'long': _aptitudeRank(a.distance.longRange),
    },
    'style': {
      'leadPace': _aptitudeRank(a.style.leadPace),
      'withPace': _aptitudeRank(a.style.withPace),
      'offPace': _aptitudeRank(a.style.offPace),
      'lateCharge': _aptitudeRank(a.style.lateCharge),
    },
  };

  List<String> _skillTags(int id) => skillInfo[id]?.tags.toList() ?? const [];

  List<String> _factorTags(int id) => factorInfo[id]?.tags.toList() ?? const [];

  List<Map<String, dynamic>> _skills(List<Skill> skills) => [
    for (final s in skills)
      {'id': s.id, 'level': s.level, 'name': _label(labels, LabelKeys.skill, s.id), 'tags': _skillTags(s.id)},
  ];

  List<Map<String, dynamic>> _factors(FactorSet factors) => [
    for (final entry in [(0, '本人', factors.self), (1, '親1', factors.parent1), (2, '親2', factors.parent2)])
      for (final f in entry.$3)
        {
          'id': f.id,
          'star': f.star,
          'name': _label(labels, LabelKeys.factor, f.id),
          'tags': _factorTags(f.id),
          'subject': _coded(entry.$1, "$tr_script.subject.${["self", "parent1", "parent2"][entry.$1]}".tr(), 'subject'),
        },
  ];

  List<Map<String, dynamic>> _factorGroups(FactorSet factors) {
    final order = <int>[];
    final stars = <int, List<int>>{};
    void accumulate(List<Factor> list, int subject) {
      for (final f in list) {
        final slot = stars.putIfAbsent(f.id, () {
          order.add(f.id);
          return [0, 0, 0];
        });
        slot[subject] += f.star;
      }
    }

    accumulate(factors.self, 0);
    accumulate(factors.parent1, 1);
    accumulate(factors.parent2, 2);
    return [
      for (final id in order)
        {
          'id': id,
          'name': _label(labels, LabelKeys.factor, id),
          'tags': _factorTags(id),
          'selfStar': stars[id]![0],
          'parent1Star': stars[id]![1],
          'parent2Star': stars[id]![2],
          'totalStar': stars[id]!.fold<int>(0, (a, b) => a + b),
        },
    ];
  }

  List<Map<String, dynamic>> _races(List<Race> races) => [
    for (final e in races)
      {
        'title': _coded(e.title, _label(labels, 'race_title.name', e.title), 'race_title'),
        'place': e.place,
        'position': e.position,
        'won': e.won,
        'ground': _coded(e.ground, _label(labels, 'race_place.ground', e.ground), 'ground'),
        'distance': _distance(e.distance),
        'strategy': _coded(e.strategy, _label(labels, LabelKeys.raceStrategy, e.strategy), 'raceStrategy'),
        'weather': _coded(e.weather, _label(labels, 'race_weather.name', e.weather), 'weather'),
      },
  ];

  List<Map<String, dynamic>> _supportCards(List<SupportCard> cards) => [
    for (final c in cards)
      {
        'id': c.id,
        'rank': _coded(
          c.rank,
          c.rank < _supportCardRanks.length ? _supportCardRanks[c.rank] : c.rank.toString(),
          'support_rank',
        ),
        'level': c.level,
      },
  ];

  Map<String, dynamic> _metadata(CharaDetailRecord record) {
    final typeIndex = RecordType.values.indexOf(record.metadata.recordType ?? RecordType.standard);
    return {
      'recordType': _coded(typeIndex, _label(labels, LabelKeys.recordType, typeIndex), 'record_type'),
      'strategy': _coded(
        record.metadata.strategy,
        _label(labels, LabelKeys.raceStrategy, record.metadata.strategy),
        'raceStrategy',
      ),
      'isFriend': record.isFriend,
    };
  }

  Map<String, dynamic> enrich(CharaDetailRecord record) {
    final status = record.status;
    return {
      'id': record.id,
      'trainee': _chara(record.trainee.card),
      'charaRank': _charaRank(record.evaluationValue),
      'capturedDate': record.metadata.capturedDate,
      'family': _family(record.family),
      'evaluationValue': record.evaluationValue,
      'fans': record.fans,
      'trainedDate': record.trainedDate,
      'ratings': ratingsByRecord[record.id] ?? const <String, double>{},
      'memos': memosByRecord[record.id] ?? const <String, String>{},
      'status': {
        'speed': status.speed,
        'stamina': status.stamina,
        'power': status.power,
        'guts': status.guts,
        'intelligence': status.intelligence,
      },
      'aptitudes': _aptitudes(record.aptitudes),
      'skills': _skills(record.skills),
      'factors': _factors(record.factors),
      'factorGroups': _factorGroups(record.factors),
      'races': _races(record.races),
      'supportCards': _supportCards(record.supportCards),
      'scenario': {
        'id': record.scenario.id,
        'name': _label(labels, LabelKeys.campaignScenario, record.scenario.id).split('\n').first,
      },
      'metadata': _metadata(record),
    };
  }
}

/// Support-card rarity labels (ascending). The recognizer emits an index but the
/// repository carries no label source, so this fixed map provides `.name` while
/// `.code` exposes the raw, order-stable index.
const _supportCardRanks = ['R', 'SR', 'SSR'];

final _enricherProvider = Provider<_Enricher>((ref) {
  final labels = ref.watch(labelMapProvider);
  final skillInfo = {for (final s in ref.watch(skillInfoProvider)) s.sid: s};
  final factorInfo = {for (final f in ref.watch(factorInfoProvider)) f.sid: f};
  final ratingsByRecord = <String, Map<String, double>>{};
  for (final storage in ref.watch(charaDetailRecordRatingStorageDataProvider)) {
    ref.watch(charaDetailRecordRatingProvider(storage.key)).data.forEach((recordId, value) {
      (ratingsByRecord[recordId] ??= {})[storage.key] = value;
    });
  }
  final memosByRecord = <String, Map<String, String>>{};
  for (final storage in ref.watch(charaDetailRecordMemoStorageDataProvider)) {
    ref.watch(charaDetailRecordMemoProvider(storage.key)).data.forEach((recordId, value) {
      (memosByRecord[recordId] ??= {})[storage.key] = value;
    });
  }
  final charaRankBorder = ref.watch(charaRankBorderProvider);
  final charaCardNames = ref.watch(charaCardInfoProvider).map((e) => e.names.first).toList();
  return _Enricher(labels, skillInfo, factorInfo, ratingsByRecord, memosByRecord, charaRankBorder, charaCardNames);
});

final _recordIndexProvider = Provider<Map<String, CharaDetailRecord>>((ref) {
  return {for (final r in ref.watch(charaDetailRecordStorageProvider)) r.id: r};
});

/// The enriched plain Map for one record, cached and shared across script
/// columns. Only built when a [ScriptColumnSpec] reads it, so non-script users
/// pay nothing.
final enrichedRecordProvider = Provider.family<Map<String, dynamic>, String>((ref, recordId) {
  final record = ref.watch(_recordIndexProvider)[recordId];
  if (record == null) return const <String, dynamic>{};
  return ref.watch(_enricherProvider).enrich(record);
});

// --- Compilation ------------------------------------------------------------

/// A compiled user script, or the compile error that prevented it.
class CompiledScript {
  final Runtime? runtime;
  final String? error;

  CompiledScript._(this.runtime, this.error);

  static CompiledScript compile(String source) {
    try {
      final compiler = Compiler()
        ..addPlugin(FacadePlugin())
        ..entrypoints.add(_scriptLib);
      final program = compiler.compile({
        'script': {'script.dart': "import 'package:script/facade.dart';\n$source"},
      });
      final runtime = Runtime.ofProgram(program)..addPlugin(FacadePlugin());
      return CompiledScript._(runtime, null);
    } catch (e) {
      return CompiledScript._(null, e.toString());
    }
  }
}

/// Compiles a script source once and caches it, keyed by the source text.
///
/// This is the render-path cache only: [parse] reads it for every grid build.
/// The dialog's edit/preview path compiles directly via [CompiledScript.compile]
/// (see [_ScriptColumnSelectorState._evaluate] and [_previewEntry]) and never
/// touches this provider, so it is NOT autoDispose — that would drop the program
/// after each build and force a recompile on every grid rebuild. The cache is
/// keyed by committed source text, so it is bounded by the number of distinct
/// saved script columns; mid-edit sources never reach it.
final compiledScriptProvider = Provider.family<CompiledScript, String>((ref, source) {
  return CompiledScript.compile(source);
});

// --- Cell result / data -----------------------------------------------------

// Diagnostic messages stored in [ScriptCellResult.error]. They are deliberately
// plain (non-localized) strings: the same normalization runs inside the preview
// isolate (see [_previewEntry]), where easy_localization's global is not
// initialized and `.tr()` would fail. Raw dart_eval exceptions are already shown
// untranslated through the same ⚠ path, so this is consistent.
const _displayObjectError =
    'display() returned an object. Return a number, string, or Cell(...). '
    'For coded fields use .name (e.g. r.scenario.name).';
const _budgetError = 'Execution budget exceeded; this and the remaining rows were not evaluated.';

/// The per-record outcome of running filter + display, computed once in
/// [ScriptColumnSpec.parse] and shared by evaluate / plutoCell / plutoColumn.
class ScriptCellResult {
  final bool visible;
  final String display;
  final Comparable? sortValue;
  final String? color;
  final String? background;
  final String? icon;
  final String? iconColor;
  final String? error;

  const ScriptCellResult({
    required this.visible,
    required this.display,
    this.sortValue,
    this.color,
    this.background,
    this.icon,
    this.iconColor,
    this.error,
  });

  /// Builds a result from a `Cell(...)`'s backing map: the wrapped
  /// {display, sort, color, background, icon, iconColor}.
  factory ScriptCellResult.fromCell(Map value) {
    return ScriptCellResult(
      visible: true,
      display: (value['display'] ?? '').toString(),
      sortValue: value['sort'] is Comparable ? value['sort'] as Comparable : null,
      color: value['color'] as String?,
      background: value['background'] as String?,
      icon: value['icon'] as String?,
      iconColor: value['iconColor'] as String?,
    );
  }

  /// Normalizes a plain (already unwrapped) display-script return value.
  ///
  /// A `Cell(...)` is handled earlier by [fromCell]; any other [Map] reaching
  /// here is a facade object the script returned by mistake (e.g. a `$Coded`
  /// like `r.scenario` instead of `r.scenario.name`), which would otherwise
  /// render as a silent blank — so it is surfaced as an error instead.
  factory ScriptCellResult.fromDisplay(Object? value) {
    if (value is num) return ScriptCellResult(visible: true, display: value.toString(), sortValue: value);
    if (value is bool) return ScriptCellResult(visible: true, display: value.toString());
    if (value is List) {
      return ScriptCellResult(visible: true, display: value.map((e) => '$e').join(', '));
    }
    if (value == null) return const ScriptCellResult(visible: true, display: '');
    if (value is Map) return const ScriptCellResult(visible: true, display: '', error: _displayObjectError);
    return ScriptCellResult(visible: true, display: value.toString());
  }
}

class ScriptCellData implements CellData {
  final ScriptCellResult result;

  ScriptCellData(this.result);

  @override
  String get csv => result.display;

  @override
  Predicate<TrinaGridOnSelectedEvent>? get onSelected => null;
}

/// Column type for script cells: the whole [ScriptCellResult] lives in
/// `cell.value`, so sorting reads the numeric sort key while the column
/// `formatter` (and thus auto-fit) and the renderer use the display text. It
/// mirrors the minimal surface of the built-in text type; `applyFormat*` come
/// from trina's default extension (a no-op for a non-format type).
class _ScriptColumnType with TrinaColumnTypeDefaultMixin implements TrinaColumnType {
  const _ScriptColumnType();

  @override
  dynamic get defaultValue => null;

  @override
  bool isValid(dynamic value) => true;

  @override
  dynamic makeCompareValue(dynamic v) {
    final result = v as ScriptCellResult;
    return result.sortValue ?? result.display;
  }

  @override
  int compare(dynamic a, dynamic b) {
    if (a == null || b == null) return a == b ? 0 : (a == null ? -1 : 1);
    if (a is num && b is num) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }

  // The column always supplies its own `renderer` and disables editing, so this
  // default cell is effectively unused; mirror the renderer for safety.
  @override
  Widget buildCell(TrinaGridStateManager stateManager, TrinaCell cell, TrinaColumn column, TrinaRow row) {
    final data = cell.getUserData<ScriptCellData>();
    return data == null ? const SizedBox.shrink() : _ScriptCell(result: data.result);
  }
}

// --- Color / icon resolution (renderer side) --------------------------------

Color? _resolveColor(String? source) {
  final argb = resolveColorArgb(source);
  return argb == null ? null : Color(argb);
}

/// Stand-in characters whose width approximates the leading icon (16px) plus its
/// gap (4px), prepended to the auto-fit measurement string of icon-bearing
/// columns so the icon never squeezes the text into an ellipsis.
const _iconWidthReserve = 'MM';

const Map<String, IconData> _iconMap = {
  'cross': Icons.close, // ×
  'circle': Icons.circle_outlined, // ○
  'double_circle': Icons.radio_button_checked, // ◎
  'check': Icons.check, // ✓
  'star': Icons.star_border, // ☆ (outline)
  'favorite': Icons.favorite_border, // ♡ (outline)
  'flag': Icons.flag_outlined, // ⚑ (outline)
  'arrow_upward': Icons.arrow_upward, // ↑
  'arrow_downward': Icons.arrow_downward, // ↓
};

// --- Spec -------------------------------------------------------------------

@MappableClass(discriminatorValue: 'ScriptColumnSpec', ignoreNull: true)
class ScriptColumnSpec extends ColumnSpec<ScriptCellResult> with ScriptColumnSpecMappable {
  @override
  final String id;

  @override
  final String title;

  /// The single source holding `filter`, `display`, and any shared helpers.
  final String source;

  /// Facade API contract version this script was written against.
  final int apiVersion;

  /// User-provided tooltip text shown on the column chip. Null/empty means "no
  /// tooltip" (the chip then shows a localized "no description" fallback).
  /// Omitted from the serialized map (via the class-level `ignoreNull`) so
  /// pre-existing specs are never flagged as broken by [isSpecMapIncomplete].
  final String? description;

  // Render-phase scratch state: whether every visible row carried a numeric sort
  // key, and whether any cell renders a leading icon. Derived from the parsed
  // results and read by plutoColumn/plutoCell, which receive only `ref` (no column
  // aggregate). They are set ONLY through [_applyHints]; they are not constructor
  // fields, so dart_mappable never serializes them. Fully immutable handling would
  // require threading the aggregate through the shared ColumnSpec interface.
  bool _numericSort = false;
  bool _hasIcon = false;

  ScriptColumnSpec({
    required this.id,
    required this.title,
    required this.source,
    this.apiVersion = scriptApiVersion,
    this.description,
  });

  ScriptColumnSpec copyWith({
    String? id,
    String? title,
    String? source,
    int? apiVersion,
    Object? description = _unset,
  }) {
    return ScriptColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      source: source ?? this.source,
      apiVersion: apiVersion ?? this.apiVersion,
      description: identical(description, _unset) ? this.description : description as String?,
    );
  }

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  /// A script saved against a different facade contract is surfaced as broken
  /// until the user reopens it, passes the check, and re-saves (which restamps
  /// [apiVersion] to [scriptApiVersion] and clears the broken flag).
  @override
  bool get isObsolete => apiVersion != scriptApiVersion;

  @override
  List<ScriptCellResult> parse(RefBase ref, List<CharaDetailRecord> records) {
    final compiled = ref.read(compiledScriptProvider(source));
    if (compiled.error != null) {
      _numericSort = false;
      _hasIcon = false;
      return [for (final _ in records) ScriptCellResult(visible: true, display: '', error: compiled.error)];
    }
    final runtime = compiled.runtime!;
    // Make the name→code tables visible to codeOf/atLeast/atMost for this run.
    scriptCodeTables = ref.read(scriptCodeTablesProvider);
    // Production has no hard per-call timeout: dart_eval exposes no instruction
    // hook, so a single runaway record cannot be interrupted here. The save-time
    // check runs the whole record set under [_previewTimeout], which is what
    // guarantees no such script is committed. As a softer secondary guard against
    // cumulative cost (e.g. far more records than existed at check time), abort
    // once the looser [_productionBudget] is spent and mark the remaining rows.
    final stopwatch = Stopwatch()..start();
    final results = <ScriptCellResult>[];
    var aborted = false;
    for (final record in records) {
      if (aborted) {
        results.add(const ScriptCellResult(visible: true, display: '', error: _budgetError));
        continue;
      }
      results.add(_run(ref, runtime, record));
      if (stopwatch.elapsedMicroseconds > _productionBudget.inMicroseconds) aborted = true;
    }
    _applyHints(results.where((r) => r.visible));
    return results;
  }

  /// Derives the render hints from the visible cell results. A column sorts
  /// numerically only when every visible row carries a numeric sort key.
  static ({bool numericSort, bool hasIcon}) _renderHints(Iterable<ScriptCellResult> visible) {
    final list = visible.toList();
    return (
      numericSort: list.isNotEmpty && list.every((r) => r.sortValue is num),
      hasIcon: list.any((r) => r.icon != null),
    );
  }

  /// Sets [_numericSort]/[_hasIcon] from the visible results. The only writer of
  /// the render-phase scratch state, shared by [parse] and the preview grid.
  void _applyHints(Iterable<ScriptCellResult> visible) {
    final hints = _renderHints(visible);
    _numericSort = hints.numericSort;
    _hasIcon = hints.hasIcon;
  }

  ScriptCellResult _run(RefBase ref, Runtime runtime, CharaDetailRecord record) {
    try {
      final map = ref.read(enrichedRecordProvider(record.id));
      final visible = _unwrap(runtime.executeLib(_scriptLib, 'filter', [$Record.wrap(map)])) == true;
      if (!visible) return const ScriptCellResult(visible: false, display: '');
      return _displayResult(runtime.executeLib(_scriptLib, 'display', [$Record.wrap(map)]));
    } catch (e) {
      return ScriptCellResult(visible: true, display: '', error: e.toString());
    }
  }

  static Object? _unwrap(Object? result) => result is $Value ? result.$value : result;

  /// Normalizes a raw `display` return value, distinguishing a real `Cell` from
  /// any other facade object (an error) before unwrapping. Shared by the render
  /// path and the preview isolate so both treat return values identically.
  static ScriptCellResult _displayResult(Object? raw) {
    if (raw is $Cell) return ScriptCellResult.fromCell(raw.$value);
    return ScriptCellResult.fromDisplay(_unwrap(raw));
  }

  @override
  List<bool> evaluate(RefBase ref, List<ScriptCellResult> values) {
    return values.map((e) => e.visible).toList();
  }

  @override
  TrinaCell plutoCell(RefBase ref, ScriptCellResult value) {
    // The full result is the cell value (see [_ScriptColumnType]); the renderer
    // and formatter read it for display/measurement, sorting for the sort key.
    return TrinaCell(value: value)..setUserData(ScriptCellData(value));
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    return TrinaColumn(
      title: title,
      field: id,
      type: const _ScriptColumnType(),
      textAlign: _numericSort ? TrinaColumnTextAlign.right : TrinaColumnTextAlign.left,
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      enableEditingMode: false,
      // Auto-fit measures formattedValueForDisplay(cell.value); make that the real
      // display text (the renderer draws the same), plus an icon-width reserve when
      // any cell renders a leading icon so the icon never squeezes text to ellipsis.
      formatter: (value) => '${_hasIcon ? _iconWidthReserve : ''}${(value as ScriptCellResult).display}',
      renderer: (context) => _ScriptCell(result: context.cell.getUserData<ScriptCellData>()!.result),
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) =>
      (description?.trim().isEmpty ?? true) ? "$tr_script.tooltip.empty".tr() : description!.trim();

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) => ScriptColumnSelector(specId: id, onDecided: onDecided);
}

class _ScriptCell extends StatelessWidget {
  final ScriptCellResult result;

  const _ScriptCell({required this.result});

  @override
  Widget build(BuildContext context) {
    if (result.error != null) {
      return Tooltip(
        message: result.error!,
        child: const Icon(Icons.error_outline, size: 18, color: Colors.orange),
      );
    }
    final iconData = result.icon == null ? null : _iconMap[result.icon!];
    final text = Text(
      result.display,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: _resolveColor(result.color)),
    );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (iconData != null) ...[
          Icon(iconData, size: 18, color: _resolveColor(result.iconColor)),
          const SizedBox(width: 4),
        ],
        Flexible(child: text),
      ],
    );
    final background = _resolveColor(result.background);
    if (background == null) return row;
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.centerLeft,
      child: row,
    );
  }
}

// --- Preview (separate isolate + timeout) -----------------------------------

/// Maximum number of rows the preview grid widget renders. The check itself runs
/// against every record; this only bounds how many result rows are shown (and
/// hashed into the grid key) so a large dataset stays responsive in the dialog.
const _previewDisplayLimit = 100;

/// Hard cap on a save-time check, now run over the FULL record set; exceeding it
/// rejects the save (infinite loops, pathologically heavy scripts).
const _previewTimeout = Duration(seconds: 3);

/// Looser wall-clock budget for the synchronous production grid build. A script
/// that passed the stricter full-set check stays well under this; the headroom
/// absorbs slower hardware or more records added after the check. See
/// [ScriptColumnSpec.parse]. dart_eval cannot interrupt a single runaway record,
/// so this only bounds cumulative cost across rows.
const _productionBudget = Duration(seconds: 10);

/// Estimated full-grid cost above which the user is warned (soft) before saving.
const _costWarnMicros = 1500000; // ~1.5s across all records.

/// Formats a microsecond duration for the estimated full-table cost line.
String _formatMicros(int micros) {
  if (micros >= 1000000) return '${(micros / 1000000).toStringAsFixed(1)} ${"$tr_script.preview.unit.seconds".tr()}';
  if (micros >= 1000) return '${(micros / 1000).round()} ${"$tr_script.preview.unit.milliseconds".tr()}';
  return '$micros ${"$tr_script.preview.unit.microseconds".tr()}';
}

class _PreviewRequest {
  final SendPort port;
  final String source;
  final List<Map<String, dynamic>> records;
  final Map<String, Map<String, int>> tables;

  _PreviewRequest(this.port, this.source, this.records, this.tables);
}

class ScriptPreviewResult {
  // Full styled cell results (display + color/background/icon/sort/error), so the
  // preview can render each row exactly as the production grid would. The fields
  // are plain values, so the list crosses the isolate boundary unchanged.
  final List<ScriptCellResult> rows;
  final double microsPerRecord;
  final String? compileError;
  final bool timedOut;

  ScriptPreviewResult({this.rows = const [], this.microsPerRecord = 0, this.compileError, this.timedOut = false});

  bool get ok => compileError == null && !timedOut && rows.every((r) => r.error == null);
}

/// Isolate entry: recompiles the (already main-side-validated) source and runs
/// filter + display over the sampled records, timing the whole pass. Runs in a
/// killable isolate so an infinite loop can be aborted by the caller's timeout.
void _previewEntry(_PreviewRequest request) {
  final compiled = CompiledScript.compile(request.source);
  if (compiled.error != null) {
    request.port.send(ScriptPreviewResult(compileError: compiled.error));
    return;
  }
  final runtime = compiled.runtime!;
  // Mirror the production run: name→code tables for codeOf/atLeast/atMost.
  scriptCodeTables = request.tables;
  final rows = <ScriptCellResult>[];
  final stopwatch = Stopwatch()..start();
  for (final map in request.records) {
    try {
      final visible = ScriptColumnSpec._unwrap(runtime.executeLib(_scriptLib, 'filter', [$Record.wrap(map)])) == true;
      if (!visible) {
        rows.add(const ScriptCellResult(visible: false, display: ''));
        continue;
      }
      rows.add(ScriptColumnSpec._displayResult(runtime.executeLib(_scriptLib, 'display', [$Record.wrap(map)])));
    } catch (e) {
      rows.add(ScriptCellResult(visible: true, display: '', error: e.toString()));
    }
  }
  stopwatch.stop();
  final micros = request.records.isEmpty ? 0.0 : stopwatch.elapsedMicroseconds / request.records.length;
  request.port.send(ScriptPreviewResult(rows: rows, microsPerRecord: micros));
}

Future<ScriptPreviewResult> runScriptPreview(
  String source,
  List<Map<String, dynamic>> records, [
  Map<String, Map<String, int>> tables = const {},
]) async {
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(_previewEntry, _PreviewRequest(receivePort.sendPort, source, records, tables));
  try {
    final result = await receivePort.first.timeout(_previewTimeout);
    return result as ScriptPreviewResult;
  } on TimeoutException {
    isolate.kill(priority: Isolate.immediate);
    return ScriptPreviewResult(timedOut: true);
  } finally {
    receivePort.close();
  }
}

// --- Selector ---------------------------------------------------------------

/// Copies [text] to the clipboard and confirms with a toast.
void _copyToClipboard(String text) {
  Clipboard.setData(ClipboardData(text: text));
  Toaster.show(ToastData.success(description: "$tr_script.copy.done".tr()));
}

/// A small copy-to-clipboard affordance shared by the code field and the error
/// log; the actual text is resolved lazily so it always copies the latest.
class _CopyButton extends StatelessWidget {
  final String Function() text;
  final Color? color;

  const _CopyButton({required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: "$tr_script.copy.tooltip".tr(),
      child: IconButton(
        icon: Icon(Icons.copy, size: 18, color: color),
        visualDensity: VisualDensity.compact,
        onPressed: () => _copyToClipboard(text()),
      ),
    );
  }
}

// --- Name lookup ------------------------------------------------------------

// The "common" selector translation prefix. Inlined as a literal because both
// base.dart and gui/chara_detail/common.dart export a `tr_common` const with
// this value, so referencing the bare identifier here would be ambiguous.
const _trCommonSelector = "pages.chara_detail.column_predicate.common.selector";

/// One selectable lookup category: the script accessor [path] that yields these
/// [names], plus a [hintKey] for the dimmed Japanese label shown beside it.
///
/// [category] / [codeByName] are set only for `$Coded`-backed accessors: they
/// feed the runtime name→code tables ([scriptCodeTablesProvider]) used by
/// `$Coded.codeOf` / `atLeast` / `atMost`, with [codeByName] keyed by the same
/// display names listed here. Non-coded categories (skills, factors, scenario)
/// leave [category] null.
class _LookupCategory {
  final String path;
  final String hintKey;
  final List<String> names;
  final String? category;
  final Map<String, int> codeByName;

  const _LookupCategory(this.path, this.hintKey, this.names, {this.category, this.codeByName = const {}});
}

/// Drops blanks and removes duplicates while preserving first-seen order.
List<String> _distinctNonEmpty(Iterable<String> names) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in names) {
    final name = raw.trim();
    if (name.isNotEmpty && seen.add(name)) result.add(name);
  }
  return result;
}

/// Maps each non-blank label to its code (`index + offset`, first-seen wins),
/// mirroring the enricher's code assignment for that category (e.g. aptitude
/// uses `offset: 1` since its code is `level + 1`).
Map<String, int> _codeByIndex(List<String> labels, {int offset = 0}) {
  final map = <String, int>{};
  for (final (index, raw) in labels.indexed) {
    final name = raw.trim();
    if (name.isNotEmpty) map.putIfAbsent(name, () => index + offset);
  }
  return map;
}

/// Every category of `.name` a script can read, paired with the accessor path
/// that produces it. Each name list is derived with the SAME transform the
/// enricher uses (see [_Enricher]), so a copied string equals the script's
/// `.name` verbatim.
List<_LookupCategory> _buildLookupCategories(LabelMap labels, List<String> charaNames) {
  List<String> label(String key) => labels[key] ?? const [];

  // A `$Coded`-backed category: `names` for the picker, `codeByName` for the
  // runtime tables. `source` order/offset must match the enricher's codes.
  _LookupCategory coded(String path, String hintKey, String category, List<String> source, {int offset = 0}) {
    return _LookupCategory(
      path,
      hintKey,
      _distinctNonEmpty(source),
      category: category,
      codeByName: _codeByIndex(source, offset: offset),
    );
  }

  final subjectNames = ['self', 'parent1', 'parent2'].map((k) => "$tr_script.subject.$k".tr()).toList();
  final distanceNames = [
    'short_range',
    'mile_range',
    'middle_range',
    'long_range',
  ].map((k) => "pages.chara_detail.columns.aptitude.$k.title".tr()).toList();

  return [
    coded('r.trainee.name', 'trainee', 'trainee', charaNames),
    coded('r.charaRank.name', 'chara_rank', 'charaRank', label(LabelKeys.charaRank)),
    _LookupCategory('r.skills[].name', 'skill', _distinctNonEmpty(label(LabelKeys.skill))),
    _LookupCategory('r.factors[].name', 'factor', _distinctNonEmpty(label(LabelKeys.factor))),
    coded('r.factors[].subject.name', 'subject', 'subject', subjectNames),
    _LookupCategory(
      'r.scenario.name',
      'scenario',
      _distinctNonEmpty(label(LabelKeys.campaignScenario).map((e) => e.split('\n').first)),
    ),
    // Aptitude codes are `level + 1` (see _Enricher._aptitudeRank).
    coded('r.aptitudes.*.name', 'aptitude', 'aptitude', label(LabelKeys.aptitude), offset: 1),
    coded('r.races[].title.name', 'race_title', 'race_title', label('race_title.name')),
    coded('r.races[].ground.name', 'ground', 'ground', label('race_place.ground')),
    coded('r.races[].distance.name', 'distance', 'distance', distanceNames),
    coded('r.races[].strategy.name', 'strategy', 'raceStrategy', label(LabelKeys.raceStrategy)),
    coded('r.races[].weather.name', 'weather', 'weather', label('race_weather.name')),
    coded('r.metadata.recordType.name', 'record_type', 'record_type', label(LabelKeys.recordType)),
    coded('r.supportCards[].rank.name', 'support_rank', 'support_rank', _supportCardRanks),
  ];
}

/// Per-category name→code tables for the script runtime, shared with the dialog
/// name picker via [_buildLookupCategories] so the two never diverge. Injected
/// into [scriptCodeTables] just before a script runs (see [ScriptColumnSpec.parse]
/// and [_previewEntry]).
final scriptCodeTablesProvider = Provider<Map<String, Map<String, int>>>((ref) {
  final labels = ref.watch(labelMapProvider);
  final charaNames = ref.watch(charaCardInfoProvider).map((e) => e.names.first).toList();
  return {
    for (final c in _buildLookupCategories(labels, charaNames))
      if (c.category != null) c.category!: c.codeByName,
  };
});

/// A reference helper inside the script dialog: pick a category (labeled by its
/// script accessor path), filter by substring, and click a chip to copy the
/// name to the clipboard. Purely a reference — it never touches the save gate.
class _NameLookup extends ConsumerStatefulWidget {
  const _NameLookup();

  @override
  ConsumerState<_NameLookup> createState() => _NameLookupState();
}

class _NameLookupState extends ConsumerState<_NameLookup> {
  int? _categoryIndex;
  String _query = '';
  bool _collapsed = true;
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Copies [name] as a Dart string literal so it pastes ready to use.
  ///
  /// [jsonEncode] yields a double-quoted, escaped literal (handling `"`, `\` and
  /// control characters); it leaves non-ASCII characters intact. JSON has no
  /// notion of Dart's `$` interpolation, so that one character is escaped on top
  /// — the only escaping not delegated to the standard library.
  void _copyName(String name) {
    final literal = jsonEncode(name).replaceAll(r'$', r'\$');
    Clipboard.setData(ClipboardData(text: literal));
    Toaster.show(ToastData.success(description: "$tr_script.copy.done".tr()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final charaNames = ref.watch(charaCardInfoProvider).map((e) => e.names.first).toList();
    final categories = _buildLookupCategories(ref.watch(labelMapProvider), charaNames);
    final category = _categoryIndex == null ? null : categories[_categoryIndex!];
    final query = _query.trim().toLowerCase();
    final matched = category == null
        ? const <String>[]
        : (query.isEmpty
              ? category.names
              : category.names.where((name) => name.toLowerCase().contains(query)).toList());
    final needCollapse = _collapsed && matched.length > 30;
    final reduced = needCollapse ? matched.partial(0, 30) : matched;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<int>(
                value: _categoryIndex,
                hint: Text("$tr_script.name_lookup.category_hint".tr()),
                borderRadius: BorderRadius.circular(8),
                items: [
                  for (final (index, c) in categories.indexed)
                    DropdownMenuItem<int>(
                      value: index,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(c.path, style: GoogleFonts.mPlus1Code(fontSize: 14)),
                          const SizedBox(width: 8),
                          Text(
                            "$tr_script.name_lookup.hints.${c.hintKey}".tr(),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _categoryIndex = value;
                    _collapsed = true;
                  });
                },
              ),
              if (category != null)
                Tooltip(
                  message: "$tr_script.name_lookup.search_hint".tr(),
                  child: DenseTextField(
                    controller: _searchController,
                    debounce: const Duration(milliseconds: 200),
                    hintText: "$tr_script.name_lookup.search_hint".tr(),
                    allowEmpty: true,
                    onChanged: (text) => setState(() => _query = text),
                  ),
                ),
            ],
          ),
        ),
        if (category != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.topLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (matched.isEmpty) Text("$_trCommonSelector.not_found_message".tr()),
                  for (final name in reduced)
                    ActionChip(
                      label: Text(name),
                      backgroundColor: theme.colorScheme.surfaceContainerLow,
                      onPressed: () => _copyName(name),
                    ),
                  if (needCollapse)
                    ActionChip(
                      avatar: const Icon(Icons.expand_more),
                      label: Text("$_trCommonSelector.expand_button".tr()),
                      side: BorderSide.none,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      onPressed: () => setState(() => _collapsed = false),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<ScriptColumnSpec>();

class ScriptColumnSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const ScriptColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  ConsumerState<ScriptColumnSelector> createState() => _ScriptColumnSelectorState();
}

class _ScriptColumnSelectorState extends ConsumerState<ScriptColumnSelector> {
  late String title;
  late String description;
  late final DartHighlightController _codeController;

  // The last source whose preview succeeded. Only this is committed on OK, so a
  // script that fails to compile / times out / throws is never saved (the only
  // guard against an infinite loop freezing the synchronous grid build).
  late String _validatedSource;

  // Last seen code text, to tell a real edit from a mere cursor/selection move
  // (the controller notifies listeners on both).
  late String _lastText;

  ScriptPreviewResult? _result;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    final spec = _clonedSpecProvider.read(ref, widget.specId);
    title = spec.title;
    description = spec.description ?? "";
    _codeController = DartHighlightController(text: spec.source);
    _validatedSource = spec.source;
    _lastText = spec.source;
    // Saving is gated on a passing check: disabled until the user runs the check,
    // and disabled again whenever the code is edited.
    WidgetsBinding.instance.addPostFrameCallback((_) => _setSaveEnabled(false));
    _codeController.addListener(_onCodeChanged);
    widget.onDecided.addListener(() {
      // Stamp the current contract version: saving is gated on a passing check,
      // so a committed source is, by definition, validated against the current
      // facade. This clears the obsolete/broken flag for a re-saved old script.
      _clonedSpecProvider.update(
        ref,
        widget.specId,
        (spec) => spec.copyWith(
          title: title,
          source: _validatedSource,
          apiVersion: scriptApiVersion,
          description: description.trim().isEmpty ? null : description.trim(),
        ),
      );
    });
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    super.dispose();
  }

  void _setSaveEnabled(bool value) {
    if (!mounted) return;
    ref.read(columnSpecSaveEnabledProvider(widget.specId).notifier).set(value);
  }

  void _onCodeChanged() {
    // Ignore selection/cursor-only notifications; only a real text edit
    // invalidates the last check.
    if (_codeController.text == _lastText) return;
    _lastText = _codeController.text;
    _setSaveEnabled(false);
  }

  Future<void> _evaluate() async {
    setState(() => _running = true);
    final source = _codeController.text;
    // Compile on the main isolate first: compilation always terminates, so it is
    // safe here and surfaces syntax errors without spawning an isolate.
    final compiled = CompiledScript.compile(source);
    if (compiled.error != null) {
      _setSaveEnabled(false);
      setState(() {
        _running = false;
        _result = ScriptPreviewResult(compileError: compiled.error);
      });
      return;
    }
    // Validate against every record, not a sample: the full-set run (bounded by
    // [_previewTimeout]) is the real guard that no committed script hangs the grid.
    final records = ref
        .read(charaDetailRecordStorageProvider)
        .map((r) => ref.read(enrichedRecordProvider(r.id)))
        .toList();
    final result = await runScriptPreview(source, records, ref.read(scriptCodeTablesProvider));
    if (!mounted) return;
    _setSaveEnabled(result.ok);
    setState(() {
      _running = false;
      _result = result;
      if (result.ok) _validatedSource = source;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FormGroup(
          title: Text("$tr_script.notation.label".tr()),
          description: Text("$tr_script.notation.description".tr()),
          children: [
            FormLine(
              title: Text("$tr_script.notation.title.label".tr()),
              children: [DenseTextField(initialText: title, onChanged: (value) => title = value)],
            ),
            FormLine(
              title: Text("$tr_script.notation.tooltip_field.label".tr()),
              children: [
                DenseTextField(initialText: description, allowEmpty: true, onChanged: (value) => description = value),
              ],
            ),
          ],
        ),
        const SizedBox(height: 32),
        FormGroup(
          title: Text("$tr_script.code.label".tr()),
          description: Row(
            children: [
              Expanded(child: Text("$tr_script.code.description".tr())),
              _CopyButton(text: () => _codeController.text),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextField(
                controller: _codeController,
                maxLines: null,
                minLines: 12,
                style: GoogleFonts.mPlus1Code(fontSize: 15),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          clipBehavior: Clip.antiAlias,
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ExpansionTile(
            title: Text("$tr_script.name_lookup.label".tr()),
            subtitle: Text("$tr_script.name_lookup.description".tr()),
            expandedAlignment: Alignment.centerLeft,
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: const [_NameLookup()],
          ),
        ),
        const SizedBox(height: 32),
        FormGroup(
          title: Text("$tr_script.preview.label".tr()),
          description: Text("$tr_script.preview.description".tr()),
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _running ? null : _evaluate,
                  icon: _running
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow),
                  label: Text("$tr_script.preview.button".tr()),
                ),
              ),
            ),
            if (_result != null)
              _PreviewPanel(
                result: _result!,
                recordCount: ref.read(charaDetailRecordStorageProvider).length,
                title: title,
                refBase: ref.base,
              ),
          ],
        ),
      ],
    );
  }
}

class _PreviewPanel extends StatelessWidget {
  final ScriptPreviewResult result;
  final int recordCount;
  final String title;
  final RefBase refBase;

  const _PreviewPanel({required this.result, required this.recordCount, required this.title, required this.refBase});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (result.compileError != null) {
      return _message(theme, "$tr_script.preview.compile_error".tr(), result.compileError!, theme.colorScheme.error);
    }
    if (result.timedOut) {
      return _message(theme, "$tr_script.preview.timeout".tr(), '', theme.colorScheme.error);
    }
    final firstError = result.rows
        .firstWhere((r) => r.error != null, orElse: () => const ScriptCellResult(visible: true, display: ''))
        .error;
    final estTotal = (result.microsPerRecord * recordCount).round();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "$tr_script.preview.estimated_total".tr(
              namedArgs: {"count": "$recordCount", "time": _formatMicros(estTotal)},
            ),
          ),
          if (estTotal > _costWarnMicros)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text("$tr_script.preview.cost_warning".tr(), style: TextStyle(color: theme.colorScheme.tertiary)),
            ),
          if (firstError != null)
            _message(theme, "$tr_script.preview.runtime_error".tr(), firstError, theme.colorScheme.error),
          if (recordCount == 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                "$tr_script.preview.zero_records_warning".tr(),
                style: TextStyle(color: theme.colorScheme.tertiary, fontWeight: FontWeight.bold),
              ),
            ),
          if (result.ok && recordCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text("$tr_script.preview.ok".tr(), style: TextStyle(color: theme.colorScheme.primary)),
            ),
          const SizedBox(height: 8),
          _PreviewGrid(refBase: refBase, title: title, rows: result.rows),
        ],
      ),
    );
  }

  Widget _message(ThemeData theme, String title, String body, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(color: color, fontWeight: FontWeight.bold),
              ),
              if (body.isNotEmpty) _CopyButton(text: () => body, color: color),
            ],
          ),
          if (body.isNotEmpty)
            Text(
              body,
              style: GoogleFonts.mPlus1Code(textStyle: theme.textTheme.bodySmall, color: color),
            ),
        ],
      ),
    );
  }
}

/// Renders the visible preview rows in a real [TrinaGrid], built from the spec's
/// own [ScriptColumnSpec.plutoColumn]/[ScriptColumnSpec.plutoCell] and styled
/// like the production data table, so the preview is the actual table widget —
/// not an approximation — including header, sorting, alternating rows, and the
/// cell renderer (colors, icons, backgrounds, ⚠ markers).
class _PreviewGrid extends StatelessWidget {
  final RefBase refBase;
  final String title;
  final List<ScriptCellResult> rows;

  const _PreviewGrid({required this.refBase, required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Production hides filtered-out rows; mirror that. Error rows stay visible
    // (they render a ⚠ marker), matching the grid.
    final visible = rows.where((r) => r.visible).toList();
    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text("$tr_script.preview.no_rows".tr(), style: TextStyle(color: theme.disabledColor)),
      );
    }
    // The check already ran against every record; the grid only renders a capped
    // window so a large result set stays responsive in the dialog.
    final truncated = visible.length > _previewDisplayLimit;
    final shown = truncated ? visible.take(_previewDisplayLimit).toList() : visible;

    // A throwaway spec drives the production rendering path. plutoColumn/plutoCell
    // for a script column read no providers, so the RefBase is only a pass-through.
    final spec = ScriptColumnSpec(id: 'preview', title: title, source: '');
    spec._applyHints(shown);
    final column = spec.plutoColumn(refBase);
    final trinaRows = [
      for (final result in shown) TrinaRow(cells: {spec.id: spec.plutoCell(refBase, result)}),
    ];

    final grid = SizedBox(
      height: 280,
      child: TrinaGrid(
        // Key on every rendered field: TrinaGrid caches its rows in the state
        // manager and won't refresh unless the key changes, so any styling tweak
        // (e.g. background only) must alter the key.
        key: ValueKey(
          Object.hashAll(
            shown.map(
              (r) => '${r.display}|${r.sortValue}|${r.color}|${r.background}|${r.icon}|${r.iconColor}|${r.error}',
            ),
          ),
        ),
        columns: [column],
        rows: trinaRows,
        mode: TrinaGridMode.readOnly,
        configuration: TrinaGridConfiguration(
          scrollbar: const TrinaGridScrollbarConfig(isAlwaysShown: true, radius: 8, thickness: 12),
          style: TrinaGridStyleConfig(
            enableCellBorderVertical: false,
            gridBackgroundColor: theme.colorScheme.surface,
            rowColor: theme.colorScheme.surface,
            evenRowColor: theme.colorScheme.stripedRowColor,
            gridBorderColor: theme.colorScheme.outline,
            columnTextStyle: theme.textTheme.titleSmall!,
            cellTextStyle: theme.textTheme.bodyMedium!,
          ),
        ),
        onLoaded: (event) => event.stateManager.autoFitColumns(),
      ),
    );
    if (!truncated) return grid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            "$tr_script.preview.showing_first".tr(
              namedArgs: {"shown": "${shown.length}", "total": "${visible.length}"},
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ),
        grid,
      ],
    );
  }
}

// --- Builder ----------------------------------------------------------------

class ScriptColumnBuilder extends ColumnBuilder {
  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  ScriptColumnBuilder({required this.title, required this.category, this.type = ColumnBuilderType.normal});

  @override
  ScriptColumnSpec build(RefBase ref) {
    return ScriptColumnSpec(
      id: const Uuid().v4(),
      title: title,
      source:
          "bool filter(CharaRecord r) {\n  return true;\n}\n\ndynamic display(CharaRecord r) {\n  return r.status.speed;\n}\n",
    );
  }
}
