// Backpressure policy of [CapturePreviewSink]: one decode in flight, ONE pending slot, latest wins.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_preview_sink_test.dart
//
// This is the property the whole preview rests on. Frames arrive at the producer's pace (5 Hz, and the
// producer never waits for us) and are decoded at the engine's; the moment the second is slower than the
// first, anything queue-shaped grows without bound -- on web each queued payload is an ImageBitmap holding
// a GPU surface, so an unbounded queue is not slow, it is fatal. Dropping the middle frames is not a
// degradation here: for a preview only the newest frame is worth showing.
//
// The decoder is a controllable fake, so the "slow decode" is exact rather than timing-dependent.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/capture_preview.dart';

/// A decoder the test steps by hand: each `decode` call parks on a completer until the test
/// releases it, so the sink's in-flight/pending bookkeeping is observed deterministically.
class _ManualDecoder {
  final decoded = <String>[];
  final _gates = <String, Completer<ui.Image>>{};

  Future<ui.Image> call(String payload) {
    decoded.add(payload);
    final gate = Completer<ui.Image>();
    _gates[payload] = gate;
    return gate.future;
  }

  /// Finishes the decode of [payload] with a 1x1 image the sink will hand on.
  Future<void> finish(String payload) async => finishWith(payload, await _tinyImage());

