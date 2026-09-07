import 'package:flutter/material.dart';

/// Theme tokens for colors that Material 3's [ColorScheme] cannot express.
///
/// These are registered on [ThemeData.extensions] in `app_widget.dart` with
/// brightness-appropriate values, so widgets read them via
/// `Theme.of(context).semantic` / `.chart` / `.codeHighlight` instead of hard
/// coding literals. This file is the single source of truth for the values and
/// is intentionally exempt from the no-color-literal pre-commit guardrail.

/// Convenience accessors for the custom [ThemeExtension]s below.
extension AppThemeExtensions on ThemeData {
  AppSemanticColors get semantic => extension<AppSemanticColors>()!;
  AppChartColors get chart => extension<AppChartColors>()!;
  CodeHighlightColors get codeHighlight => extension<CodeHighlightColors>()!;
}

/// Status / brand colors not covered by [ColorScheme]. Values are
/// brightness-tuned (darker on light surfaces, lighter on dark) for consistent
/// contrast, mirroring the shade-by-brightness pattern used previously.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  /// Success / positive state (capture requirement OK, addon success, pass mark).
  final Color success;

  /// Warning / caution state (capture unsure, addon timeout, script error icon).
  final Color warning;

  /// Informational / in-progress state (info toasts, addon running).
  final Color info;

  /// Danger / failure state. Wired to `colorScheme.error` at registration.
  final Color danger;

  /// Foreground for text/icons drawn on a filled accent (e.g. toast chips).
  final Color onAccent;

  /// Amber/gold accent for rating stars.
  final Color ratingAccent;

  /// Soft "notice" container background (dashboard updater card, warning cells).
  final Color noticeContainer;

  /// Foreground on [noticeContainer].
  final Color onNoticeContainer;

  /// Character-name banner brand color.
  final Color brandBanner;

  /// Foreground on [brandBanner].
  final Color onBrandBanner;

  /// Neutral indicator for inactive/not-started state.
  final Color mutedIndicator;

  const AppSemanticColors({
    required this.success,
    required this.warning,
    required this.info,
    required this.danger,
    required this.onAccent,
    required this.ratingAccent,
    required this.noticeContainer,
    required this.onNoticeContainer,
    required this.brandBanner,
    required this.onBrandBanner,
    required this.mutedIndicator,
  });

  factory AppSemanticColors.light(ColorScheme scheme) => AppSemanticColors(
    success: Colors.green.shade700,
    warning: Colors.orange.shade700,
    info: Colors.blue.shade700,
    danger: scheme.error,
    onAccent: Colors.white,
    ratingAccent: Colors.amber,
    noticeContainer: Colors.amber.shade200,
    onNoticeContainer: Colors.black87,
    brandBanner: const Color(0xFFEC6A8E),
    onBrandBanner: Colors.white,
    mutedIndicator: Colors.grey.shade500,
  );

  factory AppSemanticColors.dark(ColorScheme scheme) => AppSemanticColors(
    success: Colors.green.shade300,
    warning: Colors.orange.shade300,
    info: Colors.blue.shade300,
    danger: scheme.error,
    onAccent: Colors.white,
    ratingAccent: Colors.amber,
    noticeContainer: Colors.amber.shade800,
    onNoticeContainer: Colors.white,
    brandBanner: const Color(0xFFEC6A8E),
    onBrandBanner: Colors.white,
    mutedIndicator: Colors.grey.shade500,
  );

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? warning,
    Color? info,
    Color? danger,
    Color? onAccent,
    Color? ratingAccent,
    Color? noticeContainer,
    Color? onNoticeContainer,
    Color? brandBanner,
    Color? onBrandBanner,
    Color? mutedIndicator,
  }) {
    return AppSemanticColors(
      success: success ?? this.success,
      warning: warning ?? this.warning,
      info: info ?? this.info,
      danger: danger ?? this.danger,
      onAccent: onAccent ?? this.onAccent,
      ratingAccent: ratingAccent ?? this.ratingAccent,
      noticeContainer: noticeContainer ?? this.noticeContainer,
      onNoticeContainer: onNoticeContainer ?? this.onNoticeContainer,
      brandBanner: brandBanner ?? this.brandBanner,
      onBrandBanner: onBrandBanner ?? this.onBrandBanner,
      mutedIndicator: mutedIndicator ?? this.mutedIndicator,
    );
  }

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      ratingAccent: Color.lerp(ratingAccent, other.ratingAccent, t)!,
      noticeContainer: Color.lerp(noticeContainer, other.noticeContainer, t)!,
      onNoticeContainer: Color.lerp(onNoticeContainer, other.onNoticeContainer, t)!,
      brandBanner: Color.lerp(brandBanner, other.brandBanner, t)!,
      onBrandBanner: Color.lerp(onBrandBanner, other.onBrandBanner, t)!,
      mutedIndicator: Color.lerp(mutedIndicator, other.mutedIndicator, t)!,
    );
  }
}

