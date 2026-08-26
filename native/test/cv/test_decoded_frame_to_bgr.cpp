// Tests for the I420 -> BGR conversion the web offline producer feeds the pipeline through
// (native/wasm/wasm_api.cpp's pushOfflineFrame).
//
// WHAT IS ACTUALLY BEING PINNED. Not "a BT.601 conversion" -- there are several, and they disagree. This one
// has to be the conversion cv::VideoCapture's FFmpeg backend applies for the CLI's offline producer, because
// .claude/rules/platform-parity.md requires the two offline producers to agree on pixel VALUES and because
// every constant in cv/detail_crop_calibrator.h is calibrated against those exact pixels. The vectors below
// were read off swscale's own output for a synthetic frame enumerating all 2^24 (Y, U, V) triples, and the
// full sweep matched on all 50,331,648 bytes; what is kept here is the subset that a change to any one
// coefficient, or to where a value is floored or clamped, would move.
//
// ONE UNIT OF THAT AGREEMENT HAS SINCE BEEN SPENT ON PURPOSE. The limited-range luma ramp is coarsened (see
// kLumaRampCoarse* in the header), so six of the fourteen vectors below no longer equal swscale's byte -- each
// by exactly 1, each with swscale's own value named in a trailing comment. The bound itself is asserted over
// the whole luma range by "the coarse luma ramp stays within one unit of the exact expansion" below; these
// vectors are what makes the error visible at the pixels that were chosen for mattering.
//
// The two header-green cases are the defect this conversion exists for: measured at the probe
// isHeaderGreen gates on, the landscape reference clip reads G = 194 and the portrait one G = 199 through
// cv::VideoCapture, while the same frames taken out of WebCodecs as RGBA read 176 and 182 -- one side of
// `g >= 180` and the other, i.e. an import that latched no pane and produced no records.

// The second half of this file is the equivalence proof for the vectorised BT.601 body: it is what makes the
// optimisation safe, and it is a claim about the function's WHOLE domain rather than about a suite staying
// green. See "the vectorised body" section below.

#include <doctest/doctest.h>
#include <nameof/nameof.hpp>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <string>
#include <vector>

#include "cv/decoded_frame_to_bgr.h"

