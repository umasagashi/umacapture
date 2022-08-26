import 'package:another_xlider/another_xlider.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_common = "pages.chara_detail.column_predicate.common";

class FormLine extends ConsumerWidget {
  final Widget title;
  final List<Widget> children;

  const FormLine({
    Key? key,
    required this.title,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Align(
        alignment: Alignment.topLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            title,
            ...children,
          ],
        ),
      ),
    );
  }
}

class FormGroup extends ConsumerWidget {
  final Widget title;
  final Widget? description;
  final List<Widget> children;

  const FormGroup({
    Key? key,
    required this.title,
    this.description,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            title,
            const Expanded(child: Divider(indent: 8)),
          ],
        ),
        if (description != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.topLeft,
              child: description,
            ),
          ),
        ...children,
      ],
    );
  }
}

class DenseTextField extends ConsumerWidget {
  final TextEditingController controller;
  final StringCallback onChanged;

  DenseTextField({
    Key? key,
    required String initialText,
    required this.onChanged,
  })  : controller = TextEditingController(text: initialText),
        super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IntrinsicWidth(
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          isDense: true,
          isCollapsed: true,
          contentPadding: const EdgeInsets.all(8).copyWith(right: 16),
          errorStyle: const TextStyle(fontSize: 0),
        ),
        autovalidateMode: AutovalidateMode.always,
        validator: (value) => (value == null || value.isEmpty) ? "title cannot be empty" : null,
        onChanged: (value) => onChanged(value),
      ),
    );
  }
}

class NoteCard extends ConsumerWidget {
  final Widget description;
  final List<Widget> children;

  const NoteCard({
    Key? key,
    required this.description,
    this.children = const [],
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.2),
        border: Border.all(color: theme.colorScheme.primaryContainer),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: description,
            ),
            if (children.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...children,
            ]
          ],
        ),
      ),
    );
  }
}

class TagSelector extends ConsumerWidget {
  final ProviderBase<List<Tag>> candidateTagsProvider;
  final StateProviderLike<Set<String>> selectedTagsProvider;

  const TagSelector({
    Key? key,
    required this.candidateTagsProvider,
    required this.selectedTagsProvider,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final candidateTags = ref.watch(candidateTagsProvider);
    final selectedTags = ref.watch(selectedTagsProvider.listenable);
    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tag in candidateTags)
            FilterChip(
              label: Text(tag.name),
              backgroundColor: selectedTags.contains(tag.id) ? null : theme.colorScheme.surfaceVariant,
              showCheckmark: false,
              selected: selectedTags.contains(tag.id),
              onSelected: (selected) {
                ref.read(selectedTagsProvider.notifier).update((tags) {
                  return Set.from(tags)..toggle(tag.id, shouldExists: !selected);
                });
              },
            ),
        ],
      ),
    );
  }
}

class ChoiceFormLine<T extends Enum> extends ConsumerWidget {
  final Widget title;
  final String prefix;
  final bool tooltip;
  final List<T> values;
  final T selected;
  final Set<T>? disabled;

  final Callback<T> onSelected;

  const ChoiceFormLine({
    Key? key,
    required this.title,
    required this.prefix,
    this.tooltip = true,
    required this.values,
    required this.selected,
    this.disabled,
    required this.onSelected,
  }) : super(key: key);

