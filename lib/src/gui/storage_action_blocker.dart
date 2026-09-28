/// Why the storage view is withholding an action it otherwise offers, right now
/// — today, only because a capture is running and writes into the group.
///
/// **Separate from whether the action exists at all.** `storageGroupOffersDelete`
/// and the zip/copy capability providers answer a property of the group or of the
/// build, and those answers never change while the app runs. This one is a
/// property of what the app is *doing*, it goes away by itself, and it therefore
/// has to explain itself: a control that is dead for a reason the user can remove
/// must name the reason first and the remedy second.
///
/// **It covers extraction as well as deletion, because the hint promised that and
/// a read needs the same exclusion a write does.** temp's hint says 「キャプチャや
/// 動画の取り込みを実行中の場合は、その処理が失敗することがあります」, and bundling a
/// folder into a zip takes the very lock a delete does
/// — which `runUnderStorageExclusion` honours by taking the group's
/// lock, but only against a counterparty that takes it too. **A capture's writers
/// never do**: the synchronous merge cannot await an acquisition and the native
/// core is another process, so for the groups they write into the lock table has
/// no answer whatever the group's [StorageLockScope] says, and this gate is the
/// whole of it — for a zip exactly as for a delete, since a bundle taken out of a
/// folder that is still being written is a broken archive that looks like a good
/// one until it is opened. Which groups those are is
/// [StorageGroup.writtenByLiveCapture], where the writers are named one by one.
///
/// **A live capture is on the long-read registry as well, and this gate is
/// not a duplicate of that.** [LongReadKind.liveCapture] is claimed for the
/// length of a session over the same groups, which is what lets the record page,
/// the settings page and the module installs — none of which read this file —
/// withhold their own controls. What this gate keeps is the half the registry
/// deliberately gives up: it knows *which* activity is running, so the storage
/// view can name it and offer the remedy (「キャプチャを止めてから」), where
/// `longReadBusyMessage` is subjectless by design and can only say to wait. The
/// storage view therefore asks this first and returns on its answer.
/// [LongReadKind.videoImport] has had exactly this arrangement since it was
/// wired, and its doc gives the reason at the member.
///
/// **Why the activity arrives as [CaptureActivity] and not as a bool.**
/// `video_import_ops.dart` records what happened when several gates each read the
/// capture flag and the import state separately: they disagreed, and an open file
/// dialog was explained as a running import. The first version of this gate read
/// the capture flag alone, which does not disagree with anything — it simply did
/// not see the import, while the sentence beside it promised that it did.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/storage/storage_group.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/storage_tree.dart';

/// What the view was about to do, in the words the refusal has to use.
///
/// Members and not one string per call site: the sentence differs only in its
/// verb, and a verb supplied by the caller is a verb that can be supplied wrongly
/// — or forgotten, and rendered as an empty clause — without anything noticing.
enum StorageAction {
  /// Removing the target (`storage_delete_action.dart`).
  delete,

  /// Reading the target out of the app: a zip, a download, a clipboard copy.
  extract,

  /// Every action a control covers at once, named by none of them.
  ///
  /// **For a surface that withholds more than one kind of action with a single
  /// control**, which today is the row's ⋮ ([storageRowMenuRefusalOf]): it opens
  /// onto a copy, a zip, a download and a delete together, so a sentence ending
  /// in [delete]'s 「削除できません」 tells the user only that deleting is off and
  /// leaves the extractions it withheld unaccounted for on the screen. Folding
  /// several actions under one control is what creates this case — a control
  /// that offers a single action carries that action's verb.
  ///
  /// Not a default and not a fallback: a surface that offers exactly one kind of
  /// action still names it, because the neutral verb says strictly less.
  any,
}

/// Why an action on a group is being withheld at this moment.
///
/// One member per [CaptureActivity] that blocks, rather than a single "busy":
/// the sentence has to name what is running so the user knows what to stop, and
/// "something is running" is not an instruction anyone can follow.
enum StorageActionBlocker {
  /// A live capture is running and the group is one it stages into.
  capturing,

  /// A video import is decoding a clip into the same staging area.
  importing,
}