namespace uma::color {
namespace {

// A 2x2 frame of one uniform colour: the smallest buffer that exercises a whole chroma sample.
std::vector<uint8_t> uniformI420(int y, int u, int v) {
    return {static_cast<uint8_t>(y), static_cast<uint8_t>(y), static_cast<uint8_t>(y), static_cast<uint8_t>(y),
            static_cast<uint8_t>(u), static_cast<uint8_t>(v)};
}

struct Vector {
    int y;
    int u;
    int v;
    int b;
    int g;
    int r;
};

TEST_CASE("the conversion reproduces cv::VideoCapture to within one unit") {
    // Each vector is what THIS conversion produces; the trailing comment names swscale's own byte wherever the
    // coarsened luma ramp (see kLumaRampCoarse* in the header) moves it, so the size and the direction of the
    // deliberate error are visible per case rather than asserted in the abstract. Six of the fourteen move,
    // every one of them by exactly 1, and the two that matter most -- the header-green probes isHeaderGreen
    // gates on -- do not move at all.
    const Vector vectors[] = {
        // The header green each reference clip is measured at, and the whole reason this path exists.
        // Unmoved: `g >= 180` and `b <= 70` are decided on exactly these bytes.
        {143, 60, 102, 9, 194, 105},
        {149, 57, 105, 10, 199, 117},
        // The limited-range anchors: 16 is black, 235 is white, and 128 is the chroma-neutral midpoint.
        // Black stays exactly black; white lands one short of saturation.
        {16, 128, 128, 0, 0, 0},
        {128, 128, 128, 130, 130, 130},
        {235, 128, 128, 254, 254, 254},  // swscale: 255, 255, 255
        // Below black and above white, where the luma expansion leaves [0, 255] and must NOT be clamped
        // before the chroma offset is added.
        {0, 0, 0, 0, 136, 0},  // swscale G: 135
        {8, 0, 5, 0, 140, 0},  // swscale G: 139
        {255, 255, 255, 255, 123, 255},  // swscale G: 124
        {250, 255, 250, 255, 121, 255},  // swscale G: 122
        // The two triples that tell the U -> G coefficient apart from the canonical 25675, which reads one
        // unit high on both of them. Unmoved, so they still tell the two coefficients apart.
        {128, 31, 128, 0, 167, 130},
        {128, 225, 128, 255, 92, 130},
        // Ordinary mixed colours, well inside the range on every channel.
        {20, 200, 40, 150, 47, 0},  // swscale: 149, 46, 0
        {120, 90, 200, 44, 76, 235},
        {200, 60, 180, 75, 196, 255},  // swscale: 76, 197, 255
    };
    for (const auto &expected : vectors) {
        CAPTURE(expected.y);
        CAPTURE(expected.u);
        CAPTURE(expected.v);
        const auto buffer = uniformI420(expected.y, expected.u, expected.v);
        const cv::Mat bgr = decodedFrameToBgr(buffer.data(), buffer.size(), DecodedFrameFormat::I420, 2, 2);
        REQUIRE(!bgr.empty());
        const cv::Vec3b pixel = bgr.at<cv::Vec3b>(0, 0);
        CHECK(static_cast<int>(pixel[0]) == expected.b);
        CHECK(static_cast<int>(pixel[1]) == expected.g);
        CHECK(static_cast<int>(pixel[2]) == expected.r);
    }
}

TEST_CASE("each chroma sample covers its own 2x2 luma block") {
    // 4x2: two chroma samples side by side, so a row/column mix-up in the plane arithmetic shows up as the
    // two halves swapping.
    std::vector<uint8_t> buffer = {
        // Y
        16, 16, 235, 235,  //
        16, 16, 235, 235,  //
        // U, then V
        31, 225,  //
        128, 128,  //
    };
    const cv::Mat bgr = decodedFrameToBgr(buffer.data(), buffer.size(), DecodedFrameFormat::I420, 4, 2);
    REQUIRE(!bgr.empty());
    REQUIRE(bgr.type() == CV_8UC3);
    for (int y = 0; y < 2; ++y) {
        // Left block: Y = 16 (black) with U = 31, which lifts G well above the luma.
        CHECK(static_cast<int>(bgr.at<cv::Vec3b>(y, 0)[1]) == 37);
        CHECK(static_cast<int>(bgr.at<cv::Vec3b>(y, 1)[1]) == 37);
        // Right block: Y = 235 (white) with U = 225, which pulls G back down. (swscale reads 217; the coarse
        // luma ramp is one short at Y = 235.)
        CHECK(static_cast<int>(bgr.at<cv::Vec3b>(y, 2)[1]) == 216);
        CHECK(static_cast<int>(bgr.at<cv::Vec3b>(y, 3)[1]) == 216);
    }
}

TEST_CASE("an odd visible rectangle keeps its trailing row and column") {
    // A visible rect may be odd on either axis; the chroma planes are then rounded UP, and the last row and
    // column read the chroma sample they share with their even neighbour.
    //
    // THE FRAME IS NON-UNIFORM ON PURPOSE. This case used to fill every plane with 128 and check one green
    // channel, which cannot tell the claim above from its negation: with Y = U = V everywhere, every pixel
    // converts to the same colour whichever chroma sample it reaches, so an implementation that indexes the
    // trailing row and column wrongly passed it. Here every luma sample and all four chroma blocks differ,
    // and the expectation is taken from the EVEN frame built on the same planes -- 3x3 has to be 4x4
    // truncated, which is what "shares the sample with its even neighbour" means, stated without restating
    // the conversion arithmetic (the coarse luma ramp) that the surrounding cases already pin.
    CHECK(decodedFrameByteCount(DecodedFrameFormat::I420, 3, 3) == 9 + 2 * 4);  // ceil, not floor
    CHECK(decodedFrameByteCount(DecodedFrameFormat::I420, 4, 4) == 16 + 2 * 4);  // the same chroma planes

    // One value per luma sample of the 4x4, addressed the same way by both frames, and one per 2x2 block.
    const auto luma = [](int x, int y) { return static_cast<uint8_t>(16 + 14 * (y * 4 + x)); };
    const std::vector<uint8_t> chroma_u = {40, 200, 90, 150};
    const std::vector<uint8_t> chroma_v = {210, 50, 160, 100};

    const auto build = [&](int extent) {
        std::vector<uint8_t> buffer;
        for (int y = 0; y < extent; ++y) {
            for (int x = 0; x < extent; ++x) {
                buffer.push_back(luma(x, y));
            }
        }
        buffer.insert(buffer.end(), chroma_u.begin(), chroma_u.end());
        buffer.insert(buffer.end(), chroma_v.begin(), chroma_v.end());
        return buffer;
    };
    const std::vector<uint8_t> odd = build(3);
    const std::vector<uint8_t> even = build(4);
    REQUIRE(odd.size() == decodedFrameByteCount(DecodedFrameFormat::I420, 3, 3));
    REQUIRE(even.size() == decodedFrameByteCount(DecodedFrameFormat::I420, 4, 4));

    const cv::Mat bgr = decodedFrameToBgr(odd.data(), odd.size(), DecodedFrameFormat::I420, 3, 3);
    const cv::Mat reference = decodedFrameToBgr(even.data(), even.size(), DecodedFrameFormat::I420, 4, 4);
    REQUIRE(!bgr.empty());
    REQUIRE(!reference.empty());
    CHECK(bgr.cols == 3);
    CHECK(bgr.rows == 3);

    // The four blocks have to produce four different colours, or the comparison below would prove nothing --
    // exactly the hole the uniform buffer left. Corners of the reference, one per chroma block.
    const std::vector<cv::Vec3b> blocks{reference.at<cv::Vec3b>(0, 0), reference.at<cv::Vec3b>(0, 2),
                                        reference.at<cv::Vec3b>(2, 0), reference.at<cv::Vec3b>(2, 2)};
    for (size_t a = 0; a < blocks.size(); ++a) {
        for (size_t b = a + 1; b < blocks.size(); ++b) {
            CAPTURE(a);
            CAPTURE(b);
            CHECK(blocks[a] != blocks[b]);
        }
    }

    const cv::Mat truncated = reference(cv::Rect(0, 0, 3, 3)).clone();
    CHECK(cv::countNonZero(bgr.reshape(1) != truncated.reshape(1)) == 0);
}

TEST_CASE("NV12 reads the same chroma samples out of one interleaved plane") {
    // The SAME frame in the other 4:2:0 layout a decoder may hand over -- a hardware decode path routinely
    // produces this one, and it cannot be asked to produce I420 instead (VideoFrame.copyTo converts only to
    // the RGB formats). So it has to convert to the same pixels, not merely to plausible ones.
    const std::vector<uint8_t> i420 = {16, 16, 235, 235, 16, 16, 235, 235, 31, 225, 128, 128};
    const std::vector<uint8_t> nv12 = {16, 16, 235, 235, 16, 16, 235, 235, 31, 128, 225, 128};
    const cv::Mat from_i420 = decodedFrameToBgr(i420.data(), i420.size(), DecodedFrameFormat::I420, 4, 2);
    const cv::Mat from_nv12 = decodedFrameToBgr(nv12.data(), nv12.size(), DecodedFrameFormat::Nv12, 4, 2);
    REQUIRE(!from_i420.empty());
    REQUIRE(!from_nv12.empty());
    CHECK(cv::countNonZero(from_i420.reshape(1) != from_nv12.reshape(1)) == 0);
    CHECK(static_cast<int>(from_nv12.at<cv::Vec3b>(0, 0)[1]) == 37);
    CHECK(static_cast<int>(from_nv12.at<cv::Vec3b>(1, 3)[1]) == 216);
}

TEST_CASE("an RGBA frame is reordered and not colour-converted") {
    // A frame the decoder produced AS RGB never went through a colour matrix, so there is nothing to
    // reproduce -- and nothing that may be invented. Every channel must survive exactly.
    const std::vector<uint8_t> rgba = {10, 20, 30, 255, 200, 100, 50, 0};
    const cv::Mat bgr = decodedFrameToBgr(rgba.data(), rgba.size(), DecodedFrameFormat::Rgba, 2, 1);
    REQUIRE(!bgr.empty());
    CHECK(bgr.at<cv::Vec3b>(0, 0) == cv::Vec3b(30, 20, 10));
    CHECK(bgr.at<cv::Vec3b>(0, 1) == cv::Vec3b(50, 100, 200));
}

TEST_CASE("a format name this build does not know is refused rather than defaulted") {
    // THE FORMAT SET IS DISCOVERED, NOT LISTED, for the reason test_frame_shaper.cpp and
    // test_video_frame_grabber.cpp discover theirs: three literals typed out beside a three-value enum say
    // nothing about a FOURTH format added without an `if` in parseDecodedFrameFormat(). That omission is
    // precisely the one the enum's own comment says the string spelling exists to prevent -- a format this
    // build does not know must be REFUSED, and a format it does know must be reachable -- and it would have
    // left this case green. The compiler cannot see it either: parseDecodedFrameFormat is a chain of string
    // comparisons, not a switch, so there is no enumerator for a warning to miss.
    //
    // THE WIRE NAME IS DERIVED, not typed: the enum comment pins the spelling to WebCodecs, whose format
    // strings are the upper-case form of these identifiers (I420 / NV12 / RGBA). So uppercasing what nameof
    // reports IS the wire name, and a new enumerator brings its own expected name with it. If a future
    // format is ever spelled some other way, this case goes red and says so, which is the right outcome for
    // a break in the convention the header states.
    std::vector<DecodedFrameFormat> formats;
    for (int value = 0; value <= 64; ++value) {
        const auto format = static_cast<DecodedFrameFormat>(value);
        if (!nameof::nameof_enum(format).empty()) {
            formats.push_back(format);
        }
    }
    REQUIRE(formats.size() >= 3);  // the three the header documents; more is fine, fewer means the scan broke

    for (const auto format : formats) {
        const auto identifier = std::string(nameof::nameof_enum(format));
        CAPTURE(identifier);
        std::string wire_name = identifier;
        std::transform(wire_name.begin(), wire_name.end(), wire_name.begin(), [](const unsigned char c) {
            return static_cast<char>(std::toupper(c));
        });
        CAPTURE(wire_name);
        // A format the enum carries but the parser does not name cannot be asked for at all -- the offline
        // producer that hands over such a frame is refused as if this build did not support the format.
        // CHECK, not REQUIRE: a REQUIRE would abort the case at the FIRST unnamed format, and if a change
        // adds two, the report should name both.
        const auto parsed = parseDecodedFrameFormat(wire_name);
        CHECK(parsed.has_value());
        if (parsed.has_value()) {
            CHECK(parsed.value() == format);
        }
        // ... and the match is case-SENSITIVE, so the wire spelling is the only one that gets in. Derived
        // the same way, so this too follows a format that is added later.
        std::string folded = identifier;
        std::transform(folded.begin(), folded.end(), folded.begin(), [](const unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });
        CHECK(folded != wire_name);  // every WebCodecs name carries a letter; a scan that lost it is a bug
        if (folded != wire_name) {
            CHECK(!parseDecodedFrameFormat(folded).has_value());
        }
    }

    // Negative space, stated for names no enumerator can produce: a WebCodecs format this build has not
    // implemented, a case-folded spelling of one it has, and the empty string.
    CHECK(!parseDecodedFrameFormat("I422").has_value());
    CHECK(!parseDecodedFrameFormat("i420").has_value());
    CHECK(!parseDecodedFrameFormat("").has_value());
}

// The BT.709 reference used by `video --color_matrix bt709` and test/integration/run_dual_decode.py.
//
// WHY THIS TEST IS NOT OPTIONAL. A dual-decode equivalence test can be written, run, and even made to fail
// with a BT.709 table that is secretly a copy of the BT.601 one -- nothing downstream would notice, and the
// measurement would be worthless. So the table is pinned against numbers that were MEASURED OUT OF A
// BROWSER, not derived from the same arithmetic it is being checked with: the two header-green probes at the
// top of this file read G = 194 / 199 through cv::VideoCapture and G = 176 / 182 out of WebCodecs, and only
// a real BT.709 conversion lands on the second pair.
TEST_CASE("the bt709 reference reproduces what a browser decodes") {
    struct Case {
        int y;
        int u;
        int v;
        int bt601_g;  // what cv::VideoCapture reads
        int bt709_g;  // what the same frame reads out of WebCodecs
    };
    // The landscape clip's probe, then the portrait one's. 194 sits above `isHeaderGreen`'s g >= 180 and 176
    // below it -- the import that latched no pane and produced no records -- while 199 and 182 both pass,
    // with a margin of 2.
    const Case cases[] = {
        {143, 60, 102, 194, 176},
        {149, 57, 105, 199, 182},
    };
    for (const auto &expected : cases) {
        CAPTURE(expected.y);
        const auto buffer = uniformI420(expected.y, expected.u, expected.v);
        const auto i420 = DecodedFrameFormat::I420;
        const cv::Mat bt601 = decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, 2, ColorMatrix::Bt601);
        const cv::Mat bt709 = decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, 2, ColorMatrix::Bt709);
        REQUIRE(!bt601.empty());
        REQUIRE(!bt709.empty());
        CHECK(static_cast<int>(bt601.at<cv::Vec3b>(0, 0)[1]) == expected.bt601_g);
        CHECK(static_cast<int>(bt709.at<cv::Vec3b>(0, 0)[1]) == expected.bt709_g);
    }
}

