import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/theme_extensions.dart';

/// A debug-only inspector and the single source of truth for the app's palette.
///
/// Renders the full `ColorScheme` role set (roles the app never references keep
/// their normal swatch but carry a "not used" note), the `ThemeData` colors, the role-based
/// translucent composites resolved over the real background they are painted on,
/// and the custom `ThemeExtension` tokens (`AppSemanticColors`, `AppChartColors`,
/// `CodeHighlightColors`). Each swatch is annotated with a short description of
/// what the color is used for.
///
/// Reached from a `kDebugMode`-guarded tile in the settings page. Swatches
/// resolve against the *current* theme brightness, so toggle the app theme mode
/// and reopen to compare light vs dark. This replaces the earlier static
/// markdown inventory; it is the working surface for the theme review.
///
/// The usage descriptions are a snapshot of how the code uses each color and can
/// drift as the code changes; re-check when relying on them for a refactor.
class ThemeGalleryDialog extends ConsumerWidget {
  const ThemeGalleryDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const ThemeGalleryDialog());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brightness = Theme.of(context).brightness;
    return CardDialog(
      dialogTitle: 'Theme gallery — ${brightness.name} (debug)',
      closeButtonTooltip: 'Close',
      content: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ColorSchemeSection(),
          _ThemeDataSection(),
          _BlendSection(),
          _SemanticSection(),
          _ChartSection(),
          _CodeHighlightSection(),
        ],
      ),
    );
  }
}

