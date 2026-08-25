import 'dart:async';

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
import '/src/core/providers.dart';
import '/src/core/raw_frame_probe.dart';
import '/src/core/sound_player.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/core/video_import.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/app_widget.dart';
import '/src/gui/capture.dart';
import '/src/gui/common.dart';
import '/src/gui/license_alt.dart' as license;
import '/src/gui/module_update_dialog.dart';
import '/src/gui/raw_frame_probe_view.dart';
import '/src/gui/toast.dart';
import '/src/gui/storage_settings.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/theme_gallery.dart';
import '/src/gui/video_import.dart';
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
        // Both of the settings below need something a browser only grants in
        // response to a gesture, so neither is offered on web:
        //
        // - auto_start: starting a capture on web opens getDisplayMedia, which
        //   requires transient user activation. A load-time start has none, so it
        //   is guarded away in platform_controller.dart (the `!kIsWeb &&` next to
        //   autoStartCaptureStateProvider) and the switch would do nothing here.
        // - auto_copy: a browser clipboard write requires transient user
        //   activation too, which the post-capture callback that would perform
        //   this copy does not have (see CharaDetailRecordStorage.copyToClipboard).
        //
        // Same reasoning as the clipboard_paste_image_mode dropdown further down.
        if (!kIsWeb)
          SwitchWidget(
            title: Text("$tr_settings.capture.auto_start.title".tr()),
            description: Text("$tr_settings.capture.auto_start.description".tr()),
            provider: autoStartCaptureStateProvider,
          ),
        if (!kIsWeb)
          DropdownButtonWidget<CharaDetailRecordImageMode?>(
            title: "$tr_settings.capture.auto_copy.title".tr(),
            description: "$tr_settings.capture.auto_copy.description".tr(),
            name: (e) => "$tr_settings.capture.auto_copy.choice.${e!.name.snakeCase}".tr(),
            provider: autoCopyClipboardStateProvider,
          ),
        // Disabled while capturing for the same reason force_resize is: the core reads
        // `detail_crop_calibration` once, when the pipeline is built, so a mid-session toggle could not
        // take effect and would silently misrepresent what the running session is doing.
        Disabled(
          disabled: isCapturing,
          tooltip: "$tr_settings.capture.detail_crop_calibration.disabled_tooltip".tr(),
          child: const DetailCropCalibrationTile(),
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

// ignore: constant_identifier_names
const tr_detail_crop = "$tr_settings.capture.detail_crop_calibration";

/// Controls detail-crop auto-calibration and shows the corrected crop it currently uses.
///
/// The values come from native's `onDetailCropReported`, which is throttled at the source, so this rebuilds
/// at most about once a second while a crop is being measured.
@visibleForTesting
class DetailCropCalibrationTile extends ConsumerWidget {
  const DetailCropCalibrationTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = ref.watch(detailCropCalibrationStateProvider);
    final report = ref.watch(detailCropReportProvider);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final value = report == null
        ? "$tr_detail_crop.value.unmeasured".tr()
        : "$tr_detail_crop.value.corrected".tr(
            namedArgs: {
              "left": report.correctedRect.left.toString(),
              "top": report.correctedRect.top.toString(),
              "width": report.correctedRect.width.toString(),
              "height": report.correctedRect.height.toString(),
            },
          );

    void setEnabled(bool value) => ref.read(detailCropCalibrationStateProvider.notifier).set(value);

    return ListTile(
      title: Text("$tr_detail_crop.title".tr()),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("$tr_detail_crop.description".tr()),
          Text(value, style: labelStyle),
        ],
      ),
      trailing: Align(
        widthFactor: 1,
        child: Switch(value: enabled, onChanged: setEnabled),
      ),
      onTap: () => setEnabled(!enabled),
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
  /// Whether the current custom file is absent. Kept out of [build] so the filesystem stat runs
  /// only when the tile is created or the path changes, not on every rebuild.
  bool _fileMissing = false;

  /// Serial number of the most recently started stat. A stat that finishes after a newer one was
  /// started is discarded, so a rapid path change cannot settle the flag on the stale answer.
  int _statGeneration = 0;

  SoundType get _type => widget.type;

  @override
  void initState() {
    super.initState();
    // The tile is recreated whenever the settings page is opened, so this also re-checks on each
    // open. The stat is asynchronous (see [_recheckMissing]), so the first frame shows no warning
    // and the flag settles once the backend answers.
    unawaited(_recheckMissing(ref.read(soundSettingProvider(_type))));
  }

  /// Re-stats the custom file and updates [_fileMissing] if it changed.
  ///
  /// A custom clip that is gone makes the player silently fall back to the default, so the UI
  /// would otherwise keep showing a path that never plays. This is not desktop-only: a web custom
  /// sound lives in OPFS, which the browser may evict when storage was never granted persistence
  /// (see the storage persistence tile), leaving exactly the same state.
  ///
  /// Uses the asynchronous [PathEntity.exists] rather than `existsSync`, which is a desktop-only
  /// sync FS call that throws on web.
  Future<void> _recheckMissing(SoundSetting setting) async {
    final generation = ++_statGeneration;
    final missing = setting.isCustom && !await FilePath(setting.path).exists();
    if (!mounted || generation != _statGeneration || missing == _fileMissing) return;
    setState(() => _fileMissing = missing);
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: "$tr_sound.picker_title".tr(),
      type: FileType.custom,
      allowedExtensions: const ["wav", "mp3"],
    );
    if (file == null) return;
    if (kIsWeb) {
      try {
        final stored = await persistCustomSound(
          directory: ref.read(pathInfoProvider).customSoundDir,
          type: _type,
          originalName: file.name,
          bytes: await file.readAsBytes(),
        );
        ref.read(soundSettingProvider(_type).notifier).setCustomFile(stored.path);
      } catch (error, stackTrace) {
        logger.e("Failed to persist custom sound", error, stackTrace);
        Toaster.show(ToastData.error(description: "$tr_sound.save_failure".tr()));
      }
      return;
    }
    final path = file.path;
    if (path == null) return;
    ref.read(soundSettingProvider(_type).notifier).setCustomFile(path);
  }

  void _test() => ref.read(soundEffectProvider(_type).future).playSafely();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Re-check existence only when the path or source actually changes, not on volume-slider commits.
    ref.listen(soundSettingProvider(_type), (prev, next) {
      if (prev?.path != next.path || prev?.source != next.source) unawaited(_recheckMissing(next));
    });
    final setting = ref.watch(soundSettingProvider(_type));
    final notifier = ref.read(soundSettingProvider(_type).notifier);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final title = Text("$tr_sound.type.${_type.name.snakeCase}".tr(), style: theme.textTheme.titleMedium);
    final missing = _fileMissing;
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
          SizedBox(
            width: 200,
            child: _VolumeSlider(volume: setting.volume, onChangeEnd: notifier.setVolume),
          ),
          testButton,
          pickButton,
          resetButton,
        ],
      ),
    );
  }
}