TEST_CASE("bt601 stays the default and the two matrices really differ") {
    const auto buffer = uniformI420(143, 60, 102);
    const auto i420 = DecodedFrameFormat::I420;
    // Omitting the matrix must not change the shipping conversion by one byte.
    const cv::Mat implicit = decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, 2);
    const cv::Mat explicit_601 = decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, 2, ColorMatrix::Bt601);
    const cv::Mat bt709 = decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, 2, ColorMatrix::Bt709);
    REQUIRE(!implicit.empty());
    CHECK(implicit.at<cv::Vec3b>(0, 0) == explicit_601.at<cv::Vec3b>(0, 0));
    // Every channel moves, so a table accidentally left equal to BT.601 fails here rather than passing
    // quietly through a test that only looks at G.
    CHECK(bt709.at<cv::Vec3b>(0, 0)[0] != explicit_601.at<cv::Vec3b>(0, 0)[0]);
    CHECK(bt709.at<cv::Vec3b>(0, 0)[1] != explicit_601.at<cv::Vec3b>(0, 0)[1]);
    CHECK(bt709.at<cv::Vec3b>(0, 0)[2] != explicit_601.at<cv::Vec3b>(0, 0)[2]);
}

TEST_CASE("the two matrices agree on chroma-neutral pixels except where their rounding differs") {
    struct Case {
        int y;
        int bt601_g;
        int bt709_g;
    };
    // U = V = 128 removes the matrix from the arithmetic entirely, so only the luma ramp is left, and on a
    // grey pixel this case is therefore a direct read of the two ramps against each other. BT.709's is the
    // browser's 16.16 approximation of 255/219; BT.601's is the coarsened one (kLumaRampCoarse* in the
    // header), so where they now differ is where the coarsening bites -- Y = 200 -- and no longer at Y = 235,
    // where the coarse ramp happens to fall on the browser's own value. Both stay within one unit of the
    // exact expansion, which is what the ramp-bound case below pins over the whole range rather than at four
    // samples.
    const Case cases[] = {{16, 0, 0}, {128, 130, 130}, {200, 213, 214}, {235, 254, 254}};
    for (const auto &expected : cases) {
        CAPTURE(expected.y);
        const auto buffer = uniformI420(expected.y, 128, 128);
        const auto i420 = DecodedFrameFormat::I420;
        const cv::Mat bt601 = decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, 2, ColorMatrix::Bt601);
        const cv::Mat bt709 = decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, 2, ColorMatrix::Bt709);
        CHECK(static_cast<int>(bt601.at<cv::Vec3b>(0, 0)[1]) == expected.bt601_g);
        CHECK(static_cast<int>(bt709.at<cv::Vec3b>(0, 0)[1]) == expected.bt709_g);
    }
}

