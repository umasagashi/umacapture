import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/const.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/unclassified_scan.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/virtual_tree_fs_backend.dart';

/// A layout whose fourteen directories are all distinct, so a containment check
/// below means what it says.
///
/// [PathInfo.tempSession] is non-null on purpose: without a session `tempDir` and
/// `tempRootDir` are the same directory (asserted below), and "this container
/// really does contain a group" would be trivially true for a pair that is one
/// path. The field exists precisely so a test can describe the scoped layout on a
/// platform that cannot mint a real claim.
PathInfo layoutUnder(String root, {DirectoryPath? dataRoot}) => PathInfo(
  documentDir: DirectoryPath('$root/documents'),
  supportDir: DirectoryPath('$root/support'),
  executableDir: DirectoryPath('$root/exe'),
  downloadDir: DirectoryPath('$root/downloads'),
  dataRoot: dataRoot,
  tempSession: 'session-1',
);

/// Every `DirectoryPath` getter declared on `PathInfo`, read out of its source.
///
/// Getters, not fields. `app_root_scrub_test.dart` reads the same class with
/// `RegExp(r'final DirectoryPath\??\s+(\w+);')` and asserts it finds *no* getters,
/// which is right for what that test guards (the Sentry scrub only needs the base
/// directories). Every logical storage group is a getter, so an extractor shaped
/// like that one would stay green no matter how many groups were added.
Set<String> declaredDirectoryGetters(String source) {
  final body = source.substring(source.indexOf('class PathInfo {'), source.indexOf('/// Resolves the app'));
  // `List<DirectoryPath> get appOwnedRoots` does not match: `>` sits where the
  // whitespace before `get` has to be. That is deliberate — it is a list of the
  // fields, not a directory of its own.
  return RegExp(r'\bDirectoryPath\??\s+get\s+(\w+)').allMatches(body).map((e) => e.group(1) ?? '').toSet();
}

/// Every translation-key field `StorageGroup` declares, read out of its source.
///
/// The same technique as [declaredDirectoryGetters], for the same reason: nothing
/// can enumerate a class's fields at runtime, so the only way a hand-written list
/// of them can be held to the class is to read the declaration. This is what
/// stops "no group has a missing …" from silently narrowing when a key field is
/// added to `StorageGroup` and not to that test's list.
Set<String> declaredTranslationKeyFields(String source) {
  final body = source.substring(source.indexOf('class StorageGroup {'), source.indexOf('const _groupKeyPrefix'));
  return RegExp(r'\bfinal String\??\s+(\w+Key);').allMatches(body).map((e) => e.group(1) ?? '').toSet();
}

