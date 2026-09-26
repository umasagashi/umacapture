// The storage view's delete, driven below `runStorageDelete`, and a backend that
// holds a delete inside the filesystem for as long as a test needs.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/settings_store_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/utils.dart';

import 'web_like_fs_backend.dart';

/// Deletes [targets] of [group] the way `runStorageDelete` does: inside one
/// delete's claim over exactly [targets], so a target something else holds is
/// refused before anything is removed.
///
/// For a suite about the engine rather than about when the claim is released:
/// nothing the app remembers is forgotten here, which is `runStorageDelete`'s
/// half.
Future<StorageDeleteReport> deleteUnderClaim(
  RefBase ref, {
  required StorageGroup group,
  required List<PathEntity> targets,
}) {
  return holdForDelete(
    ref.read(longReadRegistryProvider.notifier),
    paths: targets,
    action: (claim) => deleteStorageEntries(ref, claim: claim, group: group, targets: targets),
  );
}

/// Removes the settings stores the way `runStorageDelete` does, inside a delete's
/// claim — over nothing, as on web, because a suite of the removal itself has no
/// layout and no other claimant for the claim to be asked about.
Future<StorageDeleteReport> deleteSettingsStoresUnderClaim() async {
  final container = ProviderContainer();
  try {
    return await holdForDelete(
      container.read(longReadRegistryProvider.notifier),
      paths: const [],
      action: deleteSettingsStores,
    );
  } finally {
    container.dispose();
  }
}

/// Delegates to the io backend but refuses [refuse] paths, and pauses on
/// [pauseOn] until [gate] completes.
///
/// This is how a held file is produced deterministically: actually holding one
/// open depends on the operating system's sharing rules, which differ between the
/// two platforms the engine has to work on, so the refusal is injected at the
/// boundary the engine talks to instead.
///
/// [arrived] completes with the first paused path, once the delete has reached
/// it — which is how a test knows the delete is under way and has not finished.
class ObstructedFsBackend extends WebLikeFsBackend {
  ObstructedFsBackend(super.inner, {this.refuse, this.pauseOn, this.gate});

  final bool Function(String path)? refuse;
  final bool Function(String path)? pauseOn;
  final Future<void>? gate;

  final arrived = Completer<String>();

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    if (pauseOn?.call(path) ?? false) {
      if (!arrived.isCompleted) {
        arrived.complete(path);
      }
      await gate;
    }
    if (refuse?.call(path) ?? false) {
      throw FileSystemException('The process cannot access the file because it is being used', path);
    }
    return super.delete(path, recursive: recursive);
  }
}
