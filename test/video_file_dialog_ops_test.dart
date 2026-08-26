// The one container list both clip dialogs read (`video_file_dialog_ops.dart`), and the browser
// spelling derived from it.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_file_dialog_ops_test.dart
//
// WHAT THIS IS FOR. Video import and the video-import error report each open a "choose a clip"
// dialog, on Windows through `package:file_picker` and in a browser through `<input type="file">`,
// and the two front ends must not disagree about which of the user's own recordings they will look
// at: a clip the import accepted has to be a clip the report can re-open. Until now the browser
// filter was a hand-written string, spelled twice, next to a Windows list spelled a third time — the
// kind of table whose next omission is silent, because nothing fails to compile and no test that
// does not already know the answer can notice.
//
// So the cases below never compare the accept attribute to a literal of their own. They take
// `videoFileExtensions` as given and require the attribute to account for exactly it, element for
// element and count for count, which is the property that survives a container being added.
//
// WHAT IT CANNOT COVER: that the dialogs actually apply the filter. `pickVideoFile` opens a modal
// Win32 dialog and `pickVideoFileFromBrowser` needs a live DOM and a user gesture, so neither
// default is callable from a suite; the web leg additionally cannot be compiled by the VM at all.
// What is reachable is the fact they share, which is the fact that was duplicated.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/video_file_dialog_ops.dart';

void main() {
  test('the browser accept attribute offers every container the extension list names, and no other', () {
    final tokens = videoFileAcceptAttribute.split(',');
    final extensions = tokens.where((t) => t.startsWith('.')).map((t) => t.substring(1)).toList();

    // Counted rather than spot-checked, so a container added to the list but dropped from the
    // attribute fails here instead of quietly disappearing from one front end's dialog.
    expect(extensions, videoFileExtensions);
    expect(extensions.length, videoFileExtensions.length);
  });

  test('the browser accept attribute keeps the MIME wildcard alongside the extensions', () {
    // `.mkv` carries no registered MIME type on every platform, and mkv is OBS's default container
    // and what this project's own clips are — so neither half of the filter is optional. The
    // wildcard matches what the OS recognises, the extensions match what it does not.
    expect(videoFileAcceptAttribute.split(','), contains('video/*'));
    expect(videoFileExtensions, contains('mkv'));
  });

  test('the extension list is written the way both dialogs consume it', () {
    // The Windows filter (`FilePicker.pickFile(allowedExtensions: ...)`) takes bare extensions, and
    // the browser attribute adds the dot itself. A leading dot here would reach Win32 as `.*.mp4`
    // and match nothing, which is a failure the user sees as an empty dialog.
    for (final extension in videoFileExtensions) {
      expect(extension.startsWith('.'), isFalse, reason: '"$extension" must be a bare extension');
      expect(extension, equals(extension.toLowerCase()));
      expect(extension, isNotEmpty);
    }
  });
}
