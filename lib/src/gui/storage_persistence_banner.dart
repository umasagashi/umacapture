import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:recase/recase.dart';

import '/src/core/fs/storage_persistence.dart';
import '/src/gui/record_store_banner.dart';

// ignore: constant_identifier_names
const tr_storage_persistence = "pages.capture.storage_persistence";

/// The host that answers "will the data I already saved still be there later?".
///
/// Indirected through a provider so a test can substitute a fake; production
/// resolves to the io or OPFS implementation via the conditional import in
/// `fs/storage_persistence.dart`.
final storagePersistenceProvider = Provider<StoragePersistence>((_) => platformStoragePersistence);

/// The persistence state as the UI sees it: `state` is null until the first read
/// settles, and `requesting` is true while a re-request is outstanding.
typedef StoragePersistenceStatus = ({StoragePersistenceState? state, bool requesting});

/// The app-visible persistence state, read once when first watched and updated
/// after each user-driven re-request.
class StoragePersistenceNotifier extends Notifier<StoragePersistenceStatus> {
  @override
  StoragePersistenceStatus build() {
    unawaited(_read());
    return (state: null, requesting: false);
  }

  Future<void> _read() async {
    final result = await ref.read(storagePersistenceProvider).read();
    if (ref.mounted) state = (state: result, requesting: false);
  }

  /// Asks the host for persistence and adopts the answer.
  ///
  /// The in-flight flag is not cosmetic: on Firefox this call sits on an
  /// unanswered doorhanger for the backend's whole timeout, and further taps
  /// would queue more prompts behind it.
  Future<void> request() async {
    if (state.requesting) return;
    state = (state: state.state, requesting: true);
    final result = await ref.read(storagePersistenceProvider).request();
    if (ref.mounted) state = (state: result, requesting: false);
  }
}

final storagePersistenceStateProvider = NotifierProvider<StoragePersistenceNotifier, StoragePersistenceStatus>(
  StoragePersistenceNotifier.new,
);

/// Blocking-looking banner shown at the top of the capture tab while the host
/// does not guarantee that saved data survives.
///
/// It exists because of a browser failure mode with no desktop analogue: OPFS
/// data is evictable until `navigator.storage.persist()` is granted, and neither
/// browser says so. Chromium decides without asking and can simply refuse; on
/// Firefox the user can leave the permission doorhanger unanswered forever. In
/// both cases the records can disappear under storage pressure with nothing in
/// the app ever having said so. This banner is the "having said so", and it sits
/// on the capture tab because that is where the user is about to create the data
/// that would be lost.
///
/// It is deliberately **not** web-only, and contains no platform test at all.
/// The state is a platform-neutral tri-state (see [StoragePersistenceState]) and
/// desktop simply always answers [StoragePersistenceState.persisted], which is
/// the branch that renders nothing — so the platform difference is carried
/// entirely by the state.
///
/// [StoragePersistenceState.unknown] warns as well. It is not evidence of risk,
/// but it is not evidence of safety either, and the case that produces it — an
/// unanswered Firefox doorhanger — leaves storage genuinely evictable. Only a
/// settled `persisted` earns silence. The wording stays distinct so the two are
/// not conflated.
class StoragePersistenceBanner extends ConsumerWidget {
  const StoragePersistenceBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(storagePersistenceStateProvider);
    final state = status.state;
    // Null is the first read still in flight; it is asynchronous on both
    // backends, so rendering a guess here would flash a warning at every
    // desktop launch.
    if (state == null || state == StoragePersistenceState.persisted) {
      return const SizedBox.shrink();
    }
    // The inset lives on the visible branch only, as it does for the app-level
    // banners: a padding that survived the invisible branch would push the whole
    // capture tab down by its own margin on every launch that is fine.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: RecordStoreBanner(
        // Keyed off the state's own name so a state added later reaches a
        // translation key instead of silently falling into another one's text.
        message: "$tr_storage_persistence.status.${state.name.snakeCase}".tr(),
        actions: [
          RecordStoreBannerAction(
            label: "$tr_storage_persistence.request_button".tr(),
            icon: Symbols.shield_rounded,
            // Disabled rather than merely idempotent while a request is in
            // flight: on Firefox it is sitting on a doorhanger the user has not
            // answered, and a button that still looks live invites the taps that
            // would queue more prompts behind it. Said as `inProgress` rather
            // than by nulling the callback, because the wait is the longest this
            // button is ever unavailable and a plain grey button gives the user
            // nothing to read it as; the banner turns this into a spinner.
            inProgress: status.requesting,
            onPressed: () => unawaited(ref.read(storagePersistenceStateProvider.notifier).request()),
          ),
        ],
      ),
    );
  }
}
