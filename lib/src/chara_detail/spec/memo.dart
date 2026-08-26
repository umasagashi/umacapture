import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
// For [commitStorageChange]: the rating and memo columns are one storage mechanism over
// two files, and a refusal has to reach the user in one voice from both.
import '/src/chara_detail/spec/rating.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';

part 'memo.mapper.dart';

// ignore: constant_identifier_names
const tr_memo = "pages.chara_detail.column_predicate.memo";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

/// Persists [memo] for [recordId], announcing a refusal. Answers whether it was saved.
bool saveMemo(RefBase ref, {required String storageKey, required String recordId, required String? memo}) {
  final controller = ref.read(charaDetailRecordMemoProvider(storageKey).notifier);
  return commitStorageChange(() => controller.updateMemo(recordId: recordId, memo: memo));
}

/// The title the memo dialog is headed with, or null when the storage failed to load.
///
/// Asked here, at the tap, rather than inside the dialog: the title is the one read
/// that refuses a storage which did not load ([CharaDetailRecordMemoController.title]
/// throws rather than answer with the default title), and a throw from inside the
/// dialog's `build` would replace the dialog with a grey error box that explains
/// nothing. Null means the user has already been told, and the dialog must not open —
/// every memo typed into it would be refused.
String? memoDialogTitle(RefBase ref, String storageKey) {
  final controller = ref.read(charaDetailRecordMemoProvider(storageKey).notifier);
  String? title;
  commitStorageChange(() => title = controller.title);
  return title;
}

@MappableClass()
class RegExpPredicate with RegExpPredicateMappable {
  final RegExp? pattern;

  RegExpPredicate({this.pattern});

  bool apply(String? value) {
    return pattern?.hasMatch(value ?? "") ?? true;
  }

  RegExpPredicate copyWith({RegExp? pattern}) {
    return RegExpPredicate(pattern: pattern ?? this.pattern);
  }
}

class MemoCellData implements CellData {
  final String? value;

  @override
  final CellSelectedCallback? onSelected;

  @override
  String get csv => value ?? "";

  MemoCellData(this.value, this.onSelected);
}

@MappableClass(discriminatorValue: 'MemoColumnSpec', ignoreNull: true)
class MemoColumnSpec extends ColumnSpec<String?> with MemoColumnSpecMappable {
  final Parser parser;
  final RegExpPredicate predicate;
  final String storageKey;

  @override
  final String id;

  @override
  final String title;

  /// User-provided tooltip text shown on the column chip above the filter
  /// condition. Null/empty means "no tooltip"; omitted from the serialized map
  /// (via the class-level `ignoreNull`) so pre-existing specs are never flagged
  /// as broken by [isSpecMapIncomplete].
  @override
  final String? description;

  @override
  final bool hidden;