  /// Finishes the decode of [payload] with [image], so the caller keeps a handle on the exact
  /// image the sink receives and can assert on its disposal.
  Future<void> finishWith(String payload, ui.Image image) async {
    final gate = _gates.remove(payload);
    expect(gate, isNotNull, reason: '$payload was never decoded');
    gate!.complete(image);
    // Two turns: one for the sink's `await decode(...)`, one for the loop that picks up the pending slot.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// Fails the decode of [payload], as a malformed frame would.
  Future<void> fail(String payload) async {
    final gate = _gates.remove(payload);
    expect(gate, isNotNull, reason: '$payload was never decoded');
    gate!.completeError(StateError('bad frame'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ui.Image> _tinyImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  return recorder.endRecording().toImage(1, 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('drops everything but the newest payload while a decode is in flight', () async {
    final decoder = _ManualDecoder();
    final released = <String>[];
    final shown = <ui.Image>[];
    final sink = CapturePreviewSink<String>(decode: decoder.call, onImage: shown.add, disposePayload: released.add);

    sink.push('a');
    // 'a' starts decoding at once; 'b' and 'c' arrive behind it and only ONE of them can wait.
    sink.push('b');
    sink.push('c');
    expect(decoder.decoded, ['a'], reason: 'at most one decode may be in flight');
    expect(released, ['b'], reason: 'the superseded pending payload must be released, not collected');
    expect(sink.droppedCount, 1);

    await decoder.finish('a');
    expect(decoder.decoded, ['a', 'c'], reason: 'the newest waiting payload wins');
    expect(shown, hasLength(1));

    await decoder.finish('c');
    expect(shown, hasLength(2));
    // Nothing is left waiting, so the next push starts a decode immediately rather than queueing.
    sink.push('d');
    expect(decoder.decoded, ['a', 'c', 'd']);

    await decoder.finish('d');
    for (final image in shown) {
      image.dispose();
    }
  });

  test('an arrival with nothing in flight decodes immediately (no throttle of its own)', () async {
    // The sink is backpressure, not rate limiting: the throttle lives at the source, so a lone frame
    // must never be delayed here.
    final decoder = _ManualDecoder();
    final shown = <ui.Image>[];
    final sink = CapturePreviewSink<String>(decode: decoder.call, onImage: shown.add);

    sink.push('only');
    expect(decoder.decoded, ['only']);
    await decoder.finish('only');

    expect(shown, hasLength(1));
    expect(sink.droppedCount, 0);
    shown.single.dispose();
  });

  test('a failed decode is swallowed and does not wedge the sink', () async {
    // A preview failure must cost one frame and nothing else: no throw out of push (which runs inside
    // the native-message dispatch), and the next frame must still be decoded.
    final decoder = _ManualDecoder();
    final shown = <ui.Image>[];
    final sink = CapturePreviewSink<String>(decode: decoder.call, onImage: shown.add);

    sink.push('bad');
    sink.push('good');
    await decoder.fail('bad');

    expect(sink.errorCount, 1);
    expect(decoder.decoded, ['bad', 'good'], reason: 'the pending frame must still be picked up');
    await decoder.finish('good');
    expect(shown, hasLength(1));
    shown.single.dispose();
  });

  test('a failed decode releases the payload, and a successful one does not', () async {
    // Ownership of the payload passes to the decoder only when the decode SUCCEEDS (on web
    // `createImageFromImageBitmap` consumes the bitmap). A throw hands it back, and nothing else will ever
    // release it: on a browser/renderer pair that rejects every frame this strands one ImageBitmap -- one
    // GPU surface -- every throttle window, roughly 300 a minute, while the 1-in-30 failure log hides it.
    final decoder = _ManualDecoder();
    final released = <String>[];
    final sink = CapturePreviewSink<String>(
      decode: decoder.call,
      onImage: (image) => image.dispose(),
      disposePayload: released.add,
    );

    sink.push('bad');
    await decoder.fail('bad');
    expect(released, ['bad'], reason: 'a decoder that threw never took the payload; the sink still owns it');

    sink.push('good');
    await decoder.finish('good');
    expect(released, ['bad'], reason: 'a consumed payload must not be double-released');

    // Still exactly one release after a second failure of the same shape: once per dropped payload.
    sink.push('bad2');
    await decoder.fail('bad2');
    expect(released, ['bad', 'bad2']);
    expect(sink.errorCount, 2);
  });

  test('an image that finishes decoding after close is disposed, not handed on', () async {
    // The mirror image of the payload leak: by the time the decode lands the sink is gone, so the ui.Image
    // it produced has no owner at all. On web that is a GPU surface with nothing left to release it.
    final decoder = _ManualDecoder();
    final shown = <ui.Image>[];
    final sink = CapturePreviewSink<String>(decode: decoder.call, onImage: shown.add);

    sink.push('inflight');
    sink.close();

    final image = await _tinyImage();
    await decoder.finishWith('inflight', image);

    expect(shown, isEmpty, reason: 'a closed sink must not hand an image to a listener that is gone');
    expect(image.debugDisposed, isTrue);
  });

  test('an onImage that throws disposes the image and does not re-release the payload', () async {
    // Ownership hands over twice: the decoder takes the payload, then `onImage` takes the image --
    // and only by returning normally. A throw out of `onImage` used to strand the image (a GPU
    // surface on web) while the payload, already consumed by the decoder, was released a second
    // time. The production sink does not throw, so this pins the contract for the next one.
    final decoder = _ManualDecoder();
    final released = <String>[];
    final sink = CapturePreviewSink<String>(
      decode: decoder.call,
      onImage: (_) => throw StateError('listener blew up'),
      disposePayload: released.add,
    );

    sink.push('boom');
    sink.push('next');
    final image = await _tinyImage();
    await decoder.finishWith('boom', image);

    expect(image.debugDisposed, isTrue, reason: 'a rejected image has no owner left; the sink must release it');
    expect(released, isEmpty, reason: 'the decoder already consumed the payload; releasing it again is a double free');
    expect(sink.errorCount, 1, reason: 'a listener failure is counted and logged like any other preview failure');
    expect(decoder.decoded, ['boom', 'next'], reason: 'the sink must not wedge on a throwing listener');

    final second = await _tinyImage();
    await decoder.finishWith('next', second);
    expect(second.debugDisposed, isTrue);
    expect(sink.errorCount, 2);
  });

  test('a disposePayload that throws while unwinding a failed decode must not jam the sink', () async {
    // `_release` runs arbitrary app code (an ImageBitmap's `close()`, on web) and can throw. If that
    // throw happened to skip the `_decoding = false` reset, the exception would abort `_drain` before
    // any reset ran, `_decoding` would stay stuck `true` forever, and every later `push` would queue
    // behind it without ever starting a new decode -- a permanent jam. The reset must be structurally
    // unskippable, so this pins that a throwing release still leaves the sink usable.
    final decoder = _ManualDecoder();
    final shown = <ui.Image>[];
    final releaseAttempts = <String>[];
    final sink = CapturePreviewSink<String>(
      decode: decoder.call,
      onImage: shown.add,
      disposePayload: (payload) {
        releaseAttempts.add(payload);
        throw StateError('release blew up for $payload');
      },
    );

    final errors = <Object>[];
    await runZonedGuarded(() async {
      sink.push('bad');
      await decoder.fail('bad');
    }, (error, stackTrace) => errors.add(error));

    expect(releaseAttempts, ['bad']);
    expect(errors, isNotEmpty, reason: 'the throwing release must still surface, not vanish silently');

    // The sink must still be usable: a fresh push must start decoding right away rather than queue
    // forever behind a `_decoding` flag stuck true.
    sink.push('good');
    expect(decoder.decoded, ['bad', 'good'], reason: 'the sink must not be permanently jammed');
    await decoder.finish('good');
    expect(shown, hasLength(1));
    shown.single.dispose();
  });

  test('close releases the waiting payload and refuses later ones', () async {
    // Nothing may outlive the sink holding a GPU surface.
    final decoder = _ManualDecoder();
    final released = <String>[];
    final sink = CapturePreviewSink<String>(
      decode: decoder.call,
      onImage: (image) => image.dispose(),
      disposePayload: released.add,
    );

    sink.push('a');
    sink.push('waiting');
    sink.close();
    expect(released, ['waiting']);

    sink.push('after');
    expect(released, ['waiting', 'after']);
    expect(decoder.decoded, ['a'], reason: 'a closed sink starts no new decode');

    await decoder.finish('a');
  });
}
