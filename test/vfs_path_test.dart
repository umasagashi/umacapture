import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/vfs_path.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

/// The web layout, spelled the way `platform_dirs_web.dart` and `pathInfoLoader`
/// produce it: the OPFS root carries no application-namespace segment, so the
/// support dir is the empty path and the documents dir is a single segment under
/// it. Only single-segment derivations are compared below, so nothing here depends
/// on which separator `PathEntity.context` uses on the host running the test.
PathInfo _webLayout() {
  return PathInfo(
    documentDir: DirectoryPath(<String>['umacapture']),
    supportDir: DirectoryPath(<String>[]),
    executableDir: DirectoryPath(<String>[]),
    downloadDir: DirectoryPath(<String>['umacapture']),
  );
}

void main() {
  group('vfsChildPath', () {
    test('an empty prefix is the OPFS root, so the child is the bare name', () {
      expect(vfsChildPath('', 'modules'), 'modules');
      expect(vfsChildPath('', 'umacapture'), 'umacapture');
    });

    test('a non-empty prefix is joined with one separator', () {
      expect(vfsChildPath('umacapture', 'storage'), 'umacapture/storage');
      expect(vfsChildPath('modules', 'labels.json'), 'modules/labels.json');
    });

    test('a nested prefix keeps the whole chain', () {
      expect(vfsChildPath('umacapture/chara_detail', 'active'), 'umacapture/chara_detail/active');
      expect(
        vfsChildPath('umacapture/chara_detail/active', 'record.json'),
        'umacapture/chara_detail/active/record.json',
      );
    });

    test('a prefix made only of separators names the root too', () {
      // `WebVfs._split` discards empty segments, so `/` and `` address the same
      // directory; spelling their children differently would be the same defect
      // in a second place.
      expect(vfsChildPath('/', 'modules'), 'modules');
      expect(vfsChildPath('\\', 'modules'), 'modules');
    });

    test('a trailing separator on the prefix is not doubled', () {
      expect(vfsChildPath('umacapture/', 'storage'), 'umacapture/storage');
      expect(vfsChildPath('umacapture//', 'storage'), 'umacapture/storage');
    });

    test('nothing is prepended, so no result starts with a separator', () {
      for (final prefix in ['', '/', 'umacapture', 'umacapture/chara_detail']) {
        expect(vfsChildPath(prefix, 'child').startsWith('/'), isFalse, reason: 'prefix=$prefix');
      }
    });
  });

  group('agreement with the paths PathInfo derives on web', () {
    // The point of the whole exercise: an enumeration is the one place a backend
    // invents a path, and it has to invent the same string the app derives for
    // that location. Comparing the two producers directly is what a literal
    // expectation alone cannot do.
    test('a child of the support dir is spelled the way PathInfo spells it', () {
      final info = _webLayout();
      expect(info.supportDir.path, '');
      expect(vfsChildPath(info.supportDir.path, 'modules'), info.modulesDir.path);
      expect(vfsChildPath(info.supportDir.path, 'modules'), 'modules');
    });

    test('a child of the support dir that is the documents root agrees as well', () {
      final info = _webLayout();
      expect(vfsChildPath(info.supportDir.path, 'umacapture'), info.documentDir.path);
      expect(vfsChildPath(info.supportDir.path, 'umacapture'), 'umacapture');
    });

    test('a spelled child round-trips through PathEntity to the same path', () {
      // `PathEntity.list` wraps every listed path with `PathEntity(...)`, which
      // splits it. A leading separator survives that as a `/` root segment and
      // comes back out of `.path`, which is how the old spelling reached callers.
      final spelled = vfsChildPath('', 'modules');
      expect(DirectoryPath(spelled).path, 'modules');
      expect(DirectoryPath(spelled).name, 'modules');
      expect(DirectoryPath(spelled).parent.path, '');
    });
  });
}
