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
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

part 'memo.mapper.dart';

// ignore: constant_identifier_names
const tr_memo = "pages.chara_detail.column_predicate.memo";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

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
    final memos = ref.watch(charaDetailRecordMemoProvider(storageKey));
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
        final record = event.row!.getUserData<CharaDetailRecord>()!;
        final memos = ref.read(charaDetailRecordMemoProvider(storageKey));
        _RecordMemoDialog.show(
          ref,
          recordId: record.id,
          storageKey: storageKey,
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
  final String initialMemo;

  const _RecordMemoDialog({required this.recordId, required this.storageKey, required this.initialMemo});

  static void show(RefBase ref, {required String recordId, required String storageKey, required String initialMemo}) {
    CardDialog.show(ref, (_) {
      return _RecordMemoDialog(recordId: recordId, storageKey: storageKey, initialMemo: initialMemo);
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
    final memoStorage = ref.read(charaDetailRecordMemoProvider(widget.storageKey).notifier);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 800, maxHeight: 400),
      child: CardDialog(
        dialogTitle: memoStorage.title,
        closeButtonTooltip: "$tr_memo.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.file(
                iconPath.toFile(),
                // Archived records keep their trainee icon, but guard against a
                // missing/corrupt file so the dialog shows a placeholder instead
                // of a red error box.
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Symbols.hide_image_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(record.evaluationValue.toNumberString(), style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  focusNode: focusNode,
                  controller: controller,
                  onSubmitted: (value) {
                    memoStorage.update(recordId: record.id, memo: controller.text);
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
                  memoStorage.update(recordId: record.id, memo: controller.text);
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
    _commitPattern = () {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(predicate: spec.predicate.copyWith(pattern: RegExp(pattern)));
      });
    };
    widget.onDecided.addListener(_commitPattern);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitPattern);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return FormGroup(
      title: Text("$tr_memo.pattern.label".tr()),
      description: Text("$tr_memo.pattern.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_memo.pattern.regexp.label".tr()),
          children: [
            DenseTextField(
              initialText: predicate.pattern?.pattern ?? "",
              allowEmpty: true,
              hintText: ".*",
              onChanged: (value) {
                pattern = value;
              },
            ),
          ],
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
      memoController.updateTitle(title: title);

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
      title: Text("$tr_memo.notation.label".tr()),
      description: Text("$tr_memo.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_memo.notation.title.label".tr()),
          children: [
            DenseTextField(
              initialText: title,
              onChanged: (value) {
                title = value;
              },
            ),
          ],
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
          onLongPress: () {
            final memoStorageController = ref.read(charaDetailRecordMemoStorageDataProvider.notifier);
            memoStorageController.update((state) {
              state.removeWhere((e) => e.key == storageKey);
              return [...state];
            });

            final storageFile = ref.watch(pathInfoProvider).charaDetailMemoDir.filePath("$storageKey.json");
            if (storageFile.existsSync()) {
              storageFile.deleteSyncWithCheck();
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
