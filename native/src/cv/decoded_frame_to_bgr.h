#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

#include <string>

// WHY THIS INCLUDE IS HERE AND NOT INSIDE THE OPENCV BLOCK BELOW. OpenCV 4.13 picks its Universal-Intrinsics
// backend from CV_SSE2 / CV_NEON / CV_WASM_SIMD / ..., and cv_cpu_dispatch.h sets CV_WASM_SIMD only inside its
// `#if defined __OPENCV_BUILD` branch. The block a downstream consumer actually reaches is the "Compatibility
// code" one, which has cases for SSE2, NEON, SVE and VSX and NO case for wasm -- so it never includes the
// header that declares v128_t either. This include is that missing half; native/wasm/build.sh supplies the
// other half (-DCV_WASM_SIMD=1). See the static_assert below for what happens without them.
#ifdef __EMSCRIPTEN__
#include <wasm_simd128.h>
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/core.hpp>
#include <opencv2/core/hal/intrin.hpp>
#include <opencv2/imgproc.hpp>
#pragma clang diagnostic pop

// THE VECTORISED BODY BELOW MUST ACTUALLY BE VECTOR CODE, AND NOTHING ELSE IN THIS REPOSITORY CAN NOTICE IF IT
// IS NOT. When no backend macro is set, intrin.hpp falls through to intrin_cpp.hpp -- an element-wise reference
// implementation of the whole Universal-Intrinsics API. It compiles, it produces the SAME BYTES, and it emits
// no warning; measured, it turns one v_store_interleave into 48 `v128.store8_lane` where the real backend emits
// 3 `v128.store`. A silent, platform-asymmetric slowdown is exactly what .claude/rules/platform-parity.md
// exists to prevent, so the missing flag is made a build failure rather than a performance report nobody runs.
static_assert(CV_SIMD128,
              "OpenCV's Universal Intrinsics fell back to intrin_cpp.hpp, so cv/decoded_frame_to_bgr.h would "
              "compile to scalar code with no other symptom. A wasm build needs -DCV_WASM_SIMD=1 and "
              "<wasm_simd128.h> included before <opencv2/core/hal/intrin.hpp> (native/wasm/build.sh); an x64 "
              "MSVC build gets CV_SSE2 from OpenCV's own compatibility block and needs neither.");

