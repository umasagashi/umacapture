import 'dart:math';

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
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/theme_extensions.dart';

part 'character.mapper.dart';

// ignore: constant_identifier_names
const tr_character = "pages.chara_detail.column_predicate.character";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

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
  CellSelectedCallback? get onSelected => null;
}

@MappableClass(discriminatorValue: 'CharacterCardColumnSpec', ignoreNull: true)
class CharacterCardColumnSpec extends ColumnSpec<int> with CharacterCardColumnSpecMappable {
  final Parser parser;
  final CharacterCardPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final bool hidden;

  @override
  final String? description;

  @override
  final double? width;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  // Renders a fixed-size trainee portrait, not wrapping text.
  @override
  bool get wrapsText => false;

  CharacterCardColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    this.hidden = false,
    this.description,
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
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => copyWith(predicate: CharacterCardPredicate.any());

  CharacterCardColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    CharacterCardPredicate? predicate,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return CharacterCardColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
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
    // Resolve trainee icons from the currently displayed source: archived records
    // live under archive/, not active/.
    final pathInfo = ref.watch(pathInfoProvider);
    final recordRootDir = ref.watch(recordSourceProvider) == RecordSource.active
        ? pathInfo.charaDetailActiveDir
        : pathInfo.charaDetailArchiveDir;
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.number(),
      width: width ?? TrinaGridSettings.columnWidth,
      enableContextMenu: false,
      enableDropToResize: true,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (TrinaColumnRendererContext context) {
        final record = context.row.getUserData<CharaDetailRecord>()!;
        final icon = Image.file(
          (recordRootDir.filePath(record.traineeIconPath)).toFile(),
          // Archived records keep their trainee icon, but guard against a
          // missing/corrupt file so the cell shows a placeholder instead of a red
          // error box. Sized to the cell, not the larger dialog placeholder.
          errorBuilder: (context, error, stackTrace) =>
              Icon(Symbols.hide_image_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
        );
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
    // The portrait is a square fit to the cell, so its side is the smaller of the
    // available width and height — which shrinks/grows as the row height (or
    // column width) changes. Derive the banner's width, font, and padding from
    // that side so the rental marker resizes at the icon's scale instead of
    // staying pinned to a fixed font.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final side = (width.isFinite && height.isFinite) ? min(width, height) : (height.isFinite ? height : width);
        final bannerWidth = side * 0.75;
        final semantic = Theme.of(context).semantic;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            icon,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: bannerWidth,
                  decoration: ShapeDecoration(color: semantic.brandBanner, shape: const StadiumBorder()),
                  padding: EdgeInsets.symmetric(horizontal: bannerWidth * 0.08, vertical: bannerWidth * 0.02),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      "$tr_character.marker.friend".tr(),
                      style: TextStyle(
                        color: semantic.onBrandBanner,
                        fontWeight: FontWeight.bold,
                        fontSize: bannerWidth * 0.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
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
            avatar: const Icon(Symbols.select_all_rounded, size: 20),
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
            avatar: const Icon(Symbols.deselect_rounded, size: 20),
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
  late final VoidCallback _commitTitle;

  @override
  void initState() {
    super.initState();
    title = _clonedSpecProvider.read(ref, widget.specId).title;
    _commitTitle = () {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
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
