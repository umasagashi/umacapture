// WHAT THE BROWSER CLIPBOARD IS ALLOWED TO SAY WENT WRONG.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/clipboard_web_outcome_test.dart
//
// `ClipboardWriteOutcome` has four cases because the caller renders three of them as different
// sentences: nothing to copy, no clipboard here at all, and a write that was attempted and refused.
// The browser half used to be able to produce only three of them — a page with no async clipboard
// (a plain `http://` host on a LAN, a document where the API is not exposed) fell out of the same
// `return false` as a rejected write, so the user was told the copy had failed and retried a thing
// that cannot succeed on that page. The same function reported "this record has no image" by
// throwing, which landed in the generic diagnostic and put a warning breadcrumb — with a stack —
// into every Sentry event that followed an ordinary right-click.
//
// READ AS TEXT, NOT RUN, and that is a real weakness rather than a preference:
// `clipboard_image_writer_web.dart` imports `package:web`, so the VM suite cannot compile it, and
// the browser suite CI does have is a `dart test --platform chrome` job that compiles no
// `package:flutter` — this file reaches the framework through `utils.dart`. So what is checked here
// is what the source says, never what a `navigator` actually answers; the capability probe itself
// is unverified by any suite and has to be exercised in a browser. The two rules below are written
// against the enum's own `values` rather than a list, so an outcome added later is covered without
// anyone remembering to come back.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_image_writer.dart';

const _imageEntryPoint = 'Future<ClipboardWriteOutcome> copyImageToClipboard(';
const _byteEntryPoint = 'Future<bool> writeClipboardImage(';

void main() {
  late String web;
  late String native;

  setUpAll(() {
    web = _read('lib/src/core/clipboard_image_writer_web.dart');
    native = _read('lib/src/core/clipboard_image_writer_stub.dart');
  });

  test('both halves of the seam can express every outcome the enum defines', () {
    // The contract is stated on the enum ("distinguishing the three failures the UI reports
    // differently"), so it is a property of every implementation and both are read alike — a
    // divergence shows up as a failure rather than as an absence.
    for (final MapEntry(key: leg, value: source) in {'web': web, 'native': native}.entries) {
      final body = _methodBody(source, _imageEntryPoint);
      expect(body.length, greaterThan(100), reason: 'the $leg body came back nearly empty; the scanner is broken');
      for (final outcome in ClipboardWriteOutcome.values) {
        expect(
          body,
          contains('ClipboardWriteOutcome.${outcome.name}'),
          reason: 'the $leg leg cannot report ${outcome.name}, so that situation is rounded off to another one',
        );
      }
    }
  });

  test('the rule does flag a leg that cannot say "unavailable", so a green run above means something', () {
    // The web body exactly as it was before this was fixed. Without this case a scanner that had
    // stopped matching would make the rule above vacuously true.
    const crippled =
        'Future<ClipboardWriteOutcome> copyImageToClipboard(RefBase ref, ClipboardImageResolver resolve) async {\n'
        '  var missing = false;\n'
        '  final ok = await writeClipboardImage(() async { return null; });\n'
        '  if (ok) return ClipboardWriteOutcome.success;\n'
        '  return missing ? ClipboardWriteOutcome.missing : ClipboardWriteOutcome.failed;\n'
        '}\n';
    final body = _methodBody(crippled, _imageEntryPoint);

    expect(ClipboardWriteOutcome.values.where((outcome) => !body.contains('ClipboardWriteOutcome.${outcome.name}')), [
      ClipboardWriteOutcome.unavailable,
    ]);
  });

  test('"this record has no image" is told apart from a failure before anything is logged', () {
    // The browser leaves no other route: the candidate lookup has to happen inside the blob
    // promise, so the only way out of the loader is to reject it. What must not happen is that
    // rejection reaching the diagnostic, because every `logger` line above trace becomes a Sentry
    // breadcrumb and the ring is finite.
    final body = _methodBody(web, _byteEntryPoint);
    expect(body, contains('logger.w'), reason: 'the diagnostic is gone, so this case asserts nothing');

    final filtered = body.indexOf('on _NoClipboardImageCandidate');
    expect(filtered, greaterThanOrEqualTo(0), reason: 'an expected ending is not told apart from a real failure');
    expect(
      filtered,
      lessThan(body.indexOf('logger.w')),
      reason: 'the expected ending falls through to the diagnostic and becomes a warning breadcrumb',
    );
    // And it is carried by a type of its own rather than by a general-purpose exception, which is
    // what makes the clause above able to name it at all.
    expect(_methodBody(web, _imageEntryPoint), isNot(contains('StateError')));
  });
}

String _read(String relativePath) {
  final file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: 'run this suite from the repository root');
  return file.readAsStringSync();
}

/// The body of the function whose declaration starts with [signature], braces balanced.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'could not find "$signature"; the source layout changed');
  final open = source.indexOf('{', start + signature.length);
  expect(open, greaterThanOrEqualTo(0), reason: '"$signature" has no body');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') {
      depth++;
    } else if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open + 1, i);
    }
  }
  fail('"$signature" has no closing brace');
}