// A decoded video frame, in the pixel format its decoder produced it in, -> BGR CV_8UC3, reproducing what
// cv::VideoCapture hands the CLI's offline producer TO WITHIN ONE UNIT PER CHANNEL.
//
// ONE UNIT, NOT ZERO, AND THAT IS A DECISION RATHER THAN A DEFECT. Everything below was established as a
// byte-exact reproduction of swscale and the arithmetic still is, EXCEPT the limited-range luma ramp, which is
// deliberately coarsened -- see kLumaRampCoarse* and bt601LumaRampScalar() for the form, the measured bound and
// the reason. Read every "byte for byte" / "zero mismatches" statement in this header as applying to the
// chroma coefficients, the flooring points and the clamping points, which is where they were earned; the ramp
// contributes a known |error| <= 1 on top. What is still exact is the equality of THIS file's two bodies
// (scalar reference and vector kernel), which is what test/cv/test_decoded_frame_to_bgr.cpp proves over the
// whole 2^24 domain.
//
// WHY THIS EXISTS -- the parity argument, because a hand-written colour conversion otherwise looks like
// exactly the kind of ported-instead-of-shared step .claude/rules/platform-parity.md forbids.
//
// The two offline producers must agree on PIXEL VALUES, not merely on geometry. cv/video_loader.h reads
// through cv::VideoCapture, whose FFmpeg backend converts YUV to BGR with **swscale**, and swscale converts
// with BT.601 limited range REGARDLESS of the stream's colour tags (this project's clips are untagged, and
// re-tagging one moves ffmpeg's own PNG output but not VideoCapture's). A browser converts with BT.709, so a
// frame taken out of WebCodecs as RGBA has already been converted with BT.709. Measured on the same file, at
// the header probe cv/detail_crop_calibrator.h gates on, that is G = 194 (CLI) against G = 176 (web) -- one
// side of `isHeaderGreen`'s `g >= 180`, the other side of it, and therefore an import that latched no pane and
// produced no records at all. Handing the core the decoder's own planes and converting HERE is what removes
// the browser's conversion from the picture; this file is then the single place that decides what "the same
// pixels" means for the web offline producer.
//
// THE BROWSER IS NOT HONOURING A TAG, AND ITS REPORTED MATRIX IS NOT EVIDENCE OF ONE. Both halves of that
// matter, because both invite a fix that does not work:
//   * BT.709 is a DEFAULT, not tag fidelity. Every clip measured in this work is untagged (`color_space=
//     unknown`, no `colr` box) and a browser still converts it as BT.709 -- so "tag the clips BT.601 and the
//     two front ends will agree" is not a remedy. It is also not the CLI's remedy: swscale ignores the tags.
//   * THE REPORTED VALUE DOES NOT TRACK THE CONVERSION. Firefox 153, handed a stream tagged BT.601
//     explicitly, decodes it as BT.601 and goes on reporting `VideoFrame.colorSpace.matrix === 'bt709'`.
//     So do NOT branch on the reported matrix and convert accordingly: the report is a constant here, not a
//     measurement, and a branch on it would silently pick the wrong matrix for the one case it exists for.
// The only reliable position is the one this file takes: take the decoder's PLANES, before any matrix is
// applied, and choose the matrix here. That is what makes the two offline producers comparable at all.
//
// WHY NOT cv::cvtColor(COLOR_YUV2BGR_I420). Because it does not reproduce swscale. It is BT.601 limited range
// too, but it rounds differently: over a full frame of the landscape clip it disagrees with VideoCapture on
// 17% of bytes (max 6), and at that same header probe it reads 196 where the CLI reads 194. Close enough to
// pass the gate, not close enough to be the same pixels -- and "the same pixels" is the property the golden
// suite and every calibrated constant in cv/detail_crop_calibrator.h are pinned to.
//
// HOW THE NUMBERS BELOW WERE ESTABLISHED. Not by transcribing swscale, which arrives at its tables through
// several intermediate rescalings; by measuring the mapping it actually produces and then reproducing it. A
// synthetic 4096x4096 yuv420p frame enumerating every one of the 2^24 (Y, U, V) triples exactly once was put
// through swscale, and the result is reproduced by the closed form here on all 50,331,648 output bytes with
// ZERO mismatches. The same form is byte-identical to cv::VideoCapture on real frames of both reference clips
// (2326x1340 landscape, 738x1310 portrait), including frames the BROWSER decoded and handed over as NV12.
// test/cv/test_decoded_frame_to_bgr.cpp pins the parts of that domain a change to any coefficient would move.
//
// The chroma upsampling is nearest-neighbour on both sides, which is not an assumption: swscale's `neighbor`
// and `bicubic` flags produce byte-identical output for this unscaled 4:2:0 -> packed conversion, so there is
// no interpolation to match.
//
// WHY THE FORMAT IS A PARAMETER RATHER THAN ALWAYS I420. Because the caller cannot choose. WebCodecs' copyTo
// converts only to the RGB formats -- naming any other one is `NotSupportedError` unless it is the frame's own
// format -- so "give me I420" is not something a browser can ask a decoder that produced NV12, which is what a
// hardware decode path routinely produces. The caller therefore copies the frame in whatever format it already
// has and says which that is, and the only formats accepted here are the ones where doing so costs no colour
// decision: the two 4:2:0 layouts, converted below, and packed RGBA, which needs no matrix at all because a
// frame that was decoded as RGB never went through one.
//
// WHY THE BT.601 BODY IS VECTORISED, AND WHY IT IS SAFE TO BE. This conversion is the single most expensive
// step of a web import -- measured at 74% of the import window on a 1080x2520 clip -- so it is worth
// vectorising; detail::writeBt601RowsSimd() below does that, and detail::writeRowsScalar() is the arithmetic it
// has to agree with.
//
// BOTH OF ITS LOOPS ARE VECTORISED, and the distinction matters when reading the equivalence claim. The pixel
// loop expands luma and adds the chroma offsets; the per-chroma-row loop that BUILDS those offsets used to be
// scalar table lookups and now computes them with detail::scaledChroma(). That second one is EXACT -- the
// reference divides by 2^16 with floorDiv() and an arithmetic right shift by 16 is that same floor -- so it
// moves no output byte at all, and the |error| <= 1 above remains entirely the luma ramp's.
//
// The argument that nothing downstream may move is NOT that a suite stayed green. It is that the two bodies
// produce THE SAME BYTES, over the conversion's whole input space -- for a 4:2:0 frame every output pixel is a
// function of its own luma byte and its chroma column's two bytes and of nothing else, so 2^24 (Y, U, V)
// triples IS the domain, and test/cv/test_decoded_frame_to_bgr.cpp enumerates every one of them exactly once
// and compares all 50,331,648 output bytes, plus whole images at 40 geometries for the strides and tails a
// per-pixel proof cannot speak about. Byte identity makes every calibrated constant downstream unmovable by
// construction rather than by observation, which is the only kind of argument that covers the inputs nobody
// tried.
//
// IT IS ONE IMPLEMENTATION, NOT A PLATFORM BRANCH. It is written in OpenCV's Universal Intrinsics, so the same
// source is SSE2 under MSVC x64 and SIMD128 in the wasm module. A hand-written wasm-SIMD kernel was measured
// against it and is 1.54x faster, and it is NOT taken: it would exist on one platform only, and
// .claude/rules/platform-parity.md admits a divergence only for something a platform CANNOT do. Wasm and SSE2
// can both express this kernel, so "wasm's own intrinsics are faster here" is a preference, and taking it would
// leave two copies of the arithmetic whose entire purpose is that the two offline producers agree on pixel
// values. The price of the portable spelling is stated rather than hidden: it takes 38.4% off the conversion
// and 21.8% off the import window where the wasm-only kernel would take 60.1% and 30.0% (measured 2026-08-13,
// Chromium, one clip).
namespace uma::color {

// The pixel formats an offline producer may hand over, spelled as WebCodecs spells them.
//
// A STRING ON THE WIRE, and unknown names are REFUSED rather than defaulted -- the same reasoning as
// CaptureSessionKind's spelling in native/wasm/wasm_api.cpp. An integer tag would let a caller from a
// mismatched bundle name a format by accident, and picking a default for a format this build does not know is
// how a frame gets reinterpreted as something it is not.
enum class DecodedFrameFormat {
    I420,  // Planar Y, then Cb, then Cr, each tightly packed; chroma planes are ceil(w/2) x ceil(h/2).
    Nv12,  // Planar Y, then ONE interleaved CbCr plane of the same chroma dimensions.
    Rgba,  // Packed 8-bit RGBA. No colour conversion is involved, only a channel reorder.
};

inline std::optional<DecodedFrameFormat> parseDecodedFrameFormat(const std::string &name) {
    if (name == "I420") {
        return DecodedFrameFormat::I420;
    }
    if (name == "NV12") {
        return DecodedFrameFormat::Nv12;
    }
    if (name == "RGBA") {
        return DecodedFrameFormat::Rgba;
    }
    return std::nullopt;
}

// Which YUV -> RGB matrix a conversion uses.
//
// PRODUCTION ONLY EVER USES Bt601. It is what swscale applies regardless of a stream's colour tags, so it is
// what cv::VideoCapture hands the CLI, and handing the wasm module the decoder's own planes exists precisely
// so the web offline producer converts with the same one. Bt709 is here as the REFERENCE for the mapping a
// browser applies when it converts a stream itself -- which it does with BT.709 whether or not the stream is
// tagged (the RGBA path, where the decision was already made before the frame reached us):
// test/integration/run_dual_decode.py runs the same clip through both and requires the recognized records to
// be identical, which is what makes "the recognition is colour-shift
// tolerant" a measurable property instead of an opinion. Nothing in the shipping paths selects Bt709.
enum class ColorMatrix {
    Bt601,
    Bt709,
};

// Chroma plane dimensions for a `width` x `height` I420 frame. Rounded UP, because a visible rectangle may be
// odd on either axis and the decoder still carries a chroma sample for the trailing row/column.
inline int chromaWidth(int width) {
    return (width + 1) / 2;
}

inline int chromaHeight(int height) {
    return (height + 1) / 2;
}

// The byte count a tightly packed frame of this format and size occupies. Zero for a size that cannot describe
// a frame, which is what makes the size check in decodedFrameToBgr() reject it too.
inline size_t decodedFrameByteCount(DecodedFrameFormat format, int width, int height) {
    if (width <= 0 || height <= 0) {
        return 0;
    }
    const size_t luma = static_cast<size_t>(width) * static_cast<size_t>(height);
    if (format == DecodedFrameFormat::Rgba) {
        return luma * 4;
    }
    // I420 and NV12 carry the same number of chroma SAMPLES; they differ only in whether Cb and Cr sit in one
    // interleaved plane or two.
    const size_t chroma = static_cast<size_t>(chromaWidth(width)) * static_cast<size_t>(chromaHeight(height));
    return luma + 2 * chroma;
}

// WHERE EACH PLANE OF A TIGHTLY PACKED FRAME BEGINS AND HOW WIDE ITS ROWS ARE, stated as DATA so that a
// caller which was HANDED a layout by its decoder can be held to it instead of being trusted.
//
// WHY THE BYTE COUNT ABOVE IS NOT ENOUGH, which is the whole reason this sits next to it. WebCodecs'
// `VideoFrame.copyTo` RETURNS the layout it used, per plane, as an (offset, stride) pair -- the caller does
// not choose it. A copy with row padding occupies MORE bytes, so decodedFrameByteCount() already refuses it;
// but a copy that merely places Cr before Cb (the YV12 ordering) occupies EXACTLY the same number of bytes,
// and reading it as I420 yields a plausible picture assembled out of the right bytes in the wrong places.
// That is the same silent-wrong-pixels failure parseDecodedFrameFormat() refuses an unknown format name to
// avoid, and it is refusable the same way: compare the layout the caller was given against the one named
// here, and refuse a mismatch BY NAME. A size check cannot see it and no downstream stage can either.
//
// The planes come in the order the buffer holds them: Y, Cb, Cr for I420; Y then the one interleaved CbCr
// plane for NV12; one packed plane for RGBA. detail::planarLayout() below walks the very same bytes for the
// conversion itself, and test/cv/test_decoded_frame_to_bgr.cpp pins the two against each other -- two
// descriptions of one buffer that drifted apart would put this check to work defending the wrong offsets.
struct PlanePlacement {
    size_t offset = 0;
    size_t stride = 0;
};

// C++17 generates no operator!=, so a caller writes !(a == b).
inline bool operator==(const PlanePlacement &a, const PlanePlacement &b) {
    return a.offset == b.offset && a.stride == b.stride;
}

// Empty for a size that cannot describe a frame -- the same answer decodedFrameByteCount() gives it, so a
// layout can never be obtained for a frame the conversion would go on to refuse.
inline std::vector<PlanePlacement> tightlyPackedLayout(DecodedFrameFormat format, int width, int height) {
    if (decodedFrameByteCount(format, width, height) == 0) {
        return {};
    }
    const size_t luma_stride = static_cast<size_t>(width);
    const size_t luma_bytes = luma_stride * static_cast<size_t>(height);
    if (format == DecodedFrameFormat::Rgba) {
        return {PlanePlacement{0, luma_stride * 4}};
    }
    const size_t chroma_stride = static_cast<size_t>(chromaWidth(width));
    if (format == DecodedFrameFormat::Nv12) {
        // ONE plane carrying both chroma components, so its rows are twice as wide as I420's.
        return {PlanePlacement{0, luma_stride}, PlanePlacement{luma_bytes, chroma_stride * 2}};
    }
    const size_t chroma_bytes = chroma_stride * static_cast<size_t>(chromaHeight(height));
    return {PlanePlacement{0, luma_stride}, PlanePlacement{luma_bytes, chroma_stride},
            PlanePlacement{luma_bytes + chroma_bytes, chroma_stride}};
}

// THE VERDICT: is `supplied` the layout above, plane for plane? Every entry point that is handed a layout by
// its decoder asks THIS -- one comparison for the whole repository, rather than one per entry point and a
// third written out in the caller's own language.
//
// It lives here, next to the layout it judges, for two reasons beyond having a single copy. The layout and the
// verdict drift apart the moment they are written in different files (a plane order added here and compared
// there is exactly the silent-wrong-pixels case this whole pair exists to refuse). And the entry points that
// need it are embind exports in native/wasm/, which no test in this repository compiles -- while this header
// is on umacapture_tests' own include path, so the rule stays falsifiable by name.
//
// A width or height that cannot describe a frame answers FALSE for every `supplied`, the empty layout
// included: there is no tightly packed layout for such a frame, so nothing can be it. That keeps the answer
// aligned with decodedFrameByteCount(), which refuses the same sizes -- a caller cannot be told its layout is
// fine and then be refused on the bytes.
inline bool isTightlyPackedLayout(
    DecodedFrameFormat format,
    int width,
    int height,
    const std::vector<PlanePlacement> &supplied) {
    const auto expected = tightlyPackedLayout(format, width, height);
    if (expected.empty() || supplied.size() != expected.size()) {
        return false;
    }
    return std::equal(supplied.begin(), supplied.end(), expected.begin());
}

namespace detail {

// Where the planes of a tightly packed 4:2:0 frame begin and how to walk the chroma ones. It is a function so
// that the conversion and the equivalence test in test/cv/test_decoded_frame_to_bgr.cpp reach the row writers
// over the SAME plane arithmetic: a second copy of it in the test could agree with itself while disagreeing
// with the shipping one, and the test would then be proving something about neither.
struct PlanarLayout {
    const uint8_t *y_plane = nullptr;
    const uint8_t *u_plane = nullptr;
    const uint8_t *v_plane = nullptr;
    int chroma_width = 0;
    size_t chroma_stride = 0;
    int chroma_step = 0;
};

inline PlanarLayout planarLayout(const uint8_t *data, DecodedFrameFormat format, int width, int height) {
    const bool interleaved = format == DecodedFrameFormat::Nv12;
    const size_t chroma_plane =
        static_cast<size_t>(chromaWidth(width)) * static_cast<size_t>(chromaHeight(height));
    PlanarLayout layout;
    layout.y_plane = data;
    layout.u_plane = data + static_cast<size_t>(width) * static_cast<size_t>(height);
    // NV12 keeps Cr in the same plane as Cb, one byte later; I420 keeps it in the plane after.
    layout.v_plane = interleaved ? layout.u_plane + 1 : layout.u_plane + chroma_plane;
    layout.chroma_width = chromaWidth(width);
    layout.chroma_stride = interleaved ? static_cast<size_t>(chromaWidth(width)) * 2
                                       : static_cast<size_t>(chromaWidth(width));
    layout.chroma_step = interleaved ? 2 : 1;
    return layout;
}

// Floored division, for the negative numerators the two G coefficients produce. C++ integer division
// truncates toward zero, which is NOT what the reference mapping does.
inline int floorDiv(int64_t numerator, int64_t denominator) {
    int64_t quotient = numerator / denominator;
    if ((numerator % denominator != 0) && ((numerator < 0) != (denominator < 0))) {
        --quotient;
    }
    return static_cast<int>(quotient);
}

// ---- the limited-range luma expansion, and the one place its coarseness is decided --------------------------
//
// THE EXACT FUNCTION IS floor((Y - 16) * 255 / 219), and this is NOT it. What is computed instead is
//
//     ramp(Y) = d + floor((d * 10 + 52) / 64),   d = Y - 16
//
// which agrees with the exact ramp to WITHIN ONE OUTPUT UNIT over the whole domain Y in [0, 255] (measured
// exhaustively by the doctest case "the coarse luma ramp stays within one unit of the exact expansion":
// 134 of the 256 luma values are off by exactly 1, none by more, and Y = 16 -- black -- is exact).
//
// WHY A DELIBERATE ERROR IS ALLOWED HERE. The property this conversion has to have is not colour accuracy and
// is not byte identity with swscale; it is that the RECOGNITION RESULT does not move (the consumer, models
// included, is built to tolerate colour that is off by a few units -- an unqualified byte-identity requirement
// would buy precision nothing downstream can resolve, at the price of an int32 widening per eight pixels).
// The exact form needed a multiply-expand to int32 and two 32-bit shifts because floor(d * 36 / 219) has no
// bit-exact int16-only spelling; this one is five int16 operations with no widening at all.
//
// WHAT THAT COSTS, STATED PLAINLY, because it is the claim this file used to make and no longer does: the
// output is NO LONGER byte-identical to cv::VideoCapture / swscale, so the two offline producers now agree on
// pixel values to within 1 rather than exactly. Where a downstream threshold sits within 1 of a probe, that is
// the whole exposure -- the header probes cv/detail_crop_calibrator.h gates on are measured at G = 194 and
// G = 199 against `g >= 180`, and both are unmoved by this ramp; what pins the RESULT rather than the argument
// is test/integration/run_dual_decode.py, whose bt601 control diffs the record set produced through THIS file
// against the committed golden produced through swscale.
//
// The two arms below -- the table the scalar body reads and the vector kernel -- must stay the SAME function,
// so both are written in terms of the constants here and the exhaustive equivalence test compares them.
constexpr int kLumaBlackLevel = 16;
constexpr int kLumaRampCoarseNumerator = 10;
constexpr int kLumaRampCoarseBias = 52;
constexpr int kLumaRampCoarseShift = 6;

// d * 10 + 52 over d in [-16, 239] spans [-108, 2442], so the whole intermediate fits int16 with room to
// spare; that is the point of this form. The shift is an ARITHMETIC one on both arms -- `>> 6` here through
// floorDiv, `cv::v_shr` on the vector side -- so a negative d (Y below black) floors on both, identically.
inline int bt601LumaRampScalar(int y) {
    const int above_black = y - kLumaBlackLevel;
    return above_black
           + floorDiv(static_cast<int64_t>(above_black) * kLumaRampCoarseNumerator + kLumaRampCoarseBias,
                      1 << kLumaRampCoarseShift);
}

// The luma ramp and the four chroma offsets, all in OUTPUT units and all floored INDEPENDENTLY -- that
// independence is itself part of what was measured, since combining the two G offsets under a single floor
// disagrees with the reference on 32157 of the 65536 (U, V) pairs.
struct YuvToRgbTables {
    // The limited-range luma expansion, COARSENED -- see kLumaRampCoarse* below for the form and for what it
    // costs. Deliberately NOT clamped to [0, 255]: it is only an intermediate, and clamping it before the
    // chroma offset is added disagrees with the reference on 7% of the domain (every triple whose luma alone
    // falls outside the range but whose sum does not).
    //
    // Shared by both matrices: BT.601 and BT.709 differ in the chroma coefficients only, and both describe a
    // limited-range (16-235) source, so the luma ramp is the same function in both.
    std::array<int, 256> luma{};
    std::array<int, 256> v_to_r{};
    std::array<int, 256> u_to_g{};
    std::array<int, 256> v_to_g{};
    std::array<int, 256> u_to_b{};
};

// ---- the four BT.601 chroma coefficients, in ONE place ------------------------------------------------------
//
// THE VECTOR KERNEL COMPUTES THESE OFFSETS INSTEAD OF LOOKING THEM UP, so the coefficients are no longer the
// private business of makeTables(): the table below and detail::scaledChroma() further down are two arms of the
// SAME function, exactly as the luma ramp's two arms are, and the reason is the same -- a value that differed
// between them would make one output row disagree with itself wherever the vector step and the scalar tail meet.
// Naming them here is what makes "the same coefficient" a fact of the source rather than of somebody's care.
//
// The first, second and fourth are the canonical BT.601 coefficients (1.596, 0.813, 2.018); `kBt601UToG` is NOT
// the canonical 25675, because that value disagrees with the reference at U = 31 and U = 225 and thus on 94688
// output bytes. Every value in [-25673, -25669] reproduces the reference exactly over the whole domain; the
// middle of that interval is taken so that being one or two units out in either direction still lands inside it.
//
// 16.16 FIXED POINT, AND THE SHIFT IS THE WHOLE REASON THE VECTOR ARM CAN BE EXACT. The reference divides by
// 65536 with floorDiv(); 65536 is 2^16, so an ARITHMETIC right shift by 16 is that floor, on negative chroma
// too -- no rounding decision is left over for the two arms to make differently.
constexpr int kChromaBias = 128;
constexpr int kChromaFixedPointShift = 16;
constexpr int kBt601VToR = 104597;
constexpr int kBt601UToG = -25671;
constexpr int kBt601VToG = -53279;
constexpr int kBt601UToB = 132201;

// The G pair is stored already negated, which is why nothing below subtracts.
inline YuvToRgbTables makeBt601Tables() {
    YuvToRgbTables tables;
    for (int i = 0; i < 256; ++i) {
        const int64_t chroma = i - kChromaBias;
        const int64_t one = static_cast<int64_t>(1) << kChromaFixedPointShift;
        tables.luma[i] = bt601LumaRampScalar(i);
        tables.v_to_r[i] = floorDiv(kBt601VToR * chroma, one);
        tables.u_to_g[i] = floorDiv(kBt601UToG * chroma, one);
        tables.v_to_g[i] = floorDiv(kBt601VToG * chroma, one);
        tables.u_to_b[i] = floorDiv(kBt601UToB * chroma, one);
    }
    return tables;
}

inline const YuvToRgbTables &bt601Tables() {
    static const YuvToRgbTables tables = makeBt601Tables();
    return tables;
}

// BT.709, and it is NOT bt601Tables() with different coefficients -- it accumulates before it floors, where
// BT.601 floors every term independently. That difference is not cosmetic and not a style choice: the two
// tables model two different IMPLEMENTATIONS, because the two matrices reach this project through different
// code.
//
// BT.601 arrives via swscale, which really does floor its luma ramp and its four chroma offsets separately
// (combining the two G offsets under one floor disagrees with it on 32157 of the 65536 (U, V) pairs -- see
// bt601Tables()). BT.709 arrives via a browser, which converts with libyuv: one fixed-point accumulation per
// channel, shifted down once at the end. Flooring per term instead reads TWO LOW on the very pixels this
// exists to describe. The two header-green probes test/cv/test_decoded_frame_to_bgr.cpp pins read G = 194 and
// G = 199 through cv::VideoCapture and G = 176 and G = 182 out of WebCodecs; the form below reproduces 176
// and 182 exactly, and a per-term-floor BT.709 gives 174 and 180 -- which would have put one of them back on
// the passing side of `isHeaderGreen`'s `g >= 180` and quietly understated the defect.
//
// The coefficients themselves are the canonical BT.709 limited-range ones (1.164383, 1.792741, 0.213249,
// 0.532909, 2.112402) in 16.16. Unlike the BT.601 values they are NOT reverse-engineered from a reference
// implementation, because there is no single one to match: swscale's own BT.709 table and libyuv's constants
// are each a slightly different rounding of the same matrix and differ from these by at most 1 per channel.
// One unit is far below what any threshold in the pipeline can resolve, and the property this table exists
// to express -- the same clip under the other matrix -- is a ~7 mean / 37 max shift.
struct Bt709Tables {
    // All five in 16.16 NUMERATORS, summed per channel and floored once. `luma` is 255/219 * (Y - 16), the
    // same limited-range expansion BT.601 uses; only its rounding point differs.
    std::array<int, 256> luma{};
    std::array<int, 256> v_to_r{};
    std::array<int, 256> u_to_g{};
    std::array<int, 256> v_to_g{};
    std::array<int, 256> u_to_b{};
};

inline const Bt709Tables &bt709Tables() {
    static const Bt709Tables tables = [] {
        Bt709Tables result;
        for (int i = 0; i < 256; ++i) {
            const int chroma = i - 128;
            result.luma[i] = 76309 * (i - 16);  // round(255/219 * 65536)
            result.v_to_r[i] = 117489 * chroma;
            result.u_to_g[i] = -13975 * chroma;
            result.v_to_g[i] = -34924 * chroma;
            result.u_to_b[i] = 138438 * chroma;
        }
        return result;
    }();
    return tables;
}

inline uchar clampToByte(int value) {
    return static_cast<uchar>(value < 0 ? 0 : (value > 255 ? 255 : value));
}

// The scalar body, for BOTH matrices, over a tightly packed 4:2:0 frame.
//
// IT IS PRODUCTION CODE AND IT IS ALSO THE REFERENCE. `use_709` is the shipping path for the BT.709 reference
// matrix (nothing that ships selects it, but `video --color_matrix bt709` and
// test/integration/run_dual_decode.py do). Its BT.601 arm is what writeBt601RowsSimd() below replaced, and it
// is deliberately kept: "produces the same bytes as the arithmetic it replaced" is the whole safety argument
// for vectorising at all, and an argument needs something to be equal TO. Its only consumer on that arm is
// test/cv/test_decoded_frame_to_bgr.cpp, which is a sufficient reason for code to exist -- deleting it would
// leave the equivalence test comparing the vector kernel with itself.
inline void writeRowsScalar(const YuvToRgbTables &tables, const Bt709Tables &tables_709, bool use_709,
                            const PlanarLayout &layout, int width, int height, cv::Mat &bgr) {
    for (int y = 0; y < height; ++y) {
        const uint8_t *y_row = layout.y_plane + static_cast<size_t>(y) * static_cast<size_t>(width);
        const size_t chroma_row = static_cast<size_t>(y / 2) * layout.chroma_stride;
        const uint8_t *u_row = layout.u_plane + chroma_row;
        const uint8_t *v_row = layout.v_plane + chroma_row;
        uchar *out = bgr.ptr<uchar>(y);
        for (int x = 0; x < width; ++x) {
            const int u = u_row[(x / 2) * layout.chroma_step];
            const int v = v_row[(x / 2) * layout.chroma_step];
            if (use_709) {
                // One accumulation per channel, floored once -- see bt709Tables() for why this differs from
                // the BT.601 form below rather than merely swapping coefficients.
                const int luma = tables_709.luma[y_row[x]];
                out[3 * x + 0] = clampToByte(floorDiv(luma + tables_709.u_to_b[u], 65536));
                out[3 * x + 1] = clampToByte(floorDiv(luma + tables_709.u_to_g[u] + tables_709.v_to_g[v], 65536));
                out[3 * x + 2] = clampToByte(floorDiv(luma + tables_709.v_to_r[v], 65536));
                continue;
            }
            const int luma = tables.luma[y_row[x]];
            out[3 * x + 0] = clampToByte(luma + tables.u_to_b[u]);
            out[3 * x + 1] = clampToByte(luma + tables.u_to_g[u] + tables.v_to_g[v]);
            out[3 * x + 2] = clampToByte(luma + tables.v_to_r[v]);
        }
    }
}

// How many pixels one step of the vectorised main loop converts: the lane count of the v_uint8x16 of luma bytes
// it loads. Their chroma offsets are 16-bit and each covers two pixels, so one v_int16x8 of offsets spans the
// same 16 pixels.
constexpr int kSimdPixelsPerStep = 16;
constexpr int kSimdChromaLanesPerStep = kSimdPixelsPerStep / 2;

// v_setall_s16 takes a short; every constant this file declares is an int, so this is where they narrow.
inline cv::v_int16x8 splatInt16(int value) {
    return cv::v_setall_s16(static_cast<short>(value));
}

// The vector arm of bt601LumaRampScalar() -- COMPUTED rather than looked up, because a 256-entry gather is what
// this kernel cannot vectorise (scaledChroma() below answers the same question the same way, for the four
// chroma columns, and the only table lookups left are in the scalar tails). Five int16 operations, no widening:
// the coarse form was
// chosen so that d * 10 + 52 stays inside int16 over the whole luma range, which is what removes the
// v_mul_expand / two 32-bit shifts / v_pack the exact ramp needed. `cv::v_shr` on a signed lane is the
// arithmetic shift, i.e. the same floor the scalar arm takes.
inline cv::v_int16x8 bt601LumaRamp(const cv::v_int16x8 &luma) {
    const cv::v_int16x8 above_black = cv::v_sub_wrap(luma, splatInt16(kLumaBlackLevel));
    const cv::v_int16x8 numerator = cv::v_add_wrap(
        cv::v_mul_wrap(above_black, splatInt16(kLumaRampCoarseNumerator)), splatInt16(kLumaRampCoarseBias));
    return cv::v_add_wrap(above_black, cv::v_shr<kLumaRampCoarseShift>(numerator));
}

// One chroma coefficient applied to eight CENTRED chroma samples: floor(coefficient * (c - 128) / 65536), i.e.
// the vector arm of one of the four columns makeBt601Tables() fills. Same function, computed instead of gathered
// -- a 256-entry lookup is the step this kernel cannot vectorise, and there is nothing to look up once the
// multiply is in registers.
//
// WHY int32 APPEARS HERE AND WAS REMOVED FROM THE LUMA RAMP. The largest coefficient is 132201, so the product
// with a chroma sample needs 25 bits and no int16-only spelling exists at all -- unlike the ramp, where a
// coarser int16 form was available and taken. The cost is paid once per chroma column (a quarter of the pixels)
// rather than once per pixel, which is why it is worth paying to be EXACT here and was not there.
//
// `v_shr` on a signed lane is the ARITHMETIC shift, so it floors on negative chroma exactly as floorDiv() does
// on the table arm -- that is the whole reason this substitution costs no accuracy. `v_pack` is the saturating
// int32 -> int16 narrow and cannot saturate on this input: over c in [0, 255] every one of the four columns
// stays inside [-260, 256], against int16's +-32767.
inline cv::v_int16x8 scaledChroma(const cv::v_int16x8 &centered, int coefficient) {
    cv::v_int32x4 lo;
    cv::v_int32x4 hi;
    cv::v_expand(centered, lo, hi);
    const cv::v_int32x4 factor = cv::v_setall_s32(coefficient);
    return cv::v_pack(cv::v_shr<kChromaFixedPointShift>(cv::v_mul(lo, factor)),
                      cv::v_shr<kChromaFixedPointShift>(cv::v_mul(hi, factor)));
}

// The three per-chroma-column offsets of eight columns, written where the pixel loop and its scalar tail both
// read them.
inline void writeChromaOffsets(const cv::v_uint16x8 &u, const cv::v_uint16x8 &v, int16_t *offset_b,
                               int16_t *offset_g, int16_t *offset_r) {
    const cv::v_int16x8 bias = splatInt16(kChromaBias);
    const cv::v_int16x8 u_centered = cv::v_sub_wrap(cv::v_reinterpret_as_s16(u), bias);
    const cv::v_int16x8 v_centered = cv::v_sub_wrap(cv::v_reinterpret_as_s16(v), bias);
    cv::v_store(offset_b, scaledChroma(u_centered, kBt601UToB));
    // The two G terms are floored SEPARATELY and only then summed, which is what the table arm does and is not
    // a detail: one floor over the sum disagrees with the reference on 32157 of the 65536 (U, V) pairs.
    cv::v_store(offset_g,
                cv::v_add_wrap(scaledChroma(u_centered, kBt601UToG), scaledChroma(v_centered, kBt601VToG)));
    cv::v_store(offset_r, scaledChroma(v_centered, kBt601VToR));
}

// How many chroma columns one step of the offset build covers: the lane count of the v_uint8x16 of chroma bytes
// it loads, expanded into two halves of eight.
constexpr int kSimdChromaColumnsPerBuildStep = 16;

// The Cb and Cr samples of kSimdChromaColumnsPerBuildStep columns, out of whichever 4:2:0 layout they arrived
// in -- sixteen bytes per plane for I420, thirty-two interleaved bytes for NV12. THE INTERLEAVE IS UNDONE BY
// OpenCV'S OWN DEINTERLEAVING LOAD, deliberately and not by masking a v_uint16x8's low and high bytes: the
// mask version is shorter and assumes a byte order the Universal Intrinsics do not promise, and this is a file
// whose entire purpose is that two backends agree.
inline void loadChromaColumns(const PlanarLayout &layout, const uint8_t *u_row, const uint8_t *v_row,
                              int chroma_x, cv::v_uint8x16 &u, cv::v_uint8x16 &v) {
    if (layout.chroma_step == 2) {
        cv::v_load_deinterleave(u_row + 2 * static_cast<size_t>(chroma_x), u, v);
        return;
    }
    u = cv::v_load(u_row + chroma_x);
    v = cv::v_load(v_row + chroma_x);
}

// The BT.601 body, vectorised. Byte-for-byte the BT.601 arm of writeRowsScalar() above; see the file header for
// why that identity is the justification and why this is written portably rather than in wasm's own intrinsics.
//
// Two steps of the arithmetic are forced rather than chosen, and both are where a rewrite would go wrong:
//   * `v_pack_u` is the SATURATING unsigned narrow, i.e. exactly clampToByte, applied at exactly the point the
//     scalar body applies it -- after the chroma offset is added and never to the luma ramp alone (see
//     YuvToRgbTables::luma for what clamping it early would cost);
//   * the two G offsets are floored SEPARATELY in the table (bt601Tables() measured that as the difference on
//     32157 of the 65536 (U, V) pairs) and are only SUMMED here, in int16, after both lookups. Nothing is
//     re-floored.
inline void writeBt601RowsSimd(const YuvToRgbTables &tables, const PlanarLayout &layout, int width, int height,
                               cv::Mat &bgr) {
    const int chroma_width = layout.chroma_width;
    // The three per-chroma-column offsets a row PAIR shares, materialised once per chroma row -- once per two
    // output rows, over half the columns, a quarter of the per-pixel work the scalar body does. Padded by
    // one vector so that the last main-loop step's 8-lane loads stay in bounds without a case analysis on how
    // chroma_width rounded; those padding lanes only ever feed pixels beyond the 16 the step stores, and the
    // build below never writes into them, so they stay the zeros this line puts there.
    const size_t scratch_size = static_cast<size_t>(chroma_width) + kSimdChromaLanesPerStep;
    std::vector<int16_t> offset_b(scratch_size, 0);
    std::vector<int16_t> offset_g(scratch_size, 0);
    std::vector<int16_t> offset_r(scratch_size, 0);
    int filled_chroma_row = -1;
    for (int y = 0; y < height; ++y) {
        const int chroma_y = y / 2;
        if (chroma_y != filled_chroma_row) {
            filled_chroma_row = chroma_y;
            const size_t chroma_row = static_cast<size_t>(chroma_y) * layout.chroma_stride;
            const uint8_t *u_row = layout.u_plane + chroma_row;
            const uint8_t *v_row = layout.v_plane + chroma_row;
            int chroma_x = 0;
            for (; chroma_x + kSimdChromaColumnsPerBuildStep <= chroma_width;
                 chroma_x += kSimdChromaColumnsPerBuildStep) {
                cv::v_uint8x16 u_bytes;
                cv::v_uint8x16 v_bytes;
                loadChromaColumns(layout, u_row, v_row, chroma_x, u_bytes, v_bytes);
                cv::v_uint16x8 u_lo;
                cv::v_uint16x8 u_hi;
                cv::v_uint16x8 v_lo;
                cv::v_uint16x8 v_hi;
                cv::v_expand(u_bytes, u_lo, u_hi);
                cv::v_expand(v_bytes, v_lo, v_hi);
                const size_t at = static_cast<size_t>(chroma_x);
                const size_t half = static_cast<size_t>(kSimdChromaLanesPerStep);
                writeChromaOffsets(u_lo, v_lo, offset_b.data() + at, offset_g.data() + at,
                                   offset_r.data() + at);
                writeChromaOffsets(u_hi, v_hi, offset_b.data() + at + half, offset_g.data() + at + half,
                                   offset_r.data() + at + half);
            }
            // The tail -- and every chroma row narrower than one step -- through the TABLE, which is the arm
            // the vector code above has to agree with and the same one writeRowsScalar() reads. Both arms fill
            // ONE scratch row, so the pixel loop and its own tail cannot see the seam; what would make a row
            // disagree with itself is the two arms computing different numbers, which is what the whole-domain
            // equivalence test in test/cv/test_decoded_frame_to_bgr.cpp exists to refuse.
            for (; chroma_x < chroma_width; ++chroma_x) {
                const int u = u_row[chroma_x * layout.chroma_step];
                const int v = v_row[chroma_x * layout.chroma_step];
                offset_b[static_cast<size_t>(chroma_x)] = static_cast<int16_t>(tables.u_to_b[u]);
                offset_g[static_cast<size_t>(chroma_x)] =
                    static_cast<int16_t>(tables.u_to_g[u] + tables.v_to_g[v]);
                offset_r[static_cast<size_t>(chroma_x)] = static_cast<int16_t>(tables.v_to_r[v]);
            }
        }
        const uint8_t *y_row = layout.y_plane + static_cast<size_t>(y) * static_cast<size_t>(width);
        uchar *out = bgr.ptr<uchar>(y);
        int x = 0;
        for (; x + kSimdPixelsPerStep <= width; x += kSimdPixelsPerStep) {
            const cv::v_uint8x16 luma_bytes = cv::v_load(y_row + x);
            cv::v_uint16x8 luma_lo;
            cv::v_uint16x8 luma_hi;
            cv::v_expand(luma_bytes, luma_lo, luma_hi);
            const cv::v_int16x8 ramp_lo = bt601LumaRamp(cv::v_reinterpret_as_s16(luma_lo));
            const cv::v_int16x8 ramp_hi = bt601LumaRamp(cv::v_reinterpret_as_s16(luma_hi));
            // v_zip(c, c) duplicates each 16-bit offset into the two pixels that share its chroma column, which
            // is the nearest-neighbour chroma upsampling the scalar body's `x / 2` performs.
            const int16_t *chroma_at = nullptr;
            cv::v_int16x8 b_lo;
            cv::v_int16x8 b_hi;
            cv::v_int16x8 g_lo;
            cv::v_int16x8 g_hi;
            cv::v_int16x8 r_lo;
            cv::v_int16x8 r_hi;
            chroma_at = offset_b.data() + (x / 2);
            cv::v_zip(cv::v_load(chroma_at), cv::v_load(chroma_at), b_lo, b_hi);
            chroma_at = offset_g.data() + (x / 2);
            cv::v_zip(cv::v_load(chroma_at), cv::v_load(chroma_at), g_lo, g_hi);
            chroma_at = offset_r.data() + (x / 2);
            cv::v_zip(cv::v_load(chroma_at), cv::v_load(chroma_at), r_lo, r_hi);
            const cv::v_uint8x16 b =
                cv::v_pack_u(cv::v_add_wrap(ramp_lo, b_lo), cv::v_add_wrap(ramp_hi, b_hi));
            const cv::v_uint8x16 g =
                cv::v_pack_u(cv::v_add_wrap(ramp_lo, g_lo), cv::v_add_wrap(ramp_hi, g_hi));
            const cv::v_uint8x16 r =
                cv::v_pack_u(cv::v_add_wrap(ramp_lo, r_lo), cv::v_add_wrap(ramp_hi, r_hi));
            cv::v_store_interleave(out + 3 * x, b, g, r);
        }
        // The tail -- and every width below one vector -- through the scalar arithmetic, table lookup included.
        for (; x < width; ++x) {
            const int luma = tables.luma[y_row[x]];
            out[3 * x + 0] = clampToByte(luma + offset_b[static_cast<size_t>(x / 2)]);
            out[3 * x + 1] = clampToByte(luma + offset_g[static_cast<size_t>(x / 2)]);
            out[3 * x + 2] = clampToByte(luma + offset_r[static_cast<size_t>(x / 2)]);
        }
    }
}

}  // namespace detail

// Converts a TIGHTLY PACKED decoded frame into a freshly allocated BGR CV_8UC3 image. Returns an empty Mat
// when the buffer does not hold exactly one frame of that format and size.
//
// Freshly allocated on purpose: the caller hands the result straight to a Frame, which forwards it without
// cloning, so the buffer has to outlive the call (cv/video_loader.h's clone exists for the opposite reason --
// cv::VideoCapture reuses its Mat).
inline cv::Mat decodedFrameToBgr(const uint8_t *data, size_t size, DecodedFrameFormat format, int width,
                                 int height, ColorMatrix matrix = ColorMatrix::Bt601) {
    if (data == nullptr || size != decodedFrameByteCount(format, width, height)) {
        return {};
    }
    if (format == DecodedFrameFormat::Rgba) {
        // A REORDER, NOT A CONVERSION. The frame was decoded as RGB, so no colour matrix was ever applied to
        // it on either platform and there is nothing here for the two producers to disagree about.
        const cv::Mat rgba(height, width, CV_8UC4, const_cast<uint8_t *>(data));
        cv::Mat bgr;
        cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
        return bgr;
    }
    const detail::PlanarLayout layout = detail::planarLayout(data, format, width, height);
    cv::Mat bgr(height, width, CV_8UC3);
    // WHICH BRANCH IS VECTORISED, stated here because "it is fast" is not a property a reader can see: BT.601
    // over the two 4:2:0 layouts, and nothing else. RGBA returned above is a channel reorder with no matrix,
    // and BT.709 is the reference matrix nothing that ships selects; each would be a separate proof obligation
    // the size of the one BT.601 carries, bought for a path that either costs nothing or runs in a test. Both
    // therefore keep the scalar arithmetic.
    if (matrix == ColorMatrix::Bt709) {
        detail::writeRowsScalar(detail::bt601Tables(), detail::bt709Tables(), true, layout, width, height, bgr);
        return bgr;
    }
    detail::writeBt601RowsSimd(detail::bt601Tables(), layout, width, height, bgr);
    return bgr;
}

}  // namespace uma::color
