import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:recase/recase.dart';
import 'package:url_launcher/url_launcher.dart';

import '/const.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/sound_player.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/app_widget.dart';
import '/src/gui/capture.dart';
import '/src/gui/common.dart';
import '/src/gui/license_alt.dart' as license;
import '/src/gui/module_update_dialog.dart';
import '/src/gui/storage_settings.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/theme_gallery.dart';
import '/src/preference/notifier.dart';
import '/src/preference/privacy_setting.dart';

// ignore: constant_identifier_names
const tr_settings = "pages.settings";

// ignore: constant_identifier_names
const tr_sound = "$tr_settings.sound";

class ToggleButtonWidget<T> extends ConsumerWidget {
  final String title;
  final String description;
  final Widget Function(T) icon;
  final ExclusiveItemsNotifierProvider<T> provider;

  const ToggleButtonWidget({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.provider,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(provider);
    final values = ref.read(provider.notifier).values;
    return ListTile(
      title: Text(title),
      subtitle: Text(description),
      trailing: Align(
        widthFactor: 1,
        child: ToggleButtons(
          isSelected: values.map((e) => e == current).toList(),
          onPressed: (index) => ref.read(provider.notifier).setIndex(index),
          children: values.map<Widget>((e) => icon(e)).toList(),
        ),
      ),
      onTap: () => ref.read(provider.notifier).next(),
    );
  }
}

class DropdownButtonWidget<T> extends ConsumerWidget {
  final String title;
  final String description;
  final String Function(T) name;

  /// Optional per-item tooltip shown on hover over each menu entry. Null (the
  /// default) leaves the entries untooltipped.
  final String Function(T)? tooltip;

  final ExclusiveItemsNotifierProvider<T> provider;

  /// Text style for the selected-value label. Null keeps the default size.
  final TextStyle? style;

  const DropdownButtonWidget({
    super.key,
    required this.title,
    required this.description,
    required this.name,
    this.tooltip,
    required this.provider,
    this.style,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(provider);
    final values = ref.read(provider.notifier).values;
    final theme = Theme.of(context);
    return ListTile(
      title: Text(title),
      subtitle: Text(description),
      trailing: PopupMenuButton<T>(
        // disable tool tip
        tooltip: '',
        initialValue: current,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<T>>[
          for (final item in values)
            PopupMenuItem<T>(
              value: item,
              child: tooltip == null
                  ? Text(name(item))
                  : Tooltip(
                      message: tooltip!(item),
                      child: SizedBox(width: double.infinity, child: Text(name(item))),
                    ),
            ),
        ],
        onSelected: (T item) => ref.read(provider.notifier).setValue(item),
        // Mirrors the choice dropdown in chara_detail/common.dart: no Container
        // `alignment` (which would expand to fill the ListTile and trip the
        // "trailing widget consumes the entire tile width" assertion). The label is
        // centred via the Text, and the minWidth lets the box grow with longer labels
        // instead of wrapping them.
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(width: 1, color: theme.colorScheme.onSurface)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 100),
            child: Text(name(current), textAlign: TextAlign.center, style: style),
          ),
        ),
      ),
      onTap: () => ref.read(provider.notifier).next(),
    );
  }
}

class SwitchWidget extends ConsumerWidget {
  final Widget title;
  final Widget description;
  final BooleanNotifierProvider provider;

  const SwitchWidget({super.key, required this.title, required this.description, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: title,
      subtitle: description,
      trailing: Align(
        widthFactor: 1,
        child: Switch(value: ref.watch(provider), onChanged: (enabled) => ref.read(provider.notifier).set(enabled)),
      ),
      onTap: () => ref.read(provider.notifier).toggle(),
    );
  }
}

/// A compact −/value/+ spinbox bound to an [IntNotifierProvider], clamped to
/// [min]..[max] (the buttons disable at the bounds). The value is also directly
/// editable via the shared [IntStepperField]. Mirrors [SwitchWidget]'s shape for
/// use in the same settings groups.
class StepperWidget extends ConsumerWidget {
  final Widget title;
  final Widget description;
  final IntNotifierProvider provider;
  final int min;
  final int max;

