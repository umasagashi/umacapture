// WHAT THE APP REFUSES TO EXECUTE WHEN IT UPDATES ITSELF.
// Run: .fvm/flutter_sdk/bin/flutter test test/app_update_payload_test.dart
//
// `AppUpdaterGroup.downloadAndOpen` downloads a file over HTTPS and hands it to ShellExecuteW. A
// response that is not a program -- a captive-portal login page, a proxy error page, a transfer cut
// short -- arrives with a 200 and no exception, so only an inspection of the bytes can stop it.
// `requireAppUpdatePayload` is that inspection, and this file pins the three things it owes: the
// refusal, the removal of the refused file, and the sentence the user is shown.
//
// WHAT IS NOT ASSERTED HERE, and cannot be: that the payload is the *authentic* build. The check is
// structural only, so a well-formed hostile executable passes every case below. Nothing in this file
// should be read as evidence that the update channel is verified.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/gui/dashboard.dart';

import 'support/localization.dart';

late Directory _tempDir;

/// A file in the scratch directory holding exactly [bytes].
FilePath _payload(String name, List<int> bytes) {
  final file = File('${_tempDir.path}/$name')..writeAsBytesSync(bytes);
  return FilePath(file.path);
}

/// A synthesized but structurally complete PE header: `MZ`, an `e_lfanew` at 0x3c, and the `PE\0\0`
/// signature where it points.
Uint8List _minimalPeHeader({int peOffset = 0x40, List<int> signature = const [0x50, 0x45, 0x00, 0x00]}) {
  final bytes = Uint8List(peOffset + signature.length);
  bytes[0] = 0x4d;
  bytes[1] = 0x5a;
  ByteData.sublistView(bytes).setUint32(0x3c, peOffset, Endian.little);
  bytes.setRange(peOffset, peOffset + signature.length, signature);
  return bytes;
}

/// The first 4 KiB of a real, compiler-produced Windows executable: the Dart VM running this test.
///
/// The positive control that a hand-written header cannot be -- it proves the predicate accepts the
/// header layout an actual linker emits, not merely the one this file constructs.
Uint8List _realExecutableHeader() {
  final handle = File(Platform.resolvedExecutable).openSync();
  try {
    return handle.readSync(4096);
  } finally {
    handle.closeSync();
  }
}

Future<void> _expectRefused(FilePath path, AppUpdatePayloadKind kind) async {
  await expectLater(requireAppUpdatePayload(path, kind), throwsA(isA<AppUpdatePayloadException>()));
  expect(File(path.path).existsSync(), isFalse, reason: 'a refused download must not stay on disk');
}

