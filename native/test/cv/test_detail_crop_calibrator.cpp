// Behavioral tests for the detail-dialog crop calibrator.
//
// The calibrator reconstructs the game's client rect from three in-frame landmarks (green header
// boundary / close-button bottom edge / 5-stat green band centre). Its contract is that it NEVER throws and
// NEVER reports an error: it runs on every frame while the dialog is closed, so every anomaly must degrade
// to a status code and "no result". The second half of the contract, and the harder one, is that it must
// never return a CONFIDENT WRONG result -- a status of Ok carrying a rect that is off by more than a pixel
// or so is worse than no result at all, because the caller has no way to tell.
//
// The real screenshots the landmark constants were measured on are not committed (they live under the
// gitignored .notes/), so these tests synthesize the dialog in code instead: makeDialog() paints the header
// bar, stat band and close button (both of its borders) at their measured normalized positions inside a
// client rect placed anywhere in a larger frame. That makes the reconstruction check exact enough to catch a
// wrong constant or a swapped axis, while the negative cases are produced by painting one landmark out or by
// handing the calibrator a deliberately mis-sized caller estimate.
//
// The residual error of a synthetic reconstruction is dominated by the whole-pixel rounding used to PAINT
// the landmarks (the real dialog is pixel-snapped the same way), so the tolerance below is 1.5 px -- the
// same order as the +-1.1 px worst case measured on real footage.

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/detail_crop_calibrator.h"
#include "cv/frame.h"