/// A volume slider that commits to the notifier only on drag end.
///
/// Isolated so dragging (which rebuilds every frame) does not rebuild the surrounding tile — in
/// particular the front-ellipsized path label, whose [TextPainter] measurement would otherwise
/// re-run per frame.
class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({required this.volume, required this.onChangeEnd});

  /// The persisted volume; shown whenever the user is not mid-drag.
  final double volume;

  /// Commits the released volume to the notifier (reloads the audio player).
  final ValueChanged<double> onChangeEnd;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  /// Slider position while the user is dragging. Kept local so the persisted volume (which reloads
  /// the audio player) is only committed once, on drag end.
  double? _dragVolume;

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _dragVolume ?? widget.volume,
      onChanged: (value) => setState(() => _dragVolume = value),
      onChangeEnd: (value) {
        widget.onChangeEnd(value);
        setState(() => _dragVolume = null);
      },
    );
  }
}

class SystemGroup extends ConsumerWidget {
  const SystemGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Built as a list rather than inlined so the empty case is decidable: every
    // row here is platform-gated, and on web both gates close, which would
    // otherwise leave a titled card band with nothing under it.
    final rows = <Widget>[
      // Browsers can copy image bytes after a user gesture, but cannot place
      // native file references on the system clipboard, so there is no mode
      // choice to expose on web.
      if (!kIsWeb)
        DropdownButtonWidget<ClipboardPasteImageMode?>(
          title: "$tr_settings.system.clipboard_paste_image_mode.title".tr(),
          description: "$tr_settings.system.clipboard_paste_image_mode.description".tr(),
          name: (e) => "$tr_settings.system.clipboard_paste_image_mode.choice.${e!.name.snakeCase}".tr(),
          provider: clipboardPasteImageModeProvider,
        ),
      // Windows-only: the migration flow relies on a PowerShell relaunch and on
      // desktop path semantics (the settings box living under the documents
      // dir). Neither holds on Android/iOS/web, so the relocation UI is hidden
      // there rather than offering a broken migration. The web build reports
      // the host OS via defaultTargetPlatform (isWindows() is true in a Windows
      // browser), so exclude web explicitly.
      if (!CurrentPlatform.isWeb() && CurrentPlatform.isWindows()) const DataRootTile(),
    ];
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListCard(title: "$tr_settings.system.title".tr(), padding: EdgeInsets.zero, children: rows);
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
        const RegenerateAllRecordsTile(),
        const ResolveInheritanceTile(),
        const ModuleManualUpdateTile(),
      ],
    );
  }
}

