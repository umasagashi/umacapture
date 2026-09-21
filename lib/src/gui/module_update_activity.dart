import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/module_update_dialog.dart';

/// What a page waiting on [moduleVersionLoader] is actually waiting for: the
/// sentence to show, and the fraction for a progress bar (`null` for an
/// indeterminate bar).
typedef ModuleUpdateActivityDisplay = ({String label, double? fraction});

/// The one place that decides which module update phase a waiting page names.
///
/// A parked install ([longReadDeferralsProvider]) wins over the published phase,
/// because the park happens inside [ModuleInstalling]: the install has been
/// announced but is not running yet. `null` when the update is in no named phase,
/// in which case the page keeps its own loading text.
ModuleUpdateActivityDisplay? moduleUpdateActivityDisplay(WidgetRef ref) {
  final parked = ref.watch(longReadDeferralsProvider).containsKey(LongReadKind.moduleInstall);
  final activity = ref.watch(moduleUpdateActivityProvider);
  if (parked) {
    return (label: "$tr_module_update.activity.waiting".tr(), fraction: null);
  }
  return switch (activity) {
    null => null,
    ModuleDownloading(:final progress) => _downloadingDisplay(progress),
    ModuleInstalling() => (label: "$tr_module_update.activity.installing".tr(), fraction: null),
  };
}

ModuleUpdateActivityDisplay _downloadingDisplay(Progress progress) {
  final received = _megabytes(progress.count);
  // Checked before [Progress.progress], which divides by a zero total here.
  if (progress.indeterminate) {
    return (
      label: "$tr_module_update.activity.downloading_unknown_length".tr(namedArgs: {"received": received}),
      fraction: null,
    );
  }
  // Clamped: a browser that decompresses a gzip body reports the decompressed
  // byte count against the compressed length, so the ratio can pass 1.
  final fraction = Math.clamp(0.0, progress.progress, 1.0);
  return (
    label: "$tr_module_update.activity.downloading".tr(
      namedArgs: {
        "percent": (fraction * 100).floor().toString(),
        "received": received,
        "total": _megabytes(progress.total),
      },
    ),
    fraction: fraction,
  );
}

String _megabytes(int bytes) => (bytes / 1000000).toStringAsFixed(1);

/// The phase as text alone, for the one-line surfaces (the settings version row
/// and the manual update dialog).
String? moduleUpdateActivityLabel(WidgetRef ref) => moduleUpdateActivityDisplay(ref)?.label;

/// Names what a page waiting on [moduleVersionLoader] is waiting for, with a
/// progress bar. Renders nothing while the update is in no named phase, so a
/// page can place it unconditionally under its own loading indicator.
class ModuleUpdateActivityView extends ConsumerWidget {
  const ModuleUpdateActivityView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = moduleUpdateActivityDisplay(ref);
    if (display == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            display.label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          // Bounded: an unconstrained linear indicator in a centred column
          // stretches across the whole page.
          SizedBox(width: 240, child: LinearProgressIndicator(value: display.fraction)),
        ],
      ),
    );
  }
}