// THE BOUND ON THE DELIBERATE ERROR, over the whole luma range rather than at the samples above.
//
// The BT.601 luma ramp is not floor((Y - 16) * 255 / 219) any more; it is the cheaper form in the header, and
// the only thing standing between "cheaper" and "wrong" is a stated, checked bound. So the exact expansion is
// recomputed here from its definition -- NOT from the table under test -- and every one of the 256 luma values
// is compared against it. This is the assertion the header's prose points at; the size of the error is what
// downstream tolerance is judged against, and a change that widened it would otherwise be invisible until a
// recognition threshold moved.
TEST_CASE("the coarse luma ramp stays within one unit of the exact expansion") {
    int moved = 0;
    for (int y = 0; y < 256; ++y) {
        CAPTURE(y);
        const int exact = detail::floorDiv(static_cast<int64_t>(y - 16) * 255, 219);
        const int coarse = detail::bt601LumaRampScalar(y);
        // The table the scalar body reads and the function the vector kernel mirrors must be one function.
        CHECK(detail::bt601Tables().luma[static_cast<size_t>(y)] == coarse);
        const int error = coarse - exact;
        CHECK(error >= -1);
        CHECK(error <= 1);
        moved += error == 0 ? 0 : 1;
        // The intermediate the vector arm computes in int16 lanes with wrapping adds and multiplies. If this
        // ever left the range, v_mul_wrap / v_add_wrap would wrap silently and the two arms would part company
        // only on the luma values nobody sampled.
        const int intermediate = (y - 16) * detail::kLumaRampCoarseNumerator + detail::kLumaRampCoarseBias;
        CHECK(intermediate >= -32768);
        CHECK(intermediate <= 32767);
        if (y > 0) {
            // Monotone: a ramp that folded back would map two different lumas onto one output byte.
            CHECK(coarse >= detail::bt601LumaRampScalar(y - 1));
        }
    }
    // Black is the one anchor that has to be exact -- every "is this pixel dark" rule downstream reads it.
    CHECK(detail::bt601LumaRampScalar(16) == 0);
    // Pinned rather than merely bounded, so that swapping the constants for another within-1 triple is a
    // visible change and not a silent one.
    CHECK(moved == 134);
}

TEST_CASE("a buffer that is not exactly one frame is refused") {
    const auto buffer = uniformI420(128, 128, 128);
    const auto i420 = DecodedFrameFormat::I420;
    CHECK(decodedFrameToBgr(buffer.data(), buffer.size() - 1, i420, 2, 2).empty());
    CHECK(decodedFrameToBgr(buffer.data(), buffer.size() + 1, i420, 2, 2).empty());
    CHECK(decodedFrameToBgr(nullptr, buffer.size(), i420, 2, 2).empty());
    CHECK(decodedFrameToBgr(buffer.data(), buffer.size(), i420, 0, 2).empty());
    CHECK(decodedFrameToBgr(buffer.data(), buffer.size(), i420, 2, -2).empty());
    // The same buffer is the wrong length for a frame of that size in another format, which is what keeps a
    // caller from naming one format and copying another.
    CHECK(decodedFrameToBgr(buffer.data(), buffer.size(), DecodedFrameFormat::Rgba, 2, 2).empty());
}

// ---- the plane layout a caller is held to ------------------------------------------------------------------
//
// tightlyPackedLayout() exists so that a caller which was HANDED a layout by its decoder (VideoFrame.copyTo
// resolves to one) can be refused when that layout is not the one this conversion reads. The cases below pin
// the three things that could make the check defend the wrong thing: the numbers themselves, their agreement
// with the plane arithmetic the conversion actually walks, and the existence of a wrong layout that the byte
// count alone cannot see.

