import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/theme_extensions.dart';

/// A debug-only inspector and the single source of truth for the app's palette.
///
/// Renders the full `ColorScheme` role set (roles the app never references are
/// shown dimmed with a "not used" note), the surface-tint tokens, the
/// translucent / blended composites resolved over the real background they are
/// painted on, and the scattered hardcoded brand/status colors. Each swatch is
/// annotated with a short description of what the color is used for.
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
          _TokenSection(),
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

/// A solid swatch showing a color's label and resolved hex.
class _Swatch extends StatelessWidget {
  final String label;
  final Color color;
  final Color? onColor;
  final String? sub;

  const _Swatch(this.label, this.color, {this.onColor, this.sub});

  @override
  Widget build(BuildContext context) {
    final foreground = onColor ?? _contrastOn(color);
    return Container(
      width: 168,
      height: 64,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
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
          if (sub != null) Text(sub!, style: TextStyle(color: foreground, fontSize: 10)),
          Text(_hex(color), style: TextStyle(color: foreground, fontSize: 11)),
        ],
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
    return Container(
      width: 168,
      height: 64,
      decoration: BoxDecoration(
        color: composite,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
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
          Opacity(opacity: unused ? 0.45 : 1, child: swatch),
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
    return _Section(
      'ColorScheme roles',
      [
        for (final (name, color, on) in roles)
          _SwatchRow(
            _Swatch(name, color, onColor: on),
            _roleUsages[name] ?? _unusedNote(name),
            unused: !_roleUsages.containsKey(name),
          ),
      ],
      note:
          'FlexScheme.blue + surface blend. Dimmed rows are unused roles. surfaceContainerHighest is tinted at build.',
    );
  }
}

/// Note shown for a `ColorScheme` role the app never references.
String _unusedNote(String role) => switch (role) {
  'surfaceContainerHigh' => 'Not referenced directly, but tinted at build time alongside surfaceContainerHighest.',
  'shadow' => 'Not used as a role; ThemeData.shadowColor drives shadows instead.',
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

class _TokenSection extends StatelessWidget {
  const _TokenSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _Section(
      'Surface-tint tokens & theme blends',
      [
        _SwatchRow(
          _Swatch('blueTintedSurface', cs.blueTintedSurface, onColor: cs.onSurface, sub: 'primCont@10%/surf'),
          'Light-blue background for statistic cards.',
        ),
        _SwatchRow(
          _Swatch('stripedRowColor', cs.stripedRowColor, onColor: cs.onSurface, sub: 'primCont@20%/surf'),
          'Striped (even) row background in the data table and script grid.',
        ),
        _SwatchRow(
          _Swatch(
            'CardDialog header',
            Color.lerp(theme.scaffoldBackgroundColor, theme.cardColor, 0.5)!,
            onColor: cs.onSurface,
            sub: 'lerp(scaf,card,.5)',
          ),
          'Header band color of plain (non-attention) ListCard headers.',
        ),
      ],
      note: 'Composed in common.dart / app_widget.dart. surfaceContainerHighest above already reflects its tint.',
    );
  }
}

class _BlendSection extends StatelessWidget {
  const _BlendSection();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shadow = Theme.of(context).shadowColor;
    return _Section(
      'Translucent composites (as painted)',
      [
        _SwatchRow(
          _BlendSwatch(
            'hover overlay',
            overlay: cs.onSurface.withValues(alpha: 0.06),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Hover highlight on the window-control buttons.',
        ),
        _SwatchRow(
          _BlendSwatch('modal scrim', overlay: shadow.withValues(alpha: 0.5), base: cs.surface, baseLabel: 'surface'),
          'Dim backdrop painted behind modal dialogs.',
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
            'warning cell',
            overlay: Colors.amber.withValues(alpha: 0.45),
            base: cs.surface,
            baseLabel: 'surface',
          ),
          'Warning-cell highlight in the data table.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'preview text bg',
            overlay: Colors.white.withValues(alpha: 0.5),
            base: const Color(0xFF808080),
            baseLabel: 'image',
          ),
          'Caption background drawn over the preview image.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'preview border',
            overlay: Colors.black.withValues(alpha: 0.5),
            base: Colors.white,
            baseLabel: 'white',
          ),
          'Border around the preview thumbnail.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'preview placeholder',
            overlay: Colors.black.withValues(alpha: 0.3),
            base: Colors.white,
            baseLabel: 'white',
          ),
          'Tint of the "no image" placeholder icon.',
        ),
        _SwatchRow(
          _BlendSwatch(
            'preview empty bg',
            overlay: Colors.black.withValues(alpha: 0.04),
            base: Colors.white,
            baseLabel: 'white',
          ),
          'Fill of the empty preview area.',
        ),
      ],
      note: 'Left chip = raw translucent over a checkerboard; body = composite over the real background, with its hex.',
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
      ('onAccent', s.onAccent, s.success, 'Text/icons drawn on a filled accent (toast chips, requirement chips).'),
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
    final categories = Theme.of(context).chart.categories;
    return _Section('Chart palette (AppChartColors)', [
      for (final (i, color) in categories.indexed)
        _SwatchRow(_Swatch('category $i', color), 'Category color $i of the count-by-strategy charts.'),
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
              'Syntax highlight color for ${entry.key} tokens in the script editor.',
            ),
      ],
      note: 'VS Code-style palette. Theme-driven; defined in lib/src/gui/theme_extensions.dart.',
    );
  }
}

