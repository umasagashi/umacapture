// When a repeated one-time `init` may be coalesced onto the worker's existing setup, and when it
// must re-run it (`resolveSetupRefresh` / `sameWorkerAssets` in `lib/src/core/wasm_worker_ops.dart`).
// Run: .fvm/flutter_sdk/bin/flutter test test/wasm_worker_module_refresh_test.dart
//
// THE DEFECT THIS PINS. `WasmWorkerClient.init` coalesced on "a setup has been issued" alone, and
// the inputs of the *first* one were replayed on every later worker spawn. So the recognizer kept
// the ONNX set and the `version_info.json` of the module that was installed when the page loaded,
// for the rest of that page's life — across a manual module update, and across the `terminate()`
// that ends every regeneration batch. Nothing reported it. Worse, the settings screen re-reads
// `version_info.json` straight from storage, so it showed the *new* version while the recognizer
// used the old one, and the re-recognition an update kicks off wrote the old `recognizer_version`
// back onto every record — leaving "these records are out of date" true after a batch that had
// just reported success. The UI's only statement about the module was the wrong one.
//
// The fix makes the coalesce condition data: the module assets themselves. The comparison is over
// bytes and not over a count, a total size or a version string, because a module update can replace
// a model with one of exactly the same size — and answering "unchanged" for precisely the update
// this is asked about is the failure being removed, not a smaller version of it.
//
// `wasm_worker_client.dart` cannot be compiled by the VM suite (it imports `dart:js_interop`), so
// what is testable is the rule. What is *not* reachable from here, and is therefore claimed
// nowhere: that `_refreshSetupIfModulesChanged` actually re-reads OPFS through the loader closure,
// that `terminate()` + `_issueInit` really re-creates the ORT sessions in the browser, and that the
// deferred branch is picked up by the next spawn.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

Map<String, Uint8List> _module({List<int> aptitude = const [1, 2, 3], List<int> versionInfo = const [9, 9]}) => {
  'onnx:aptitude/prediction.onnx': _bytes(aptitude),
  'json:version_info.json': _bytes(versionInfo),
};

void main() {
  group('sameWorkerAssets', () {
    test('an unchanged module set is the same set', () {
      expect(sameWorkerAssets(_module(), _module()), isTrue);
    });

    test('order does not matter, because the loader walks a directory', () {
      final forwards = <String, Uint8List>{
        'json:a.json': _bytes([1]),
        'onnx:b.onnx': _bytes([2]),
      };
      final backwards = <String, Uint8List>{
        'onnx:b.onnx': _bytes([2]),
        'json:a.json': _bytes([1]),
      };
      expect(sameWorkerAssets(forwards, backwards), isTrue);
    });

    test('a model replaced by one of exactly the same size is a change', () {
      // The case a length or a count comparison would miss, and the case a module update *is*.
      expect(sameWorkerAssets(_module(aptitude: [1, 2, 3]), _module(aptitude: [1, 2, 4])), isFalse);
    });

    test('a changed version_info.json alone is a change', () {
      expect(sameWorkerAssets(_module(versionInfo: [9, 9]), _module(versionInfo: [1, 0])), isFalse);
    });

    test('an added or removed asset is a change', () {
      final extra = _module()..['onnx:skill/prediction.onnx'] = _bytes([7]);
      expect(sameWorkerAssets(_module(), extra), isFalse);
      expect(sameWorkerAssets(extra, _module()), isFalse);
    });

    test('a renamed asset with identical bytes is a change', () {
      final renamed = <String, Uint8List>{
        'onnx:renamed/prediction.onnx': _bytes([1, 2, 3]),
      };
      final original = <String, Uint8List>{
        'onnx:aptitude/prediction.onnx': _bytes([1, 2, 3]),
      };
      expect(sameWorkerAssets(original, renamed), isFalse);
    });

    test('two empty sets are the same set', () {
      expect(sameWorkerAssets(const {}, const {}), isTrue);
    });
  });

  group('resolveSetupRefresh', () {
    test('an unchanged module set coalesces, which is what the page-load rebuilds need', () {
      expect(resolveSetupRefresh(assetsChanged: false, workerBusy: false), SetupRefresh.coalesce);
      expect(resolveSetupRefresh(assetsChanged: false, workerBusy: true), SetupRefresh.coalesce);
    });

    test('a changed module set on an idle worker re-runs the setup', () {
      // The assertion the old coalesce failed: this is the module update reaching the recognizer.
      expect(resolveSetupRefresh(assetsChanged: true, workerBusy: false), SetupRefresh.reissue);
    });

    test('a changed module set is never applied over a session that owns the worker', () {
      // Tearing the worker down here would end a live capture, an import mid-clip or a regeneration
      // batch with no terminal message and no harvest — the same silence `finishUpdate` refuses.
      expect(resolveSetupRefresh(assetsChanged: true, workerBusy: true), SetupRefresh.deferToNextSpawn);
    });
  });
}