  Widget chip(BuildContext context, WidgetRef ref, T value) {
    final theme = Theme.of(context);
    final isDisabled = disabled?.contains(value) ?? false;
    final isSelected = value == selected;
    return Disabled(
      disabled: isDisabled,
      tooltip: isDisabled ? "$prefix.${value.name.snakeCase}.disabled_tooltip".tr() : "",
      child: ChoiceChip(
        label: Text("$prefix.${value.name.snakeCase}.label".tr()),
        tooltip: tooltip ? "$prefix.${value.name.snakeCase}.tooltip".tr() : "",
        backgroundColor: isSelected ? null : theme.colorScheme.surfaceVariant,
        selected: isSelected,
        onSelected: (_) => onSelected(value),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormLine(
      title: title,
      children: [
        for (final value in values) chip(context, ref, value),
      ],
    );
  }
}

class _SelectorChip extends ConsumerWidget {
  final Text label;
  final String tooltip;
  final bool selected;
  final ValueChanged<bool> onSelected;

  const _SelectorChip({
    Key? key,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return FilterChip(
      label: label,
      backgroundColor: selected ? null : theme.colorScheme.surfaceVariant,
      showCheckmark: false,
      tooltip: tooltip,
      selected: selected,
      onSelected: onSelected,
    );
  }
}

class _SelectorExpandButton extends ConsumerWidget {
  final VoidCallback onPressed;

  const _SelectorExpandButton({Key? key, required this.onPressed}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ActionChip(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          avatar: const Icon(Icons.expand_more),
          label: Text("$tr_common.selector.expand_button".tr()),
          side: BorderSide.none,
          backgroundColor: theme.colorScheme.primaryContainer.withOpacity(0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class SelectorWidget<T> extends ConsumerStatefulWidget {
  final Widget description;
  final List<T> candidates;
  final Set<int> selected;
  final Value2Callback<int, bool> onSelected;

  const SelectorWidget({
    Key? key,
    required this.description,
    required this.candidates,
    required this.selected,
    required this.onSelected,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SelectorWidgetState();
}

class _SelectorWidgetState extends ConsumerState<SelectorWidget> {
  late bool collapsed;

  @override
  void initState() {
    super.initState();
    collapsed = true;
  }

  @override
  Widget build(BuildContext context) {
    final needCollapse = collapsed && widget.candidates.length > 30;
    final reduced = needCollapse ? widget.candidates.partial(0, 30) : widget.candidates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
          child: widget.description,
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.candidates.isEmpty) Text("$tr_common.selector.not_found_message".tr()),
                for (final info in reduced)
                  _SelectorChip(
                    label: Text(info.label),
                    tooltip: info.tooltip,
                    selected: widget.selected.contains(info.sid),
                    onSelected: (selected) => widget.onSelected(info.sid, selected),
                  ),
                if (needCollapse) Text("${widget.candidates.length - reduced.length} more"),
              ],
            ),
          ),
        ),
        if (needCollapse)
          _SelectorExpandButton(
            onPressed: () {
              setState(() => collapsed = false);
            },
          ),
      ],
    );
  }
}

class CustomRangeSlider extends ConsumerStatefulWidget {
  final double min;
  final double max;
  final double step;
  final double start;
  final double end;
  final String Function(double) formatter;
  final Value2Callback<double, double> onChanged;

  const CustomRangeSlider({
    Key? key,
    required this.min,
    required this.max,
    required this.step,
    required this.start,
    required this.end,
    required this.formatter,
    required this.onChanged,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CustomRangeSliderState();
}

class _CustomRangeSliderState extends ConsumerState<CustomRangeSlider> {
  late double start;
  late double end;

  @override
  void initState() {
    super.initState();
    start = widget.start;
    end = widget.end;
  }

  Widget popup(double value) {
    if (value == widget.min) {
      return Text("$tr_common.range.popup.same_as_min".tr());
    } else if (value == widget.max) {
      return Text("$tr_common.range.popup.same_as_max".tr());
    } else {
      return Text(widget.formatter(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FlutterSlider(
      rangeSlider: true,
      jump: true,
      min: widget.min,
      max: widget.max,
      step: FlutterSliderStep(step: widget.step),
      handler: FlutterSliderHandler(
        child: Tooltip(
          message: "$tr_common.range.tooltip.min".tr(),
          child: Icon(
            Icons.arrow_right,
            color: theme.colorScheme.onPrimary,
          ),
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
      rightHandler: FlutterSliderHandler(
        child: Tooltip(
          message: "$tr_common.range.tooltip.max".tr(),
          child: Icon(
            Icons.arrow_left,
            color: theme.colorScheme.onPrimary,
          ),
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
      tooltip: FlutterSliderTooltip(
        alwaysShowTooltip: true,
        disableAnimation: true,
        custom: (value) => Chip(label: popup(value)),
      ),
      values: [start, end],
      onDragging: (handlerIndex, start, end) {
        widget.onChanged(start, end);
        setState(() {
          this.start = start;
          this.end = end;
        });
      },
    );
  }
}
