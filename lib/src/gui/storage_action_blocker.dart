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
/// **A live capture is now on the long-read registry as well, and this gate is
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

import '/src/core/platform_controller.dart';
import '/src/core/storage/storage_group.dart';
import '/src/core/video_import_ops.dart';

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
  /// the row's three buttons into one control is what created this case — each
  /// button used to carry the verb of the one action it was.
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
/// delete confirmation both reach it through the two refusal helpers in
/// `storage_tree.dart`, so a capture or an import that starts while the
/// confirmation is open withdraws its confirm by the same evaluation that
/// withdrew the row's menu button — and `ref.watch` is what makes them react to
/// it rather than answering with whatever was true when they were built.
StorageActionBlocker? storageActionBlockerOf(WidgetRef ref, StorageGroup group, StorageAction action) {
  return storageActionBlocker(group, action, activity: ref.watch(captureActivityProvider));
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
