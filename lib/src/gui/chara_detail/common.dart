import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/core/utils.dart';

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

class NoteCard extends ConsumerWidget {
  final Widget description;
  final List<Widget> children;

  const NoteCard({
    Key? key,
    required this.description,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Container(
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
                padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
                child: description,
              ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class TagSelector extends ConsumerWidget {
  final ProviderBase<List<Tag>> candidateTagsProvider;
  final StateProviderLike<Set<Tag>> selectedTagsProvider;

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
              backgroundColor: selectedTags.contains(tag) ? null : theme.colorScheme.surfaceVariant,
              showCheckmark: false,
              selected: selectedTags.contains(tag),
              onSelected: (selected) {
                ref.read(selectedTagsProvider.notifier).update((tags) {
                  return Set.from(tags)..toggle(tag, shouldExists: !selected);
                });
              },
            ),
        ],
      ),
    );
  }
}
