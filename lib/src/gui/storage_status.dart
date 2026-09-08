/// The storage view's "something is happening" states, in the one shape they are
/// all allowed to take (stage 7).
///
/// **A glyph never appears on its own.** A spinner alone says "something", an
/// error triangle alone says "something bad", and neither reaches a screen reader
/// or a user who has not learned this view's iconography. Every state this view can
/// be in — a level being listed, a size being walked, a file being read, a store
/// being opened — is a sentence with a glyph beside it, and the sentence is the
/// part that carries the state.
///
/// **This library exists because saying that in a comment was not enough.** The
/// pair used to be built by a private helper in `storage_tree.dart`, whose own
/// comment claimed that building it in one place "keeps a later status from being
/// added as a bare icon again". Being private, it could not: `storage_file_preview.dart`
/// went on to add two bodies that were a centred progress ring and nothing else,
/// one for a file being read and one for a settings store, and neither said a
/// word.
/// The helpers are public here so that the rule is reachable from every surface
/// of the view, and `storage_status_test.dart` reads the sources to assert that no
/// other file in the view constructs a progress indicator of its own — the check
/// counts the occurrences itself rather than listing the sites that had one at
/// the time it was written.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The view's progress glyph, at whatever size the surface around it uses.
///
/// [size] matches the glyph it stands in for: 16 beside a line of body text, and
/// the icon size of a panel when it stands where a panel's icon would.
Widget storageStatusSpinner({double size = 16}) {
  return SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(strokeWidth: math.max(2, size / 10)),
  );
}

/// A glyph with the sentence that says what it means, on one line.
///
/// The compact form, for a row inside the tree. A panel-sized surface says the
/// same thing stacked instead — see `_PreviewMessage` in
/// `storage_file_preview.dart` — but neither form is a glyph by itself.
Widget storageStatusLine(Widget glyph, String message) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    },
  );
}
