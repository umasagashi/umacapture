import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/platform_dirs_web.dart';

void main() {
  test('documents and support use the origin-private filesystem root', () async {
    const dirs = WebPlatformDirs();

    expect((await dirs.documentsDir()).segments, isEmpty);
    expect((await dirs.supportDir()).segments, isEmpty);
  });

  test('shared path composition creates one application namespace', () async {
    const dirs = WebPlatformDirs();
    final documentDir = (await dirs.documentsDir()) / 'umacapture';

    expect((documentDir / 'storage').segments, ['umacapture', 'storage']);
    expect(((await dirs.supportDir()) / 'modules').segments, ['modules']);
  });
}