/// Categorical palette for the count-by-strategy charts. Theme-independent today,
/// but tokenized so a future dark-mode variant has a home.
@immutable
class AppChartColors extends ThemeExtension<AppChartColors> {
  final List<Color> categories;

  /// Single-series color for monochrome charts (bar, line, scatter), where the
  /// multi-hue [categories] palette would be meaningless.
  final Color series;

  const AppChartColors({required this.categories, required this.series});

  factory AppChartColors.standard() => const AppChartColors(
    categories: [Color(0xFF0293EE), Color(0xFFF8B250), Color(0xFF845BEF), Color(0xFF13D38E)],
    series: Colors.cyan,
  );

  @override
  AppChartColors copyWith({List<Color>? categories, Color? series}) =>
      AppChartColors(categories: categories ?? this.categories, series: series ?? this.series);

  @override
  AppChartColors lerp(ThemeExtension<AppChartColors>? other, double t) {
    if (other is! AppChartColors || other.categories.length != categories.length) return this;
    return AppChartColors(
      categories: [for (var i = 0; i < categories.length; i++) Color.lerp(categories[i], other.categories[i], t)!],
      series: Color.lerp(series, other.series, t)!,
    );
  }
}

/// VS Code-style syntax-highlight palette for the script editor, keyed by the
/// `highlight` package's node class names. Separate light/dark instances are
/// registered, so the editor reads one map without branching on brightness.
@immutable
class CodeHighlightColors extends ThemeExtension<CodeHighlightColors> {
  final Map<String, TextStyle> styles;

  const CodeHighlightColors({required this.styles});

  factory CodeHighlightColors.light() => const CodeHighlightColors(
    styles: {
      'comment': TextStyle(color: Color(0xFF008000), fontStyle: FontStyle.italic),
      'quote': TextStyle(color: Color(0xFF008000)),
      'keyword': TextStyle(color: Color(0xFF0000FF)),
      'literal': TextStyle(color: Color(0xFF0000FF)),
      'built_in': TextStyle(color: Color(0xFF267F99)),
      'type': TextStyle(color: Color(0xFF267F99)),
      'class': TextStyle(color: Color(0xFF267F99)),
      'title': TextStyle(color: Color(0xFF795E26)),
      'function': TextStyle(color: Color(0xFF795E26)),
      'string': TextStyle(color: Color(0xFFA31515)),
      'number': TextStyle(color: Color(0xFF098658)),
      'meta': TextStyle(color: Color(0xFFAF00DB)),
      'symbol': TextStyle(color: Color(0xFFAF00DB)),
      'subst': TextStyle(color: Color(0xFF001080)),
      'variable': TextStyle(color: Color(0xFF001080)),
      'params': TextStyle(color: Color(0xFF001080)),
      // JSON's object-key class (highlight has no Dart equivalent). Deliberately
      // the SAME value as 'variable'/'subst'/'params' above, not a new hue: VS
      // Code's own Light+/Dark+ themes paint a JSON key in the same blue as a
      // variable (the dark value below, #9CDCFE, matches Dark+ exactly), so this
      // extends that theme's existing rule instead of inventing a JSON-specific
      // color. It exists to read differently from 'string' (JSON values), which
      // is the distinction that matters for a key/value preview.
      'attr': TextStyle(color: Color(0xFF001080)),
    },
  );

  factory CodeHighlightColors.dark() => const CodeHighlightColors(
    styles: {
      'comment': TextStyle(color: Color(0xFF6A9955), fontStyle: FontStyle.italic),
      'quote': TextStyle(color: Color(0xFF6A9955)),
      'keyword': TextStyle(color: Color(0xFF569CD6)),
      'literal': TextStyle(color: Color(0xFF569CD6)),
      'built_in': TextStyle(color: Color(0xFF4EC9B0)),
      'type': TextStyle(color: Color(0xFF4EC9B0)),
      'class': TextStyle(color: Color(0xFF4EC9B0)),
      'title': TextStyle(color: Color(0xFFDCDCAA)),
      'function': TextStyle(color: Color(0xFFDCDCAA)),
      'string': TextStyle(color: Color(0xFFCE9178)),
      'number': TextStyle(color: Color(0xFFB5CEA8)),
      'meta': TextStyle(color: Color(0xFFC586C0)),
      'symbol': TextStyle(color: Color(0xFFC586C0)),
      'subst': TextStyle(color: Color(0xFF9CDCFE)),
      'variable': TextStyle(color: Color(0xFF9CDCFE)),
      'params': TextStyle(color: Color(0xFF9CDCFE)),
      // See the light-theme 'attr' entry above for why this reuses 'variable'.
      'attr': TextStyle(color: Color(0xFF9CDCFE)),
    },
  );

  @override
  CodeHighlightColors copyWith({Map<String, TextStyle>? styles}) => CodeHighlightColors(styles: styles ?? this.styles);

  @override
  CodeHighlightColors lerp(ThemeExtension<CodeHighlightColors>? other, double t) {
    if (other is! CodeHighlightColors) return this;
    // Discrete palettes; snap at the midpoint rather than blending per glyph.
    return t < 0.5 ? this : other;
  }
}
