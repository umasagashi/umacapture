// The desktop clip dialog (`video_file_dialog_io.dart`) and the one argument this change is about:
// the container filter it hands `package:file_picker`.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_file_dialog_io_test.dart
//
// WHY IT EXISTS. `videoFileExtensions` is now the repository's single statement of which of the
// user's own recordings this app will open, and the browser spelling is derived from it in code. The
// Windows spelling is not derived — the list is passed through as-is — so nothing but a test can say
// that this leg still reads the shared list rather than a literal of its own. Without this file,
// replacing the argument with a hand-written list would turn no test red on the io side.
//
// The real picker must never run here: `flutter test` executes the generated plugin registrant, so
// the default platform instance is the genuine `FilePickerWindows` and it would open a modal
// `GetOpenFileNameW` dialog on the machine running the suite. `installFakeFilePicker` swaps it out;
// see test/support/file_picker.dart.
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/video_file_dialog_io.dart';
import 'package:umacapture/src/core/video_file_dialog_ops.dart';

import 'support/file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFilePicker picker;
  setUp(() => picker = installFakeFilePicker());

  test('the desktop dialog is filtered to the one shared container list', () async {
    picker.answerWith([PlatformFile(path: r'C:\clips\race.mkv', name: 'race.mkv', size: 1)]);

    await pickVideoFile();

    final call = picker.calls.single;
    expect(call.type, FileType.custom);
    // Element for element against the shared list, not against a literal of this test's own: a
    // container added to `videoFileExtensions` has to reach this dialog with nothing to remember.
    expect(call.allowedExtensions, videoFileExtensions);
  });

  test('the desktop dialog asks for one clip and never for its bytes', () async {
    picker.answerWith([PlatformFile(path: r'C:\clips\race.mkv', name: 'race.mkv', size: 1)]);

    await pickVideoFile();

    final call = picker.calls.single;
    // `pickFiles` defaults `allowMultiple` to true, which the Windows backend turns into
    // OFN_ALLOWMULTISELECT: the user could rubber-band a folder and the caller would silently use the
    // first. `withData` false is what keeps a gigabytes-large recording off the heap.
    expect(call.allowMultiple, isFalse);
    expect(call.withData, isFalse);
    expect(call.lockParentWindow, isTrue);
  });

  test('a dismissed dialog is a null clip, not a failure', () async {
    picker.result = null;

    expect(await pickVideoFile(), isNull);
  });
}