/// The blocker in force for [action] on [group], or null when it may proceed.
///
/// Takes the activity as a value rather than reading it, so the rule is testable
/// without a widget and so every surface that shows it — the row's menu button,
/// its entries, the confirmation's confirm button — decides it once and the
/// same way.
StorageActionBlocker? storageActionBlocker(
  StorageGroup group,
  StorageAction action, {
  required CaptureActivity activity,
}) {
  if (!group.writtenByLiveCapture) {
    return null;
  }
  // Exhaustive over the activity, so a fifth thing the capture card learns to run
  // stops this compiling rather than falling through to "nothing is happening".
  // [action] does not appear: a folder being written to is equally unsafe to
  // delete and to bundle, and a rule that let one of them through would have to
  // say which of the two the native core minds, which nothing here knows.
  return switch (activity) {
    CaptureActivity.idle => null,
    CaptureActivity.capturing => StorageActionBlocker.capturing,
    CaptureActivity.importing => StorageActionBlocker.importing,
    // An open file dialog is deliberately not a blocker here, and this is the one
    // gate in the app where that phase is answered with null. Every other gate
    // treats it as 動画取り込み running because the four features of the capture
    // card are mutually exclusive as a *product* rule; this gate is not one of
    // those four, and its question is the physical one — is something writing into
    // this folder right now? [VideoImportPhase.picking] owns "no session, no
    // pipeline, no decoder", so nothing is, and a refusal here could not truthfully
    // say what would fail if it were allowed.
    CaptureActivity.pickingClip => null,
  };
}

/// [storageActionBlocker] against the app's live state.
///
/// **The one place the storage view asks what is running.** The tree and the
/// delete confirmation both reach it through [storageDeleteRefusalOf] and
/// [storageExtractRefusalOf], so a capture or an import that starts while the
/// confirmation is open withdraws its confirm by the same evaluation that
/// withdrew the row's menu button — and `ref.watch` is what makes them react to
/// it rather than answering with whatever was true when they were built.
///
/// **Private, so that those two are the only way to ask it.** Both read
/// [longReadRegistryProvider] in the same call, and a surface that weighed the
/// capture alone would offer a control over a folder a long reader is holding.
/// Keeping this reading inside the library that composes the refusals makes that
/// surface one that does not compile, rather than one a census has to find. What
/// it does not close: [storageActionBlocker] stays public, because it is the pure
/// rule the gate suites assert over, so a surface could still rebuild this
/// reading from it and `captureActivityProvider` by hand.
StorageActionBlocker? _storageActionBlockerOf(WidgetRef ref, StorageGroup group, StorageAction action) {
  return storageActionBlocker(group, action, activity: ref.watch(captureActivityProvider));
}

/// Why a storage control is withheld at this moment — one value carrying both
/// refusals a destructive or extracting surface has to weigh, already ordered.
///
/// **The order lives here, and in no surface.** Every surface that weighs both
/// refusals — the row's menu and the delete confirmation — takes them already
/// ordered, with the activity blocker first. An ordering written by hand at each
/// surface would be one more place for the next surface to put them the other way
/// round: both orders compile, both produce a dead button, and the only
/// difference is that one of them tells the user to wait for something they
/// could have stopped instead.
///
/// **Asking is what subscribes, which is the point.** The two answers come from
/// two different places — `captureActivityProvider` inside
/// [_storageActionBlockerOf], and [longReadRegistryProvider] — and a surface that
/// asked only the first is the defect these helpers exist to make unspellable:
/// there is one call, it reads both, and half of it cannot be left out. A *new*
/// surface cannot go back to asking the blocker on its own either:
/// [_storageActionBlockerOf] is private to this library and these two helpers are
/// its only callers, so the compiler rather than a census of call sites is what
/// holds it.
///
/// Sealed rather than a `(blocker, kind)` pair so a surface that renders the two
/// refusals differently — the delete confirmation shows one as a warning and the
/// other as a note — is made to say which is which by a `switch` the compiler
/// checks, instead of by re-deriving the priority a third time.
sealed class StorageRefusal {
  const StorageRefusal({required this.message});

  /// What the withheld control says for itself.
  ///
  /// Resolved where the refusal is built, because the activity sentence is
  /// composed from the blocker and the action and only the builder holds both.
  final String message;
}

/// Something the user started is writing into the group; it can be stopped.
final class StorageActivityRefusal extends StorageRefusal {
  const StorageActivityRefusal({required this.blocker, required super.message});

  final StorageActionBlocker blocker;
}

/// A registered long reader is holding what the control would touch; the only
/// remedy is to wait for it.
final class StorageLongReadRefusal extends StorageRefusal {
  const StorageLongReadRefusal({required this.kind, required super.message});

  /// Carried for a surface that wants to say more than the shipped sentence
  /// does. None does today — there is one sentence, and it is subjectless about
  /// the holder, for [longReadBusyMessage]'s reasons.
  final LongReadKind kind;
}