  const StepperWidget({
    super.key,
    required this.title,
    required this.description,
    required this.provider,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(provider);
    return ListTile(
      title: title,
      subtitle: description,
      trailing: Align(
        widthFactor: 1,
        child: IntStepperField(value: value, min: min, max: max, onChanged: ref.read(provider.notifier).set),
      ),
    );
  }
}

class _BrightnessWidget extends ConsumerWidget {
  static final _iconMap = <ThemeMode, Widget>{
    ThemeMode.light: Tooltip(
      message: "$tr_settings.style.brightness.choice.light".tr(),
      child: const Icon(Symbols.wb_sunny_rounded),
    ),
    ThemeMode.dark: Tooltip(
      message: "$tr_settings.style.brightness.choice.dark".tr(),
      child: const Icon(Symbols.brightness_3_rounded),
    ),
    ThemeMode.system: Tooltip(
      message: "$tr_settings.style.brightness.choice.system".tr(),
      child: const Icon(Symbols.brightness_auto_rounded),
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ToggleButtonWidget<ThemeMode>(
      title: "$tr_settings.style.brightness.title".tr(),
      description: "$tr_settings.style.brightness.description".tr(),
      icon: (mode) => _iconMap[mode]!,
      provider: themeSettingProvider,
    );
  }
}

class StyleSettingsGroup extends ConsumerWidget {
  const StyleSettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_settings.style.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        _BrightnessWidget(),
        SwitchWidget(
          title: Text("$tr_settings.style.font_bold.title".tr()),
          description: Text("$tr_settings.style.font_bold.description".tr()),
          provider: fontBoldSettingProvider,
        ),
      ],
    );
  }
}

class CaptureSettingsGroup extends ConsumerWidget {
  const CaptureSettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCapturing = ref.watch(capturingStateProvider);
    return ListCard(
      title: "$tr_settings.capture.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        SwitchWidget(
          title: Text("$tr_settings.capture.auto_start.title".tr()),
          description: Text("$tr_settings.capture.auto_start.description".tr()),
          provider: autoStartCaptureStateProvider,
        ),
        DropdownButtonWidget<CharaDetailRecordImageMode?>(
          title: "$tr_settings.capture.auto_copy.title".tr(),
          description: "$tr_settings.capture.auto_copy.description".tr(),
          name: (e) => "$tr_settings.capture.auto_copy.choice.${e!.name.snakeCase}".tr(),
          provider: autoCopyClipboardStateProvider,
        ),
        Disabled(
          disabled: isCapturing,
          tooltip: "$tr_settings.capture.force_resize.disabled_tooltip".tr(),
          child: SwitchWidget(
            title: Text("$tr_settings.capture.force_resize.title".tr()),
            description: Text("$tr_settings.capture.force_resize.description".tr()),
            provider: forceResizeModeStateProvider,
          ),
        ),
      ],
    );
  }
}

/// Settings for the notification sounds, letting the user swap each built-in clip for a custom
/// audio file and adjust its volume.
class SoundSettingsGroup extends ConsumerWidget {
  const SoundSettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_sound.title".tr(),
      padding: EdgeInsets.zero,
      children: [for (final type in SoundType.values) _SoundSettingTile(type: type)],
    );
  }
}

/// A single notification sound row: name, current source, volume slider, and the pick/test/reset
/// actions.
class _SoundSettingTile extends ConsumerStatefulWidget {
  final SoundType type;

  const _SoundSettingTile({required this.type});

  @override
  ConsumerState<_SoundSettingTile> createState() => _SoundSettingTileState();
}

class _SoundSettingTileState extends ConsumerState<_SoundSettingTile> {
  /// Slider position while the user is dragging. Kept local so the persisted volume (which reloads
  /// the audio player) is only committed once, on drag end.
  double? _dragVolume;

  /// Cache for [_isMissing]: the last custom path checked and whether it was absent.
  String? _checkedPath;
  bool _fileMissing = false;

  SoundType get _type => widget.type;