void main() {
  setUpAll(loadAppTranslations);

  setUp(() => _tempDir = Directory.systemTemp.createTempSync('app_update_payload'));
  tearDown(() => _tempDir.deleteSync(recursive: true));

  group('installer branch', () {
    // Each case below is red if the refusal is dropped, weakened to "any non-empty file", or moved
    // after the rename -- and the existence assertion is red if the refusal throws without deleting.
    test('refuses an HTML error page served with a 200', () async {
      final page = _payload(
        'update.exe.part',
        '<!DOCTYPE html><html><body>Sign in to the network</body></html>'.codeUnits,
      );
      await _expectRefused(page, AppUpdatePayloadKind.installer);
    });

    test('refuses an empty response', () async {
      await _expectRefused(_payload('empty.exe.part', const []), AppUpdatePayloadKind.installer);
    });

    test('refuses a transfer cut short inside the DOS stub', () async {
      // Red if the check stops at the MZ magic: these bytes start with a valid DOS header whose
      // e_lfanew points past the end of what arrived.
      final truncated = _minimalPeHeader(peOffset: 0x100).sublist(0, 0x80);
      await _expectRefused(_payload('short.exe.part', truncated), AppUpdatePayloadKind.installer);
    });

    test('refuses a file that starts with MZ but carries no PE signature', () async {
      // Red if the check never follows e_lfanew.
      final impostor = _minimalPeHeader(signature: const [0x5a, 0x5a, 0x5a, 0x5a]);
      await _expectRefused(_payload('impostor.exe.part', impostor), AppUpdatePayloadKind.installer);
    });

    test('accepts a real Windows executable and leaves it in place', () async {
      // The positive control. Red if the predicate rejects everything -- which every refusal case
      // above would still pass.
      final real = _payload('real.exe.part', _realExecutableHeader());
      await requireAppUpdatePayload(real, AppUpdatePayloadKind.installer);
      expect(File(real.path).existsSync(), isTrue, reason: 'an accepted download must survive the check');
    });

    test('accepts a minimal well-formed PE header', () async {
      final synthetic = _payload('synthetic.exe.part', _minimalPeHeader());
      await requireAppUpdatePayload(synthetic, AppUpdatePayloadKind.installer);
      expect(File(synthetic.path).existsSync(), isTrue);
    });
  });

  group('archive branch', () {
    test('refuses an HTML error page', () async {
      final page = _payload('update.zip.part', '<html>proxy error</html>'.codeUnits);
      await _expectRefused(page, AppUpdatePayloadKind.archive);
    });

    test('refuses an archive holding nothing', () async {
      // The shape a captive-portal page decodes into, and the case the module updater documents as
      // the reason its own refusal exists. Red if the check accepted any zip-ish response.
      await _expectRefused(_payload('empty.zip.part', ZipEncoder().encode(Archive())), AppUpdatePayloadKind.archive);
    });

    test('accepts a real zip and leaves it in place', () async {
      final archive = Archive()..addFile(ArchiveFile('umacapture.exe', 2, Uint8List.fromList([0x4d, 0x5a])));
      final zip = _payload('real.zip.part', ZipEncoder().encode(archive));
      await requireAppUpdatePayload(zip, AppUpdatePayloadKind.archive);
      expect(File(zip.path).existsSync(), isTrue);
    });
  });

  group('what the user is told', () {
    // These assert the WHOLE sentence the toast carries, not just the detail line, because the
    // defect this group exists for lived in the WRAPPER: the detail said the payload had been
    // refused while the sentence around it said the download had failed, sending the user to check
    // a connection that worked. A test that read `describeError` alone stayed green through it.
    test('a refused payload is not reported as a failed download', () {
      final detail = appSentenceAt(
        'pages.dashboard.app_updater.invalid_payload.template',
      ).replaceFirst('{file}', appSentenceAt('pages.dashboard.app_updater.invalid_payload.exe'));
      final shown = AppUpdaterGroup.describeFailure(
        const AppUpdatePayloadException(AppUpdatePayloadKind.installer, 'no PE signature at offset 64'),
      );
      // Red if the rejection wrapper is dropped or put back to `download_failed`, and red if the
      // detail arm is dropped (the sentence would carry the English `toString`).
      expect(
        shown,
        appSentenceAt('pages.dashboard.app_updater.download_rejected.template').replaceFirst('{error}', detail),
      );
      expect(
        shown,
        isNot(contains(_literalHead(appSentenceAt('pages.dashboard.app_updater.download_failed.template')))),
        reason: 'the transfer succeeded, so the user must not be told the download failed',
      );
    });

    test('an ordinary transfer failure is still reported as a failed download', () {
      // The positive control for the assertion above: the two wrappers are actually distinguishable
      // and something still says "download failed", so the first test is not passing because that
      // sentence went missing everywhere. Red if the rejection wrapper is applied to every failure.
      final shown = AppUpdaterGroup.describeFailure(const SocketException('connection reset'));
      expect(shown, contains(_literalHead(appSentenceAt('pages.dashboard.app_updater.download_failed.template'))));
    });

    test('the archive branch names the archive, not the installer', () {
      final shown = AppUpdaterGroup.describeFailure(
        const AppUpdatePayloadException(AppUpdatePayloadKind.archive, 'not a zip local file header'),
      );
      expect(shown, contains(appSentenceAt('pages.dashboard.app_updater.invalid_payload.zip')));
    });

    test('the failure toast shows exactly what describeFailure composed', () {
      // WHY THIS READS THE SOURCE. The three tests above pin `describeFailure`, which is only the
      // string the user sees if the toast shows it UNWRAPPED -- and the defect being fixed was
      // precisely a second wrapper at the call site. Driving `downloadAndOpen` end to end would say
      // it directly, but its failure arm cannot be reached from a test: `ref.read(provider.future)`
      // on a container never completes (measured -- the arm runs only when the container is
      // disposed, and by then the progress notifier is gone). Until that is reachable, this locks
      // the shape instead: the toast passes `describeFailure(error)` and nothing else, and the
      // download-failure template is named in exactly one place, inside `describeFailure`.
      final source = File('lib/src/gui/dashboard.dart').readAsStringSync();
      expect(
        source,
        contains('Toaster.show(ToastData.error(description: describeFailure(error)))'),
        reason: 'the toast must show the composed sentence, not re-wrap it',
      );
      const failedTemplate = 'app_updater.download_failed.template';
      expect(
        failedTemplate.allMatches(source).length,
        1,
        reason: 'a second mention of the download-failure template is a second wrapper',
      );
      final composition = source.substring(
        source.indexOf('static String describeFailure'),
        source.indexOf('static String describeError'),
      );
      expect(composition, contains(failedTemplate), reason: 'the one mention must be the choice, not a wrapper');
    });
  });
}

/// The part of a template before its first placeholder.
///
/// `contains` against a whole template can never match once `{error}` has been substituted; matching
/// the literal head keeps the assertion tied to the shipped wording instead of to a copy of it here.
String _literalHead(String template) => template.split('{').first.trim();