/// The refusal in force for extracting [target] out of [group], or null when the
/// control may be offered.
///
/// Both questions are asked before either is answered, so the widget's
/// subscription does not depend on which refusal wins: an early return past
/// `ref.watch` would leave a control that is dead for a capture deaf to a claim
/// arriving behind it, and it would come back only because the capture ending
/// happened to rebuild it.
///
/// A null [target] answers null, which is [storageExtractBlockedBy]'s answer for
/// a row with nothing to hand over — the activity blocker is still weighed,
/// because a group being written into is a fact about the group and not about
/// the row.
///
/// **The activity sentence composed here — `pages.storage.blocked.verb.extract`
/// — reaches no screen at all, and since the row's buttons became one ⋮ that is a
/// fact about the app rather than about which groups happen to exist.** The one
/// surface that renders a [StorageRefusal.message] is the row's menu button
/// tooltip; that control covers a delete and the extractions together, so
/// [storageRowMenuRefusalOf] re-composes the activity sentence with
/// [StorageAction.any] whichever side it took, and no row can carry this verb any
/// more, whether or not the row offers a delete. The long-read half below is unaffected: it carries
/// [longReadBusyMessage], which is the delete side's sentence too.
///
/// The verb is kept rather than retired, for two reasons that are about the code
/// and not about a screen. The composition in `storageActionBlockedMessage` is
/// exhaustive over (blocker, action), so retiring the member would be retiring
/// the *distinction* — this helper would then have nothing but [StorageAction.any]
/// to ask with, and an extraction control that names its own action (which is
/// what a control outside a row would do) could not be written without reinstating it. And the delete
/// side's counterpart is not in the same position: `storage_delete_action.dart`
/// renders `…verb.delete` on the confirmation, so the pair is not dead symmetry.
/// `storage_row_menu_gate_test.dart` asserts the choice directly, since no widget
/// can.
StorageRefusal? storageExtractRefusalOf(WidgetRef ref, {required StorageGroup group, required PathEntity? target}) {
  final claims = ref.watch(longReadRegistryProvider).values;
  final blocker = _storageActionBlockerOf(ref, group, StorageAction.extract);
  if (blocker != null) {
    return StorageActivityRefusal(
      blocker: blocker,
      message: storageActionBlockedMessage(blocker, StorageAction.extract),
    );
  }
  if (target == null) {
    return null;
  }
  final kind = storageExtractBlockedBy(target, claims);
  return kind == null ? null : StorageLongReadRefusal(kind: kind, message: longReadBusyMessage());
}

/// The refusal in force for the delete [request] on [group], or null when the
/// control may be offered. [storageExtractRefusalOf]'s counterpart, and it reads
/// both answers up front for the same reason.
StorageRefusal? storageDeleteRefusalOf(
  WidgetRef ref, {
  required StorageGroup group,
  required StorageDeleteRequest? request,
}) {
  final claims = ref.watch(longReadRegistryProvider).values;
  final blocker = _storageActionBlockerOf(ref, group, StorageAction.delete);
  if (blocker != null) {
    return StorageActivityRefusal(
      blocker: blocker,
      message: storageActionBlockedMessage(blocker, StorageAction.delete),
    );
  }
  final kind = storageDeleteBlockedBy(request, claims);
  return kind == null ? null : StorageLongReadRefusal(kind: kind, message: longReadBusyMessage());
}

/// Translation key of the sentence [storageActionBlockedMessage] fills in.
const String storageActionBlockedTemplateKey = 'pages.storage.blocked.template';

/// Translation key of the name of what is running.
String storageActionBlockerActivityKey(StorageActionBlocker blocker) {
  return switch (blocker) {
    StorageActionBlocker.capturing => 'pages.storage.blocked.activity.capturing',
    StorageActionBlocker.importing => 'pages.storage.blocked.activity.importing',
  };
}

/// Translation key of the clause naming what cannot be done.
String storageActionBlockedVerbKey(StorageAction action) {
  return switch (action) {
    StorageAction.delete => 'pages.storage.blocked.verb.delete',
    StorageAction.extract => 'pages.storage.blocked.verb.extract',
    StorageAction.any => 'pages.storage.blocked.verb.any',
  };
}

/// What a withheld [action] says for itself: what is happening, then what to do.
///
/// Composed from three keys rather than written out once per pair, because the
/// pairs multiply — two activities times three actions today — and six
/// hand-written sentences are six places for the seventh to be missed. The two
/// `switch`es above
/// are exhaustive, so a third activity or a third action is named by the compiler
/// instead.
String storageActionBlockedMessage(StorageActionBlocker blocker, StorageAction action) {
  return storageActionBlockedTemplateKey.tr(
    namedArgs: {
      'activity': storageActionBlockerActivityKey(blocker).tr(),
      'action': storageActionBlockedVerbKey(action).tr(),
    },
  );
}
