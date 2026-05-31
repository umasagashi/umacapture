import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// riverpod 3 moved ProviderListenable out of the default export surface.
import 'package:flutter_riverpod/misc.dart';
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
    super.key,
    required this.title,
    required this.children,
  });

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
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: title,
            ),
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
    super.key,
    required this.title,
    this.description,
    required this.children,
  });

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

class DenseTextField extends ConsumerStatefulWidget {
  final String? initialText;
  final TextEditingController? controller;
  final StringCallback onChanged;
  final Duration? debounce;
  final bool allowEmpty;
  final String? hintText;

  const DenseTextField({
    super.key,
    this.initialText,
    this.controller,
    required this.onChanged,
    this.debounce,
    this.allowEmpty = false,
    this.hintText,
  })  : assert((initialText == null) != (controller == null));

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => DenseTextFieldState();
}

class DenseTextFieldState extends ConsumerState<DenseTextField> {
  late final TextEditingController controller;
  Timer? debouncedOnChangedTimer;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      controller.dispose();
    }
    debouncedOnChangedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          isDense: true,
          isCollapsed: true,
          contentPadding: const EdgeInsets.all(8).copyWith(right: 16),
          errorStyle: const TextStyle(fontSize: 0),
          hintText: widget.hintText,
        ),
        autovalidateMode: AutovalidateMode.always,
        validator: (value) => (!widget.allowEmpty && (value == null || value.isEmpty)) ? "cannot be empty" : null,
        onChanged: (value) {
          if (widget.debounce != null) {
            debouncedOnChangedTimer?.cancel();
            debouncedOnChangedTimer = Timer(widget.debounce!, () => widget.onChanged(value));
          } else {
            widget.onChanged(value);
          }
        },
      ),
    );
  }
}

class NoteCard extends ConsumerWidget {
  final Widget description;
  final List<Widget> children;
  final Color? color;

  const NoteCard({
    super.key,
    required this.description,
    this.children = const [],
    this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final baseColor = color ?? theme.colorScheme.primaryContainer;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: baseColor),
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
  final ProviderListenable<List<Tag>> candidateTagsProvider;
  final NotifierProvider<TagSelectionNotifier, Set<String>> selectedTagsProvider;

  const TagSelector({
    super.key,
    required this.candidateTagsProvider,
    required this.selectedTagsProvider,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final candidateTags = ref.watch(candidateTagsProvider);
    final selectedTags = ref.watch(selectedTagsProvider);
    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tag in candidateTags)
            FilterChip(
              label: Text(tag.name),
              backgroundColor: selectedTags.contains(tag.id) ? null : theme.colorScheme.surfaceContainerHighest,
              showCheckmark: false,
              selected: selectedTags.contains(tag.id),
              onSelected: (selected) {
                ref.read(selectedTagsProvider.notifier).toggle(tag.id, shouldExists: !selected);
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
    super.key,
    required this.title,
    required this.prefix,
    this.tooltip = true,
    required this.values,
    required this.selected,
    this.disabled,
    required this.onSelected,
  });

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
        backgroundColor: isSelected ? null : theme.colorScheme.surfaceContainerHighest,
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
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return FilterChip(
      label: label,
      backgroundColor: selected ? null : theme.colorScheme.surfaceContainerHighest,
      showCheckmark: false,
      tooltip: tooltip,
      selected: selected,
      onSelected: onSelected,
    );
  }
}

class _SelectorExpandButton extends ConsumerWidget {
  final VoidCallback onPressed;

  const _SelectorExpandButton({required this.onPressed});

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
          backgroundColor: theme.colorScheme.primaryContainer,
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
  final Callback<Set<int>> onSelected;
  final Callback<String> onTextQueryChanged;

  const SelectorWidget({
    super.key,
    required this.description,
    required this.candidates,
    required this.selected,
    required this.onSelected,
    required this.onTextQueryChanged,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SelectorWidgetState();
}

class _SelectorWidgetState extends ConsumerState<SelectorWidget> {
  late bool collapsed;
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    collapsed = true;
    controller = TextEditingController();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Widget controlWidget(BuildContext context) {
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
              widget.onSelected({...widget.selected}..addAll(widget.candidates.map((e) => e.sid)));
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
              widget.onSelected({...widget.selected}..removeAll(widget.candidates.map((e) => e.sid)));
            },
          ),
          Tooltip(
            message: "$tr_common.selector.control.text_search.tooltip".tr(),
            child: DenseTextField(
              controller: controller,
              debounce: const Duration(milliseconds: 200),
              hintText: "$tr_common.selector.control.text_search.label".tr(),
              allowEmpty: true,
              onChanged: (text) => widget.onTextQueryChanged(text),
            ),
          ),
        ],
      ),
    );
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
          padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
          child: controlWidget(context),
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
                    onSelected: (selected) {
                      final current = {...widget.selected};
                      if (selected) {
                        current.add(info.sid);
                      } else {
                        current.remove(info.sid);
                      }
                      widget.onSelected(current);
                    },
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

  CustomRangeSlider({
    super.key,
    required this.min,
    required this.max,
    required this.step,
    required this.start,
    required this.end,
    required this.formatter,
    required this.onChanged,
  }) {
    if (min == max) {
      logger.e("This condition is illegal and should be prevented.");
    }
  }

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
    assert(widget.min != widget.max);
    if (start > end || widget.min > widget.max || start < widget.min || widget.max < end) {
      logger.e("Invalid slider range. start=$start, end=$end, min=${widget.min}, max=${widget.max}");
    }
    final divisions = ((widget.max - widget.min) / widget.step).round();
    final clampedStart = start.clamp(widget.min, widget.max);
    final clampedEnd = end.clamp(widget.min, widget.max);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Tooltip(
              message: "$tr_common.range.tooltip.min".tr(),
              child: Chip(label: popup(clampedStart)),
            ),
            Tooltip(
              message: "$tr_common.range.tooltip.max".tr(),
              child: Chip(label: popup(clampedEnd)),
            ),
          ],
        ),
        RangeSlider(
          min: widget.min,
          max: widget.max,
          divisions: divisions > 0 ? divisions : null,
          labels: RangeLabels(widget.formatter(clampedStart), widget.formatter(clampedEnd)),
          values: RangeValues(clampedStart, clampedEnd),
          onChanged: (values) {
            widget.onChanged(values.start, values.end);
            setState(() {
              start = values.start;
              end = values.end;
            });
          },
        ),
      ],
    );
  }
}
