import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_store_unavailable.dart';
import '/src/core/providers.dart';
import '/src/gui/record_store_banner.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

/// Blocking banner shown whenever this context cannot provide the cross-tab
/// record lock.
///
/// Mounted at app level, not on the record tab: every persisted read and write
/// goes through that lock, so capture, import, archive and the record list all
/// fail together and the statement has to be visible wherever the user is. The
/// capability is probed once per session
/// ([recordMutationLockUnavailabilityProvider]) instead of being discovered as a
/// thrown exception on each individual record operation — which previously
/// surfaced, if at all, as an untranslated developer message with no cause and
/// no remedy.
///
/// The three reasons carry three different remedies (serve the app over HTTPS,
/// use another browser, report a build/wiring fault), so each has its own text.
class RecordLockUnavailableBanner extends ConsumerWidget {
  const RecordLockUnavailableBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reason = ref.watch(recordMutationLockUnavailabilityProvider);
    if (reason == null) {
      return const SizedBox.shrink();
    }
    // The horizontal inset lives here, on the visible branch only: this banner is
    // mounted above every page, so a padding that survived the invisible branch
    // would shift the whole app down by its own margin on every startup.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: RecordStoreBanner(
        icon: Symbols.dangerous_rounded,
        message: "app.record_lock_unavailable.${reason.name.toSnakeCase()}".tr(),
      ),
    );
  }
}

/// Statement shown when a whole store could not be scanned at all.
///
/// One widget for both scopes because the user-facing shape is identical — say
/// which store is missing, say whether waiting fixes it, offer the rescan — and
/// only the message key and the provider to invalidate differ. The rescan is the
/// only action there is: the rescan is what re-runs the listing that failed, and
/// it is the same gesture [IncompleteStoreBanner] offers one scope down.
class _StoreOutageBanner extends StatelessWidget {
  const _StoreOutageBanner({
    required this.outage,
    required this.messageKey,
    required this.onRescan,
    this.rescanLabelKey = "$tr_chara_detail.store_outage.rescan",
  });

  final RecordStoreUnavailable outage;
  final String messageKey;
  final VoidCallback onRescan;

  /// Overridden by the startup scope, whose retry restarts the app's own
  /// initialization rather than rescanning a store the app never reached.
  final String rescanLabelKey;

  @override
  Widget build(BuildContext context) {
    return RecordStoreBanner(
      // A blocked store is not going to clear on its own, so it gets the harder
      // icon; a busy one is the ordinary "another tab is working" wait.
      icon: outage.transient ? Symbols.hourglass_top_rounded : Symbols.dangerous_rounded,
      message: "$messageKey.${outage.transient ? 'busy' : 'blocked'}".tr(),
      actions: [
        RecordStoreBannerAction(label: rescanLabelKey.tr(), icon: Symbols.refresh_rounded, onPressed: onRescan),
      ],
    );
  }
}

/// Blocking banner shown when the app's own startup could not open the record
/// store.
///
/// Mounted app level, next to [RecordLockUnavailableBanner] and for the same
/// reason: `pathInfoLoader` resolves the directory layout *and* runs the
/// exclusive-root maintenance that prepares the store, and capture, settings,
/// addons and both record stores all await it. When it fails they fail together,
/// so a statement on the record tab would be both incomplete and, on every other
/// tab, absent — leaving the raw exception in the page's error view as the only
/// account of why nothing works.
///
/// The retry re-runs the loader itself rather than any store scan: the stores are
/// downstream of it, so rescanning them would replay the same cached rejection.
class RecordStoreStartupOutageBanner extends ConsumerWidget {
  const RecordStoreStartupOutageBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outage = ref.watch(pathInfoOutageProvider);
    if (outage == null) {
      return const SizedBox.shrink();
    }
    // As in [RecordLockUnavailableBanner], the inset lives on the visible branch
    // only: this banner is above every page, and a padding that survived the
    // invisible branch would shift the whole app down on every startup.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: _StoreOutageBanner(
        outage: outage,
        messageKey: "app.record_store_startup",
        rescanLabelKey: "app.record_store_startup.retry",
        onRescan: () => ref.invalidate(pathInfoLoader),
      ),
    );
  }
}

/// Full-width replacement for the record table when the *active* store could not
/// be scanned.
///
/// Mounted ahead of the loader, for the same reason
/// [RecordLockUnavailableBanner] is: without a listing there is no table to draw,
/// the store provider is in an error state, and the page's generic error branch
/// can only paint the raw exception — an English `RecordMutationLockBusy` and a
/// stack trace in a Japanese UI, with no statement of what to do.
///
/// The outage is passed in rather than watched: the page reads it off the loader
/// that already awaits the store, so watching the store here would start its scan
/// out of turn (see [CharaDetailDataTableLoaderLayer]).
class RecordStoreOutageBanner extends ConsumerWidget {
  const RecordStoreOutageBanner({super.key, required this.outage});

  final RecordStoreUnavailable outage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: _StoreOutageBanner(
        outage: outage,
        messageKey: "$tr_chara_detail.store_outage",
        // The archive is rescanned with it: it sequences itself after the active
        // store, so a root outage almost always took both down together.
        onRescan: () {
          ref.invalidate(charaDetailRecordStorageLoaderProvider);
          ref.invalidate(charaDetailArchiveStorageLoaderProvider);
        },
      ),
    );
  }
}

/// Persistent banner shown when the *archive* store could not be scanned.
///
/// Sits above the table rather than replacing it: the active records are loaded
/// and usable, and the loss is that duplicate detection and inheritance
/// resolution are running without the archived candidates. That is invisible
/// otherwise — the archive load is deliberately not awaited by the page, so its
/// failure changes nothing on screen while quietly changing what the app decides.
class ArchiveStoreOutageBanner extends ConsumerWidget {
  const ArchiveStoreOutageBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outage = ref.watch(charaDetailArchiveOutageProvider);
    if (outage == null) {
      return const SizedBox.shrink();
    }
    return _StoreOutageBanner(
      outage: outage,
      messageKey: "$tr_chara_detail.store_outage.archive",
      onRescan: () => ref.invalidate(charaDetailArchiveStorageLoaderProvider),
    );
  }
}

/// Persistent banner shown while the last store scan could not open every
/// record.
///
/// The transient toast at load time is not enough on its own: it is shown once,
/// while the same incompleteness silently weakens duplicate detection and
/// inheritance resolution for the whole session. Counting only quarantined
/// records — which is what the banner row used to do — left an incomplete store
/// with no persistent trace at all.
class IncompleteStoreBanner extends ConsumerWidget {
  const IncompleteStoreBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unavailable = ref.watch(charaDetailUnavailableRecordsProvider);
    if (unavailable.isEmpty) {
      return const SizedBox.shrink();
    }
    return RecordStoreBanner(
      message: "$tr_chara_detail.incomplete_banner.message".tr(namedArgs: {"count": "${unavailable.length}"}),
      actions: [
        RecordStoreBannerAction(
          label: "$tr_chara_detail.incomplete_banner.rescan".tr(),
          icon: Symbols.refresh_rounded,
          onPressed: () {
            ref.invalidate(charaDetailRecordStorageLoaderProvider);
            ref.invalidate(charaDetailArchiveStorageLoaderProvider);
          },
        ),
      ],
    );
  }
}

extension on String {
  /// `insecureContext` -> `insecure_context`, so a
  /// [RecordMutationLockUnavailableReason] maps to a translation key without a
  /// switch that a new reason could silently escape.
  String toSnakeCase() => replaceAllMapped(RegExp('[A-Z]'), (match) => '_${match.group(0)?.toLowerCase()}');
}