// Snapshot of what each ColorScheme role is used for in the app. Derived from a
// scan of `lib/`; re-check if relied upon for a refactor.
const Map<String, String> _roleUsages = {
  'primary': 'Brand accent: dialog header bands, selected tag chips, button outlines, data-table accents, progress.',
  'onPrimary': 'Text and icons drawn on primary surfaces (dialog headers, selected chips).',
  'primaryContainer':
      'Tint source and light accent fills: surface-tint tokens, tag/stat/table-row tints, chara-detail panels.',
  'secondaryContainer': 'Subtle highlight backgrounds: capture info panel, dashboard, data-table, tag chips.',
  'onSecondaryContainer': 'Text on secondaryContainer (capture info panel).',
  'tertiary': 'Special-emphasis accents in the script column.',
  'tertiaryContainer': 'Tertiary badge background.',
  'onTertiaryContainer': 'Text on tertiary badges.',
  'error': 'Error/danger emphasis: storage warnings, script errors, delete/regenerate dialogs, task failures.',
  'onError': 'Text and icons on error surfaces.',
  'errorContainer': 'Error/warning card and chip backgrounds.',
  'onErrorContainer': 'Text and icons on errorContainer backgrounds.',
  'surface': 'Base backgrounds: data-table, window chrome, side preview.',
  'onSurface': 'Default body text and icon color.',
  'onSurfaceVariant': 'Secondary text: setting descriptions, captions, muted labels.',
  'surfaceContainerLow': 'Low-contrast card/panel backgrounds (chara-detail, family, script, labels).',
  'surfaceContainer': 'Panel backgrounds (addon list, side preview).',
  'surfaceContainerHighest': 'Raised backgrounds: input fields, module-update, column builder, statistics.',
  'outline': 'Borders and dividers: data-table grid lines, preset bar, script frame.',
  'onInverseSurface': 'Text on the inverse surface (column builder dialog).',
};

const Map<String, String> _themeDataUsages = {
  'scaffoldBackground': 'Page background; one end of the ListCard header blend.',
  'cardColor': 'Card backgrounds (license page) and the ListCard header blend.',
  'dividerColor': 'Divider and border lines (dialog frames, table borders).',
  'shadowColor': 'Source color for the modal scrim overlay.',
  'disabledColor': 'Disabled-state elements (data-table, family registration, script).',
  'hintColor': 'Input placeholders and hints (task dialog, column builder, script).',
};