TEST_CASE("the tightly packed layout names the offsets and strides the conversion reads") {
    // Written out as literals rather than recomputed from the same helpers the implementation uses: a test
    // that derives its expectation the way the code does would agree with any consistent mistake.
    const auto rgba = tightlyPackedLayout(DecodedFrameFormat::Rgba, 4, 3);
    REQUIRE(rgba.size() == 1);
    CHECK(rgba[0] == PlanePlacement{0, 16});

    // 4x2 I420: 8 luma bytes, then a 2x1 Cb plane, then a 2x1 Cr plane.
    const auto i420 = tightlyPackedLayout(DecodedFrameFormat::I420, 4, 2);
    REQUIRE(i420.size() == 3);
    CHECK(i420[0] == PlanePlacement{0, 4});
    CHECK(i420[1] == PlanePlacement{8, 2});
    CHECK(i420[2] == PlanePlacement{10, 2});

    // The same frame as NV12: one chroma plane, rows twice as wide, and no third plane at all.
    const auto nv12 = tightlyPackedLayout(DecodedFrameFormat::Nv12, 4, 2);
    REQUIRE(nv12.size() == 2);
    CHECK(nv12[0] == PlanePlacement{0, 4});
    CHECK(nv12[1] == PlanePlacement{8, 4});

    // An odd extent rounds the chroma plane UP on both axes, the same way the conversion does.
    const auto odd = tightlyPackedLayout(DecodedFrameFormat::I420, 3, 3);
    REQUIRE(odd.size() == 3);
    CHECK(odd[0] == PlanePlacement{0, 3});
    CHECK(odd[1] == PlanePlacement{9, 2});
    CHECK(odd[2] == PlanePlacement{13, 2});

    // A size that cannot describe a frame yields no layout, so a caller cannot be told where the planes of a
    // frame decodedFrameToBgr() would refuse begin.
    CHECK(tightlyPackedLayout(DecodedFrameFormat::I420, 0, 2).empty());
    CHECK(tightlyPackedLayout(DecodedFrameFormat::I420, 2, -1).empty());
}

TEST_CASE("the published layout is the one the conversion actually walks") {
    // TWO DESCRIPTIONS OF ONE BUFFER. tightlyPackedLayout() is what a caller is compared against;
    // detail::planarLayout() is what the conversion reads. If they drifted apart, the check would happily
    // refuse layouts that were right and accept ones that were wrong, and every other case in this file would
    // still pass. Bound here rather than trusted.
    const std::vector<uint8_t> data(4096, 0);
    const int geometries[][2] = {{4, 2}, {3, 3}, {17, 9}, {32, 16}, {1, 1}};
    for (const auto &geometry : geometries) {
        const int width = geometry[0];
        const int height = geometry[1];
        for (const auto format : {DecodedFrameFormat::I420, DecodedFrameFormat::Nv12}) {
            CAPTURE(width);
            CAPTURE(height);
            const auto published = tightlyPackedLayout(format, width, height);
            const auto walked = detail::planarLayout(data.data(), format, width, height);
            REQUIRE(published.size() >= 2);
            CHECK(published[0].offset == static_cast<size_t>(walked.y_plane - data.data()));
            CHECK(published[0].stride == static_cast<size_t>(width));
            CHECK(published[1].offset == static_cast<size_t>(walked.u_plane - data.data()));
            CHECK(published[1].stride == walked.chroma_stride);
            if (format == DecodedFrameFormat::I420) {
                REQUIRE(published.size() == 3);
                CHECK(published[2].offset == static_cast<size_t>(walked.v_plane - data.data()));
            } else {
                // NV12 keeps Cr inside the same plane, one byte after Cb, so there is no third offset to
                // publish and the interleaved plane's own stride already carries both components.
                CHECK(published.size() == 2);
                CHECK(walked.v_plane == walked.u_plane + 1);
            }
        }
        // The layout describes the whole buffer and nothing beyond it.
        const auto planes = tightlyPackedLayout(DecodedFrameFormat::I420, width, height);
        const size_t chroma_rows = static_cast<size_t>(chromaHeight(height));
        CHECK(planes.back().offset + planes.back().stride * chroma_rows
              == decodedFrameByteCount(DecodedFrameFormat::I420, width, height));
    }
}

TEST_CASE("a chroma plane order the byte count cannot see is a different picture") {
    // WHY THE LAYOUT IS CHECKED AT ALL, demonstrated rather than asserted. Swapping Cb and Cr is the YV12
    // ordering; it occupies EXACTLY as many bytes as I420, so no size check can refuse it, and what comes out
    // is a plausible image built out of the right bytes in the wrong places -- the failure a report of "the
    // pixels the recogniser saw" must not be able to contain.
    std::vector<uint8_t> i420 = {60, 60, 60, 60, 200, 40};
    std::vector<uint8_t> yv12 = {60, 60, 60, 60, 40, 200};
    REQUIRE(i420.size() == yv12.size());
    REQUIRE(i420.size() == decodedFrameByteCount(DecodedFrameFormat::I420, 2, 2));

    const cv::Mat correct = decodedFrameToBgr(i420.data(), i420.size(), DecodedFrameFormat::I420, 2, 2);
    const cv::Mat swapped = decodedFrameToBgr(yv12.data(), yv12.size(), DecodedFrameFormat::I420, 2, 2);
    REQUIRE_FALSE(correct.empty());
    REQUIRE_FALSE(swapped.empty());
    // Both decode; they simply disagree, which is precisely why the byte count is not a sufficient guard.
    CHECK(cv::countNonZero(cv::Mat(correct.reshape(1) != swapped.reshape(1))) > 0);

    // And the published layout is what makes the two distinguishable on the wire: the Cb plane comes before
    // the Cr plane, so a copy that reversed them does not match.
    const auto planes = tightlyPackedLayout(DecodedFrameFormat::I420, 2, 2);
    REQUIRE(planes.size() == 3);
    CHECK(planes[1].offset < planes[2].offset);
    const std::vector<PlanePlacement> reversed{planes[0], planes[2], planes[1]};
    CHECK_FALSE(std::equal(planes.begin(), planes.end(), reversed.begin()));
}

