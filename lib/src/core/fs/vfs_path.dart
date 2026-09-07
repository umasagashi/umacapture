/// How the OPFS adapter spells the path of a child it enumerated.
///
/// This library holds one decision and nothing else, and it is deliberately free
/// of `package:flutter`, `package:web` and `dart:js_interop`, because inside
/// `web_vfs.dart` that decision is unreachable from **both** kinds of test this
/// repository can run: the VM suite (`flutter test`) cannot import a library that
/// reaches `dart:js_interop`, and `dart test --platform chrome` cannot compile one
/// that reaches `package:flutter` — which `web_vfs.dart` does, through
/// `fs_backend.dart`'s `package:flutter/foundation.dart` import. A rule no test can
/// name is a rule that drifts, and this one already had. `origin_storage_estimate_web.dart`
/// is kept Flutter-free for the same class of reason.
library;

/// Separators at the tail of a prefix, which name no segment.
///
/// Hoisted for the same reason `WebVfs._pathSeparator` is: [vfsChildPath] runs
/// once per enumerated entry, and a recursive listing enumerates the whole tree.
final RegExp _trailingSeparators = RegExp(r'[/\\]+$');

/// The path of the entry named [name] inside the directory whose path is [prefix].
///
/// **A directory is named by its segments, and the child is those segments plus
/// [name].** Everything that spells a path in the VFS agrees on that, so a prefix
/// that carries no segment — `''` or `'/'`, both of which `WebVfs._split` resolves
/// to the OPFS root — contributes nothing to spell, and the child is [name] alone.
///
/// The empty prefix is not a corner case on web, it is the *root of the app*:
/// `platform_dirs_web.dart` returns `DirectoryPath([])` for the support directory,
/// because OPFS is origin-private and needs no application-namespace segment. So
/// `PathInfo.modulesDir.path` is `modules`, with no leading separator, and every
/// other path the app derives is spelled the same way.
///
/// This function exists because the enumeration is **the one place a backend
/// invents a path** instead of being handed one, which makes it the one place that
/// can disagree with the rest of the app about how a location is spelled. It did:
/// composing `'$prefix/$name'` verbatim put a leading separator on — and only on —
/// the children of the OPFS root, so `/modules` came back for a directory the app
/// calls `modules`, and a caller comparing the two as strings subtracted nothing.
/// (`unclassified_scan.dart` was that caller; it now rebuilds each child from the
/// root it is already holding, so it no longer needs the two spellings to agree.
/// This is the other half: they agree.)
String vfsChildPath(String prefix, String name) {
  final base = prefix.replaceFirst(_trailingSeparators, '');
  return base.isEmpty ? name : '$base/$name';
}