namespace uma {
namespace {

// Tolerance for a reconstructed edge, in pixels. See the file comment.
constexpr double kTolerance = 1.5;

// Normalized geometry of the synthetic dialog. The boundary/edge values are the landmarks the calibrator
// looks for; the rest only has to be plausible enough to place them.
constexpr double kHeaderTopY = 0.0400;
constexpr double kHeaderBoundaryY = 0.12907;
constexpr double kBandTopY = 0.4239;
constexpr double kBandBottomY = 0.4606;
constexpr double kBandScanTopY = 0.4266;
constexpr double kBandScanBottomY = 0.4592;
constexpr double kBandLeftX = 0.03252;
constexpr double kBandRightX = 0.96613;
constexpr double kButtonTopBorderY = 1.5883;
constexpr double kButtonBottomY = 1.69057;
constexpr double kButtonLeftX = 0.3139;
constexpr double kButtonRightX = 0.6848;

// OpenCV stores BGR, so every literal below is written as (b, g, r) of the RGB colour named in the survey.
const cv::Scalar kOutside(20, 20, 20);  // window chrome / letterbox around the client area
const cv::Scalar kCanvas(215, 231, 240);  // dialog canvas, RGB (240, 231, 215)
const cv::Scalar kHeaderGreen(8, 205, 127);  // header bar, RGB (127, 205, 8)
const cv::Scalar kBandGreen(35, 216, 122);  // 5-stat band, RGB (122, 216, 35)
const cv::Scalar kButtonWhite(252, 250, 250);  // close-button interior, RGB (250, 250, 252)
const cv::Scalar kButtonTopBorder(145, 138, 139);  // close-button TOP border, RGB (139, 138, 145)
const cv::Scalar kButtonBottomBorder(121, 98, 101);  // close-button BOTTOM border, RGB (101, 98, 121)

int scaled(double normalized, double unit) {
    return static_cast<int>(std::lround(normalized * unit));
}

// Fills the half-open rect [x0, x1) x [y0, y1), clipped to the image.
void fillRect(cv::Mat &image, int x0, int y0, int x1, int y1, const cv::Scalar &color) {
    const int left = std::max(0, x0);
    const int top = std::max(0, y0);
    const int right = std::min(image.cols, x1);
    const int bottom = std::min(image.rows, y1);
    if (right <= left || bottom <= top) {
        return;
    }
    image(cv::Rect(left, top, right - left, bottom - top)).setTo(color);
}

// A frame of `frame_size` whose game client area sits at (left, top) and is `unit` pixels wide.
cv::Mat makeDialog(const Size<int> &frame_size, int left, int top, double unit) {
    cv::Mat image(frame_size.height(), frame_size.width(), CV_8UC3, kOutside);
    const int client_right = left + scaled(1.0, unit);
    const int client_bottom = top + scaled(16.0 / 9.0, unit);
    fillRect(image, left, top, client_right, client_bottom, kCanvas);

    // Header bar: its last row is the one above the boundary, so the boundary row is the first canvas row.
    fillRect(
        image, left, top + scaled(kHeaderTopY, unit), client_right, top + scaled(kHeaderBoundaryY, unit), kHeaderGreen);

    fillRect(
        image,
        left + scaled(kBandLeftX, unit),
        top + scaled(kBandTopY, unit),
        left + scaled(kBandRightX, unit) + 1,
        top + scaled(kBandBottomY, unit) + 1,
        kBandGreen);

    // The close button, with BOTH of its borders. The top one matters: it is border-coloured too, so a scan
    // that starts above the button stops on it and silently reports the wrong landmark.
    const int button_left = left + scaled(kButtonLeftX, unit);
    const int button_right = left + scaled(kButtonRightX, unit) + 1;
    const int top_border = top + scaled(kButtonTopBorderY, unit);
    const int bottom_border = top + scaled(kButtonBottomY, unit);
    fillRect(image, button_left, top_border, button_right, top_border + 1, kButtonTopBorder);
    fillRect(image, button_left, top_border + 1, button_right, bottom_border, kButtonWhite);
    fillRect(image, button_left, bottom_border, button_right, bottom_border + 3, kButtonBottomBorder);
    return image;
}

// Repaints the stat band so it covers ONLY the rows the calibrator is supposed to average over. Any scan
// window placed a dozen rows off then reads mostly canvas and finds no edge.
void tightenBand(cv::Mat &image, int left, int top, double unit) {
    fillRect(
        image,
        left,
        top + scaled(kBandTopY, unit),
        left + scaled(1.0, unit),
        top + scaled(kBandBottomY, unit) + 1,
        kCanvas);
    fillRect(
        image,
        left + scaled(kBandLeftX, unit),
        top + scaled(kBandScanTopY, unit),
        left + scaled(kBandRightX, unit) + 1,
        top + scaled(kBandScanBottomY, unit) + 1,
        kBandGreen);
}

// Extends the header green by `rows` in a narrow strip around probe column `column`, so that one column
// reports its boundary `rows` px later than the others.
void shiftHeaderBoundary(cv::Mat &image, double column, int rows) {
    const int x = scaled(column, 540);
    fillRect(image, x - 2, scaled(kHeaderBoundaryY, 540), x + 3, scaled(kHeaderBoundaryY, 540) + rows, kHeaderGreen);
}

// Paints a stray border-coloured run `rows` px above the real bottom border, in a narrow strip around probe
// column `column`, so that one column reports its border `rows` px early.
void shiftButtonBorder(cv::Mat &image, double column, int rows) {
    const int x = scaled(column, 540);
    fillRect(
        image,
        x - 2,
        scaled(kButtonBottomY, 540) - rows,
        x + 3,
        scaled(kButtonBottomY, 540) - rows + 1,
        kButtonBottomBorder);
}

// The calibrator is always handed the caller's current estimate; the default one is what a Frame would use.
Rect<int> defaultIntersection(const cv::Mat &image) {
    return FrameAnchor::intersect(Size<int>{image.size()}).intersection();
}

DetailCropResult calibrate(const cv::Mat &image) {
    return calibrateDetailCrop(image, defaultIntersection(image));
}

TEST_CASE("calibrateDetailCrop reconstructs a dialog that already fills the frame") {
    const cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    const DetailCropResult result = calibrate(image);

    REQUIRE(result.status == DetailCropStatus::Ok);
    CHECK(std::abs(result.calibration.left) < kTolerance);
    CHECK(std::abs(result.calibration.top) < kTolerance);
    CHECK(std::abs(result.calibration.width - 540.0) < kTolerance);
    CHECK(std::abs(result.calibration.height - 960.0) < kTolerance * 16.0 / 9.0);

    const Rect<int> rect = result.calibration.toRect();
    CHECK(rect.left() == 0);
    CHECK(rect.top() == 0);
    CHECK(rect.width() == 540);
    CHECK(rect.height() == 960);
}

TEST_CASE("calibrateDetailCrop recovers a mis-anchored client rect (the browser-chrome case)") {
    // Geometry of the real Chrome window-share frame: a 30 px title bar and a 1 px border on the left.
    const cv::Mat image = makeDialog(Size<int>{666, 1214}, 1, 30, 665);

    // The default anchor is what breaks scene detection: it centres a 540:960 rect and lands 15 px high.
    const Rect<int> before = defaultIntersection(image);
    CHECK(before.top() == 15);

    const DetailCropResult result = calibrate(image);
    REQUIRE(result.status == DetailCropStatus::Ok);
    CHECK(std::abs(result.calibration.left - 1.0) < kTolerance);
    CHECK(std::abs(result.calibration.top - 30.0) < kTolerance);
    CHECK(std::abs(result.calibration.width - 665.0) < kTolerance);
}

TEST_CASE("calibrateDetailCrop places the band rows from the reconstruction, not from the caller") {
    // The band window is only ~18 rows tall, so deriving it from the caller's (top, unit) instead of the
    // solved ones would slide it off the band as soon as the caller is a little off. Here the band is
    // painted only on the rows the solved geometry selects, and the caller is handed an estimate skewed on
    // both axes; a caller-derived window would sit ~13 rows low and read mostly canvas.
    cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    tightenBand(image, 0, 0, 540);

    const Rect<int> skewed{Point<int>{0, -24}, Point<int>{536, 936}};
    const DetailCropResult result = calibrateDetailCrop(image, skewed);

    REQUIRE(result.status == DetailCropStatus::Ok);
    CHECK(std::abs(result.calibration.left) < kTolerance);
    CHECK(std::abs(result.calibration.top) < kTolerance);
    CHECK(std::abs(result.calibration.width - 540.0) < kTolerance);
}

TEST_CASE("calibrateDetailCrop tolerates a 1 px disagreement between probe columns") {
    cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    // One header column keeps its green one row longer -- the boundary is a 2-3 px soft gradient in the
    // real dialog, so a 1 px difference between columns is expected, not a failure. All three still
    // cluster inside the tolerance, so the consensus is their median.
    shiftHeaderBoundary(image, 0.30, 1);

    CHECK(calibrate(image).status == DetailCropStatus::Ok);
}

TEST_CASE("calibrateDetailCrop rides out one bad probe column") {
    // The point of the majority vote: a mouse cursor crossing a scan line, or a UI element overlapping it,
    // takes out one column. Two agreeing columns must still carry the result.
    SUBCASE("one header column reads 5 px late") {
        cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        shiftHeaderBoundary(image, 0.30, 5);
        const DetailCropResult result = calibrate(image);
        REQUIRE(result.status == DetailCropStatus::Ok);
        CHECK(std::abs(result.calibration.width - 540.0) < kTolerance);
    }
    SUBCASE("one button column reads 5 px early") {
        cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        shiftButtonBorder(image, 0.60, 5);
        const DetailCropResult result = calibrate(image);
        REQUIRE(result.status == DetailCropStatus::Ok);
        CHECK(std::abs(result.calibration.width - 540.0) < kTolerance);
    }
    SUBCASE("one header column finds nothing at all") {
        // A column that never leaves the green votes not at all; two agreeing columns are still a majority.
        cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        fillRect(image, scaled(0.80, 540) - 2, scaled(kHeaderBoundaryY, 540), scaled(0.80, 540) + 3, 400, kHeaderGreen);
        const DetailCropResult result = calibrate(image);
        REQUIRE(result.status == DetailCropStatus::Ok);
        CHECK(std::abs(result.calibration.width - 540.0) < kTolerance);
    }
}

TEST_CASE("calibrateDetailCrop reports HeaderStart when no dialog is open") {
    SUBCASE("blank black frame") {
        const cv::Mat image(960, 540, CV_8UC3, cv::Scalar(0, 0, 0));
        CHECK(calibrate(image).status == DetailCropStatus::HeaderStart);
    }
    SUBCASE("a dialog-less game screen") {
        cv::Mat image(960, 540, CV_8UC3, kCanvas);
        fillRect(image, 0, 300, 540, 700, cv::Scalar(90, 120, 200));
        CHECK(calibrate(image).status == DetailCropStatus::HeaderStart);
    }
    SUBCASE("the header painted out of an otherwise complete dialog") {
        cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        fillRect(image, 0, 0, 540, scaled(kHeaderBoundaryY, 540), kCanvas);
        CHECK(calibrate(image).status == DetailCropStatus::HeaderStart);
    }
}

TEST_CASE("calibrateDetailCrop reports HeaderMissing when the header never ends") {
    const cv::Mat image(960, 540, CV_8UC3, kHeaderGreen);
    CHECK(calibrate(image).status == DetailCropStatus::HeaderMissing);
}

TEST_CASE("calibrateDetailCrop reports HeaderSpread when no two columns agree") {
    // A mid-transition or animating frame: every column reads a different row, so there is no majority to
    // trust. Distinct from HeaderMissing, where nothing was found at all.
    cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    shiftHeaderBoundary(image, 0.30, 4);
    shiftHeaderBoundary(image, 0.70, 8);

    CHECK(calibrate(image).status == DetailCropStatus::HeaderSpread);
}

TEST_CASE("calibrateDetailCrop reports ButtonStart when the button interior is not white") {
    cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    fillRect(image, 0, scaled(1.62, 540), 540, scaled(1.70, 540), cv::Scalar(100, 100, 100));

    CHECK(calibrate(image).status == DetailCropStatus::ButtonStart);
}

TEST_CASE("calibrateDetailCrop reports ButtonMissing when the button has no bottom border") {
    cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    fillRect(image, 0, scaled(kButtonBottomY, 540), 540, scaled(kButtonBottomY, 540) + 3, kButtonWhite);

    CHECK(calibrate(image).status == DetailCropStatus::ButtonMissing);
}

TEST_CASE("calibrateDetailCrop reports ButtonSpread when no two columns agree") {
    cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    shiftButtonBorder(image, 0.60, 4);
    shiftButtonBorder(image, 0.63, 8);

    CHECK(calibrate(image).status == DetailCropStatus::ButtonSpread);
}

TEST_CASE("calibrateDetailCrop refuses a caller estimate narrow enough to fool the button scan") {
    // Regression for the worst failure this code can have -- stated as the PROPERTY that matters rather than
    // as the stage that enforces it. A caller estimate 35 px narrow puts the button scan's start point ABOVE
    // the button, on dialog canvas, which passes the "is it white" start test exactly as the button interior
    // does. The scan then stops on the button's TOP border and all three probe columns agree on it, so the
    // spread check cannot notice, and the baseline is solved from the wrong pair -- a scale 6.6 % small.
    //
    // What is pinned here is only that no CONFIDENT result escapes: a status of Ok carrying a rect tens of
    // pixels out is worse than no result at all (see the file comment). Which stage refuses it is
    // deliberately NOT pinned, so that this test keeps its meaning if the refusal moves -- it already has
    // once, from a local close-button-height check to the stat-band cross-check one stage later.
    const cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    const Rect<int> narrow{Point<int>{0, 0}, Point<int>{505, 960}};

    CHECK(calibrateDetailCrop(image, narrow).status != DetailCropStatus::Ok);
}

TEST_CASE("calibrateDetailCrop refuses to latch onto the window's own border") {
    // Regression for the mirror-image failure: a caller estimate 30 px wide puts the scan start BELOW the
    // button, on canvas, and the only dark thing left within the span is the browser window's 1 px border at
    // the very bottom of the frame. Without the brightness floor on the stop pixel that border is accepted
    // and the reported width comes out tens of pixels too large.
    cv::Mat image = makeDialog(Size<int>{540, 962}, 0, 0, 540);
    fillRect(image, 0, 961, 540, 962, cv::Scalar(0, 0, 0));
    const Rect<int> wide{Point<int>{0, 0}, Point<int>{570, 962}};

    CHECK(calibrateDetailCrop(image, wide).status == DetailCropStatus::ButtonMissing);
}

TEST_CASE("calibrateDetailCrop reports a band failure when the 5-stat band is absent") {
    SUBCASE("whole band painted out") {
        cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        fillRect(image, 0, scaled(kBandTopY, 540) - 2, 540, scaled(kBandBottomY, 540) + 3, kCanvas);
        CHECK(calibrate(image).status == DetailCropStatus::BandLeftEdge);
    }
    SUBCASE("only the right end painted out") {
        cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        fillRect(image, 480, scaled(kBandTopY, 540) - 2, 540, scaled(kBandBottomY, 540) + 3, kCanvas);
        CHECK(calibrate(image).status == DetailCropStatus::BandRightEdge);
    }
}

TEST_CASE("calibrateDetailCrop reports BandWidth when an edge lands on the wrong feature") {
    // A green patch further out than the band, inside the left search window -- what an in-game green
    // background beside the dialog would look like. The captured span then disagrees with the width the
    // vertical scale predicts, which is the only signal that the recovered centre is several pixels off.
    cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    fillRect(image, 2, scaled(kBandTopY, 540), 9, scaled(kBandBottomY, 540) + 1, kBandGreen);

    CHECK(calibrate(image).status == DetailCropStatus::BandWidth);
}

TEST_CASE("calibrateDetailCrop reports a start point that falls outside the image") {
    SUBCASE("header start above the top edge") {
        const cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        const Rect<int> shifted{Point<int>{0, -600}, Point<int>{540, 360}};
        CHECK(calibrateDetailCrop(image, shifted).status == DetailCropStatus::HeaderStart);
    }
    SUBCASE("button start below a truncated frame") {
        const cv::Mat full = makeDialog(Size<int>{540, 960}, 0, 0, 540);
        const cv::Mat cropped = full(cv::Rect(0, 0, 540, 800)).clone();
        CHECK(
            calibrateDetailCrop(cropped, Rect<int>{Point<int>{0, 0}, Point<int>{540, 800}}).status
            == DetailCropStatus::ButtonStart);
    }
}

TEST_CASE("calibrateDetailCrop rejects an unusable image or intersection") {
    const Rect<int> whole{Point<int>{0, 0}, Point<int>{540, 960}};
    CHECK(calibrateDetailCrop(cv::Mat(), whole).status == DetailCropStatus::UnsupportedImage);
    CHECK(
        calibrateDetailCrop(cv::Mat(960, 540, CV_8UC1, cv::Scalar(0)), whole).status
        == DetailCropStatus::UnsupportedImage);

    const cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    const Rect<int> degenerate{Point<int>{0, 0}, Point<int>{0, 960}};
    CHECK(calibrateDetailCrop(image, degenerate).status == DetailCropStatus::UnsupportedImage);
}

TEST_CASE("calibrateDetailCrop survives degenerate geometry without throwing") {
    const cv::Mat tiny(1, 1, CV_8UC3, kHeaderGreen);
    CHECK_NOTHROW((void) calibrateDetailCrop(tiny, Rect<int>{Point<int>{0, 0}, Point<int>{1, 1}}));
    CHECK_FALSE(calibrateDetailCrop(tiny, Rect<int>{Point<int>{0, 0}, Point<int>{1, 1}}).ok());

    const cv::Mat image = makeDialog(Size<int>{540, 960}, 0, 0, 540);
    // An intersection wildly larger than the image: every scan start lands outside it.
    const Rect<int> huge{Point<int>{-4000, -4000}, Point<int>{4000, 4000}};
    CHECK_NOTHROW((void) calibrateDetailCrop(image, huge));
    CHECK_FALSE(calibrateDetailCrop(image, huge).ok());
}

TEST_CASE("DetailCropCalibration::toRect rounds origin and extent independently") {
    // The width is the `unit` a FrameAnchor derives from this rect, and scene detection is sensitive to it,
    // so it must survive rounding rather than absorbing the origin's rounding error.
    const DetailCropCalibration calibration{0.6, 29.6, 664.75, 1181.8};
    const Rect<int> rect = calibration.toRect();
    CHECK(rect.left() == 1);
    CHECK(rect.top() == 30);
    CHECK(rect.width() == 665);
    CHECK(rect.height() == 1182);
}

TEST_CASE("toRect(frame) absorbs one row of its own rounding overhang and no more") {
    // The numbers are the recorded incident, not an invented case: on the 2326x1340 Firefox landscape
    // decode, a header boundary one row early solved scale 737.752 / top 28.778 / height 1312, which rounds
    // to top 29 + height 1312 = bottom 1341 in a 1340-row frame. isCropInsideFrame refused it, nothing
    // latched, and the import produced no records and no error. See the note above calibrateDetailCrop.
    const Size<int> frame{2326, 1340};
    const DetailCropCalibration incident{794.0, 28.778, 737.752, 1312.0};

    const Rect<int> plain = incident.toRect();
    CHECK(plain.top() == 29);
    CHECK(plain.bottom() == 1341);  // one row outside a 1340-row frame

    const Rect<int> fitted = incident.toRect(frame);
    CHECK(fitted.bottom() == 1340);  // pulled in
    // Everything else is bit-identical -- the WIDTH above all, since it is the anchor `unit`.
    CHECK(fitted.left() == plain.left());
    CHECK(fitted.top() == plain.top());
    CHECK(fitted.right() == plain.right());
    CHECK(fitted.width() == plain.width());
    CHECK(fitted.width() == 738);

    // Two rows out is not this function's rounding: left alone, for the gate to refuse.
    const DetailCropCalibration two_out{794.0, 29.0, 737.752, 1313.0};
    CHECK(two_out.toRect().bottom() == 1342);
    CHECK(two_out.toRect(frame).bottom() == 1342);

    // A rect already inside the frame is returned unchanged, including the flush case every supported
    // capture form actually lands on.
    const DetailCropCalibration flush{0.0, 29.861, 737.1118, 1310.4};
    CHECK(flush.toRect().bottom() == 1340);
    CHECK(flush.toRect(frame) == flush.toRect());

    // The bottom edge is the only one that moves: a rect overhanging on the RIGHT keeps its width, because
    // pulling the right edge in would shrink the unit.
    const DetailCropCalibration wide{1589.0, 0.0, 738.0, 1000.0};
    CHECK(wide.toRect().right() == 2327);  // one column outside a 2326-column frame
    CHECK(wide.toRect(frame).right() == 2327);
    CHECK(wide.toRect(frame).width() == 738);
}

// --- isHeaderGreen, pinned against BOTH YUV -> RGB interpretations -------------------------------------
//
// This one predicate decides whether the calibrator even starts, and where the header/canvas boundary
// falls. It once carried a `g >= 180` floor read off BT.601-decoded footage; a browser decodes the same
// H.264 stream as BT.709, which darkens this green by ~20 on G, and a landscape import whose header reads
// G=176 was therefore rejected on all 374 of its frames and produced no record and no error. Every pixel
// below is a MEASURED one, so a future retune has to argue with real footage rather than with a synthetic
// swatch. The clip-level version of the same contract is the dual-decode suite
// (native/test/integration/run_dual_decode.py, case landscape_2pane_ps5).
TEST_CASE("isHeaderGreen accepts the header under both BT.601 and BT.709") {
    using detail_crop_impl::Bgr;
    using detail_crop_impl::isHeaderGreen;

    // Header-scan start pixels, portrait 736x1308 phone capture (the ten golden clips).
    CHECK(isHeaderGreen(Bgr{14, 219, 123}));  // BT.601
    CHECK(isHeaderGreen(Bgr{8, 199, 118}));  // BT.709, the same pixel

    // Header-scan start pixels, 2326x1340 landscape import, dialog in a 738-wide pane. The BT.709 one is
    // the regression: G=176 sat 4 below the old floor, and this is the whole reason the case existed.
    CHECK(isHeaderGreen(Bgr{9, 194, 105}));  // BT.601
    CHECK(isHeaderGreen(Bgr{4, 176, 101}));  // BT.709 -- rejected by the old `g >= 180`
    CHECK(isHeaderGreen(Bgr{4, 175, 103}));  // BT.709, the darkest header plateau measured anywhere
    CHECK(isHeaderGreen(Bgr{3, 180, 114}));

    // The header's LAST row -- its bottom TRANSITION one, soft because the 4:2:0 source shares one chroma
    // sample between luma rows 124 and 125 -- on that same landscape clip, frame 100, at the three probe
    // columns x = 524 / 818 / 892. These are the pixels a real desktop Firefox 153 handed to the core, not a
    // `--color_matrix bt709` reconstruction of them, and that distinction is the point: nominal bt709 reads
    // g - b = 121 / 120 / 121 here and STILL CLEARS the old 120, by exactly 0 on x=818, so it is Firefox's
    // own 4..5 units of rounding on top of the matrix that decided this. They are why `g - b` reads 100 and
    // not 120: at 120 the scan stops one row early, which solves a different scale (737.752 instead of
    // 737.112, the landmark gap being 1152 rows instead of 1151) and puts the reconstructed top at +28.778
    // instead of +29.861 -- so the crop rounds to top 29 / bottom 1341 in a 1340-row frame, which is what
    // cost the whole import at the time. `toRect(frame)` now absorbs that one row (see the case above), so
    // the residue of a scan stopping early is a 1-row-off geometry rather than silence -- still wrong, and
    // still this predicate's job to prevent.
    // Row numbers here are the corrected `_toppad` geometry; see the note in cv/detail_crop_calibrator.h.
    // The BT.601 partner of each is the pixel swscale produces from the same source row.
    CHECK(isHeaderGreen(Bgr{56, 173, 120}));  // Firefox, g - b = 117
    CHECK(isHeaderGreen(Bgr{57, 172, 117}));  // Firefox, g - b = 115 -- the worst margin measured anywhere
    CHECK(isHeaderGreen(Bgr{55, 184, 123}));  // swscale BT.601, the same row: g - b = 129
    CHECK(isHeaderGreen(Bgr{56, 184, 120}));  // swscale BT.601, g - b = 128
}

TEST_CASE("isHeaderGreen rejects the gold aptitude glyph a losing pane probe lands on") {
    using detail_crop_impl::Bgr;
    using detail_crop_impl::isHeaderGreen;

    // These two were once pinned as ACCEPTED "load-bearing header pixels", with a note claiming they ruled
    // out any g - r floor. Both claims were wrong, and were checked against the footage before this test
    // replaced them: the pixel is the friend_inheritance clip's frame 166 at row 470 -- the gold "S"
    // aptitude rank glyph in the distance-aptitude row, not header green at all -- and it was reached by a
    // probe of the LOSING pane candidate, on a call that does not reach Ok either way (it only moves from
    // NoMajority/HeaderSpread to NoStart/HeaderStart, and updateState drops both through the same
    // `if (!result.ok()) continue;`). Gold is exactly the colour a g - r test exists to reject: R stands
    // ABOVE G here, where real header green keeps G at least 52 above R.
    CHECK_FALSE(isHeaderGreen(Bgr{63, 185, 222}));  // BT.601
    CHECK_FALSE(isHeaderGreen(Bgr{59, 183, 228}));  // BT.709, the same glyph
}

TEST_CASE("isHeaderGreen rejects what is not the header") {
    using detail_crop_impl::Bgr;
    using detail_crop_impl::isHeaderGreen;

    CHECK_FALSE(isHeaderGreen(Bgr{215, 231, 240}));  // dialog canvas
    CHECK_FALSE(isHeaderGreen(Bgr{250, 250, 250}));  // canvas, the flat part
    CHECK_FALSE(isHeaderGreen(Bgr{96, 203, 150}));  // the "greenish" canvas B is there to separate
    CHECK_FALSE(isHeaderGreen(Bgr{20, 20, 20}));  // window chrome / letterbox
    CHECK_FALSE(isHeaderGreen(Bgr{190, 190, 190}));  // light grey UI
    CHECK_FALSE(isHeaderGreen(Bgr{0, 100, 0}));  // a green too dark to be this header

    // The first canvas rows the scan must stop on, measured on the BT.709 runs. B is what separates them
    // from the last header row (48 -> 91), so the boundary keeps landing in the same place.
    CHECK_FALSE(isHeaderGreen(Bgr{91, 176, 141}));
    CHECK_FALSE(isHeaderGreen(Bgr{94, 192, 153}));
}

TEST_CASE("isHeaderGreen keeps its three discriminating limits exactly where they are") {
    using detail_crop_impl::Bgr;
    using detail_crop_impl::isHeaderGreen;

    // b <= 70 is inclusive and load-bearing: a real BT.601 header pixel sits exactly on it, and widening
    // the limit to 80 changed 331 BT.601 header decisions across the golden corpus.
    CHECK(isHeaderGreen(Bgr{70, 208, 134}));
    CHECK_FALSE(isHeaderGreen(Bgr{71, 208, 134}));

    // g - b >= 100 is inclusive too, and it is the one limit here that was measured DOWNWARDS: 120 rejected
    // the header's bottom transition row once a browser decoded it (g - b = 115), 110 and 100 change no
    // BT.601 decision in the golden corpus and 90 changes one, so 100 is the measured floor. Both pixels
    // clear b <= 70 and g - r >= 40, so this pair isolates the difference test.
    CHECK(isHeaderGreen(Bgr{50, 150, 110}));
    CHECK_FALSE(isHeaderGreen(Bgr{51, 150, 110}));

    // g - r >= 40 is inclusive too. Both pixels sit inside the loose absolute box (r = 150 / 151 is well
    // under its r <= 200), so this pair isolates the difference test: it is the only term that separates
    // them, which is what makes it the thing that fails if the limit is dropped.
    CHECK(isHeaderGreen(Bgr{50, 190, 150}));
    CHECK_FALSE(isHeaderGreen(Bgr{50, 190, 151}));
}

TEST_CASE("the loose absolute bounds in isHeaderGreen stay far away from real header green") {
    using detail_crop_impl::Bgr;
    using detail_crop_impl::isHeaderGreen;

    // These bounds are insurance and must never be the deciding term (that role is what made `g >= 180`
    // cost a whole import). Each is pinned at the value the accepted-pixel survey sized it to: g >= 125
    // against a measured worst of 169, r >= 40 against 100, r <= 200 against 142. b >= 0 and g <= 255 are
    // the uint8 endpoints and cannot be crossed; b's MAXIMUM is `b <= 70`, the tight boundary locator,
    // pinned in the test above and deliberately not duplicated by a looser one.
    //
    // Every pixel below is synthetic ON PURPOSE: no real header pixel comes near these limits, which is
    // exactly the property being asserted. Each pair differs only in the channel named, and the accepted
    // half proves the rejection is that bound and not another term.
    CHECK(isHeaderGreen(Bgr{0, 125, 60}));
    CHECK_FALSE(isHeaderGreen(Bgr{0, 124, 60}));  // g under its minimum

    CHECK(isHeaderGreen(Bgr{0, 130, 40}));
    CHECK_FALSE(isHeaderGreen(Bgr{0, 130, 39}));  // r under its minimum

    CHECK(isHeaderGreen(Bgr{60, 250, 200}));
    CHECK_FALSE(isHeaderGreen(Bgr{60, 250, 201}));  // r over its maximum
}

}  // namespace
}  // namespace uma