  /// Whether [setting] points at a custom file that no longer exists on disk.
  ///
  /// The player silently falls back to the default clip in that case, so the UI would otherwise
  /// keep showing a path that never plays. Memoized on the path so dragging the volume slider
  /// (which rebuilds every frame) does not trigger a filesystem stat per frame.
  bool _isMissing(SoundSetting setting) {
    if (!setting.isCustom) return false;
    if (setting.path != _checkedPath) {
      _checkedPath = setting.path;
      _fileMissing = !FilePath(setting.path).existsSync();
    }
    return _fileMissing;
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: "$tr_sound.picker_title".tr(),
      type: FileType.custom,
      allowedExtensions: const ["wav", "mp3"],
    );
    final path = file?.path;
    if (path == null) return;
    ref.read(soundSettingProvider(_type).notifier).setCustomFile(path);
  }

  void _test() {
    // load()/play() already log their own failures; swallow here only to avoid an unhandled async
    // error if the future rejects (e.g. the player was superseded mid-load, or setup threw).
    ref.read(soundEffectProvider(_type).future).then((effect) => effect.play()).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final setting = ref.watch(soundSettingProvider(_type));
    final notifier = ref.read(soundSettingProvider(_type).notifier);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final title = Text("$tr_sound.type.${_type.name.snakeCase}".tr(), style: theme.textTheme.titleMedium);
    final missing = _isMissing(setting);
    final pathStyle = missing ? labelStyle?.copyWith(color: theme.semantic.warning) : labelStyle;
    final sourceLabel = setting.isCustom
        ? Tooltip(
            // A full path rarely fits, so ellipsize from the front to keep the file name visible;
            // the tooltip shows the whole path on hover. When the file is gone, flag it so the user
            // knows the default clip is playing instead.
            message: missing ? "${"$tr_sound.missing_tooltip".tr()}\n${setting.path}" : setting.path,
            child: Row(
              children: [
                if (missing) ...[
                  Icon(Symbols.warning_rounded, size: 14, color: theme.semantic.warning),
                  const SizedBox(width: 4),
                ],
                Expanded(child: StartEllipsisText(setting.path, style: pathStyle)),
              ],
            ),
          )
        : Text("$tr_sound.source.default".tr(), style: labelStyle);

    final volumeIcon = Icon(Symbols.volume_up_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant);
    // Shared across both layouts (only one branch builds per frame): fixed-width when it sits beside
    // the path, and Expanded when it owns its own row.
    final slider = Slider(
      value: _dragVolume ?? setting.volume,
      onChanged: (value) => setState(() => _dragVolume = value),
      onChangeEnd: (value) {
        notifier.setVolume(value);
        setState(() => _dragVolume = null);
      },
    );
    final testButton = IconButton(
      tooltip: "$tr_sound.test_tooltip".tr(),
      icon: const Icon(Symbols.play_arrow_rounded),
      onPressed: _test,
    );
    final pickButton = IconButton(
      tooltip: "$tr_sound.pick_tooltip".tr(),
      icon: const Icon(Symbols.folder_open_rounded),
      onPressed: _pickFile,
    );
    // Reset is available whenever anything differs from the default: a custom clip or a tweaked
    // volume (even on the default clip).
    final canReset = setting.isCustom || setting.volume != SoundSetting.defaultValueOf(_type).volume;
    final resetButton = IconButton(
      tooltip: "$tr_sound.reset_tooltip".tr(),
      icon: const Icon(Symbols.settings_backup_restore_rounded),
      onPressed: canReset ? notifier.resetToDefault : null,
    );

    // Single row at any width: the path column takes the leftover space and ellipsizes (from the
    // front, so the file name stays visible) rather than reflowing the controls.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, sourceLabel]),
          ),
          volumeIcon,
          SizedBox(width: 200, child: slider),
          testButton,
          pickButton,
          resetButton,
        ],
      ),
    );
  }
}

class SystemGroup extends ConsumerWidget {
  const SystemGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_settings.system.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        DropdownButtonWidget<ClipboardPasteImageMode?>(
          title: "$tr_settings.system.clipboard_paste_image_mode.title".tr(),
          description: "$tr_settings.system.clipboard_paste_image_mode.description".tr(),
          name: (e) => "$tr_settings.system.clipboard_paste_image_mode.choice.${e!.name.snakeCase}".tr(),
          provider: clipboardPasteImageModeProvider,
        ),
        // Windows-only: the migration flow relies on a PowerShell relaunch and on
        // desktop path semantics (the settings box living under the documents
        // dir). Neither holds on Android/iOS/web, so the relocation UI is hidden
        // there rather than offering a broken migration.
        if (CurrentPlatform.isWindows()) const DataRootTile(),
      ],
    );
  }
}

class PrivacySettingsGroup extends ConsumerWidget {
  const PrivacySettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListCard(
      title: "$tr_settings.privacy.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        SwitchWidget(
          title: Text("$tr_settings.privacy.allow_post_user_data.title".tr()),
          description: RichText(
            text: TextSpan(
              style: theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant),
              children: [
                TextSpan(text: "$tr_settings.privacy.allow_post_user_data.description".tr()),
                TextSpan(
                  text: "$tr_settings.privacy.allow_post_user_data.sample_link".tr(),
                  style: const TextStyle(decoration: TextDecoration.underline),
                  recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Const.sentrySampleUrl),
                ),
              ],
            ),
          ),
          provider: allowPostUserDataStateProvider,
        ),
      ],
    );
  }
}

class _LicenseMaterialLocalizationsDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _LicenseMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';

  @override
  Future<MaterialLocalizations> load(Locale locale) => _LicenseMaterialLocalizations.load(locale);

  @override
  bool shouldReload(_LicenseMaterialLocalizationsDelegate old) => false;

  @override
  String toString() => 'LicenseMaterialLocalizations.delegate(en_US)';
}

