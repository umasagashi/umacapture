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
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
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
import '/src/gui/storage_tree.dart';
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
      // The layout and not `pathInfoProvider`: a custom sound is written next to the settings and
      // not into the record store, so choosing one is offered during a store outage -- and reading
      // the store-prepared layout there would have thrown out of the picker's callback instead of
      // reporting anything. Null only while the app has not resolved its own directories, which is
      // the same outcome for the user as a failed write, so it is reported as one.
      final soundDir = ref.read(pathLayoutProvider)?.customSoundDir;
      if (soundDir == null) {
        logger.e("Failed to persist custom sound: the directory layout is not resolved");
        Toaster.show(ToastData.error(description: "$tr_sound.save_failure".tr()));
        return;
      }
      try {
        final stored = await persistCustomSound(
          directory: soundDir,
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

/// Whether this build is the web one — as a **dependency**, not as a constant
/// read at each use site.
///
/// `kIsWeb` is a compile-time `false` under `flutter test`, so a use site that
/// reads it directly makes the web arrangement of this card not merely untested
/// but *unreachable* from the VM: the branch is folded away before the test
/// runs. That matters here because the two rows below are the ones that close on
/// web, and what is left when they do — [StorageManagerTile], the one row the
/// browser build has to keep, because on web that view is the only way to see the
/// app's data at all — is exactly what a VM test could not otherwise see. Same reasoning, and same shape, as `storageOnWebProvider`
/// in `storage_tree.dart` and `clipboardFileReferenceSupportProvider` in
/// `clipboard_alt.dart`; the default is `kIsWeb`, so the shipped behaviour is
/// unchanged.
final settingsOnWebProvider = Provider<bool>((ref) => kIsWeb);

class SystemGroup extends ConsumerWidget {
  const SystemGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onWeb = ref.watch(settingsOnWebProvider);
    // Built as a list rather than inlined so the empty case stays decidable. Two
    // of the three rows are platform-gated and both gates close on web; the
    // storage row is not gated, which is what keeps the card from coming out
    // empty there — see [StorageManagerTile] for why that row may not be gated.
    final rows = <Widget>[
      // Browsers can copy image bytes after a user gesture, but cannot place
      // native file references on the system clipboard, so there is no mode
      // choice to expose on web.
      if (!onWeb)
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
      if (!onWeb && CurrentPlatform.isWindows()) const DataRootTile(),
      // Where the data is, then what is in it. Ungated: this is the only way
      // into the storage view on web, where the two rows above are absent.
      const StorageManagerTile(),
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

  /// What the module row shows while the version check has not answered.
  ///
  /// Two sentences and not one, because `loading` covers two states that differ
  /// by minutes. An automatic install that reaches a held `modules/` parks until
  /// the reader lets go ([LongReadRegistry.holdWhenFree]), and the loader this
  /// row reads stays `loading` for the whole park — so the row said 「確認中...」
  /// about a check that had already finished, for as long as a whole-store
  /// re-recognition takes. The park is a state the registry carries
  /// ([longReadDeferralsProvider]), so the row is told which of the two it is
  /// rather than inferring it from how long it has been waiting.
  String moduleVersionLoadingLabel(WidgetRef ref) {
    return ref.watch(longReadDeferralsProvider).containsKey(LongReadKind.moduleInstall)
        ? "$tr_settings.about.version.waiting".tr()
        : "$tr_settings.about.version.checking".tr();
  }

  String moduleVersion(WidgetRef ref) {
    // Read before the `when`, so the row rebuilds when the park begins or ends:
    // a watch inside the `loading` branch is only established while that branch
    // is the one being built, which is true here but rests on it.
    final loadingLabel = moduleVersionLoadingLabel(ref);
    return ref
        .watch(moduleVersionLoader)
        .when(
          loading: () => loadingLabel,
          error: (e, _) => "ERROR: $e",
          data: (data) {
            return data?.recognizerVersion.toLocal().toString() ?? "$tr_settings.about.version.unknown_version".tr();
          },
        );
  }

  String appVersion(WidgetRef ref) {
    return ref
        .watch(appVersionCheckLoader)
        .when(
          loading: () => "$tr_settings.about.version.checking".tr(),
          error: (e, _) => "ERROR: $e",
          data: (data) => data.local.toString(),
        );
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

/// Why the "re-resolve parent/child links across the whole store" entry may not be pressed right
/// now.
///
/// A closed set for the same reason [RegenerateAllBlocker] is one: the tile shipped with a single
/// reason and a ternary, and the moment a second reason arrived the ternary would have paired it
/// with whichever arm it fell into, silently. With an exhaustive [resolveInheritanceBlockerKey] a
/// third reason cannot be added without the compiler demanding a sentence for it.
@visibleForTesting
enum ResolveInheritanceBlocker {
  /// A resolution started here is already in flight; a second tap would take a second whole-store
  /// lock acquisition. Fire-and-forget with no progress UI, so this flag is the only sign of it.
  resolving,

  /// A registered long reader is holding the record store this resolution reads and writes back.
  ///
  /// **This is the direction the tile was blind to.** `resolveAllInheritance` announces itself
  /// (`LongReadKind.inherit` over the record store root), so every *other* surface was already
  /// withheld while a resolution ran — but the tile itself asked nothing, and a resolution could be
  /// started on top of a zip, an export, a scan or a module relocation that had the same tree open.
  /// Named last on purpose; see [resolveInheritanceBlockerOf].
  longRead,
}

/// Which reason (if any) makes the inheritance-resolution entry inert, in precedence order.
///
/// **[longRead] is last, for the reason [resolveRegenerateAllBlocker] states.** A resolution that is
/// running holds a claim of its own over the whole record store, so [resolving] and a non-null
/// [heldBy] are true together for the whole of the most common case — and there 「再解決の実行中です」
/// is both true and specific, while the long reader's sentence would answer "why?" with 「他の処理」
/// about the user's own resolution.
@visibleForTesting
ResolveInheritanceBlocker? resolveInheritanceBlockerOf({required bool resolving, required LongReadKind? heldBy}) {
  if (resolving) {
    return ResolveInheritanceBlocker.resolving;
  }
  if (heldBy != null) {
    return ResolveInheritanceBlocker.longRead;
  }
  return null;
}

/// The **full** translation key for [blocker]'s sentence.
///
/// Exhaustive and explicit, not `blocker.name`, for the reason [regenerateAllBlockerKey] gives:
/// easy_localization renders a key it cannot find *as the key*, so a mistyped one ships `pages.…`
/// into a tooltip instead of failing anywhere.
@visibleForTesting
String resolveInheritanceBlockerKey(ResolveInheritanceBlocker blocker) => switch (blocker) {
  ResolveInheritanceBlocker.resolving => "$tr_settings.about.resolve_inheritance.blocked.resolving",
  // Not a sentence of this control's own: the one refusal every long reader produces is worded
  // once, in `long_read_registry.dart`, so this arm cost no new string.
  ResolveInheritanceBlocker.longRead => longReadBusyKey,
};

/// The "re-resolve parent/child links across the whole store" entry of [AboutGroup].
///
/// A widget of its own for the same reason [RegenerateAllRecordsTile] is: so its gate has a seam
/// a test can mount without dragging in the version loaders and the license page.
///
/// The resolution is asynchronous and fire-and-forget, so the entry disables itself while one is
/// in flight instead of letting a second tap start another whole-store lock acquisition — and it
/// **says so**. A silent grey tile is exactly the defect [RegenerateAllBlocker] was introduced
/// below to remove; leaving its immediate neighbour silent would have reproduced it. `disabled`
/// and `tooltip` are decided by one expression, so "is it inert" and "why" cannot disagree.
class ResolveInheritanceTile extends ConsumerWidget {
  const ResolveInheritanceTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolving = ref.watch(inheritanceResolutionRunningProvider);
    // Watched, not read: a long read can end while the settings page is open, and the tile has to
    // come back on its own when it does.
    final claims = ref.watch(longReadRegistryProvider).values;
    // The layout and not `pathInfoProvider`: this tile only needs to know where the store is, and
    // it is drawn during a store outage -- the one state in which the app knows that and could not
    // open the store. Watched for the same reason the claims are: the layout resolves a few frames
    // into a launch and the tile has to start answering when it does.
    final layout = ref.watch(pathLayoutProvider);
    // **The record store root, which is the path the resolution itself claims.** Both stores are
    // read in full and the changed records are written back to whichever one owns them, so the
    // honest question is the one `CharaDetailRecordStorage.resolveAllInheritance` answers about
    // itself: `rootDirectory.parent`, the parent of `active/` and `archive/`. Asking about either
    // half, or about a list of record ids, would be a second derivation of the same fact -- and the
    // one that goes stale when the store gains another directory.
    final heldBy = storageDeleteBlockedBy(
      layout == null ? null : StorageDeletePathsRequest([layout.charaDetailDir]),
      claims,
    );
    final blocker = resolveInheritanceBlockerOf(resolving: resolving, heldBy: heldBy);
    return Disabled(
      disabled: blocker != null,
      tooltip: blocker == null ? null : resolveInheritanceBlockerKey(blocker).tr(),
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

/// Why the "apply a manually downloaded modules.zip" entry may not be pressed right now.
///
/// A closed set for the reason [RegenerateAllBlocker] is one, and the same reason the ternary this
/// replaced was not enough: a second condition added beside a ternary inherits an arm silently.
@visibleForTesting
enum ModuleInstallBlocker {
  /// A video import owns the event loop, and installing modules would tear it down.
  ///
  /// The install invalidates `moduleVersionLoader`, which `platformControllerLoader` watches, so the
  /// rebuild takes the worker -- and the import riding it -- with it. It is also a regeneration
  /// entry point without a regeneration UI: on success it calls `checkRecordVersion()`, which
  /// auto-starts a whole-store batch the worker would refuse record by record.
  importing,

  /// A registered long reader is holding `modules/`, which this install rewrites.
  ///
  /// **This is the direction that stayed open when the install learnt to announce itself.**
  /// `runModuleInstall` claims `modulesDir` for the length of the extraction, so the record page's
  /// export and the storage view's zip/copy/save of the `modules` row are withheld while an install
  /// runs. The registry is not a lock, though, so that says nothing about the opposite order: an
  /// export already walking `modules/labels.json`, or a data-root relocation moving `modules/`
  /// wholesale, could be overwritten by an install started on top of it. This is the tile asking the
  /// same question of itself that it makes everyone else ask of it.
  longRead,
}

/// Which reason (if any) makes the manual module install inert, in precedence order.
///
/// [importing] first for the reason [RegenerateAllBlocker.importing] states: of the two it is the
/// one the user can go and stop. A long read has no stop and can only be waited out.
@visibleForTesting
ModuleInstallBlocker? resolveModuleInstallBlocker({required bool importing, required LongReadKind? heldBy}) {
  if (importing) {
    return ModuleInstallBlocker.importing;
  }
  if (heldBy != null) {
    return ModuleInstallBlocker.longRead;
  }
  return null;
}

/// The **full** translation key for [blocker]'s sentence.
///
/// Exhaustive and explicit for the reason [regenerateAllBlockerKey] gives, and neither arm is a
/// string of this control's own: the import refusal is the shared line every regeneration gate
/// reads, and the long-read refusal is the app's one.
@visibleForTesting
String moduleInstallBlockerKey(ModuleInstallBlocker blocker) => switch (blocker) {
  ModuleInstallBlocker.importing => "$tr_video_import.blocks_regeneration",
  ModuleInstallBlocker.longRead => longReadBusyKey,
};

/// The "apply a manually downloaded modules.zip" entry of [AboutGroup].
///
/// A widget of its own for the same reason [RegenerateAllRecordsTile] is: so its gate has a
/// seam a test can mount without dragging in the version loaders and the license page.
class ModuleManualUpdateTile extends ConsumerWidget {
  /// The import state to gate on, defaulting to the front end's own. Injectable because
  /// `video_import.dart` resolves to the desktop stub under `flutter test`, where the
  /// notifier is a constant idle and the gate would be permanently open.
  final ValueListenable<VideoImportState>? importState;

  const ModuleManualUpdateTile({super.key, this.importState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<VideoImportState>(
      valueListenable: importState ?? videoImportState,
      builder: (context, import, _) {
        // Watched, not read: an export or a relocation can end while the settings page is open, and
        // the entry has to come back on its own.
        final claims = ref.watch(longReadRegistryProvider).values;
        // The layout and not `pathInfoProvider`, for the reason [ResolveInheritanceTile] states: a
        // module install does not need the record store to have opened, and this entry is drawn
        // while it has not.
        final layout = ref.watch(pathLayoutProvider);
        // **`modulesDir`, which is the path `runModuleInstall` claims.** The desktop leg unpacks
        // into `modulesDir.parent`, but what it replaces is `modules/` -- and asking about the
        // parent would withhold the entry for a claim on `settings/` next door. One derivation of
        // "where a module install lands", stated on both sides of the same question.
        final heldBy = storageDeleteBlockedBy(
          layout == null ? null : StorageDeletePathsRequest([layout.modulesDir]),
          claims,
        );
        final blocker = resolveModuleInstallBlocker(importing: import.isRunning, heldBy: heldBy);
        return Disabled(
          disabled: blocker != null,
          tooltip: blocker == null ? null : moduleInstallBlockerKey(blocker).tr(),
          child: ListTile(
            title: Text("$tr_settings.module_update.entry.title".tr()),
            subtitle: Text("$tr_settings.module_update.entry.description".tr()),
            trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.download_rounded)),
            onTap: () => ModuleManualUpdateDialog.show(ref.base),
          ),
        );
      },
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

  /// A registered long reader is holding the active store this batch would rewrite.
  ///
  /// The tile stopped a batch of this kind before it explained one:
  /// `CharaDetailRecordRegenerationController.start` — the funnel all five regeneration entry
  /// points share — refuses while a long reader holds the records, so the tap did nothing and
  /// said nothing. This is that refusal, given a reason.
  ///
  /// Named last on purpose; see [resolveRegenerateAllBlocker].
  longRead,
}

/// Which reason (if any) makes the whole-store regeneration entry inert, in precedence order.
///
/// **[longRead] is last because a running batch holds a claim of its own.** While
/// [regenerating] is true so is [heldBy] — `CharaDetailRecordRegenerationController` claims every
/// `active/<id>` it was handed for the length of the batch — so the two are true together for the
/// whole of the most common case. 「再認識の実行中です」 is both true and specific there, while the
/// long reader's sentence would answer "why?" with 「他の処理」 about the user's own batch.
///
/// [importing] stays first for the reason its own member states: it is the one of the three the
/// user can go and stop.
@visibleForTesting
RegenerateAllBlocker? resolveRegenerateAllBlocker({
  required bool regenerating,
  required bool importing,
  required LongReadKind? heldBy,
}) {
  if (importing) {
    return RegenerateAllBlocker.importing;
  }
  if (regenerating) {
    return RegenerateAllBlocker.regenerating;
  }
  if (heldBy != null) {
    return RegenerateAllBlocker.longRead;
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
  // Not a sentence of this control's own, and that is the point: the one refusal every long
  // reader produces is worded once, in `long_read_registry.dart`, so this entry cost no new
  // string. Named through the exported constant rather than spelled again here.
  RegenerateAllBlocker.longRead => longReadBusyKey,
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
        // Watched, not read: a long read can end while the settings page is open, and the tile
        // has to come back on its own when it does.
        final claims = ref.watch(longReadRegistryProvider).values;
        // The layout and not `pathInfoProvider`, for the reason [ResolveInheritanceTile] states.
        final layout = ref.watch(pathLayoutProvider);
        // **The active store's root, not a list of records**, which is what a null `recordIds`
        // asks `regenerateRecordLongReadPaths` for: a whole-store batch cannot know which
        // records it will touch until `checkRecordVersion` has walked the store, so the honest
        // question is about the one directory that contains all of them. Asked through that
        // derivation rather than written out here, so this tile carries the other half of what a
        // batch writes — the write transaction journal — without a second list saying so. A
        // hand-written enumeration of destinations is what this seam exists to stop.
        final heldBy = storageDeleteBlockedBy(
          layout == null
              ? null
              : StorageDeletePathsRequest(regenerateRecordLongReadPaths(pathInfo: layout, recordIds: null)),
          claims,
        );
        // One expression decides both halves, so "is it inert" and "why" cannot disagree. They did:
        // the disjunction listed two reasons and the tooltip covered one of them.
        final blocker = resolveRegenerateAllBlocker(
          regenerating: !ref.watch(charaDetailRecordRegenerationControllerProvider).isEmpty,
          importing: import.isRunning,
          heldBy: heldBy,
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
