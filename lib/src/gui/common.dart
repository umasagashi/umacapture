import 'package:flutter/material.dart';

class ListCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const ListCard({
    Key? key,
    this.title,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Column(
        children: [
          if (title != null)
            ListTile(
              tileColor: theme.colorScheme.surfaceVariant,
              title: Text(title!, style: theme.textTheme.headline5),
            ),
          ...children,
        ],
      ),
    );
  }
}
