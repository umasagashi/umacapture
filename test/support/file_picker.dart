// A fake `file_picker` platform implementation, for tests that drive a widget's
// "pick a file" button.
//
// THE REAL PICKER MUST NEVER RUN IN A TEST, and on Windows that is not a matter
// of taste. `flutter test` executes the generated Dart plugin registrant, so the
// default `FilePickerPlatform.instance` is the genuine `FilePickerWindows`,
// which calls `GetOpenFileNameW`. A test that forgets to install this fake does
// not fail: it opens a modal dialog on the machine running the suite and waits
// for a human, i.e. it hangs. (The same constraint is written up at
// test/video_import_io_test.dart, which avoids the picker entirely by injecting
// its own seam; widgets that call `FilePicker` statically cannot, so they swap
// the platform instance instead.)
//
// `FilePicker`'s static methods all delegate to `FilePickerPlatform.instance`,
// and that field has a public setter, so the seam already exists in the package
// and needs no counterpart in production code.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

/// The arguments one `pickFiles` call was made with.
///
/// `FilePicker.pickFile` is a wrapper that calls `pickFiles` with
/// `allowMultiple: false` and `withData: false`, so a call recorded here answers
/// "single or multiple selection?" for either entry point.
class FilePickerCall {
  FilePickerCall({
    required this.allowMultiple,
    required this.withData,
    required this.type,
    required this.allowedExtensions,
    required this.lockParentWindow,
    required this.dialogTitle,
  });

  final bool allowMultiple;
  final bool withData;
  final FileType type;
  final List<String>? allowedExtensions;
  final bool lockParentWindow;
  final String? dialogTitle;
}

/// A [FilePickerPlatform] that answers with whatever the test put in [result]
/// and records the arguments of every call.
class FakeFilePicker extends FilePickerPlatform {
  /// Every `pickFiles` call this fake received, oldest first.
  final List<FilePickerCall> calls = [];

  /// What the next `pickFiles` call answers. `null` means "the user cancelled".
  FilePickerResult? result;

  /// What the next `getDirectoryPath` call answers.
  String? directoryPath;

  /// Awaited before [pickFiles] answers, so a test can keep the dialog "open".
  ///
  /// The real dialog is modal and can stay up for as long as the user browses,
  /// which is the window in which the widget that opened it can be disposed. A
  /// fake that answers within a microtask makes that window unreachable, so a
  /// test that needs it hands over a future it completes itself.
  Future<void>? holdUntil;

  /// Answers [files] for the next pick, in the order given.
  void answerWith(List<PlatformFile> files) => result = FilePickerResult(files);

  /// Answers with the files at [paths], as a native dialog would: a name, a size
  /// and a path, and no bytes (`withData` is off on every call this app makes).
  void answerWithPaths(List<String> paths) => answerWith([for (final path in paths) platformFileAt(path)]);

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    calls.add(
      FilePickerCall(
        allowMultiple: allowMultiple,
        withData: withData,
        type: type,
        allowedExtensions: allowedExtensions,
        lockParentWindow: lockParentWindow,
        dialogTitle: dialogTitle,
      ),
    );
    // Recorded before the wait: the arguments the widget asked for are a fact of
    // the call, whether or not the test lets it answer straight away.
    await holdUntil;
    return result;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
    AndroidSAFOptions? androidSafOptions,
  }) async {
    return directoryPath;
  }
}

/// A [PlatformFile] for the existing file at [path], shaped like the one a
/// desktop backend returns: path and size, no in-memory bytes.
PlatformFile platformFileAt(String path) {
  final file = File(path);
  return PlatformFile(path: path, name: file.uri.pathSegments.last, size: file.lengthSync());
}

/// Installs a [FakeFilePicker] as the platform instance for the current test and
/// restores the previous one afterwards.
///
/// Call from `setUp` or from the test body; the restore is registered with
/// `addTearDown`, which runs after either.
FakeFilePicker installFakeFilePicker() {
  final previous = FilePickerPlatform.instance;
  final fake = FakeFilePicker();
  FilePickerPlatform.instance = fake;
  addTearDown(() => FilePickerPlatform.instance = previous);
  return fake;
}
