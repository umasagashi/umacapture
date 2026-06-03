import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart' hide tr_common;
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/callback.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'character.mapper.dart';

// ignore: constant_identifier_names
const tr_character = "pages.chara_detail.column_predicate.character";

@MappableClass()
class CharacterCardPredicate with CharacterCardPredicateMappable {
  final Set<int> rejects;

  CharacterCardPredicate({this.rejects = const {}});

  CharacterCardPredicate.any() : rejects = {};

  bool apply(int value) {
    return !rejects.contains(value);
  }
}

class CharacterCardCellData implements CellData {
  final String name;

  CharacterCardCellData(this.name);

  @override
  String get csv => name;

  @override
  Predicate<TrinaGridOnSelectedEvent>? get onSelected => null;
}

@MappableClass(discriminatorValue: 'CharacterCardColumnSpec')
class CharacterCardColumnSpec extends ColumnSpec<int> with CharacterCardColumnSpecMappable {
  final Parser parser;
  final CharacterCardPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  CharacterCardColumnSpec({required this.id, required this.title, required this.parser, required this.predicate});

  CharacterCardColumnSpec copyWith({String? id, String? title, Parser? parser, CharacterCardPredicate? predicate}) {
    return CharacterCardColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  List<int> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<int>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(RefBase ref, List<int> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  TrinaCell plutoCell(RefBase ref, int value) {
    final card = ref.watch(charaCardInfoProvider)[value];
    return TrinaCell(value: card.sortKey)..setUserData(CharacterCardCellData(card.names.first));
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    final recordRootDir = ref.watch(pathInfoProvider).charaDetailActiveDir;
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.number(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (TrinaColumnRendererContext context) {
        final record = context.row.getUserData<CharaDetailRecord>()!;
        final icon = Image.file((recordRootDir.filePath(record.traineeIconPath)).toFile());
        return record.isFriend ? _FriendMarkedIcon(icon: icon) : icon;
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    final cards = ref.watch(charaCardInfoProvider).sortedBy<num>((e) => e.sortKey);
    const sep = "\n";
    if (predicate.rejects.isEmpty) {
      return "Any";
    } else if (predicate.rejects.length >= cards.length / 2) {
      final accepted = cards.where((e) => !predicate.rejects.contains(e.sid));
      return "${"$tr_character.tooltip.accept".tr()}:$sep${accepted.map((e) => e.names.first).join(sep)}";
    } else {
      final rejected = cards.where((e) => predicate.rejects.contains(e.sid));
      return "${"$tr_character.tooltip.reject".tr()}:$sep${rejected.map((e) => e.names.first).join(sep)}";
    }
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return CharacterCardColumnSelector(specId: id, onDecided: onDecided);
  }
}

/// A trainee icon with a pink "rental" banner across its bottom edge, marking a
/// friend's (practice-partner) record. The banner is overlaid at display time; the
/// underlying `trainee.jpg` is never modified.
class _FriendMarkedIcon extends StatelessWidget {
  final Widget icon;

  const _FriendMarkedIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        icon,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: FractionallySizedBox(
            widthFactor: 0.6,
            child: Container(
              decoration: const ShapeDecoration(color: Color(0xFFEC6A8E), shape: StadiumBorder()),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  "$tr_character.marker.friend".tr(),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<CharacterCardColumnSpec>();

class _CharaCardChip extends ConsumerWidget {
  final String specId;
  final AvailableCharaCardInfo card;
  final bool selected;

  const _CharaCardChip({required this.specId, required this.card, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: FilterChip(
            label: Padding(padding: const EdgeInsets.only(left: 36), child: Text(card.cardInfo.names.first)),
            backgroundColor: selected ? null : theme.colorScheme.surfaceContainerLow,
            showCheckmark: false,
            selected: selected,
            onSelected: (selected) {
              _clonedSpecProvider.update(ref, specId, (spec) {
                return spec.copyWith(
                  predicate: CharacterCardPredicate(
                    rejects: Set.from(spec.predicate.rejects)..toggle(card.cardInfo.sid, shouldExists: selected),
                  ),
                );
              });
            },
          ),
        ),
        IgnorePointer(
          child: CircleAvatar(
            backgroundColor: theme.chipTheme.selectedColor ?? theme.colorScheme.primaryContainer,
            radius: 24,
            child: ClipOval(
              child: Align(
                alignment: Alignment.bottomCenter,
                widthFactor: 0.9,
                heightFactor: 0.9,
                child: Image.file(card.iconPath.toFile()),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CharacterCardSelector extends ConsumerStatefulWidget {
  final String specId;

  const _CharacterCardSelector({required this.specId});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharacterCardSelectorState();
}

class _CharacterCardSelectorState extends ConsumerState<_CharacterCardSelector> {
  String textQuery = "";

  List<AvailableCharaCardInfo> _filterCards(List<AvailableCharaCardInfo> cards) {
    final normalizedQuery = textQuery.toLowerCase().trim();
    if (normalizedQuery.isEmpty) {
      return cards;
    }
    return cards.where((card) {
      return card.cardInfo.names.any((name) => name.toLowerCase().contains(normalizedQuery));
    }).toList();
  }

  Widget _controlWidget(BuildContext context, List<AvailableCharaCardInfo> candidates) {
    final theme = Theme.of(context);
    const EdgeInsetsGeometry padding = EdgeInsets.all(8);
    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ActionChip(
            padding: padding,
            avatar: const Icon(Icons.select_all, size: 20),
            label: Text("$tr_common.selector.control.select_all.label".tr()),
            tooltip: "$tr_common.selector.control.select_all.tooltip".tr(),
            side: BorderSide.none,
            backgroundColor: theme.colorScheme.primaryContainer,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onPressed: () {
              _clonedSpecProvider.update(ref, widget.specId, (spec) {
                return spec.copyWith(
                  predicate: CharacterCardPredicate(
                    rejects: {...spec.predicate.rejects}..removeAll(candidates.map((e) => e.cardInfo.sid)),
                  ),
                );
              });
            },
          ),
          ActionChip(
            padding: padding,
            avatar: const Icon(Icons.deselect, size: 20),
            label: Text("$tr_common.selector.control.deselect_all.label".tr()),
            tooltip: "$tr_common.selector.control.deselect_all.tooltip".tr(),
            side: BorderSide.none,
            backgroundColor: theme.colorScheme.primaryContainer,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onPressed: () {
              _clonedSpecProvider.update(ref, widget.specId, (spec) {
                return spec.copyWith(
                  predicate: CharacterCardPredicate(
                    rejects: {...spec.predicate.rejects}..addAll(candidates.map((e) => e.cardInfo.sid)),
                  ),
                );
              });
            },
          ),
          Tooltip(
            message: "$tr_common.selector.control.text_search.tooltip".tr(),
            child: DenseTextField(
              initialText: "",
              debounce: const Duration(milliseconds: 200),
              hintText: "$tr_common.selector.control.text_search.label".tr(),
              allowEmpty: true,
              onChanged: (text) => setState(() => textQuery = text),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final charaCards = ref.watch(availableCharaCardsProvider);
    final rejected = _clonedSpecProvider.watch(ref, widget.specId).predicate.rejects;
    final candidates = _filterCards(charaCards);
    return FormGroup(
      title: Text("$tr_character.selection.label".tr()),
      description: Text("$tr_character.selection.description".tr()),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
          child: _controlWidget(context, candidates),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                if (candidates.isEmpty) Text("$tr_common.selector.not_found_message".tr()),
                for (final card in candidates)
                  _CharaCardChip(specId: widget.specId, card: card, selected: !rejected.contains(card.cardInfo.sid)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _NotationSelector({required this.specId, required this.onDecided});

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
    });
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_character.notation.label".tr()),
      description: Text("$tr_character.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_character.notation.title.label".tr()),
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

class CharacterCardColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const CharacterCardColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _CharacterCardSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class CharacterCardColumnBuilder extends ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  CharacterCardColumnBuilder({required this.title, required this.category, required this.parser});

  @override
  CharacterCardColumnSpec build(RefBase ref) {
    return CharacterCardColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: CharacterCardPredicate.any(),
    );
  }
}