class _LicenseMaterialLocalizations extends DefaultMaterialLocalizations {
  const _LicenseMaterialLocalizations();

  static const LocalizationsDelegate<MaterialLocalizations> delegate = _LicenseMaterialLocalizationsDelegate();

  static Future<MaterialLocalizations> load(Locale locale) {
    return SynchronousFuture<MaterialLocalizations>(const _LicenseMaterialLocalizations());
  }

  @override
  String get licensesPageTitle => "";
}

class _LicensePageDialog extends ConsumerWidget {
  const _LicensePageDialog();

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const _LicensePageDialog());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CardDialog(
      dialogTitle: "$tr_settings.about.license.dialog.title".tr(),
      closeButtonTooltip: "$tr_settings.about.license.dialog.close_button".tr(),
      usePageView: false,
      content: Expanded(
        child: Localizations(
          delegates: const <LocalizationsDelegate<dynamic>>[
            _LicenseMaterialLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
            DefaultMaterialLocalizations.delegate,
          ],
          locale: const Locale('en'),
          child: license.LicensePage(applicationVersion: ref.read(localAppVersionLoader).value.toString()),
        ),
      ),
    );
  }
}

class AboutGroup extends ConsumerWidget {
  const AboutGroup({super.key});

  String moduleVersion(WidgetRef ref) {
    return ref
        .watch(moduleVersionLoader)
        .when(
          loading: () => "checking...",
          error: (e, _) => "ERROR: $e",
          data: (data) {
            return data?.recognizerVersion.toLocal().toString() ?? "$tr_settings.about.version.unknown_version".tr();
          },
        );
  }

  String appVersion(WidgetRef ref) {
    return ref
        .watch(appVersionCheckLoader)
        .when(loading: () => "checking...", error: (e, _) => "ERROR: $e", data: (data) => data.local.toString());
  }

  String versionString(WidgetRef ref) {
    return "$tr_settings.about.version.description".tr(
      namedArgs: {"app_version": appVersion(ref), "module_version": moduleVersion(ref)},
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_settings.about.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        ListTile(
          title: Text("$tr_settings.about.license.title".tr()),
          subtitle: Text("$tr_settings.about.license.description".tr()),
          onTap: () {
            _LicensePageDialog.show(ref.base);
          },
        ),
        ListTile(
          isThreeLine: true,
          title: Text("$tr_settings.about.version.title".tr()),
          subtitle: Text(versionString(ref)),
          trailing: const Align(
            widthFactor: 1,
            child: Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.content_paste_rounded)),
          ),
          onTap: () => Pasteboard.writeText(versionString(ref)),
        ),
        Disabled(
          disabled: !ref.watch(charaDetailRecordRegenerationControllerProvider).isEmpty,
          child: ListTile(
            title: Text("$tr_settings.about.regenerate.title".tr()),
            subtitle: Text("$tr_settings.about.regenerate.description".tr()),
            trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.refresh_rounded)),
            onTap: () {
              final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
              storage.checkRecordVersion(includeCurrentVersion: true);
            },
          ),
        ),
        ListTile(
          title: Text("$tr_settings.about.resolve_inheritance.title".tr()),
          subtitle: Text("$tr_settings.about.resolve_inheritance.description".tr()),
          trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.refresh_rounded)),
          onTap: () {
            ref.read(charaDetailRecordStorageLoaderProvider.notifier).resolveAllInheritance();
          },
        ),
        ListTile(
          title: Text("$tr_settings.module_update.entry.title".tr()),
          subtitle: Text("$tr_settings.module_update.entry.description".tr()),
          trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.download_rounded)),
          onTap: () => ModuleManualUpdateDialog.show(ref.base),
        ),
      ],
    );
  }
}

/// Debug-only settings group. Hidden in release builds; hosts developer tools
/// such as the theme color gallery used for the ongoing theme review.
class DebugSettingsGroup extends ConsumerWidget {
  const DebugSettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: 'Debug',
      padding: EdgeInsets.zero,
      children: [
        ListTile(
          title: const Text('Theme gallery'),
          subtitle: const Text('Inspect the live ColorScheme, tokens, and hardcoded colors as swatches.'),
          trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.palette_rounded)),
          onTap: () => ThemeGalleryDialog.show(ref.base),
        ),
      ],
    );
  }
}

@RoutePage()
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTilePageRootWidget(
      children: [
        const StyleSettingsGroup(),
        const CaptureSettingsGroup(),
        const SoundSettingsGroup(),
        const SystemGroup(),
        const PrivacySettingsGroup(),
        const AboutGroup(),
        if (kDebugMode) const DebugSettingsGroup(),
      ],
    );
  }
}