/// The "re-resolve parent/child links across the whole store" entry of [AboutGroup].
///
/// A widget of its own for the same reason [RegenerateAllRecordsTile] is: so its gate has a seam
/// a test can mount without dragging in the version loaders and the license page.
///
/// The resolution is asynchronous and fire-and-forget, so the entry disables itself while one is
/// in flight instead of letting a second tap start another whole-store lock acquisition — and it
/// **says so**. A silent grey tile is exactly the defect [RegenerateAllBlocker] was introduced ten
/// lines below to remove; leaving its immediate neighbour silent would have reproduced it. There is
/// one reason here and no closed set is needed for it, but the obligation is the same: `disabled`
/// and `tooltip` are decided by one expression, so "is it inert" and "why" cannot disagree.
class ResolveInheritanceTile extends ConsumerWidget {
  const ResolveInheritanceTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolving = ref.watch(inheritanceResolutionRunningProvider);
    return Disabled(
      disabled: resolving,
      tooltip: resolving ? "$tr_settings.about.resolve_inheritance.blocked.resolving".tr() : null,
      child: ListTile(
        title: Text("$tr_settings.about.resolve_inheritance.title".tr()),
        subtitle: Text("$tr_settings.about.resolve_inheritance.description".tr()),
        trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.refresh_rounded)),
        onTap: () {
          ref.read(charaDetailRecordStorageLoaderProvider.notifier).resolveAllInheritance();
        },
      ),
    );
  }
}

/// The "apply a manually downloaded modules.zip" entry of [AboutGroup].
///
/// A widget of its own for the same reason [RegenerateAllRecordsTile] is: so its gate has a
/// seam a test can mount without dragging in the version loaders and the license page.
class ModuleManualUpdateTile extends StatelessWidget {
  /// The import state to gate on, defaulting to the front end's own. Injectable because
  /// `video_import.dart` resolves to the desktop stub under `flutter test`, where the
  /// notifier is a constant idle and the gate would be permanently open.
  final ValueListenable<VideoImportState>? importState;

  const ModuleManualUpdateTile({super.key, this.importState});

  @override
  Widget build(BuildContext context) {
    // A manual install is a regeneration entry point without a regeneration UI: on success it
    // calls `checkRecordVersion()`, which auto-starts a whole-store batch. It is also the one
    // entry that can destroy a running import outright -- installing modules invalidates
    // `moduleVersionLoader`, which `platformControllerLoader` watches, so the rebuild tears the
    // worker (and the import riding it) down. Worded from the key the other regeneration gates
    // use, so the user meets one explanation and not four.
    return ValueListenableBuilder<VideoImportState>(
      valueListenable: importState ?? videoImportState,
      builder: (context, import, _) => Disabled(
        disabled: import.isRunning,
        tooltip: import.isRunning ? "$tr_video_import.blocks_regeneration".tr() : null,
        child: Consumer(
          builder: (context, ref, _) => ListTile(
            title: Text("$tr_settings.module_update.entry.title".tr()),
            subtitle: Text("$tr_settings.module_update.entry.description".tr()),
            trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.download_rounded)),
            onTap: () => ModuleManualUpdateDialog.show(ref.base),
          ),
        ),
      ),
    );
  }
}

/// Why the whole-store "re-recognize captured records" entry may not be pressed right now.
///
/// **The reason is data, and the sentence is derived from it** — the shape [VideoImportBlocker]
/// uses, brought here because [RegenerateAllRecordsTile] had the same defect in its worst form: two
/// reasons in `disabled` and a `tooltip` that was non-null for **one** of them, so the entry was
/// greyed out and completely silent whenever the reason was the more common one, a regeneration
/// batch already running. That is the rule `video_import_ops.dart` states in words — "a disabled
/// control that does not say why is the defect the removed implementation set out to avoid" — being
/// broken by its neighbour.
///
/// A closed set plus the exhaustive [regenerateAllBlockerKey] means a third reason cannot be added
/// without the compiler demanding a sentence for it. A ternary could not do that: it pairs a
/// condition with a string at the call site, so whatever is added inherits an arm, silently.
@visibleForTesting
enum RegenerateAllBlocker {
  /// A video import owns the event loop, so a batch started here would be refused record by record.
  ///
  /// Named first so the sentence does not move: this is the one reason the tile explained before,
  /// and it is also the one that would refuse at the funnel every entry point shares
  /// (`CharaDetailRecordRegenerationController.start`), so it stays the more actionable of the two.
  /// The pair is not reachable in any case — each of the two refuses to start while the other runs —
  /// so precedence only decides which true sentence a race would show.
  importing,