/// Every Dart source under `lib/`, by path.
///
/// All of it, not the filesystem layer alone: a directory this app writes is a
/// directory on the user's disk wherever the line that builds it happens to sit,
/// and [pathInfoDirectories] cannot see any of them. Scoping the scan to
/// `lib/src/core/fs/` would have been an assumption about where such a line is
/// allowed to appear, which is the kind of assumption that let a directory the
/// app writes go unaccounted for in the first place.
Map<String, String> libSources() => {
  for (final entity in Directory('lib').listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity.path: entity.readAsStringSync(),
};

/// One directory name a source joins onto a path: which file, which identifier it
/// is joined onto, and whether that identifier is one the file built itself.
typedef PathJoin = ({String file, String base, String segment, bool onDerivedBase});

/// Names joined onto a directory the same file *built*, which are therefore
/// inside something this check already covered, and which no getter should have
/// to exist for.
///
/// **An exemption list, not a filter, and bound to a place rather than a name.**
/// Two versions of this were too weak and both failed the same way — by letting a
/// *spelling* decide. The first dropped every name joined onto a locally-declared
/// identifier, so `final base = dataRoot; base / '.umacapture-probe';` reproduced
/// the original defect exactly -- a directory written as a literal that no group
/// or getter accounts for -- and stayed green. The second exempted the three names globally, so
/// the same line with `'payload'` in any file in `lib/` was waved through. An
/// exemption now names the file and the identifier as well, so it licenses the
/// four lines it was written for and nothing else; the test below also fails on an
/// entry that no longer occurs, so the list cannot grow stale in the other
/// direction. Adding to it is a visible act with a reason attached, which is what
/// an escape hatch is allowed to cost.
///
/// All four are the *inside* of a transaction slot — `<journal>/v1/<slot>/…` —
/// reached from a local the same file derived from that journal's root, and the
/// journal roots above them are two of the three `retired` resolves.
const nestedSegmentExemptions = <({String file, String base, String segment})>{
  (file: 'record_directory_transaction.dart', base: 'slot', segment: 'payload'),
  (file: 'record_directory_transaction.dart', base: 'transactionDir', segment: 'payload'),
  (file: 'web_record_write_transaction.dart', base: 'slot', segment: 'desired'),
  (file: 'web_record_write_transaction.dart', base: 'slot', segment: 'superseded'),
};

String _withoutCommentLines(String source) =>
    source.split('\n').where((line) => !line.trimLeft().startsWith('//')).join('\n');

/// Every directory name the app joins onto a path as a literal, with repeats —
/// the second extractor this file needs. Grouped by the spelling that found it
/// rather than by source position; nothing here depends on the order.
///
/// [declaredDirectoryGetters] reads `providers.dart` and therefore sees only what
/// `PathInfo` declares. A directory built as `<something> / '<name>'` down in the
/// filesystem layer is invisible to it *in principle*, so a whole tree could be —
/// and was — written to disk with no getter, no group, no row, no total and no
/// delete, while every test on the group table stayed green. This reads the other
/// half.
///
/// Only the first segment of a chain is collected: `foo / 'a' / 'b'` yields `a`
/// alone, because `b` lives inside `a` and whatever accounts for `a` accounts for
/// it. Dart's non-overlapping match order gives that for free — the match ends at
/// `'a'`, leaving no identifier in front of the next `/`.
///
/// Each result records whether its base is an identifier the same file *declared*
/// ([PathJoin.onDerivedBase]) or one it was handed. That is a hint about where the
/// directory sits, **not** a licence to skip it: both kinds are checked, the
/// derived ones against [nestedSegmentExemptions] as well.
///
/// Both spellings of a join are read: `<base> / '<name>'` and
/// `p.join(<base>, '<name>')`. The second was added because the first, alone,
/// let the crash-reporting SDK's database directory through — `sentry_util.dart`
/// builds it with `p.join`, no group or getter named it, and this check said the
/// app builds no such directory. The doc above it claimed a literal anywhere in
/// `lib/` would fail here, and for that spelling it did not.
///
/// An identifier on the right is resolved through the same file's `const`
/// declarations and through the top-level `const`s of every file under `lib/`,
/// so a name held in a constant (which is how the write transaction's root was
/// spelled) is read as the literal it is — including one deliberately shared, as
/// [settingsBoxDirName] and [sentryNativeDirName] are. Only top-level
/// declarations are shared: a class member's name is often generic enough to
/// collide with an unrelated identifier used as a path segment. An interpolated
/// string is deliberately not matched: `'${name}_$n'` is a *derived* name, not a
/// directory of the app's own, and it sits inside one of these anyway.
///
/// **What this cannot see**, stated rather than hoped away:
///  * A directory built by any means other than `/` or `join` on a path —
///    `DirectoryPath(<segments>)` from a computed list, `Directory('<literal>')`
///    from a string, a name arriving from a config file or a platform channel, a
///    segment spliced by interpolation.
///  * A name written with an escape (`…`) or spanning lines inside a `'''`
///    block. Both are excluded from the literal so that a multi-line string
///    elsewhere in `lib/` cannot be mis-read as a path; a directory name has no
///    use for either.
///  * A `const` whose value is another `const` rather than a literal, or one
///    declared as a class member and used from another file.
///
/// The check is a net over the constructions the app actually uses, not a proof
/// that no other exists.
List<PathJoin> literalPathSegments(Map<String, String> sources) {
  // Every quote spelling Dart has for a one-line, uninterpolated string, because
  // this repository uses more than one of them and the check has to see the
  // directory, not the punctuation: `providers.dart` writes every path it builds
  // with `"…"`, so a pattern that read `'…'` alone was blind to the whole class
  // the file that *names* the app's directories belongs to.
  const literal =
      r'''r?(?:'''
      r"""'''(?<a>[^'\\$\n]*)'''"""
      r'''|"""(?<b>[^"\\$\n]*)"""'''
      r"""|'(?<c>[^'\\$\n]*)'"""
      r'''|"(?<d>[^"\\$\n]*)")''';
  // Not a raw string: `$literal` has to interpolate.
  final joinPatterns = <RegExp>[
    RegExp('\\b(?<base>[A-Za-z_]\\w*)\\s*/\\s*(?:$literal|(?<ident>[A-Za-z_]\\w*))'),
    // `p.join(base.path, '<name>')`, the other way this repository builds a
    // child path. Anything after the base identifier up to the comma is a
    // property chain (`.path`), and the terminator is `,` as well as `)` so a
    // three-argument join yields its first segment for the same reason the `/`
    // chain does.
    RegExp(
      '\\b(?:p\\.)?join\\(\\s*(?<base>[A-Za-z_]\\w*)(?:\\.\\w+)*\\s*,\\s*(?:$literal|(?<ident>[A-Za-z_]\\w*))\\s*[,)]',
    ),
  ];
  final constPattern = RegExp('const\\s+(?:String\\s+)?(?<name>\\w+)\\s*=\\s*$literal\\s*;');
  // The same declaration, anchored to the start of a line: a *top-level*
  // constant. Only these are shared across files below. A class member is
  // indented and so does not match, which is what keeps a generic member name
  // from being read as a path segment somewhere else — `static const name =
  // 'SettingsRoute'` in the generated router, matched against `<root> / name`
  // in the journals, produced exactly that and is why the anchor is here.
  final topLevelConstPattern = RegExp('^const\\s+(?:String\\s+)?(?<name>\\w+)\\s*=\\s*$literal\\s*;', multiLine: true);
  // A local: something the file declares and assigns, as opposed to a parameter
  // or a field it is given. A parameter is followed by `,` or `)` and so is not
  // matched; `=>` is excluded so a getter's own name is not read as a local.
  final localPattern = RegExp(r'(?:final|var|late|const|[A-Za-z_][\w<>?]*)\s+([a-z_]\w*)\s*(?:=(?!>)|;)');
  String? quoted(RegExpMatch match) {
    for (final name in const ['a', 'b', 'c', 'd']) {
      final value = match.namedGroup(name);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  final stripped = {for (final entry in sources.entries) entry.key: _withoutCommentLines(entry.value)};
  // Every top-level `const` a literal is bound to anywhere under `lib/`, so a
  // name held in a *shared* constant is read as the literal it is. Same-file
  // declarations win below. Scanning one file at a time was the older shape, and
  // it made a directory name invisible for exactly as long as it was worth
  // sharing: `settingsBoxDirName` and [sentryNativeDirName] are both declared in
  // `const.dart` and joined onto a path in another file.
  final sharedConstants = <String, String>{
    for (final source in stripped.values)
      for (final match in topLevelConstPattern.allMatches(source)) match.namedGroup('name') ?? '': quoted(match) ?? '',
  };

  final found = <PathJoin>[];
  for (final entry in stripped.entries) {
    final file = entry.key.split(RegExp(r'[/\\]')).last;
    final source = entry.value;
    final constants = <String, String>{
      ...sharedConstants,
      for (final match in constPattern.allMatches(source)) match.namedGroup('name') ?? '': quoted(match) ?? '',
    };
    final locals = {for (final match in localPattern.allMatches(source)) match.group(1) ?? ''};
    for (final pattern in joinPatterns) {
      for (final match in pattern.allMatches(source)) {
        final base = match.namedGroup('base') ?? '';
        final segment = quoted(match) ?? constants[match.namedGroup('ident') ?? ''];
        if (segment != null) {
          found.add((file: file, base: base, segment: segment, onDerivedBase: locals.contains(base)));
        }
      }
    }
  }
  return found;
}

/// The last segment of every path the app names — a group's roots,
/// [pathInfoDirectories], and the names the app creates but this feature
/// deliberately does not manage.
///
/// The third source is not a loophole: [unmanagedDirectoryNames] is the *data*
/// that says "the app makes this and the storage view leaves it alone", and it
/// is the same set `unclassified_scan.dart` subtracts. Without it a name that
/// decision covers would have to be either a group or a failure here, and the
/// only way to keep it out of both would be to spell it somewhere this
/// extractor cannot read — which is what it did, and why the crash database was
/// invisible to this check for as long as it was.
Set<String> accountedDirectoryNames(PathInfo info) => {
  for (final dir in pathInfoDirectories(info).values) dir.name,
  for (final group in storageGroups)
    for (final entity in group.resolve(info)) entity.name,
  ...unmanagedDirectoryNames,
};

/// The getter names whose directory is exactly one of the groups' directories.
Set<String> coveredGetterNames(PathInfo info) {
  final owned = <String>{
    for (final group in storageGroups)
      // A residual bucket owns no path, and a filtered group owns matching
      // children of a directory rather than the directory itself.
      if (!group.isResidualBucket && group.nameFilter == null)
        for (final entity in group.resolve(info)) entity.path,
  };
  return pathInfoDirectories(info).entries.where((e) => owned.contains(e.value.path)).map((e) => e.key).toSet();
}

bool isStrictlyUnder(DirectoryPath ancestor, PathEntity descendant) {
  if (descendant.segments.length <= ancestor.segments.length) {
    return false;
  }
  return DirectoryPath(descendant.segments.sublist(0, ancestor.segments.length)).path == ancestor.path;
}

Object? lookupTranslation(Map<String, dynamic> root, String dottedKey) {
  Object? node = root;
  for (final part in dottedKey.split('.')) {
    if (node is! Map<String, dynamic>) {
      return null;
    }
    node = node[part];
  }
  return node;
}

void main() {
  late String providersSource;
  late String groupSource;

  setUp(() {
    providersSource = File('lib/src/core/providers.dart').readAsStringSync();
    groupSource = File('lib/src/core/storage/storage_group.dart').readAsStringSync();
  });

  group('the extractor reads what the group table is accountable for', () {
    test('it finds the getters the groups are built from, so a green run means something', () {
      final names = declaredDirectoryGetters(providersSource);
      expect(names, containsAll(<String>['charaDetailActiveDir', 'modulesDir', 'settingsDir']));
      // `documentDir` is a *field*. Catching it would mean the regex had started
      // reading declarations of another shape, and the count below would then be
      // measuring something other than the getters.
      expect(names, isNot(contains('documentDir')));
      // Nor the aggregate: `appOwnedRoots` is a list of the fields.
      expect(names, isNot(contains('appOwnedRoots')));
      expect(names.length, greaterThanOrEqualTo(14));
    });

    test('the second extractor really reads directory names out of the app', () {
      // The guard on the guard. An extractor that matched nothing would make the
      // accountability test below pass against a `lib/` full of unnamed
      // directories — a check that answers "clean" for the empty input is not a
      // check. So: it finds sources, it finds names in them, and the names are
      // the ones anyone can read in those files.
      final sources = libSources();
      expect(sources.keys.where((path) => path.endsWith('record_directory_transaction.dart')), isNotEmpty);
      final joins = literalPathSegments(sources);
      expect(joins, isNotEmpty);
      final segments = joins.map((join) => join.segment).toSet();
      expect(segments, containsAll(<String>['active', 'archive', 'quarantine', 'retired', 'chara_detail']));
      // The `join(...)` spelling as well as `/`, and a name held in a constant
      // another file declares. Each of those is a widening this extractor was
      // given for a directory that was invisible to it before, and neither
      // shows up in the accountability test below once the name is accounted
      // for — so without these two lines, removing either widening again would
      // cost nothing.
      expect(segments, contains(sentryNativeDirName));
      expect(segments, contains(settingsBoxDirName));
      // Both halves of the partition are populated, or one of the two branches
      // below would be asserting over nothing.
      expect(joins.where((join) => join.onDerivedBase), isNotEmpty);
      expect(joins.where((join) => !join.onDerivedBase), isNotEmpty);
      // And it stops at the first segment: `v1` sits inside a journal root, and
      // demanding a getter for it would demand one for every slot below it too.
      expect(segments, isNot(contains('v1')));
    });

    test('every directory name the app builds is one this view accounts for', () {
      // The guard against a directory the app writes going unaccounted for, and
      // the reason that could happen at all. Both transaction
      // journals were written as literals in the filesystem layer —
      // `.umacapture-transactions` and `.umacapture-write-transactions` — and no
      // test could see them, because every test on this table reads
      // `providers.dart`, where they did not appear. They are getters now, so
      // this passes; a *new* directory joined onto a path as a literal anywhere
      // in `lib/` — by `/` or by `join`, the two spellings
      // [literalPathSegments] reads — fails here instead of shipping invisible.
      // A name the app makes but this feature does not manage is accounted for
      // by being in [unmanagedDirectoryNames], which is a decision written down
      // rather than a spelling this check happens to miss.
      final accounted = accountedDirectoryNames(layoutUnder('/root'));
      final joins = literalPathSegments(libSources());
      final unaccounted = {
        for (final join in joins)
          if (!accounted.contains(join.segment) &&
              !nestedSegmentExemptions.contains((file: join.file, base: join.base, segment: join.segment)))
            '${join.file}: ${join.base} / ${join.segment}',
      };
      expect(
        unaccounted,
        isEmpty,
        reason: 'the app builds these directories and no group or PathInfo getter names them',
      );
    });

    test('every name declared unmanaged is one the app still builds', () {
      // The staleness half of [unmanagedDirectoryNames], for the same reason
      // [nestedSegmentExemptions] has one: an entry the app no longer creates
      // is a standing licence for whatever name next collides with it. It also
      // keeps the set honest in the other direction — a name is only allowed to
      // sit here instead of in a group while this check can see the app build
      // it.
      final segments = literalPathSegments(libSources()).map((join) => join.segment).toSet();
      expect(
        unmanagedDirectoryNames.difference(segments),
        isEmpty,
        reason: 'declared unmanaged but no longer built anywhere in lib/',
      );
    });

    test('the exemptions are only for names inside a directory this check already covered', () {
      // The staleness half. An exemption that no longer occurs is a licence
      // nobody asked for, still standing; the next name that happens to collide
      // with it would inherit it silently. And each one has to be on a base the
      // file *built* — an exemption for a name appended straight to a store root
      // would be exempting the unaccounted-directory shape itself.
      final joins = literalPathSegments(libSources());
      final derived = {
        for (final join in joins)
          if (join.onDerivedBase) (file: join.file, base: join.base, segment: join.segment),
      };
      expect(nestedSegmentExemptions.difference(derived), isEmpty, reason: 'no longer built anywhere in lib/');
      final onHandedBase = {
        for (final join in joins)
          if (!join.onDerivedBase) (file: join.file, base: join.base, segment: join.segment),
      };
      expect(nestedSegmentExemptions.intersection(onHandedBase), isEmpty);
    });
  });

  group('every directory PathInfo names is either a group or a named container', () {
    test('the hand-written table lists exactly the getters the source declares', () {
      // This is the guard. Flutter has no `dart:mirrors`, so `pathInfoDirectories`
      // cannot be derived at runtime; adding a getter to `PathInfo` and nothing
      // else has to fail here, or a new directory can be added to the app and
      // never appear in the storage view.
      final table = pathInfoDirectories(layoutUnder('/root')).keys.toSet();
      expect(table, equals(declaredDirectoryGetters(providersSource)));
    });

    test('each one is covered by a group or listed as a container, and never both', () {
      final info = layoutUnder('/root');
      final table = pathInfoDirectories(info).keys.toSet();
      final covered = coveredGetterNames(info);
      expect(covered.intersection(storageGroupContainerGetters), isEmpty);
      expect(table.difference(covered).difference(storageGroupContainerGetters), isEmpty);
      // And the container list cannot name something that no longer exists.
      expect(storageGroupContainerGetters.difference(table), isEmpty);
    });

    test('a container is excluded only because a group really does sit below it', () {
      // The justification, machine-checked: the precedent in
      // `app_root_scrub_test.dart` guards its single exclusion by asserting the
      // reason is written in the source it protects. With four exclusions that
      // does not scale, so each one has to earn its place instead.
      final info = layoutUnder('/root');
      final directories = pathInfoDirectories(info);
      // The relation has to be able to say no, or the loop below asserts nothing:
      // siblings and a directory against itself are both outside it.
      expect(isStrictlyUnder(info.charaDetailActiveDir, info.charaDetailArchiveDir), isFalse);
      expect(isStrictlyUnder(info.charaDetailDir, info.charaDetailDir), isFalse);
      final coveredPaths = coveredGetterNames(info).map((name) => directories[name]!).toList();
      for (final container in storageGroupContainerGetters) {
        expect(
          coveredPaths.where((dir) => isStrictlyUnder(directories[container]!, dir)),
          isNotEmpty,
          reason: '$container is excluded as a container but no group sits under it',
        );
      }
    });

    test('the temp pair is two directories only when a session scopes it', () {
      // Why the checks above use a session-scoped layout. On native there is no
      // second context to share the scratch tree with, so `tempDir` *is*
      // `tempRootDir` and the containment above would hold vacuously.
      final scoped = layoutUnder('/root');
      expect(scoped.tempDir.path, isNot(scoped.tempRootDir.path));
      final unscoped = PathInfo(
        documentDir: DirectoryPath('/root/documents'),
        supportDir: DirectoryPath('/root/support'),
        executableDir: DirectoryPath('/root/exe'),
        downloadDir: DirectoryPath('/root/downloads'),
      );
      expect(unscoped.tempDir.path, unscoped.tempRootDir.path);
    });
  });

  group('the group table itself', () {
    test('it is the twelve groups of the definition table, each one distinct', () {
      expect(storageGroups, hasLength(12));
      expect(storageGroups.map((e) => e.id).toSet(), hasLength(12));
      expect(storageGroups.where((e) => e.isResidualBucket), hasLength(1));
      expect(storageGroups.where((e) => e.isSynthetic), hasLength(1));
    });

    test('the enum and the table state one order, not two', () {
      // `storage_group.dart` writes the display order down twice — once as
      // `StorageGroupId`'s declaration order and once as `storageGroups` — so it
      // can disagree with itself, and nothing downstream would notice: every
      // other reader looks a group up by id. Both sides here are derived, so
      // reordering either one alone fails; *which* order it is stays a literal in
      // `storage_tree_test.dart`, next to the function that renders it.
      expect(storageGroups.map((group) => group.id).toList(), StorageGroupId.values);
    });

    test('the delete operation and the friction agree, in both directions', () {
      for (final group in storageGroups) {
        expect(
          group.operations.contains(StorageOperation.delete),
          group.deleteFriction != StorageDeleteFriction.notOffered,
          reason: '${group.id} offers a delete the friction does not describe, or the other way round',
        );
      }
    });

    test('an auxiliary root is one of the group own roots, and never the one that stands for it', () {
      // Two things a group can get wrong about `auxiliaryRoots`, both silent: name
      // a directory it does not resolve (the subtraction then removes nothing and
      // the group reads as several folders), or name so many that no root is left
      // to stand for it. Neither is a restatement of `soleRoot` -- the first is
      // about a set `soleRoot` never inspects, and the second is a claim about the
      // number it is left with. Order is not asserted because the subtraction has
      // none to get wrong, which is why the field names the roots rather than
      // counting them.
      final info = layoutUnder('/root');
      for (final group in storageGroups) {
        final roots = {for (final root in group.resolve(info)) root.path};
        final auxiliary = {for (final root in group.auxiliaryRootsOf(info)) root.path};
        expect(auxiliary.difference(roots), isEmpty, reason: '\${group.id} calls a path it does not resolve auxiliary');
        if (auxiliary.isEmpty) {
          continue;
        }
        expect(roots.difference(auxiliary), hasLength(1), reason: '\${group.id} has no root left to stand for it');
        expect(auxiliary, isNot(contains(group.soleRoot(info)?.path)), reason: '\${group.id}');
      }
      // Non-trivial: some group actually declares one, or the loop asserts nothing.
      expect(storageGroups.where((g) => g.auxiliaryRootsOf(info).isNotEmpty).map((e) => e.id), [
        StorageGroupId.retired,
      ]);
    });

    test('only the residual bucket resolves to nothing', () {
      final info = layoutUnder('/root');
      for (final group in storageGroups) {
        expect(group.resolve(info).isEmpty, group.isResidualBucket, reason: '${group.id}');
      }
    });

    test('hiddenOnWeb is exactly the two groups web cannot represent', () {
      // Literal, not derived from storage_group.dart: dataRootConfig (web's
      // `bootstrap.dart` returns early on `kIsWeb` and the concept does not exist at
      // all) and fontCache (google_fonts uses the browser's HTTP cache on web, never
      // OPFS). `hiddenOnWeb` has no other reader anywhere in `lib/` or
      // `test/`, so this is the only thing standing between a group and silently
      // vanishing (or wrongly appearing empty) on web.
      const expectedHiddenOnWeb = {StorageGroupId.dataRootConfig, StorageGroupId.fontCache};
      expect(storageGroups.where((g) => g.hiddenOnWeb).map((g) => g.id).toSet(), expectedHiddenOnWeb);
    });

    test('the delete friction matches the agreed per-group classification for all twelve groups', () {
      // Transcribed literally from the friction classification that was agreed
      // group by group, not derived from storage_group.dart. dataRootConfig is
      // listed in the double-confirm (strong warning) row, but that row's own
      // text explains why: the group offers no delete at all, and the
      // double-confirm strength applies to the *wording of the warning* shown
      // when it is referenced. So its actual friction value is notOffered and the
      // strongly worded warning lives in the hint text, not here.
      const expectedFriction = {
        StorageGroupId.activeRecords: StorageDeleteFriction.doubleConfirm,
        StorageGroupId.archivedRecords: StorageDeleteFriction.doubleConfirm,
        StorageGroupId.quarantine: StorageDeleteFriction.doubleConfirm,
        StorageGroupId.retired: StorageDeleteFriction.singleConfirm,
        StorageGroupId.metadata: StorageDeleteFriction.doubleConfirm,
        StorageGroupId.modules: StorageDeleteFriction.singleConfirm,
        StorageGroupId.settings: StorageDeleteFriction.doubleConfirm,
        StorageGroupId.temp: StorageDeleteFriction.singleConfirm,
        StorageGroupId.customSound: StorageDeleteFriction.singleConfirm,
        StorageGroupId.dataRootConfig: StorageDeleteFriction.notOffered,
        StorageGroupId.fontCache: StorageDeleteFriction.singleConfirm,
        StorageGroupId.unclassified: StorageDeleteFriction.doubleConfirm,
      };
      final actual = {for (final group in storageGroups) group.id: group.deleteFriction};
      expect(actual, expectedFriction);
    });

    test('the quarantine delete asks twice, and the retired one does not', () {
      // The pair, because the friction is decided by a question the two shelves
      // answer differently. `PathInfo.charaDetailQuarantineDir` states it: the
      // split between them is whose data it is, quarantine holding records of
      // the user's that the app could not read — a slot recovery gives up on can
      // leave one there as the only copy there is — while retired holds
      // duplicates of a record that still stands elsewhere, so there is nothing
      // in it for the user to recover.
      //
      // Named separately from the table above, which is a transcription and says
      // nothing about why any row reads as it does. This case is the reasoning,
      // and it is the one that has to be argued with before quarantine goes back
      // to one confirmation.
      expect(
        storageGroups.firstWhere((group) => group.id == StorageGroupId.quarantine).deleteFriction,
        StorageDeleteFriction.doubleConfirm,
      );
      expect(
        storageGroups.firstWhere((group) => group.id == StorageGroupId.retired).deleteFriction,
        StorageDeleteFriction.singleConfirm,
      );
    });

    test('the unclassified delete asks twice, and the temp one does not', () {
      // The pair, because these two are the groups nothing in the app reads, and
      // they still answer the friction question differently. `temp/` is swept
      // unconditionally at startup, so what is in it is the app's own scratch and
      // is coming back. The residual bucket is decided by subtraction, so a file
      // is in it exactly because the app could not classify it, which rules
      // nothing out: it may be the user's own, and nothing re-creates a file the
      // app never recognised.
      //
      // Named separately from the table above, which is a transcription and says
      // nothing about why any row reads as it does. This case is the reasoning,
      // and it is the one that has to be argued with before the residual bucket
      // goes back to one confirmation.
      expect(
        storageGroups.firstWhere((group) => group.id == StorageGroupId.unclassified).deleteFriction,
        StorageDeleteFriction.doubleConfirm,
      );
      expect(
        storageGroups.firstWhere((group) => group.id == StorageGroupId.temp).deleteFriction,
        StorageDeleteFriction.singleConfirm,
      );
    });

    test('a group carries a delete warning exactly when it offers a delete', () {
      // The warning is shown in the delete confirmation and nowhere else, so
      // "there is no delete" and "there is no warning" are one fact in two
      // fields. Both sides are derived from `storageGroups` — unlike the table
      // above, the claim is not *which* group but that no group can disagree with
      // itself — so a thirteenth group that declared `notOffered` while still
      // naming a warning, or that offered a delete with none, fails here without
      // anyone having to add it to a list.
      final withoutWarning = {
        for (final group in storageGroups)
          if (group.deleteWarningKey == null) group.id,
      };
      final withoutDelete = {
        for (final group in storageGroups)
          if (group.deleteFriction == StorageDeleteFriction.notOffered) group.id,
      };
      expect(withoutWarning, withoutDelete);
      // Non-trivial on both sides. An equality of two empty sets would also hold
      // for a table in which every group had quietly lost its warning, and for
      // one in which every group had quietly gained a delete.
      expect(withoutWarning, isNotEmpty);
      expect(storageGroups.length - withoutWarning.length, 11);
    });
  });

  group('every string the groups name exists in the one translation file', () {
    late Map<String, dynamic> translations;

    setUp(() {
      // `assets/translations/` holds ja.json and nothing else; there is no second
      // locale to fall out of step with.
      expect(Directory('assets/translations').listSync().map((e) => e.uri.pathSegments.last), ['ja.json']);
      translations = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
    });

    test('the view title is there, and a key that is not there reads as missing', () {
      expect(lookupTranslation(translations, 'pages.storage.title'), isA<String>());
      // Negative control: a lookup that answered "found" for everything would
      // make the check below pass against an empty file.
      expect(lookupTranslation(translations, 'pages.storage.group.no_such_group.delete_warning'), isNull);
      expect(lookupTranslation(translations, 'pages.storage.title.deeper'), isNull);
    });

    test('no group has a missing label, description or delete warning', () {
      final missing = <String>[];
      for (final group in storageGroups) {
        // Hand-listed because Dart cannot enumerate a class's fields without
        // mirrors. That makes the list itself the thing that can go stale, so
        // the test below counts what this loop actually looked at and pins the
        // count — adding a key field to `StorageGroup` and forgetting it here
        // fails there rather than passing quietly.
        for (final key in <String?>[group.labelKey, group.descriptionKey, group.deleteWarningKey]) {
          if (key == null) {
            continue;
          }
          expect(key, startsWith('pages.storage.'), reason: '${group.id} left the namespace of this view');
          if (lookupTranslation(translations, key) is! String) {
            missing.add(key);
          }
        }
      }
      expect(missing, isEmpty);
    });

    test('that loop looks at every translation key StorageGroup declares', () {
      // The guard on the hand-written list above. A thirteenth key field added to
      // `StorageGroup` — a per-group tooltip, a delete-button caption — has to be
      // added to that loop as well, or the group carrying it could ship pointing
      // at a key `ja.json` does not define. Literal, so it fails on the addition
      // rather than agreeing with it.
      expect(declaredTranslationKeyFields(groupSource), {'labelKey', 'descriptionKey', 'deleteWarningKey'});
    });

    test("every group names a description key in this view's namespace", () {
      // The keys themselves, not their contents: the sentences are asserted where
      // they are shown (`storage_tree_test.dart`), and what belongs here is that
      // each group asks for its *own* description rather than sharing one — the
      // failure a single mistyped `_descriptionKey('temp')` would produce.
      final keys = [for (final group in storageGroups) group.descriptionKey];
      expect(keys.toSet(), hasLength(12));
      for (final group in storageGroups) {
        expect(group.descriptionKey, startsWith('pages.storage.group.'));
        expect(group.descriptionKey, endsWith('.description'));
        // And it is a *different* string from the group's delete warning, which
        // is the whole point of adding the field rather than reusing that one.
        expect(group.descriptionKey, isNot(group.deleteWarningKey));
      }
    });

    test('every {…} placeholder under pages.storage.* is one this view already fills in', () {
      // Literal, not derived: counted by hand against ja.json. It pins *which*
      // keys carry a placeholder, and that is all it can see — the set is
      // unchanged by renaming `{name}` to `{title}`, and nothing here looks at a
      // call site. What holds the names to the code that fills them in is
      // `storage_wording_test.dart`'s "no brace survives into the sentence the
      // user is shown", which renders each of these through its own production
      // function.
      //
      //
      // `zip.too_large` is **not** here: the approved sentence names neither the
      // size nor the limit, so it carries no placeholder, and `zip_export_web.dart`
      // passes it no `namedArgs`. Listing the key anyway would make this test
      // demand a placeholder the wording does not have.
      //  * `{name}` in delete.target, `{count}` in delete.completed,
      //    `{total}`/`{deleted}`/`{cause}` in delete.partial and `{cause}` in
      //    delete.none (the confirmation dialog, and the sentence reporting what
      //    the delete actually removed), filled
      //    by `storage_delete_action.dart` — the confirmation dialog (through
      //    `storageDeleteTargetSentence`) and `storageDeleteOutcomeMessage`.
      //    `storage_delete_action_test.dart` compares the *outcome* sentences —
      //    completed, partial, none — against the interpolated `ja.json`
      //    literal, so a missing namedArgs in those three is red there as well
      //    as here. It never renders `delete.target`: that one, and the
      //    placeholder *names* of all five, are held only by
      //    `storage_wording_test.dart`'s "no brace survives into the sentence
      //    the user is shown".
      //  * `{activity}` / `{action}` in blocked.template (the refusal shown while
      //    a capture or a video import is writing into the group),
      //    filled by `storageActionBlockedMessage` in
      //    `storage_action_blocker.dart` from two further keys of its own. Both
      //    of the enums that choose those keys are enumerated in
      //    `storage_delete_capture_gate_test.dart`, which also asserts that no
      //    `{` survives the substitution — so a missing namedArgs is red there
      //    as well as here.
      //  * `{record}` / `{reason}` in delete.recovery_incomplete and `{reason}` in
      //    delete.recovery_incomplete_unidentified (the survivor row for a
      //    transaction slot recovery could not empty, which the delete declines to
      //    remove), filled by `storageRecoveryIncompleteDetail` in
      //    `core/storage/storage_delete.dart`. Two keys and not one because the
      //    record id is absent whenever the sweep could not read the slot's
      //    manifest; which is rendered is decided there, and both are rendered
      //    through their production function by `storage_wording_test.dart`.
      const expectedPlaceholderKeys = {
        'pages.storage.blocked.template',
        'pages.storage.delete.target',
        'pages.storage.delete.completed',
        'pages.storage.delete.partial',
        'pages.storage.delete.none',
        'pages.storage.delete.recovery_incomplete',
        'pages.storage.delete.recovery_incomplete_unidentified',
      };
      final placeholderPattern = RegExp(r'\{[^}]*\}');
      final found = <String>{};
      void walk(Object? node, String prefix) {
        if (node is Map<String, dynamic>) {
          for (final entry in node.entries) {
            walk(entry.value, '$prefix.${entry.key}');
          }
        } else if (node is String && placeholderPattern.hasMatch(node)) {
          found.add(prefix);
        }
      }

      walk(lookupTranslation(translations, 'pages.storage'), 'pages.storage');
      expect(found, expectedPlaceholderKeys);
    });
  });

  group('the unclassified bucket is the residue of the app-owned roots', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('storage_group_test'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String relative) {
      final file = File('${root.path}/$relative');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('x');
    }

    test('it reports strays and subtracts everything a group already shows', () async {
      final info = layoutUnder(root.path);
      // Things a group names, directly or through a container.
      Directory(info.charaDetailActiveDir.path).createSync(recursive: true);
      Directory(info.tempDir.path).createSync(recursive: true);
      Directory(info.settingsDir.path).createSync(recursive: true);
      Directory(info.modulesDir.path).createSync(recursive: true);
      write('support/data_root.json');
      write('support/MPLUS1Code_regular_deadbeef.ttf');
      // Things nothing names.
      Directory('${info.documentDir.path}/_feedback').createSync(recursive: true);
      write('support/modules.zip');
      // And the two exclusions that are not about paths at all.
      Directory('${info.supportDir.path}/$sentryNativeDirName').createSync(recursive: true);
      write('exe/umacapture.exe');
      write('downloads/user-owned.zip');

      final names = (await scanUnclassifiedEntries(info)).map((e) => e.entity.name).toSet();
      expect(names, {'_feedback', 'modules.zip'});
      // Named individually so a failure says which rule broke.
      expect(names, isNot(contains('umacapture.exe')), reason: 'the install directory is not scanned');
      expect(names, isNot(contains('user-owned.zip')), reason: 'the downloads folder belongs to the user');
      expect(names, isNot(contains(sentryNativeDirName)), reason: 'the crash database is not an app-owned store');
      expect(names, isNot(contains('storage')), reason: 'an intermediate container is still a named path');
      expect(names, isNot(contains('MPLUS1Code_regular_deadbeef.ttf')), reason: 'the font cache owns *.ttf');
    });

    test('it carries the size the enumeration already resolved', () async {
      final info = layoutUnder(root.path);
      Directory(info.documentDir.path).createSync(recursive: true);
      write('documents/leftover.bin');

      final residue = await scanUnclassifiedEntries(info);
      expect(residue.map((e) => e.entity.name), ['leftover.bin']);
      expect(residue.single.size, 1);
    });

    test('a configured data root is scanned and the default roots still are', () async {
      final dataRoot = DirectoryPath('${root.path}/elsewhere');
      final info = layoutUnder(root.path, dataRoot: dataRoot);
      Directory(info.storageDir.path).createSync(recursive: true);
      write('elsewhere/orphan.json');
      write('support/modules.zip');

      final names = (await scanUnclassifiedEntries(info)).map((e) => e.entity.name).toSet();
      expect(names, {'orphan.json', 'modules.zip'});
      expect(unclassifiedScanRoots(info).map((e) => e.path), contains(dataRoot.path));
      expect(unclassifiedScanRoots(info).map((e) => e.path), isNot(contains(info.executableDir.path)));
      expect(unclassifiedScanRoots(info).map((e) => e.path), isNot(contains(info.downloadDir.path)));
    });

    test('a data root that lands back on an existing root is walked once', () async {
      // The case `DataRootMigrationController.classify` names: a user can choose
      // the app's own documents folder as the data root. Listing it twice would
      // report every stray in it twice.
      final info = layoutUnder(root.path, dataRoot: DirectoryPath('${root.path}/documents'));
      expect(unclassifiedScanRoots(info), hasLength(2));
      write('documents/leftover.bin');

      expect((await scanUnclassifiedEntries(info)).map((e) => e.entity.name), ['leftover.bin']);
    });

    test('a root that does not exist is not an error', () async {
      expect(await scanUnclassifiedEntries(layoutUnder(root.path)), isEmpty);
    });
  });

  group('the two transaction journals are storage the view can show and delete', () {
    late Directory root;
    late PathInfo info;

    setUp(() {
      root = Directory.systemTemp.createTempSync('storage_group_journal_test');
      info = layoutUnder(root.path);
    });
    tearDown(() => root.deleteSync(recursive: true));

    void write(DirectoryPath dir, String relative, String contents) {
      final file = File('${dir.path}/$relative');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
    }

    ProviderContainer containerFor(PathInfo layout) =>
        ProviderContainer(overrides: [pathLayoutLoader.overrideWith((ref) async => layout)]);

    test('the retired group is the three directories, journals included', () {
      final paths = storageGroupOf(StorageGroupId.retired).resolve(info).map((e) => e.path);
      expect(paths, [
        info.charaDetailRetiredDir.path,
        info.charaDetailArchiveTransactionDir.path,
        info.charaDetailWriteTransactionDir.path,
      ]);
      // Both journals are siblings of the record stores, not children of one:
      // a record scan that read a slot as a record is the failure the layout
      // avoids, and a getter that pointed inside `active/` would undo it.
      expect(info.charaDetailArchiveTransactionDir.parent.path, info.charaDetailDir.path);
      expect(info.charaDetailWriteTransactionDir.parent.path, info.charaDetailDir.path);
    });

    test('their bytes are in the group total and their names are in its child list', () async {
      write(info.charaDetailRetiredDir, 'leftover/manifest.json', '12');
      write(info.charaDetailArchiveTransactionDir, 'v1/slot/manifest.json', '1234');
      write(info.charaDetailWriteTransactionDir, 'v1/slot/manifest.json', '123456');
      final container = containerFor(info);
      addTearDown(container.dispose);

      final total = await container.read(storageGroupTotalsProvider(StorageGroupId.retired).future);
      // 2 + 4 + 6. Each journal is named individually below so a failure says
      // which one fell out of the row rather than only that the number moved.
      expect(total.knownBytes, 12);
      expect(total.unresolvedEntries, 0);

      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.retired, path: null)).future,
      );
      final byName = {for (final listing in children) listing.entity.name: listing.entity.path};
      expect(byName['retired'], info.charaDetailRetiredDir.path);
      expect(byName[charaDetailArchiveTransactionDirName], info.charaDetailArchiveTransactionDir.path);
      expect(byName[charaDetailWriteTransactionDirName], info.charaDetailWriteTransactionDir.path);
    });

    test('with no journal on disk the group is the retired folder itself, as it always was', () async {
      // The cost the journals must not impose. On Windows neither is ever written
      // and on web neither survives a completed move, so for almost every user
      // this group has exactly one directory in it — and reading it as "three
      // folders, pick one" would have put `retired/`'s contents behind an extra
      // click and moved the group's zip button off the group row, permanently,
      // for two directories that are not there.
      write(info.charaDetailRetiredDir, 'leftover/manifest.json', '12');
      final container = containerFor(info);
      addTearDown(container.dispose);

      final total = await container.read(storageGroupTotalsProvider(StorageGroupId.retired).future);
      expect((total.knownBytes, total.unresolvedEntries), (2, 0));
      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.retired, path: null)).future,
      );
      expect(children.map((e) => e.entity.name), ['leftover']);
      expect(
        storageGroupZipTarget(info, storageGroupOf(StorageGroupId.retired))?.path,
        info.charaDetailRetiredDir.path,
      );
    });

    test('the group zip stays on the group row even when nothing at all is on disk', () async {
      // The Windows steady state: `retired/` is written by `retireEntryInto`,
      // which only the web transactions call, so the *primary* root is absent too.
      // A zip target derived from what exists would be null here — the button
      // would simply be gone — which is why it is derived from the declaration.
      expect(
        storageGroupZipTarget(info, storageGroupOf(StorageGroupId.retired))?.path,
        info.charaDetailRetiredDir.path,
      );
      final container = containerFor(info);
      addTearDown(container.dispose);
      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.retired, path: null)).future,
      );
      expect(children, isEmpty);
    });

    test('one journal on disk is enough to make the roots rows again', () async {
      write(info.charaDetailRetiredDir, 'leftover/manifest.json', '12');
      write(info.charaDetailWriteTransactionDir, 'v1/slot/manifest.json', '123456');
      final container = containerFor(info);
      addTearDown(container.dispose);

      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.retired, path: null)).future,
      );
      // Named rows, never a mixture of `retired/`'s contents and a journal: an
      // entry on this screen always sits under a name that says where it is.
      // Name order, as every level on this screen is sorted.
      expect(children.map((e) => e.entity.name), [charaDetailWriteTransactionDirName, 'retired']);
    });

    test('the group delete takes all three roots however few of them exist', () async {
      // The point of the whole change: a stalled journal has to be reachable. The
      // request is built from the declaration, so it does not shrink on the
      // platform where the journals are usually absent.
      final request = storageGroupDeleteRequest(info, storageGroupOf(StorageGroupId.retired));
      expect(request, isA<StorageDeletePathsRequest>());
      expect((request as StorageDeletePathsRequest).targets.map((e) => e.path), [
        info.charaDetailRetiredDir.path,
        info.charaDetailArchiveTransactionDir.path,
        info.charaDetailWriteTransactionDir.path,
      ]);
    });

    test('metadata is untouched: two peer rows, and no group zip, whichever of them exists', () async {
      // The negative control for `auxiliaryRoots`. `rating/` and `memo/` are
      // peers — neither stands for the pair — so a user who has rated records but
      // written no memo must still see a row called `rating`, not its JSON files
      // spilled into the group with nothing saying which of the two they are.
      // That is the case a count taken from the filesystem would have broken.
      final metadata = storageGroupOf(StorageGroupId.metadata);
      expect(metadata.auxiliaryRootsOf(info), isEmpty);
      expect(storageGroupZipTarget(info, metadata), isNull);
      write(info.charaDetailRatingDir, 'main.json', '12');
      final container = containerFor(info);
      addTearDown(container.dispose);

      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.metadata, path: null)).future,
      );
      expect(children.map((e) => e.entity.name), ['rating']);
      expect(children.single.entity.path, info.charaDetailRatingDir.path);
    });

    test('the archive journal the transaction actually writes is the one the group shows', () async {
      // Not "the getter equals the getter": the slot below is put there by
      // `RecordDirectoryTransaction` itself, through the same `_transactionRoot`
      // every archive uses, so a writer that moved back to a private literal
      // fails here. This is the state machine web archives with today and the one
      // desktop would gain if it ever stopped relying on an atomic rename — the
      // group covers it either way, because nothing about the coverage is
      // conditioned on the platform.
      const id = 'rec-1';
      write(info.charaDetailActiveDir, '$id/record.json', '{"id":"$id"}');
      final interrupted = RecordDirectoryTransaction(
        onCheckpoint: (checkpoint) async {
          if (checkpoint == RecordTransactionCheckpoint.payloadCopied) {
            throw StateError('interrupt');
          }
        },
      );
      final result = await interrupted.execute(
        RecordDirectoryTransactionSpec(
          recordId: id,
          source: info.charaDetailActiveDir / id,
          destination: info.charaDetailArchiveDir / id,
        ),
      );
      expect(result, isNot(RecordTransactionResult.completed));

      final slots = Directory('${info.charaDetailArchiveTransactionDir.path}/v1').listSync();
      expect(slots, isNotEmpty, reason: 'the interrupted transaction has to have left its journal behind');

      final container = containerFor(info);
      addTearDown(container.dispose);
      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.retired, path: null)).future,
      );
      expect(children.map((e) => e.entity.name), contains(charaDetailArchiveTransactionDirName));
      final total = await container.read(storageGroupTotalsProvider(StorageGroupId.retired).future);
      expect(total.knownBytes, greaterThan(0));
    });
  });

  group('the residue is the same subtraction whatever shape the paths have', () {
    final realBackend = fsBackend;
    tearDown(() => fsBackend = realBackend);

    // WHY THIS TABLE EXISTS. Every case above describes the *native* shape and
    // nothing else: `layoutUnder` gives each root a distinct, non-empty absolute
    // path, because that is the only kind `Directory.systemTemp` can hand out. Web
    // has neither property. `platform_dirs_web.dart` returns `DirectoryPath([])`
    // for the support and executable directories — the empty path, i.e. the OPFS
    // root — and `pathInfoLoader` appends `appName` to the documents dir only, so
    // the documents root is `umacapture`, a *child* of the support root.
    //
    // Both facts were invisible to a fixture built on a real filesystem, and the
    // second one is what the subtraction has to survive: a known group's directory
    // sitting directly under another root must not come back as a stray. On the
    // real web build it did — `modules` and `umacapture` were both listed as
    // unclassified and their bytes were counted a second time into the app-data
    // total — because the two sides of the subtraction were two producers'
    // *spellings* of one location rather than one location.
    final shapes = <({String name, PathInfo info, ChildSpelling spelling, List<String> knownNames})>[
      (
        name: 'Windows',
        info: layoutUnder(Directory.systemTemp.path),
        // What `Directory.list()` yields: the parent joined to the name with the
        // platform separator, which is the separator `PathEntity` joins with too.
        spelling: (prefix, name) => '$prefix${PathEntity.context.separator}$name',
        knownNames: const ['storage', 'settings', 'temp', 'modules'],
      ),
      (
        name: 'web (OPFS)',
        info: PathInfo(
          documentDir: DirectoryPath(<String>['umacapture']),
          supportDir: DirectoryPath(<String>[]),
          executableDir: DirectoryPath(<String>[]),
          // `platformDirs.downloadsDir()` is null on web and `pathLayoutLoader`
          // falls back to the documents dir, so the two really are one path here.
          downloadDir: DirectoryPath(<String>['umacapture']),
          tempSession: 'tab-1',
        ),
        spelling: opfsChildSpelling,
        knownNames: const ['storage', 'settings', 'temp', 'modules', 'umacapture'],
      ),
    ];

    for (final shape in shapes) {
      test('${shape.name}: no directory a group already shows is reported as a stray', () async {
        final info = shape.info;
        // One level per root, listed the way that platform's backend lists it.
        // The document root's children are the same in both shapes; what differs
        // is that on web it is itself a child of the support root.
        final tree = {
          info.documentDir.path: const <VirtualEntry>[
            (name: 'storage', isDirectory: true, size: null),
            (name: 'settings', isDirectory: true, size: null),
            (name: 'temp', isDirectory: true, size: null),
            (name: '_feedback', isDirectory: true, size: null),
          ],
          info.supportDir.path: <VirtualEntry>[
            if (shape.name.startsWith('web')) (name: 'umacapture', isDirectory: true, size: null),
            const (name: 'modules', isDirectory: true, size: null),
            const (name: sentryNativeDirName, isDirectory: true, size: null),
            const (name: 'stray.bin', isDirectory: false, size: 7),
          ],
        };
        fsBackend = VirtualTreeFsBackend(tree: tree, spelling: shape.spelling);

        final residue = await scanUnclassifiedEntries(info);
        final names = residue.map((e) => e.entity.name).toSet();

        expect(names, {'_feedback', 'stray.bin'});
        for (final known in shape.knownNames) {
          expect(names, isNot(contains(known)), reason: '$known is a directory a group already shows');
        }
        expect(names, isNot(contains(sentryNativeDirName)), reason: 'the crash database is not an app-owned store');

        // The residue must name each entry as a child of the root this scan was
        // already holding, not as whatever string the listing returned: that is
        // what makes the subtraction above a comparison of locations, and it is
        // also the path the view will size, expand and delete.
        final stray = residue.singleWhere((e) => e.entity.name == 'stray.bin');
        final feedback = residue.singleWhere((e) => e.entity.name == '_feedback');
        expect(stray.entity.path, info.supportDir.filePath('stray.bin').path);
        expect(feedback.entity.path, (info.documentDir / '_feedback').path);
        // The kind the listing decided is preserved, so the tab still knows which
        // rows expand and which have bytes.
        expect(stray.entity, isA<FilePath>());
        expect(feedback.entity, isA<DirectoryPath>());
        // And the size the enumeration already carried survives the renaming.
        expect(stray.size, 7);
      });
    }
  });
}
