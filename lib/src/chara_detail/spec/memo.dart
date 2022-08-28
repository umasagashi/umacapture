import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_memo = "pages.chara_detail.column_predicate.memo";

@jsonSerializable
class RegExpPredicate {
  final RegExp? pattern;

  RegExpPredicate({
    this.pattern,
  });

  bool apply(String? value) {
    return pattern?.hasMatch(value ?? "") ?? true;
  }

  RegExpPredicate copyWith({
    RegExp? pattern,
  }) {
    return RegExpPredicate(
      pattern: pattern ?? this.pattern,
    );
  }
}

class MemoCellData implements CellData {
  final String? value;

  @override
  final Predicate<PlutoGridOnSelectedEvent>? onSelected;

  @override
  String get csv => value ?? "";

  MemoCellData(this.value, this.onSelected);
}

@jsonSerializable
@Json(discriminatorValue: "MemoColumnSpec")
class MemoColumnSpec extends ColumnSpec<String?> {
  final Parser parser;
  final RegExpPredicate predicate;
  final String storageKey;

  @override
  final String id;

  @override
  final String title;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  MemoColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    required this.storageKey,
  });

  MemoColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    RegExpPredicate? predicate,
    String? storageKey,
  }) {
    return MemoColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      storageKey: storageKey ?? this.storageKey,
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
  PlutoCell plutoCell(RefBase ref, String? value) {
    return PlutoCell(
      value: value ?? "_" * 20,
    )..setUserData(MemoCellData(
        value,
        (PlutoGridOnSelectedEvent event) {
          final record = event.row!.getUserData<CharaDetailRecord>()!;
          final memos = ref.read(charaDetailRecordMemoProvider(storageKey));
          _RecordMemoDialog.show(
            ref,
            recordId: record.id,
            storageKey: storageKey,
            initialMemo: memos.data[record.id] ?? "",
          );
          return true;
        },
      ));
  }

  @override
  PlutoColumn plutoColumn(RefBase ref) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.text(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      renderer: (PlutoColumnRendererContext context) {
        final data = context.cell.getUserData<MemoCellData>()!;
        if (data.value == null) {
          return Opacity(opacity: 0.4, child: Text("$tr_memo.cell.description".tr()));
        } else {
          return Text(data.value!);
        }
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    if (predicate.pattern?.pattern.isEmpty ?? true) {
      return "Any";
    }
    return 'Pattern: "${predicate.pattern?.pattern}"';
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return MemoColumnSelector(
      specId: id,
      onDecided: onDecided,
      storageKey: storageKey,
    );
  }
}

class _RecordMemoDialog extends ConsumerStatefulWidget {
  final String recordId;
  final String storageKey;
  final String initialMemo;

  const _RecordMemoDialog({
    Key? key,
    required this.recordId,
    required this.storageKey,
    required this.initialMemo,
  }) : super(key: key);

  static void show(
    RefBase ref, {
    required String recordId,
    required String storageKey,
    required String initialMemo,
  }) {
    CardDialog.show(ref, (_) {
      return _RecordMemoDialog(
        recordId: recordId,
        storageKey: storageKey,
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
    final recordStorage = ref.watch(charaDetailRecordStorageProvider.notifier);
    final record = recordStorage.getBy(id: widget.recordId)!;
    final iconPath = recordStorage.traineeIconPathOf(record);
    final memoStorage = ref.read(charaDetailRecordMemoProvider(widget.storageKey).notifier);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 800,
        maxHeight: 400,
      ),
      child: CardDialog(
        dialogTitle: memoStorage.title,
        closeButtonTooltip: "$tr_memo.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.file(iconPath.toFile()),
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
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_circle),
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

  const _PatternSelector({
    Key? key,
    required this.specId,
    required this.onDecided,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _PatternSelectorState();
}

class _PatternSelectorState extends ConsumerState<_PatternSelector> {
  late String pattern;

  @override
  void initState() {
    super.initState();
    pattern = _clonedSpecProvider.read(ref, widget.specId).predicate.pattern?.pattern ?? "";
    widget.onDecided.addListener(() {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(predicate: spec.predicate.copyWith(pattern: RegExp(pattern)));
      });
    });
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

  const _NotationSelector({
    required this.specId,
    required this.onDecided,
    required this.storageKey,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;

  @override
  void initState() {
    super.initState();
    title = _clonedSpecProvider.read(ref, widget.specId).title;
    widget.onDecided.addListener(() {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });

      final memoController = ref.read(charaDetailRecordMemoProvider(widget.storageKey).notifier);
      memoController.updateTitle(title: title);

      final memoStorageController = ref.read(charaDetailRecordMemoStorageDataProvider.notifier);
      memoStorageController.update((state) {
        final index = state.indexWhere((e) => e.key == (widget.storageKey));
        state[index] = state[index].copyWith(title: title);
        return [...state];
      });
    });
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
      ],
    );
  }
}

class _StorageController extends ConsumerWidget {
  final String specId;
  final String storageKey;

  const _StorageController({
    required this.specId,
    required this.storageKey,
  });

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
              storageFile.deleteSync();
            }

            ref.read(currentColumnSpecsProvider.notifier).removeIfExists(specId);
            CardDialog.dismiss(ref.base);
          },
          child: Text("$tr_memo.storage.delete.button".tr()),
        )
      ],
    );
  }
}

class MemoColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;
  final String storageKey;

  const MemoColumnSelector({
    Key? key,
    required this.specId,
    required this.onDecided,
    required this.storageKey,
  }) : super(key: key);

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