  @override
  final double? width;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  MemoColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    required this.storageKey,
    this.description,
    this.hidden = false,
    this.width,
  });

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  bool get hasFilter => true;

  @override
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => copyWith(predicate: RegExpPredicate());

  @override
  String measuredText(TrinaCell? cell, String formatted) =>
      cell?.getUserData<MemoCellData>()?.value == null ? "$tr_memo.cell.description".tr() : formatted;

  MemoColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    RegExpPredicate? predicate,
    String? storageKey,
    Object? description = _unset,
    bool? hidden,
    Object? width = _unset,
  }) {
    return MemoColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      storageKey: storageKey ?? this.storageKey,
      description: identical(description, _unset) ? this.description : description as String?,
      hidden: hidden ?? this.hidden,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  @override
  List<String?> parse(RefBase ref, List<CharaDetailRecord> records) {
    // The per-key controller is an AsyncNotifier (its build reads the memo file
    // async, so web can load it from OPFS). Until the first load lands, fall back
    // to empty data; when it lands, the watch triggers a rebuild with real values.
    final memos = ref.watch(charaDetailRecordMemoProvider(storageKey)).value ?? MemoData.empty;
    return List<String?>.from(records.map((e) => memos.data[parser.parse(e)]));
  }

  @override
  List<bool> evaluate(RefBase ref, List<String?> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  TrinaCell plutoCell(RefBase _, String? value) {
    // The onSelected closure must NOT capture this build-scoped grid ref: it is
    // disposed when [currentGridProvider] rebuilds (a column resize, a memo save),
    // and a kept cell would then read through a dead ref. The table passes a live
    // ref in at tap time instead (see [CellSelectedCallback]).
    return TrinaCell(value: value ?? "_" * 20)..setUserData(
      MemoCellData(value, (RefBase ref, TrinaGridOnSelectedEvent event) {
        // Asked before anything else is looked up: a dialog whose memos would all be
        // refused must not open at all, and the refusal belongs on the tap that asked
        // for it. Answering `true` still counts the tap as handled, so the grid does
        // not fall through to its default cell action on top of the warning.
        final dialogTitle = memoDialogTitle(ref, storageKey);
        if (dialogTitle == null) {
          return true;
        }
        final record = event.row!.getUserData<CharaDetailRecord>()!;
        final memos = ref.read(charaDetailRecordMemoProvider(storageKey)).value ?? MemoData.empty;
        _RecordMemoDialog.show(
          ref,
          recordId: record.id,
          storageKey: storageKey,
          dialogTitle: dialogTitle,
          initialMemo: memos.data[record.id] ?? "",
        );
        return true;
      }),
    );
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.text(),
      width: width ?? TrinaGridSettings.columnWidth,
      enableContextMenu: false,
      enableDropToResize: true,
      enableColumnDrag: false,
      renderer: (TrinaColumnRendererContext context) {
        final data = context.cell.getUserData<MemoCellData>()!;
        if (data.value == null) {
          return CellText("$tr_memo.cell.description".tr(), opacity: 0.4);
        } else {
          return CellText(data.value!);
        }
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    // The user note ([description]) is prepended centrally by the chip's tooltip
    // composition, so this returns only the filter condition.
    return (predicate.pattern?.pattern.isEmpty ?? true) ? "Any" : 'Pattern: "${predicate.pattern?.pattern}"';
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return MemoColumnSelector(specId: id, onDecided: onDecided, storageKey: storageKey);
  }
}

class _RecordMemoDialog extends ConsumerStatefulWidget {
  final String recordId;
  final String storageKey;

  /// Resolved by [memoDialogTitle] before this dialog was opened, so the read that
  /// can refuse an unreadable storage happens on the tap rather than in `build`.
  final String dialogTitle;
  final String initialMemo;

  const _RecordMemoDialog({
    required this.recordId,
    required this.storageKey,
    required this.dialogTitle,
    required this.initialMemo,
  });

  static void show(
    RefBase ref, {
    required String recordId,
    required String storageKey,
    required String dialogTitle,
    required String initialMemo,
  }) {
    CardDialog.show(ref, (_) {
      return _RecordMemoDialog(
        recordId: recordId,
        storageKey: storageKey,
        dialogTitle: dialogTitle,
        initialMemo: initialMemo,
      );
    });
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _RecordMemoDialogState();
}

class _RecordMemoDialogState extends ConsumerState<_RecordMemoDialog> {
  late final TextEditingController controller;
  late final FocusNode focusNode;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialMemo);
    focusNode = FocusNode();
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Resolve from the displayed source so the dialog works for archived records.
    final source = ref.read(recordSourceProvider);
    final record = ref.read(displayedRecordsProvider).firstWhereOrNull((e) => e.id == widget.recordId);
    if (record == null) {
      return dismissForMissingRecord(ref.base);
    }
    final iconPath = traineeIconPathIn(recordDirOf(ref.read(pathInfoProvider), source, record));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 800, maxHeight: 400),
      child: CardDialog(
        dialogTitle: widget.dialogTitle,
        closeButtonTooltip: "$tr_memo.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RecordImage(
                iconPath,
                // Archived records keep their trainee icon, but guard against a
                // missing/corrupt file so the dialog shows a placeholder instead
                // of a red error box.
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Symbols.hide_image_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(record.evaluationValueLabel, style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  focusNode: focusNode,
                  controller: controller,
                  onSubmitted: (value) {
                    saveMemo(ref.base, storageKey: widget.storageKey, recordId: record.id, memo: controller.text);
                    CardDialog.dismiss(ref.base);
                  },
                ),
              ),
            ],
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: "$tr_memo.dialog.ok_button.tooltip".tr(),
              child: FilledButton.icon(
                icon: const Icon(Symbols.check_circle_rounded),
                label: Text("$tr_memo.dialog.ok_button.label".tr()),
                onPressed: () {
                  saveMemo(ref.base, storageKey: widget.storageKey, recordId: record.id, memo: controller.text);
                  CardDialog.dismiss(ref.base);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<MemoColumnSpec>();

class _PatternSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _PatternSelector({required this.specId, required this.onDecided});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _PatternSelectorState();
}

class _PatternSelectorState extends ConsumerState<_PatternSelector> {
  late String pattern;
  late final VoidCallback _commitPattern;

  @override
  void initState() {
    super.initState();
    pattern = _clonedSpecProvider.read(ref, widget.specId).predicate.pattern?.pattern ?? "";
    // Gate the dialog's OK button on the pattern compiling: an invalid regex must
    // never reach `_commitPattern`. Seed the initial state from the existing value.
    WidgetsBinding.instance.addPostFrameCallback((_) => _setSaveEnabled(_isValidPattern(pattern)));
    _commitPattern = () {
      // Guard `RegExp(pattern)`: the OK button is gated on a valid pattern, but the
      // Reset button flushes this listener unconditionally, so an invalid pattern
      // can still arrive here. On failure, leave the predicate unchanged.
      final RegExp compiled;
      try {
        compiled = RegExp(pattern);
      } on FormatException {
        return;
      }
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(predicate: spec.predicate.copyWith(pattern: compiled));
      });
    };
    widget.onDecided.addListener(_commitPattern);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitPattern);
    super.dispose();
  }

  bool _isValidPattern(String value) {
    // Empty is valid: `RegExp("")` matches everything, mirroring the null-pattern
    // "Any" case in `RegExpPredicate.apply`.
    try {
      RegExp(value);
      return true;
    } on FormatException {
      return false;
    }
  }

  void _setSaveEnabled(bool value) {
    if (!mounted) return;
    ref.read(columnSpecSaveEnabledProvider(widget.specId).notifier).set(value);
  }

  @override
  Widget build(BuildContext context) {
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return FormGroup(
      title: Text("$tr_memo.pattern.label".tr()),
      description: Text("$tr_memo.pattern.description".tr()),
      children: [
        FormTile(
          title: Text("$tr_memo.pattern.regexp.label".tr()),
          description: Text("$tr_memo.pattern.regexp.description".tr()),
          trailing: DenseTextField(
            initialText: predicate.pattern?.pattern ?? "",
            allowEmpty: true,
            hintText: ".*",
            onChanged: (value) {
              pattern = value;
              _setSaveEnabled(_isValidPattern(value));
            },
          ),
        ),
      ],
    );
  }
}

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;
  final String storageKey;

  const _NotationSelector({required this.specId, required this.onDecided, required this.storageKey});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;
  late final VoidCallback _commitTitle;

  @override
  void initState() {
    super.initState();
    final spec = _clonedSpecProvider.read(ref, widget.specId);
    title = spec.title;
    _commitTitle = () {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });

      final memoController = ref.read(charaDetailRecordMemoProvider(widget.storageKey).notifier);
      commitStorageChange(() => memoController.updateTitle(title: title));

      final memoStorageController = ref.read(charaDetailRecordMemoStorageDataProvider.notifier);
      memoStorageController.update((state) {
        try {
          final index = state.indexWhere((e) => e.key == (widget.storageKey));
          state[index] = state[index].copyWith(title: title);
          return [...state];
        } catch (exception, stackTrace) {
          logger.e(
            "Failed to change title. state=${state.map((e) => e.key).join(", ")}, widget=${widget.storageKey}",
            exception,
            stackTrace,
          );
          captureException(exception, stackTrace);
          return state;
        }
      });
    };
    widget.onDecided.addListener(_commitTitle);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitTitle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_common.notation.label".tr()),
      description: Text("$tr_common.notation.description".tr()),
      children: [
        FormTile(
          title: Text("$tr_common.notation.title.label".tr()),
          description: Text("$tr_common.notation.title.description".tr()),
          trailing: DenseTextField(
            initialText: title,
            minWidth: 140,
            onChanged: (value) {
              title = value;
            },
          ),
        ),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class _StorageController extends ConsumerWidget {
  final String specId;
  final String storageKey;

  const _StorageController({required this.specId, required this.storageKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormGroup(
      title: Text("$tr_memo.storage.label".tr()),
      description: Text("$tr_memo.storage.description".tr()),
      children: [
        TextButton(
          onPressed: () {},
          onLongPress: () async {
            final memoStorageController = ref.read(charaDetailRecordMemoStorageDataProvider.notifier);
            memoStorageController.update((state) {
              state.removeWhere((e) => e.key == storageKey);
              return [...state];
            });

            final storageFile = ref.read(pathInfoProvider).charaDetailMemoDir.filePath("$storageKey.json");
            if (await storageFile.exists()) {
              await storageFile.deleteWithCheck();
            }

            ref.read(currentColumnSpecsLoaderProvider.notifier).removeIfExists(specId);
            CardDialog.dismiss(ref.base);
          },
          child: Text("$tr_memo.storage.delete.button".tr()),
        ),
      ],
    );
  }
}

class MemoColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;
  final String storageKey;

  const MemoColumnSelector({super.key, required this.specId, required this.onDecided, required this.storageKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _PatternSelector(specId: specId, onDecided: onDecided),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided, storageKey: storageKey),
        const SizedBox(height: 32),
        _StorageController(specId: specId, storageKey: storageKey),
      ],
    );
  }
}

class MemoColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final String? storageKey;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  MemoColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    required this.type,
    this.storageKey,
  });

  @override
  MemoColumnSpec build(RefBase ref) {
    String? actualKey = storageKey;
    if (actualKey == null) {
      actualKey = const Uuid().v4();
      final controller = ref.read(charaDetailRecordMemoStorageDataProvider.notifier);
      controller.update((e) => [...e, MemoStorageData(key: actualKey!, title: title)]);
    }
    return MemoColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: RegExpPredicate(),
      storageKey: actualKey,
    );
  }
}