  /// A regeneration batch is already in flight. **This is the reason that had no sentence at all**:
  /// the tile is disabled for the whole length of a batch the user themselves started, which is
  /// strictly the longer-lived and more often met of the two states.
  regenerating,
}

/// Which reason (if any) makes the whole-store regeneration entry inert, in precedence order.
@visibleForTesting
RegenerateAllBlocker? resolveRegenerateAllBlocker({required bool regenerating, required bool importing}) {
  if (importing) {
    return RegenerateAllBlocker.importing;
  }
  if (regenerating) {
    return RegenerateAllBlocker.regenerating;
  }
  return null;
}

/// The **full** translation key for [blocker]'s sentence.
///
/// Full keys rather than two leaves under one `blocked` map, because the two sentences deliberately
/// do not live in one namespace: `blocks_regeneration` is the shared refusal line that
/// [ModuleManualUpdateTile] and `RegenerateRecordDialog` also read, and
/// `regenerate_all_records_tile_test.dart` pins that sharing by name ("says it in the same words the
/// per-record dialog does"). Copying it into a local map would make one refusal grow three
/// explanations that nothing compares — the very thing the sharing exists to prevent. Only the
/// regeneration sentence is this control's own, and it is new.
///
/// Exhaustive and explicit, not `blocker.name`: easy_localization renders a key it cannot find **as
/// the key**, so a mistyped key ships `pages.…` into a tooltip instead of failing anywhere.
@visibleForTesting
String regenerateAllBlockerKey(RegenerateAllBlocker blocker) => switch (blocker) {
  RegenerateAllBlocker.importing => "$tr_video_import.blocks_regeneration",
  RegenerateAllBlocker.regenerating => "$tr_settings.about.regenerate.blocked.regenerating",
};

/// The whole-store "re-recognize captured records" entry of [AboutGroup].
///
/// A widget of its own only so its gate has a seam a test can mount: [AboutGroup] pulls in
/// the version loaders and the license page, none of which this gate has anything to do with.
class RegenerateAllRecordsTile extends ConsumerWidget {
  /// The import state to gate on, defaulting to the front end's own.
  ///
  /// Injectable for the same reason [VideoImportGateNotice]'s is: the `video_import.dart` facade
  /// resolves to the desktop stub under `flutter test` (no `dart:js_interop` compiles on the
  /// VM), where the notifier is a constant idle -- so without this the gate below is
  /// permanently open and not one line of it is testable.
  final ValueListenable<VideoImportState>? importState;

  const RegenerateAllRecordsTile({super.key, this.importState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The third half of import/regeneration mutual exclusion, on exactly the predicate the record
    // table's context menu and RegenerateRecordDialog are gated on, worded from the same key so the
    // user meets one explanation and not three. Without it this entry started a whole-store batch
    // that the worker refused record by record ("a video import owns the event loop"), turning every
    // record in the store into an error-level failure. Listened to rather than read: the settings
    // page stays mounted for as long as the user leaves it open, and an import can begin behind it.
    return ValueListenableBuilder<VideoImportState>(
      valueListenable: importState ?? videoImportState,
      builder: (context, import, _) {
        // One expression decides both halves, so "is it inert" and "why" cannot disagree. They did:
        // the disjunction listed two reasons and the tooltip covered one of them.
        final blocker = resolveRegenerateAllBlocker(
          regenerating: !ref.watch(charaDetailRecordRegenerationControllerProvider).isEmpty,
          importing: import.isRunning,
        );
        return Disabled(
          disabled: blocker != null,
          tooltip: blocker == null ? null : regenerateAllBlockerKey(blocker).tr(),
          child: ListTile(
            title: Text("$tr_settings.about.regenerate.title".tr()),
            subtitle: Text("$tr_settings.about.regenerate.description".tr()),
            trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.refresh_rounded)),
            onTap: () {
              final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
              storage.checkRecordVersion(includeCurrentVersion: true);
            },
          ),
        );
      },
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
        if (rawFrameProbeEnabled) const RawFrameProbeGroup(),
        if (kDebugMode) const DebugSettingsGroup(),
      ],
    );
  }
}