/// Formats an opaque color as `#RRGGBB`, or `#AARRGGBB` when translucent.
String _hex(Color color) {
  final argb = color.toARGB32();
  if ((argb >> 24) == 0xFF) {
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
  return '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

Color _contrastOn(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : Colors.black;

/// Wraps a swatch so tapping it copies [name] to the clipboard, and shows a
/// click cursor on hover.
Widget _copyable(String name, Widget child) {
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: () => Clipboard.setData(ClipboardData(text: name)),
      child: child,
    ),
  );
}

/// A solid swatch showing a color's label and resolved hex.
class _Swatch extends StatelessWidget {
  final String label;
  final Color color;
  final Color? onColor;

  const _Swatch(this.label, this.color, {this.onColor});

  @override
  Widget build(BuildContext context) {
    final foreground = onColor ?? _contrastOn(color);
    return _copyable(
      label,
      Container(
        width: 168,
        height: 64,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: foreground, fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
            Text(_hex(color), style: TextStyle(color: foreground, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// A swatch for a translucent [overlay] painted over [base]. The left chip shows
/// the raw overlay over a checkerboard (so the alpha is visible); the body is the
/// composited result with its resolved hex.
class _BlendSwatch extends StatelessWidget {
  final String label;
  final Color overlay;
  final Color base;
  final String baseLabel;

  const _BlendSwatch(this.label, {required this.overlay, required this.base, required this.baseLabel});

  @override
  Widget build(BuildContext context) {
    final composite = Color.alphaBlend(overlay, base);
    final foreground = _contrastOn(composite);
    final alphaPct = (overlay.a * 100).round();
    return _copyable(
      label,
      Container(
        width: 168,
        height: 64,
        decoration: BoxDecoration(color: composite, borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            SizedBox(
              width: 34,
              height: 64,
              child: CustomPaint(
                painter: const _CheckerPainter(),
                child: ColoredBox(color: overlay),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: foreground, fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ),
                    Text('$alphaPct% / $baseLabel', style: TextStyle(color: foreground, fontSize: 10)),
                    Text(_hex(composite), style: TextStyle(color: foreground, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 6.0;
    final light = Paint()..color = const Color(0xFFFFFFFF);
    final dark = Paint()..color = const Color(0xFFBDBDBD);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        final even = (((x / cell).floor() + (y / cell).floor()) % 2) == 0;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), even ? light : dark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// One row: the color swatch on the left, a one-line description of what the
/// color is used for on the right.
class _SwatchRow extends StatelessWidget {
  final Widget swatch;
  final String usage;
  final bool unused;

  const _SwatchRow(this.swatch, this.usage, {this.unused = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontStyle: unused ? FontStyle.italic : null,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Unused roles render at full color (only the description marks them
          // "not used"), so the swatch stays readable for the palette review.
          swatch,
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(usage, style: style),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? note;
  final List<Widget> rows;

  const _Section(this.title, this.rows, {this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }
}

class _ColorSchemeSection extends StatelessWidget {
  const _ColorSchemeSection();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The full standard Material 3 role set, in palette order. Roles the app
    // never references are still shown (dimmed) with a "not used" note, so the
    // review can see the whole palette. The deprecated (background,
    // surfaceVariant) and "fixed" roles are excluded as effectively dead.
    final roles = <(String, Color, Color?)>[
      ('primary', cs.primary, cs.onPrimary),
      ('onPrimary', cs.onPrimary, cs.primary),
      ('primaryContainer', cs.primaryContainer, cs.onPrimaryContainer),
      ('onPrimaryContainer', cs.onPrimaryContainer, cs.primaryContainer),
      ('secondary', cs.secondary, cs.onSecondary),
      ('onSecondary', cs.onSecondary, cs.secondary),
      ('secondaryContainer', cs.secondaryContainer, cs.onSecondaryContainer),
      ('onSecondaryContainer', cs.onSecondaryContainer, cs.secondaryContainer),
      ('tertiary', cs.tertiary, cs.onTertiary),
      ('onTertiary', cs.onTertiary, cs.tertiary),
      ('tertiaryContainer', cs.tertiaryContainer, cs.onTertiaryContainer),
      ('onTertiaryContainer', cs.onTertiaryContainer, cs.tertiaryContainer),
      ('error', cs.error, cs.onError),
      ('onError', cs.onError, cs.error),
      ('errorContainer', cs.errorContainer, cs.onErrorContainer),
      ('onErrorContainer', cs.onErrorContainer, cs.errorContainer),
      ('surface', cs.surface, cs.onSurface),
      ('onSurface', cs.onSurface, cs.surface),
      ('onSurfaceVariant', cs.onSurfaceVariant, cs.surface),
      ('surfaceDim', cs.surfaceDim, cs.onSurface),
      ('surfaceBright', cs.surfaceBright, cs.onSurface),
      ('surfaceContainerLowest', cs.surfaceContainerLowest, cs.onSurface),
      ('surfaceContainerLow', cs.surfaceContainerLow, cs.onSurface),
      ('surfaceContainer', cs.surfaceContainer, cs.onSurface),
      ('surfaceContainerHigh', cs.surfaceContainerHigh, cs.onSurface),
      ('surfaceContainerHighest', cs.surfaceContainerHighest, cs.onSurface),
      ('outline', cs.outline, null),
      ('outlineVariant', cs.outlineVariant, null),
      ('inverseSurface', cs.inverseSurface, cs.onInverseSurface),
      ('onInverseSurface', cs.onInverseSurface, cs.inverseSurface),
      ('inversePrimary', cs.inversePrimary, null),
      ('shadow', cs.shadow, null),
      ('scrim', cs.scrim, null),
      ('surfaceTint', cs.surfaceTint, null),
    ];
    return _Section('ColorScheme roles', [
      for (final (name, color, on) in roles)
        _SwatchRow(
          _Swatch(name, color, onColor: on),
          _roleUsages[name] ?? _unusedNote(name),
          unused: !_roleUsages.containsKey(name),
        ),
    ], note: 'FlexScheme.blue + surface blend. Rows marked "not used" are unreferenced roles.');
  }
}

/// Note shown for a `ColorScheme` role the app never references.
String _unusedNote(String role) => switch (role) {
  'shadow' => 'Not used as a role; ThemeData.shadowColor drives shadows instead.',
  'onSecondaryContainer' =>
    'Never referenced directly; Material pairs it with secondaryContainer on its own (chips, avatars).',
  _ => 'Not used in the app.',
};

class _ThemeDataSection extends StatelessWidget {
  const _ThemeDataSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = <(String, Color)>[
      ('scaffoldBackground', theme.scaffoldBackgroundColor),
      ('cardColor', theme.cardColor),
      ('dividerColor', theme.dividerColor),
      ('shadowColor', theme.shadowColor),
      ('disabledColor', theme.disabledColor),
      ('hintColor', theme.hintColor),
    ];
    return _Section('ThemeData colors (used)', [
      for (final (name, color) in entries) _SwatchRow(_Swatch(name, color), _themeDataUsages[name] ?? ''),
    ]);
  }
}

class _BlendSection extends StatelessWidget {
  const _BlendSection();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = Theme.of(context).semantic;
    return _Section(
      'Translucent composites (role-based alpha, as painted)',
      [
        _SwatchRow(
          _BlendSwatch(
            'hover overlay',
            overlay: cs.onSurface.withValues(alpha: 0.08),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Hover highlight on the window-control buttons (M3 state opacity).',
        ),
        _SwatchRow(
          _BlendSwatch('modal scrim', overlay: cs.scrim.withValues(alpha: 0.5), base: cs.surface, baseLabel: 'surface'),
          'Dim backdrop behind modal dialogs (scrim role).',
        ),
        _SwatchRow(
          _BlendSwatch(
            'capture preview hint',
            overlay: cs.scrim.withValues(alpha: 0.6),
            base: s.onAccent,
            baseLabel: 'worst-case frame',
          ),
          'Scrim of the "click to show / hide" hint drawn over the whole capture-preview frame while the '
          'pointer is on it (hover only -- the keyboard gets a primary focus ring instead). The base shown '
          'is the worst case it can face (a white game frame); the icon and caption on top are onAccent '
          '(always light), which clears 4.5:1 on this composite in both themes.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'capture message',
            overlay: s.info.withValues(alpha: 0.15),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Background of the capture card\'s status banner and of every message tile built on it (the event '
          'line, the import gate, the unsupported-browser notice). The overlay is whichever semantic tone the '
          'message carries, always at 15%; info is shown.',
        ),
        _SwatchRow(
          _BlendSwatch('tag glow', overlay: cs.primary.withValues(alpha: 0.45), base: cs.surface, baseLabel: 'surface'),
          'Glow shadow under a tag chip while it is being dragged.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'loading veil',
            overlay: cs.surface.withValues(alpha: 0.85),
            base: cs.onSurface,
            baseLabel: 'content',
          ),
          'Veil over the data table while records are loading.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'selection overlay',
            overlay: s.noticeContainer.withValues(alpha: 0.45),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Row overlay marking selected rows (per-purpose role at 45%; archive shown).',
        ),
        _SwatchRow(
          _BlendSwatch(
            'selection label chip',
            overlay: s.noticeContainer.withValues(alpha: 0.95),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Denser chip behind the selected-row label so it stays legible over the translucent overlay.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'preview text bg',
            overlay: cs.surface.withValues(alpha: 0.5),
            base: cs.onSurface,
            baseLabel: 'image',
          ),
          'Caption background over the preview image (surface role).',
        ),
        _SwatchRow(
          _BlendSwatch(
            'preview empty bg',
            overlay: cs.onSurface.withValues(alpha: 0.04),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Fill of the empty preview placeholder.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'row divider',
            overlay: cs.outlineVariant.withValues(alpha: 0.5),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Inset hairline separating each settings row in the column-customize and table-settings dialogs.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'truth-table border',
            overlay: cs.onInverseSurface.withValues(alpha: 0.4),
            base: cs.inverseSurface,
            baseLabel: 'inverseSurface',
          ),
          'Inner grid lines of the logic truth-table rendered inside the column-builder tooltip.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'menu entry icon',
            overlay: cs.onSurface.withValues(alpha: 0.7),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Icon of a live, non-destructive entry in the storage view\'s row menus. Reproduces what the context-menu '
          'package\'s own MenuItem paints, so the destructive entry\'s error red and a withheld entry\'s '
          'disabledColor are the only departures from it.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'disabled dialog close icon',
            overlay: cs.onTertiary.withValues(alpha: 0.38),
            base: cs.tertiary,
            baseLabel: 'tertiary',
          ),
          'CardDialog\'s × button when closeButtonEnabled is false, drawn on the tertiary title band. 38% '
          'matches the strength Material greys a disabled onSurface control to; only the role differs, '
          'because the surface it sits on does.',
        ),
      ],
      note:
          'Left chip = raw translucent over a checkerboard; body = composite over the real background. '
          'Alpha is applied to theme roles, not literals.',
    );
  }
}

class _SemanticSection extends StatelessWidget {
  const _SemanticSection();

  @override
  Widget build(BuildContext context) {
    // Live values from the AppSemanticColors extension (theme_extensions.dart),
    // brightness-tuned. These replaced the scattered status/brand literals.
    final s = Theme.of(context).semantic;
    final entries = <(String, Color, Color?, String)>[
      ('success', s.success, null, 'Toast success, capture requirement OK, addon success.'),
      ('warning', s.warning, null, 'Toast warning, capture requirement unsure, addon timeout, script error icon.'),
      ('info', s.info, null, 'Info toasts, addon running status.'),
      ('danger', s.danger, null, 'Toast error, capture requirement insufficient (wired to colorScheme.error).'),
      (
        'onAccent',
        s.onAccent,
        s.success,
        'Text/icons drawn on a filled accent (toast chips, requirement chips) and on the capture-preview hint '
            'scrim, where it has to stay light in both brightnesses.',
      ),
      ('ratingAccent', s.ratingAccent, null, 'Rating star icons.'),
      ('noticeContainer', s.noticeContainer, s.onNoticeContainer, 'Updater card title band; archive row overlay.'),
      ('onNoticeContainer', s.onNoticeContainer, s.noticeContainer, 'Text/icons on noticeContainer.'),
      ('brandBanner', s.brandBanner, s.onBrandBanner, 'Character-name banner background.'),
      ('onBrandBanner', s.onBrandBanner, s.brandBanner, 'Text on the character banner.'),
      ('mutedIndicator', s.mutedIndicator, null, 'Capture progress "not started" indicator.'),
    ];
    return _Section(
      'Semantic / brand tokens (AppSemanticColors)',
      [for (final (name, color, on, usage) in entries) _SwatchRow(_Swatch(name, color, onColor: on), usage)],
      note: 'Theme-driven, light/dark-aware. Defined in lib/src/gui/theme_extensions.dart.',
    );
  }
}

class _ChartSection extends StatelessWidget {
  const _ChartSection();

  @override
  Widget build(BuildContext context) {
    final chart = Theme.of(context).chart;
    return _Section('Chart palette (AppChartColors)', [
      for (final (i, color) in chart.categories.indexed)
        _SwatchRow(_Swatch('category $i', color), 'Category color $i of the count-by-strategy charts.'),
      _SwatchRow(_Swatch('series', chart.series), 'Single-series color for the bar, line, and scatter charts.'),
    ], note: 'Theme-driven. Defined in lib/src/gui/theme_extensions.dart.');
  }
}

class _CodeHighlightSection extends StatelessWidget {
  const _CodeHighlightSection();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final styles = Theme.of(context).codeHighlight.styles;
    return _Section(
      'Code highlight (CodeHighlightColors, active: ${isDark ? 'dark' : 'light'})',
      [
        for (final entry in styles.entries)
          if (entry.value.color != null)
            _SwatchRow(
              _Swatch(entry.key, entry.value.color!),
              'Syntax highlight color for ${entry.key} tokens, in the script editor and the storage tab\'s '
              'file preview.',
            ),
      ],
      note:
          'VS Code-style palette, keyed by the `highlight` package\'s token class names. Both code fields read '
          'it -- the Dart script editor and the storage tab\'s JSON / plain-text file preview -- so a key can '
          'come from one language only (`attr` is JSON\'s object key, deliberately the same value as '
          '`variable`). Theme-driven; defined in lib/src/gui/theme_extensions.dart.',
    );
  }
}

// Snapshot of what each ColorScheme role is used for in the app. Derived from a
// scan of `lib/`; re-check if relied upon for a refactor.
const Map<String, String> _roleUsages = {
  'primary':
      'Brand accent: add-column button, drag/slot accents, data-table accents, progress, feedback drawer, '
      'storage-group folder icons.',
  'onPrimary': 'Text and icons on primary fills (add-column button, data-table accents, feedback drawer).',
  'primaryContainer':
      'Light accent fills: selected filter/choice chips (global chipTheme); NoteCard, logic-column and '
      'column-builder group borders; character avatar; table/stat accents.',
  'secondaryContainer':
      'Subtle highlight backgrounds: dashboard and data-table avatars; tag chip drag highlight. Also the '
      'source the pale surfaceContainerLowest/Low/Bright tints are lerped from.',
  'secondary': 'Accent text: script cost / zero-record warnings; experimental-warning card border.',
  'tertiary': 'Card and dialog header band (ListCard, CardDialog) and the experimental-warning card background.',
  'onTertiary': 'Text and icons on the card/dialog header band and the experimental-warning card.',
  'onTertiaryContainer':
      'Never painted under this name: the role consolidation in app_widget.dart remaps it onto onTertiary, '
      'so this is the source of the card/dialog header band\'s text color.',
  'error':
      'Error/danger emphasis: storage warnings, script errors, delete/regenerate dialogs, task failures, and the '
      'import-report dialog\'s failure card. In the storage view it moved off the row: the delete button became '
      'the one destructive entry of the row menu, which resolves this role itself, and only while that entry is '
      'live -- a withheld one takes disabledColor instead.',
  'onError': 'Text and icons on error surfaces.',
  'errorContainer': 'Error/warning card and chip backgrounds.',
  'onErrorContainer': 'Text and icons on errorContainer backgrounds.',
  'surface':
      'Base backgrounds: card surfaces (global cardTheme), data-table, window chrome, side preview, script, and '
      'the resting entries of the storage view\'s row menus.',
  'onSurface': 'Default body text and icon color.',
  'onSurfaceVariant': 'Secondary text: setting descriptions, captions, muted labels.',
  'surfaceBright': 'Pale water-blue tint filling the NoteCard body (paired with a primaryContainer border).',
  'surfaceContainerLowest':
      'Pale water-blue tint: logic-column and column-builder group backgrounds; data-table striped rows.',
  'surfaceContainerLow': 'Script name-copy chips; recolored to a pale water-blue tint.',
  'surfaceContainer':
      'Panel backgrounds (addon list, side preview); striped script rows; the focused entry of the storage '
      'view\'s row menus.',
  'surfaceContainerHigh': 'Chip backgrounds (global chipTheme) and the page background (scaffold).',
  'surfaceContainerHighest': 'Raised backgrounds: table menu bar, input fields, module-update, statistics.',
  'outline': 'Borders and dividers: data-table grid lines, preset bar, script frame, settings-group header rules.',
  'outlineVariant':
      'Faint outlines: the app-wide chip border (global chipTheme), the column-chip "settings group" frame, and the inset per-row dividers in the column/table settings dialogs.',
  'scrim': 'Dim backdrop behind modal dialogs (DialogLayer), and the capture-preview hover/focus hint.',
  'onInverseSurface': 'Text on the inverse surface (column builder dialog).',
};

const Map<String, String> _themeDataUsages = {
  'scaffoldBackground': 'Page background behind cards and content.',
  'cardColor': 'Card background on the license page (Card with an explicit cardColor).',
  'dividerColor': 'Divider and border lines (dialog frames, table borders).',
  'shadowColor': 'Elevation shadow color for raised Material surfaces (cards, dialogs).',
  'disabledColor':
      'Disabled-state elements (data-table, family registration, script), and the withheld entries of the storage '
      'view\'s row menus -- where it outranks the destructive red, so an entry that cannot act reads as dead '
      'rather than as danger.',
  'hintColor': 'Input placeholders and hints (task dialog, column builder, script).',
};
