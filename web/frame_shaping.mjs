// Pure WebCodecs framing helpers shared by the production worker and focused Node tests.
//
// WHAT IS NO LONGER HERE, AND WHY: the even-alignment geometry (`outwardEvenCropRect`), the copy plan
// (`buildFrameCopyPlan`) and the pane-anchor arithmetic (`buildPaneIngestMetadata`) moved into the shared core,
// `native/src/core/frame_shaping.h`, reached through `Module.paneCopyPlan(width, height)`. None of it is a
// browser capability -- it is integer geometry over a rectangle the core itself produced, and having a second
// implementation on this side meant a second test harness for one wire contract
// (.claude/rules/platform-parity.md: "share, don't port"). The Gecko constraint that FORCES the alignment moved
// with it and is written out in full at that function.
//
// The live preview followed it. `shouldEmitPreview` (the accepted/enabled/expected-vs-actual gate) and
// `buildPreviewBitmapPlan` (the fit geometry) are now `LivePreviewPolicy` in native/src/core/native_api.h,
// reached through `Module.setPreviewEnabled(enabled, cropped)` and `Module.takePreviewFrame()`. The worker no
// longer decides whether a frame becomes a preview, how big it is, or how often one may be emitted; it
// transports what the core hands it. That also retired the pair of "keep them identical" comments this file and
// native_api.cpp used to carry at each other.
//
// WHAT STAYS HERE, AND WHY: `rgbaCopyOptions` is a WebCodecs API shape, not geometry the recognizer can see --
// the `VideoFrame.copyTo` options object, including the rule that an absent `rect` is not the same request as a
// full-frame `rect`. The core has no notion of copyTo. The worker additionally keeps the translation from the
// visible rectangle into a VideoFrame's CODED space (adding `visibleRect.x/y`): coded vs. visible space is a
// WebCodecs concept the core never sees, and the core is handed the visible size as the captured size.

export function rgbaCopyOptions(outWidth, copyRect) {
  const options = {
    format: 'RGBA',
    layout: [{ offset: 0, stride: outWidth * 4 }],
  };
  // Omitting rect is semantically different from spelling an odd full-frame rect: Gecko accepts the former
  // for subsampled inputs and can reject the latter before converting to RGBA. A null copy rect is the core's
  // way of asking for exactly that shape (frame_shaping.h, THE CONTAINMENT + FALLBACK RULE).
  if (copyRect !== null) options.rect = copyRect;
  return options;
}