TEST_CASE("a layout that is not the one the conversion reads is refused, whatever makes it different") {
    // THE VERDICT ITSELF, and the reason it is a function in the header rather than a comparison written out
    // at each entry point. Every caller handed a layout by its decoder -- the wasm import path and the wasm
    // report path today -- asks isTightlyPackedLayout(), and nothing in this repository compiles those embind
    // exports, so this case is where "a copy laid out some other way is refused" is falsifiable at all.
    //
    // The accepted layouts are taken from tightlyPackedLayout() rather than written out again: what is under
    // test here is the VERDICT, and the numbers themselves are pinned by the literal case above. Every refused
    // layout is then derived from an accepted one by ONE difference, so a verdict that stopped looking at
    // strides, at order, or at the number of planes fails on a different line.
    for (const auto format : {DecodedFrameFormat::I420, DecodedFrameFormat::Nv12, DecodedFrameFormat::Rgba}) {
        const int geometries[][2] = {{4, 2}, {3, 3}, {1, 1}, {32, 16}};
        for (const auto &geometry : geometries) {
            const int width = geometry[0];
            const int height = geometry[1];
            CAPTURE(width);
            CAPTURE(height);
            const auto packed = tightlyPackedLayout(format, width, height);
            REQUIRE_FALSE(packed.empty());
            CHECK(isTightlyPackedLayout(format, width, height, packed));

            // A ROW PADDED OUT TO A DECODER'S ALIGNMENT. The byte count would catch this one too, but only
            // because the buffer grows; the verdict refuses it on the stride, before any buffer exists.
            auto padded = packed;
            padded[0].stride += 4;
            CHECK_FALSE(isTightlyPackedLayout(format, width, height, padded));

            // A PLANE MISSING, and -- separately -- one too many. A verdict that compared only the planes it
            // was given would accept a truncated layout for a three-plane format.
            auto dropped = packed;
            dropped.pop_back();
            CHECK_FALSE(isTightlyPackedLayout(format, width, height, dropped));
            auto extra = packed;
            extra.push_back(PlanePlacement{packed.back().offset + packed.back().stride, packed.back().stride});
            CHECK_FALSE(isTightlyPackedLayout(format, width, height, extra));

            // NOTHING AT ALL is not the layout of a frame that has one.
            CHECK_FALSE(isTightlyPackedLayout(format, width, height, {}));
        }
    }

    // THE SAME BYTES IN A DIFFERENT ORDER -- the failure no size check can see (see the case above). Cr before
    // Cb is the YV12 ordering, and it is refused here on the layout alone.
    const auto i420 = tightlyPackedLayout(DecodedFrameFormat::I420, 4, 2);
    REQUIRE(i420.size() == 3);
    CHECK_FALSE(isTightlyPackedLayout(DecodedFrameFormat::I420, 4, 2, {i420[0], i420[2], i420[1]}));

    // A LAYOUT THAT IS SOMEBODY ELSE'S. Both of these describe a real, tightly packed frame -- just not the
    // one the caller named -- so a verdict that only checked self-consistency would pass them.
    CHECK_FALSE(isTightlyPackedLayout(
        DecodedFrameFormat::I420, 4, 2, tightlyPackedLayout(DecodedFrameFormat::Nv12, 4, 2)));
    CHECK_FALSE(isTightlyPackedLayout(
        DecodedFrameFormat::I420, 4, 2, tightlyPackedLayout(DecodedFrameFormat::I420, 8, 4)));

    // A SIZE THAT CANNOT DESCRIBE A FRAME answers false for every layout, the empty one included: there is no
    // tightly packed layout to be. decodedFrameToBgr() refuses the same sizes, so a caller can never be told
    // its layout is fine and then be refused on the bytes.
    CHECK_FALSE(isTightlyPackedLayout(DecodedFrameFormat::I420, 0, 2, {}));
    CHECK_FALSE(isTightlyPackedLayout(DecodedFrameFormat::I420, 2, -1, i420));
}

}  // namespace

// ============================ the vectorised body, and why these tests exist ============================
//
// decodedFrameToBgr()'s BT.601 arm runs detail::writeBt601RowsSimd() instead of the scalar arithmetic it used
// to. THE ARGUMENT THAT NOTHING DOWNSTREAM MOVES IS NOT THAT THE GOLDEN SUITE STAYED GREEN -- it is that the
// two bodies emit the same bytes, so every calibrated constant in the recognizer is unmovable by construction,
// including on the inputs nobody has a clip of. These tests are that argument in executable form, so they have
// to be read as a proof rather than as samples:
//
//   1. THE WHOLE INPUT SPACE, not a selection. For a 4:2:0 frame every output pixel is a function of its own
//      luma byte and its chroma column's two bytes and of NOTHING else -- no neighbour, no position, no
//      accumulator -- so the domain is the triple (Y, U, V) and 2^24 is all of it.
//   2. GEOMETRY SEPARATELY, because a per-pixel proof says nothing about strides, odd extents, the trailing
//      lanes of a 16-pixel main loop, or NV12's interleave. Whole images, byte for byte.
//   3. THE COMPARATOR'S ABILITY TO FAIL, DEMONSTRATED BEFORE AGREEMENT IS CLAIMED. Two runs that both call the
//      same code would agree just as loudly, so the same comparators are handed a candidate that is one LSB
//      out on one channel and are required to catch every instance of it.
//
// WHAT THEY DO NOT ESTABLISH. They run under MSVC, where the Universal Intrinsics resolve to SSE2. The wasm
// module resolves them to SIMD128 from the same source and the static_assert(CV_SIMD128) in the header refuses
// a build where they resolved to neither, but "the same source" is not "the same instructions": this file is
// evidence for the SSE2 lowering, and for the wasm one only as far as the header's arithmetic is
// backend-independent.
namespace detail {
namespace {

// The two bodies under comparison, plus the deliberately wrong one, behind one signature so that the
// comparators cannot tell them apart and every case runs all three through identical code.
using RowWriter = void (*)(const PlanarLayout &, int, int, cv::Mat &);

void writeScalarReference(const PlanarLayout &layout, int width, int height, cv::Mat &bgr) {
    writeRowsScalar(bt601Tables(), bt709Tables(), false, layout, width, height, bgr);
}

void writeVectorised(const PlanarLayout &layout, int width, int height, cv::Mat &bgr) {
    writeBt601RowsSimd(bt601Tables(), layout, width, height, bgr);
}

// THE POSITIVE CONTROL. One LSB on one channel is the smallest observable difference the comparators must
// catch, and it is the size of error a rounding mistake in this arithmetic would actually produce; a control
// that damaged the kernel structurally (a dropped row, a mis-stride) would only prove they notice gross damage.
// Saturating, because 255 + 1 has nowhere to go -- which is why the expected mismatch count below is derived
// from the reference's own unsaturated bytes instead of being a number copied from a previous run.
void writeVectorisedOneLsbHighOnB(const PlanarLayout &layout, int width, int height, cv::Mat &bgr) {
    writeVectorised(layout, width, height, bgr);
    for (int y = 0; y < height; ++y) {
        uchar *out = bgr.ptr<uchar>(y);
        for (int x = 0; x < width; ++x) {
            out[3 * x] = static_cast<uchar>(out[3 * x] == 255 ? 255 : out[3 * x] + 1);
        }
    }
}

cv::Mat convertWith(RowWriter writer, const std::vector<uint8_t> &buffer, DecodedFrameFormat format, int width,
                    int height) {
    const PlanarLayout layout = planarLayout(buffer.data(), format, width, height);
    cv::Mat bgr(height, width, CV_8UC3);
    writer(layout, width, height, bgr);
    return bgr;
}

struct Divergence {
    long long compared = 0;
    long long mismatches = 0;
    // How many of the reference's B bytes are below 255, i.e. exactly how many bytes a saturating +1 on B is
    // able to move. The control is required to find all of them and no others.
    long long unsaturated_b = 0;
    int first_row = -1;
    int first_col = -1;
    int first_channel = -1;
    int first_reference = -1;
    int first_candidate = -1;
};

void compareImages(const cv::Mat &reference, const cv::Mat &candidate, int width, int height, Divergence &d) {
    for (int y = 0; y < height; ++y) {
        const uchar *a = reference.ptr<uchar>(y);
        const uchar *b = candidate.ptr<uchar>(y);
        for (int x = 0; x < width; ++x) {
            d.unsaturated_b += a[3 * x] == 255 ? 0 : 1;
            for (int channel = 0; channel < 3; ++channel) {
                ++d.compared;
                if (a[3 * x + channel] == b[3 * x + channel]) {
                    continue;
                }
                ++d.mismatches;
                if (d.first_row < 0) {
                    d.first_row = y;
                    d.first_col = x;
                    d.first_channel = channel;
                    d.first_reference = a[3 * x + channel];
                    d.first_candidate = b[3 * x + channel];
                }
            }
        }
    }
}

// The (Y, U, V) of the first divergence, for the failure message. Resolved from the planes rather than stored,
// so a break reports the input that caused it instead of a pixel coordinate nobody can act on.
struct Triple {
    int y = -1;
    int u = -1;
    int v = -1;
};

Triple sweepFirstTriple;

// ---- 1. every (Y, U, V) exactly once ----------------------------------------------------------------------
//
// A synthetic 4096x4096 4:2:0 frame enumerates all 2^24 triples exactly once, in sixteen 4096x256 strips so the
// buffers stay small. The chroma index c = cy * 2048 + cx runs over the frame's 2^22 chroma samples, and its
// bits are read as (V, U, k) = (c & 255, (c >> 8) & 255, (c >> 16) & 63); the four luma pixels under that
// sample take Y = 4k .. 4k+3. Each (U, V) pair therefore occurs 64 times and collects all 256 luma values
// exactly once -- which is what makes 3 * 2^24 = 50,331,648 compared bytes a proof and not a large sample.
//
// RUN FOR BOTH 4:2:0 LAYOUTS, not only I420, because the vectorised offset build takes a DIFFERENT LOAD for
// each: sixteen bytes per plane for I420, one deinterleaving load of thirty-two for NV12. While the layout
// only decided an address the two were the same code and covering one covered both; now a lane-order mistake
// would live in a path the I420 sweep never enters. The chroma samples are written through PlanarLayout, the
// same plane arithmetic the shipping code reads them with, so the enumeration cannot drift from the layout.
Divergence sweepWholeDomain(RowWriter candidate, DecodedFrameFormat format = DecodedFrameFormat::I420) {
    Divergence d;
    sweepFirstTriple = Triple{};
    constexpr int kWidth = 4096;
    constexpr int kStripHeight = 256;
    constexpr int kChromaWidth = kWidth / 2;
    constexpr int kStripChromaHeight = kStripHeight / 2;
    std::vector<uint8_t> plane(decodedFrameByteCount(format, kWidth, kStripHeight));
    const PlanarLayout layout = planarLayout(plane.data(), format, kWidth, kStripHeight);
    for (int strip = 0; strip < kWidth / kStripHeight; ++strip) {
        uint8_t *y_plane = plane.data();
        uint8_t *u_plane = const_cast<uint8_t *>(layout.u_plane);
        uint8_t *v_plane = const_cast<uint8_t *>(layout.v_plane);
        for (int cy = 0; cy < kStripChromaHeight; ++cy) {
            const long long global_cy = static_cast<long long>(strip) * kStripChromaHeight + cy;
            const size_t chroma_row = static_cast<size_t>(cy) * layout.chroma_stride;
            for (int cx = 0; cx < kChromaWidth; ++cx) {
                const long long c = global_cy * kChromaWidth + cx;
                const int u = static_cast<int>((c >> 8) & 0xFF);
                const int v = static_cast<int>(c & 0xFF);
                const int k = static_cast<int>(c >> 16) & 0x3F;
                u_plane[chroma_row + static_cast<size_t>(cx * layout.chroma_step)] = static_cast<uint8_t>(u);
                v_plane[chroma_row + static_cast<size_t>(cx * layout.chroma_step)] = static_cast<uint8_t>(v);
                for (int dy = 0; dy < 2; ++dy) {
                    for (int dx = 0; dx < 2; ++dx) {
                        y_plane[static_cast<size_t>(2 * cy + dy) * kWidth + 2 * cx + dx] =
                            static_cast<uint8_t>(4 * k + 2 * dy + dx);
                    }
                }
            }
        }
        const cv::Mat reference = convertWith(writeScalarReference, plane, format, kWidth, kStripHeight);
        const cv::Mat produced = convertWith(candidate, plane, format, kWidth, kStripHeight);
        const int already_found = d.first_row;
        compareImages(reference, produced, kWidth, kStripHeight, d);
        if (already_found < 0 && d.first_row >= 0) {
            const size_t at = static_cast<size_t>(d.first_row / 2) * layout.chroma_stride
                              + static_cast<size_t>((d.first_col / 2) * layout.chroma_step);
            sweepFirstTriple.y = y_plane[static_cast<size_t>(d.first_row) * kWidth + d.first_col];
            sweepFirstTriple.u = u_plane[at];
            sweepFirstTriple.v = v_plane[at];
        }
    }
    return d;
}

// ---- 2. whole images, at the geometries the sweep cannot speak about -------------------------------------
//
// Below one vector (1..15), exactly one (16), one-plus-tail (17), the odd/odd, odd/even and even/odd corners
// where chromaWidth/chromaHeight round up, single-row and single-column frames, the 719x523 the scraper
// actually builds, and the full decoded size -- each in both 4:2:0 layouts, filled from a fixed PRNG so a
// failure is reproducible.
unsigned int xorshift(unsigned int &state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

Divergence everyGeometry(RowWriter candidate, int &cases) {
    static const int kSizes[][2] = {{1, 1},   {1, 2},   {2, 1},    {2, 2},    {3, 3},     {4, 4},   {15, 7},
                                    {16, 16}, {17, 1},  {17, 33},  {31, 31},  {32, 32},   {33, 17}, {63, 65},
                                    {65, 63}, {127, 5}, {129, 71}, {541, 33}, {719, 523}, {1080, 2520}};
    Divergence d;
    cases = 0;
    unsigned int state = 0x2B2Bu;
    for (const auto &size : kSizes) {
        for (const auto format : {DecodedFrameFormat::I420, DecodedFrameFormat::Nv12}) {
            const int width = size[0];
            const int height = size[1];
            std::vector<uint8_t> buffer(decodedFrameByteCount(format, width, height));
            for (auto &byte : buffer) {
                byte = static_cast<uint8_t>(xorshift(state) & 0xFF);
            }
            const cv::Mat reference = convertWith(writeScalarReference, buffer, format, width, height);
            const cv::Mat produced = convertWith(candidate, buffer, format, width, height);
            ++cases;
            compareImages(reference, produced, width, height, d);
        }
    }
    return d;
}

}  // namespace

TEST_CASE("the vectorised bt601 body is byte-identical to the scalar one on the whole (Y, U, V) domain") {
    for (const auto format : {DecodedFrameFormat::I420, DecodedFrameFormat::Nv12}) {
        const bool nv12 = format == DecodedFrameFormat::Nv12;
        CAPTURE(nv12);
        const Divergence d = sweepWholeDomain(writeVectorised, format);
        CAPTURE(d.first_row);
        CAPTURE(d.first_col);
        CAPTURE(d.first_channel);
        CAPTURE(d.first_reference);
        CAPTURE(d.first_candidate);
        CAPTURE(sweepFirstTriple.y);
        CAPTURE(sweepFirstTriple.u);
        CAPTURE(sweepFirstTriple.v);
        // 3 * 2^24. If this number is not exactly this, the enumeration stopped covering the domain and the
        // "0 mismatches" below would be a statement about a subset.
        CHECK(d.compared == 50331648LL);
        CHECK(d.mismatches == 0LL);
    }
}

TEST_CASE("the vectorised bt601 body is byte-identical to the scalar one at every geometry") {
    int cases = 0;
    const Divergence d = everyGeometry(writeVectorised, cases);
    CAPTURE(d.first_row);
    CAPTURE(d.first_col);
    CAPTURE(d.first_channel);
    CAPTURE(d.first_reference);
    CAPTURE(d.first_candidate);
    CHECK(cases == 40);
    CHECK(d.compared == 18821958LL);
    CHECK(d.mismatches == 0LL);
}

// The two tests above would pass just as loudly if both sides secretly ran the same code, so this one shows
// the comparators failing first. It does not merely require SOME mismatch: it requires the exact set, every
// B byte the reference did not leave saturated and nothing else, which a comparator that skipped rows, stopped
// early or compared the wrong channel could not produce.
TEST_CASE("the equivalence comparators detect a one-LSB difference on a single channel") {
    const Divergence sweep = sweepWholeDomain(writeVectorisedOneLsbHighOnB);
    CHECK(sweep.compared == 50331648LL);
    CHECK(sweep.mismatches > 0LL);
    CHECK(sweep.mismatches == sweep.unsaturated_b);
    CHECK(sweep.first_channel == 0);
    CHECK(sweep.first_candidate == sweep.first_reference + 1);

    int cases = 0;
    const Divergence geometry = everyGeometry(writeVectorisedOneLsbHighOnB, cases);
    CHECK(cases == 40);
    CHECK(geometry.mismatches > 0LL);
    CHECK(geometry.mismatches == geometry.unsaturated_b);
    CHECK(geometry.first_channel == 0);
}

}  // namespace detail
}  // namespace uma::color
