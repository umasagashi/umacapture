// Behavioral tests for the Frame wrapper and its coordinate/color primitives.
//
// Frame is the numeric foundation of the whole recognition pipeline: color sampling, line
// measurement, and the area diff metrics that drive scroll/scene detection. These drive it with
// small, hand-built CV_8UC3 mats through Frame::fixed(), whose anchor normalizes BOTH axes by the
// frame width (unit_size == width), so a pixel (px, py) is addressed at normalized (px/w, py/w).
//
// Note: negative paths that trip assert_ (e.g. linspace(num < 2)) are NOT exercised here -- assert_
// aborts in this Debug-built test binary. Only the real, always-on throws (bgrAt / view bounds,
// size-mismatch) are checked.

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <stdexcept>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/detail_crop_tracker.h"
#include "cv/frame.h"
#include "cv/pane_mode.h"
#include "util/cv_test_helpers.h"

namespace uma {
namespace {

using testutil::solid;

void checkColor(const Color &actual, int r, int g, int b) {
    CHECK(actual.r() == r);
    CHECK(actual.g() == g);
    CHECK(actual.b() == b);
}

TEST_CASE("BGR::difference is the Manhattan distance over channels") {
    const auto black = BGR::clampFrom(Color(0, 0, 0));
    const auto white = BGR::clampFrom(Color(255, 255, 255));
    CHECK(black.difference(black) == 0);
    CHECK(black.difference(white) == 765);  // 255 * 3, the maximum
    CHECK(BGR::clampFrom(Color(100, 100, 100)).difference(BGR::clampFrom(Color(110, 110, 110))) == 30);
}

TEST_CASE("linspace produces evenly spaced samples including both endpoints") {
    const auto points = frame_impl::linspace(0.0, 10.0, 11);
    REQUIRE(points.size() == 11);
    CHECK(points.front() == doctest::Approx(0.0));
    CHECK(points.back() == doctest::Approx(10.0));
    CHECK(points[1] == doctest::Approx(1.0));
    CHECK(points[5] == doctest::Approx(5.0));
}

TEST_CASE("FrameAnchor::fixed round-trips normalized and pixel coordinates") {
    const FrameAnchor anchor = FrameAnchor::fixed(Size<int>{100, 100});

    const Point<double> normalized = anchor.mapFromFrame(Point<int>{50, 50});
    CHECK(normalized.x() == doctest::Approx(0.5));
    CHECK(normalized.y() == doctest::Approx(0.5));

    const Point<int> pixels = anchor.mapToFrame(Point<double>{0.5, 0.5});
    CHECK(pixels.x() == 50);
    CHECK(pixels.y() == 50);

    CHECK(anchor.scaleToPixels(0.5) == 50);
    CHECK(anchor.scaleFromPixels(50) == doctest::Approx(0.5));
}

TEST_CASE("FrameAnchor guards a degenerate zero-size frame against inf/NaN offsets") {
    const FrameAnchor anchor = FrameAnchor::fixed(Size<int>{0, 0});
    // Without the unit_size > 0 guard the reciprocal would be inf and this offset NaN/inf. A
    // non-ScreenStart anchor exercises the offset arrays; the result must stay finite.
    const Point<double> mapped = anchor.absolute(Point<double>(5, 5, Anchor(IntersectLogicalEnd)));
    CHECK(std::isfinite(mapped.x()));
    CHECK(std::isfinite(mapped.y()));
}

TEST_CASE("Frame::colorAt reads the pixel under a normalized point") {
    const Frame frame = Frame::fixed(solid(100, 100, Color(10, 20, 30)));
    checkColor(frame.colorAt(Point<double>(0.5, 0.5)), 10, 20, 30);
}

TEST_CASE("Frame::colorAt throws out_of_range past the frame edge") {
    const Frame frame = Frame::fixed(solid(100, 100, Color(0, 0, 0)));
    CHECK_THROWS_AS((void) frame.colorAt(Point<double>(2.0, 2.0)), std::out_of_range);
}

TEST_CASE("Frame::viewPixels crops in pixel space with a fixed full local anchor") {
    const Frame source = Frame::fixed(solid(8, 6, Color(10, 20, 30)), 42).reanchored({{1, 1}, Size<int>{6, 4}});
    const Frame cropped = source.viewPixels({{2, 1}, Size<int>{3, 2}}).clone();

    CHECK(cropped.size() == Size<int>{3, 2});
    CHECK(cropped.anchor().intersection() == Rect<int>{{0, 0}, Size<int>{3, 2}});
    CHECK(cropped.timestamp() == 42);
    CHECK_THROWS_AS((void) source.viewPixels({{7, 5}, Size<int>{2, 2}}), std::out_of_range);
}

TEST_CASE("Frame::isIn tests a point against a color range") {
    const Frame frame = Frame::fixed(solid(100, 100, Color(100, 100, 100)));
    CHECK(frame.isIn(Range<Color>(Color(50, 50, 50), Color(150, 150, 150)), Point<double>(0.5, 0.5)));
    CHECK_FALSE(frame.isIn(Range<Color>(Color(0, 0, 0), Color(50, 50, 50)), Point<double>(0.5, 0.5)));
}

TEST_CASE("Frame line sampling: isIn / isAllIn / lengthIn") {
    // Left half (x < 50) is in range; right half is out of range.
    cv::Mat mat = solid(100, 100, Color(0, 0, 0));
    mat(cv::Rect(50, 0, 50, 100)).setTo(cv::Scalar(200, 200, 200));
    const Frame frame = Frame::fixed(mat);
    const Range<Color> in_range{Color(0, 0, 0), Color(50, 50, 50)};

    const Line<double> crossing{Point<double>(0.10, 0.50), Point<double>(0.90, 0.50)};
    CHECK(frame.isIn(in_range, crossing));  // some samples are in range
    CHECK_FALSE(frame.isAllIn(in_range, crossing));  // not all are
    const std::optional<double> length = frame.lengthIn(in_range, crossing);
    REQUIRE(length.has_value());  // starts in range, so a run length is reported
    CHECK(*length > 0.0);
    CHECK(*length < 1.0);  // the run ends where the line crosses into the right half

    const Line<double> outside{Point<double>(0.60, 0.50), Point<double>(0.90, 0.50)};
    CHECK_FALSE(frame.isIn(in_range, outside));
    CHECK_FALSE(frame.lengthIn(in_range, outside).has_value());  // first sample already out of range

    const Line<double> inside{Point<double>(0.10, 0.50), Point<double>(0.40, 0.50)};
    CHECK(frame.isAllIn(in_range, inside));
    CHECK(frame.lengthIn(in_range, inside) == doctest::Approx(1.0));  // in range all the way to the end
}

TEST_CASE("Frame::fractionIn reports the share of sampled points in range") {
    // Left half (x < 50) is in range; right half is out of range.
    cv::Mat mat = solid(100, 100, Color(0, 0, 0));
    mat(cv::Rect(50, 0, 50, 100)).setTo(cv::Scalar(200, 200, 200));
    const Frame frame = Frame::fixed(mat);
    const Range<Color> in_range{Color(0, 0, 0), Color(50, 50, 50)};

    const Line<double> left{Point<double>(0.10, 0.50), Point<double>(0.40, 0.50)};
    CHECK(frame.fractionIn(in_range, left) == doctest::Approx(1.0));  // wholly in range

    const Line<double> right{Point<double>(0.60, 0.50), Point<double>(0.90, 0.50)};
    CHECK(frame.fractionIn(in_range, right) == doctest::Approx(0.0));  // wholly out of range

    // A line split evenly across the boundary reports ~half in range (the ratio, not a hard all/any).
    const Line<double> crossing{Point<double>(0.10, 0.50), Point<double>(0.90, 0.50)};
    CHECK(frame.fractionIn(in_range, crossing) == doctest::Approx(0.5).epsilon(0.05));
}

TEST_CASE("Frame::fractionIn separates a solid header band from a narrow stray run") {
    // Mirrors factorHeaderTopY's probe: a right-of-centre band is "the header" only when it is *mostly* green,
    // so a solid header row clears a 0.5 threshold while a narrow stray green pill in the same band does not.
    cv::Mat mat = solid(100, 100, Color(0, 0, 0));  // background is out of the green range
    mat(cv::Rect(0, 20, 100, 1)).setTo(cv::Scalar(0, 200, 0));  // y=20: a full-width solid green header row
    mat(cv::Rect(65, 40, 5, 1)).setTo(cv::Scalar(0, 200, 0));  // y=40: a 5px green pill inside the band
    const Frame frame = Frame::fixed(mat);
    const Range<Color> green{Color(0, 150, 0), Color(80, 255, 80)};

    // The probe band spans x[0.65,0.88] (23px on a 100px-wide frame), matching the config right-band.
    const Line<double> header_band{Point<double>(0.65, 0.20), Point<double>(0.88, 0.20)};
    CHECK(frame.fractionIn(green, header_band) == doctest::Approx(1.0));  // solid header -> accepted

    const Line<double> pill_band{Point<double>(0.65, 0.40), Point<double>(0.88, 0.40)};
    CHECK(frame.fractionIn(green, pill_band) < 0.5);  // narrow pill -> below threshold, rejected
}

TEST_CASE("Frame::diffStats counts changed pixels and reports a ratio") {
    const Frame black = Frame::fixed(solid(4, 4, Color(0, 0, 0)));
    const Frame reddish = Frame::fixed(solid(4, 4, Color(10, 0, 0)));  // per-pixel diff of 10
    const Rect<double> whole{Point<double>(0, 0), Point<double>(0, 0)};  // empty rect => whole frame

    CHECK(black.diffStats(black, whole, 0).changed == 0);  // identical frames

    const Frame::DiffStats changed = black.diffStats(reddish, whole, 5);
    CHECK(changed.changed == 16);
    CHECK(changed.total == 16);
    CHECK(changed.ratio() == doctest::Approx(1.0));

    const Frame::DiffStats unchanged = black.diffStats(reddish, whole, 10);  // gate excludes the diff
    CHECK(unchanged.changed == 0);
    CHECK(unchanged.ratio() == doctest::Approx(0.0));

    CHECK_THROWS_AS(
        (void) black.diffStats(Frame::fixed(solid(5, 5, Color(0, 0, 0))), whole, 0), std::invalid_argument);
}

TEST_CASE("Frame::DiffStats::ratio is zero when nothing was examined") {
    const Frame::DiffStats empty;
    CHECK(empty.ratio() == doctest::Approx(0.0));  // guards a divide-by-zero on total == 0
}

// --- Frame::resizedToUnit ---------------------------------------------------------------------------------
//
// The pure seam behind the "normalize the recognized image size" setting: one isotropic scale that moves the
// anchor's UNIT (the intersection width) onto a fixed value, applied to the pixels and to the intersection
// together.
//
// THE POSTCONDITION IS CHECKED WITH THE PRODUCTION PREDICATE, not a copy of it. This used to re-state
// isCropInsideFrame here "so a frame test does not depend on the tracker", and the copy had already drifted:
// it read `rect.width() > 0` while the real gate reads `rect.width() >= kMinimumCropUnit` (64). A CHECK that
// believes it is asserting "the result still satisfies isCropInsideFrame" was asserting a strictly weaker
// predicate, so every intersection 1..63 px wide would have passed here and been refused in production. The
// dependency on cv/detail_crop_tracker.h is a header include in a test binary that already links that header;
// a predicate that can silently diverge from the one it names is the more expensive of the two.

TEST_CASE("Frame::resizedToUnit lands the anchor unit exactly on the requested value") {
    const Frame source = Frame::fixed(solid(1080, 1920, Color(0, 0, 0)));
    CHECK(source.anchor().intersection().width() == 1080);

    const Frame resized = source.resizedToUnit(540);

    CHECK(resized.anchor().intersection().width() == 540);  // the unit is exactly 540, not "about" 540
    CHECK(resized.size() == Size<int>{540, 960});  // this frame's aspect ratio happens to keep it 540 wide
    CHECK(resized.timestamp() == source.timestamp());
    CHECK(isCropInsideFrame(resized.anchor().intersection(), resized.size()));
}

TEST_CASE("Frame::resizedToUnit keeps normalized coordinates addressing the same content") {
    // Bottom-right quadrant white, the rest black. Both probes sit well inside a quadrant, so bilinear
    // resampling near the boundary cannot reach them.
    cv::Mat mat = solid(1080, 1920, Color(0, 0, 0));
    mat(cv::Rect(540, 960, 540, 960)).setTo(cv::Scalar(255, 255, 255));
    const Frame source = Frame::fixed(mat);
    const Frame resized = source.resizedToUnit(540);

    const Point<double> white{0.75, 1.20};  // (810, 1296) at unit 1080; (405, 648) at unit 540
    const Point<double> black{0.25, 0.40};  // (270, 432)  at unit 1080; (135, 216) at unit 540
    checkColor(source.colorAt(white), 255, 255, 255);
    checkColor(resized.colorAt(white), 255, 255, 255);
    checkColor(source.colorAt(black), 0, 0, 0);
    checkColor(resized.colorAt(black), 0, 0, 0);
}

TEST_CASE("Frame::resizedToUnit scales a calibrated intersection by the same factor") {
    // A re-anchored frame: the crop calibration's correction, off-centre and smaller than the image.
    const Frame source = Frame::fixed(solid(1000, 800, Color(0, 0, 0))).reanchored({{40, 20}, Size<int>{600, 400}});

    const Frame resized = source.resizedToUnit(300);  // s = 300 / 600 = 0.5

    const Rect<int> intersection = resized.anchor().intersection();
    CHECK(resized.size() == Size<int>{500, 400});
    CHECK(intersection.left() == 20);
    CHECK(intersection.top() == 10);
    CHECK(intersection.width() == 300);
    CHECK(intersection.height() == 200);
    CHECK(isCropInsideFrame(intersection, resized.size()));
}

TEST_CASE("Frame::resizedToUnit clamps an intersection that would overhang the scaled frame") {
    // A case where the clamp genuinely fires: s = 540/216 = 2.5, so the top (73) and the height (173) both
    // land on a .5 and round UP, to 183 + 433 = 616 against a destination height of 615. Without the clamp
    // the intersection would hang one pixel below the image and every later probe would throw from bgrAt.
    const Frame source = Frame::fixed(solid(489, 246, Color(0, 0, 0))).reanchored({{204, 73}, Size<int>{216, 173}});

    const Frame resized = source.resizedToUnit(540);

    const Rect<int> intersection = resized.anchor().intersection();
    CHECK(resized.size() == Size<int>{1223, 615});
    CHECK(intersection.width() == 540);
    CHECK(intersection.top() == 182);  // 183 clamped back by one, so the bottom edge lands exactly on 615
    CHECK(intersection.bottom() == 615);
    CHECK(isCropInsideFrame(intersection, resized.size()));
}

TEST_CASE("Frame::resizedToUnit rounds the destination size instead of rounding it up") {
    // Regression: `ceil` looked safe but overshoots through floating point. 532 * (540.0 / 532) evaluates to
    // 540.0000000000001, so ceil made this frame 541 px wide while the unit was pinned to 540 -- content
    // stretched across one more column than the coordinate system addressing it. 133/266/532/1064/2128/4256
    // all reproduce it; 532 and 1064 are the real widths of 1682x946 / 3364x1892-class game windows.
    const Frame source = Frame::fixed(solid(532, 946, Color(0, 0, 0)));

    const Frame resized = source.resizedToUnit(540);

    CHECK(resized.size().width() == 540);  // not 541
    CHECK(resized.anchor().intersection().width() == 540);
    CHECK(resized.size().width() == resized.anchor().intersection().width());  // no unreachable column
    CHECK(isCropInsideFrame(resized.anchor().intersection(), resized.size()));

    // The same overshoot hit the height independently, for 36 of the widths in 100-4000: at width 711 the
    // exact scaled height of 1264 is 960, but the double evaluates to 960.0000000000001.
    CHECK(Frame::fixed(solid(711, 1264, Color(0, 0, 0))).resizedToUnit(540).size() == Size<int>{540, 960});
    CHECK(Frame::fixed(solid(1017, 1808, Color(0, 0, 0))).resizedToUnit(540).size() == Size<int>{540, 960});
}

TEST_CASE("Frame::resizedToUnit is a no-op within the 3 px tolerance") {
    // 539 -> 540 moves the unit by 1 px; resizing over that would only blur the image, so the frame comes
    // back untouched and the unit stays 539. The 3 px is inherited verbatim from the Windows runner's
    // original force-resize, so its users' recognition behaviour does not change.
    const Frame source = Frame::fixed(solid(539, 958, Color(0, 0, 0)));
    const Frame resized = source.resizedToUnit(540);

    CHECK(resized.size() == Size<int>{539, 958});
    CHECK(resized.anchor().intersection().width() == 539);

    // The edges of the tolerance, stated as the unit distance it is measured in.
    CHECK(source.resizedToUnit(539 + Frame::kUnitTolerance).size() == Size<int>{539, 958});  // 542: untouched
    CHECK(source.resizedToUnit(539 - Frame::kUnitTolerance).size() == Size<int>{539, 958});  // 536: untouched
    CHECK(source.resizedToUnit(539 + Frame::kUnitTolerance + 1).size() != Size<int>{539, 958});  // 543: resized
    CHECK(source.resizedToUnit(539 - Frame::kUnitTolerance - 1).size() != Size<int>{539, 958});  // 535: resized
    CHECK(Frame::kUnitTolerance == 3);  // the shipped value, so moving it fails here by name
}

TEST_CASE("Frame::resizedToUnit measures its tolerance on the unit, not on the frame size") {
    // THE REGRESSION THIS TEST EXISTS FOR. The tolerance used to compare the destination frame SIZE with the
    // current one, and the frame is scaled by unit/intersection.width() -- so on a tall frame one pixel of
    // unit is several pixels of frame, and the "negligible difference" budget shrank to a fraction of a
    // pixel of the quantity the caller actually asked for. These are the real proportions: a 1080x2520
    // portrait phone capture (the whole regression grid is this shape) with a 722 px calibrated pane.
    const Frame source =
        Frame::fixed(solid(1080, 2520, Color(0, 0, 0))).reanchored({{179, 0}, Size<int>{722, 1284}});

    // 722 -> 720 is 2 px of unit, inside the tolerance, so nothing is resampled. Under the old size-based
    // comparison the height moved by 7 px and this frame WAS resampled -- an entire 1080x2520 resample to
    // move the coordinate system by two pixels.
    const Frame kept = source.resizedToUnit(720);
    CHECK(kept.size() == Size<int>{1080, 2520});
    CHECK(kept.anchor().intersection().width() == 722);

    // And the tolerance still ends where it says it does: 4 px of unit is outside it, on the same frame.
    const Frame moved = Frame::fixed(solid(1080, 2520, Color(0, 0, 0)))
                            .reanchored({{179, 0}, Size<int>{724, 1284}})
                            .resizedToUnit(720);
    CHECK(moved.anchor().intersection().width() == 720);
    CHECK(moved.size() == Size<int>{1074, 2506});
}

// --- Frame::resizedIntoBand -------------------------------------------------------------------------------
//
// The form the pipeline configures: hold the frame's unit inside a band instead of on a single target. The
// three regions below -- under, inside, over -- are the whole behaviour, and the fourth case is where the
// band meets the tolerance above.

TEST_CASE("Frame::resizedIntoBand scales a frame below the band UP to the lower bound") {
    // Upscaling is the intended behaviour at this end, not an accident: a small window is normalized up to
    // the recognizer's reference width rather than recognized at a width no model was trained near.
    const Frame source = Frame::fixed(solid(400, 800, Color(0, 0, 0)));

    const Frame resized = source.resizedIntoBand(Range<int>{540, 720});

    CHECK(resized.anchor().intersection().width() == 540);
    CHECK(resized.size() == Size<int>{540, 1080});
    CHECK(isCropInsideFrame(resized.anchor().intersection(), resized.size()));
}

TEST_CASE("Frame::resizedIntoBand forwards a frame inside the band untouched") {
    const Frame source = Frame::fixed(solid(600, 1200, Color(0, 0, 0)));

    const Frame resized = source.resizedIntoBand(Range<int>{540, 720});

    CHECK(resized.size() == Size<int>{600, 1200});
    CHECK(resized.anchor().intersection().width() == 600);
    // Both bounds are INCLUSIVE: a frame sitting exactly on an edge is inside, not on the wrong side of it.
    CHECK(Frame::fixed(solid(540, 1080, Color(0, 0, 0))).resizedIntoBand(Range<int>{540, 720}).size()
          == Size<int>{540, 1080});
    CHECK(Frame::fixed(solid(720, 1440, Color(0, 0, 0))).resizedIntoBand(Range<int>{540, 720}).size()
          == Size<int>{720, 1440});
}

TEST_CASE("Frame::resizedIntoBand scales a frame above the band DOWN to the upper bound") {
    // 1080 is not an arbitrary "above the band": it is exactly the shrink arm's fire point at this bound
    // (720 * kShrinkDeadband), and the case below pins that edge on both sides.
    const Frame source = Frame::fixed(solid(1080, 2160, Color(0, 0, 0)));

    const Frame resized = source.resizedIntoBand(Range<int>{540, 720});

    CHECK(resized.anchor().intersection().width() == 720);
    CHECK(resized.size() == Size<int>{720, 1440});
    CHECK(isCropInsideFrame(resized.anchor().intersection(), resized.size()));
}

TEST_CASE("Frame::resizedIntoBand shrinks only once the frame is kShrinkDeadband times the upper bound") {
    // The shrink arm's DEAD BAND. A frame between the bound and the threshold is forwarded at its own width:
    // resampling it costs a full pass over the frame to buy back a few percent of the work behind it. The
    // three widths are the edge itself and its two neighbours, so `>=` cannot silently become `>`: 1080 is a
    // standard phone-recording width, and it is on the FIRING side.
    const Range<int> band{540, 720};
    const int threshold = static_cast<int>(band.max() * Frame::kShrinkDeadband);
    CHECK(threshold == 1080);  // the shipped operating point, so moving either factor fails here by name

    CHECK(Frame::fixed(solid(1079, 2158, Color(0, 0, 0))).resizedIntoBand(band).anchor().intersection().width()
          == 1079);
    CHECK(Frame::fixed(solid(1080, 2160, Color(0, 0, 0))).resizedIntoBand(band).anchor().intersection().width()
          == 720);
    CHECK(Frame::fixed(solid(1081, 2162, Color(0, 0, 0))).resizedIntoBand(band).anchor().intersection().width()
          == 720);

    // Everything between the bound and the threshold is untouched, including the width the primary golden
    // clip arrives at (736) -- which used to be resampled to 720 for a 2.2% reduction.
    for (const int width : {721, 736, 800, 1000, 1079}) {
        CAPTURE(width);
        CHECK(Frame::fixed(solid(width, 2 * width, Color(0, 0, 0))).resizedIntoBand(band).size()
              == Size<int>{width, 2 * width});
    }

    // The threshold follows the bound rather than being a second literal: at a 200-px bound it is 300.
    const Range<int> narrow{100, 200};
    CHECK(Frame::fixed(solid(299, 598, Color(0, 0, 0))).resizedIntoBand(narrow).anchor().intersection().width()
          == 299);
    CHECK(Frame::fixed(solid(300, 600, Color(0, 0, 0))).resizedIntoBand(narrow).anchor().intersection().width()
          == 200);
}

TEST_CASE("Frame::resizedIntoBand leaves a frame just outside the band alone, within the unit tolerance") {
    // The band's LOWER effective edge is widened by kUnitTolerance, because the bound is reached through
    // resizedToUnit: a frame 3 px below it is not worth a resample to pull back in, one 4 px below it is.
    // The two constants do not interact: the tolerance is measured in pixels of unit INSIDE resizedToUnit,
    // the dead band is a ratio measured OUTSIDE it, and no unit can be inside both windows -- the shrink arm
    // now fires no closer to the bound than max * (kShrinkDeadband - 1) = 360 px, two orders above the 3 px.
    // So the upper edge is governed by the dead band alone (case above), and this is the lower edge only.
    const Range<int> band{540, 720};

    CHECK(Frame::fixed(solid(537, 1074, Color(0, 0, 0))).resizedIntoBand(band).anchor().intersection().width()
          == 537);
    CHECK(Frame::fixed(solid(536, 1072, Color(0, 0, 0))).resizedIntoBand(band).anchor().intersection().width()
          == 540);
}

TEST_CASE("Frame::resizedIntoBand returns the frame untouched for a degenerate frame") {
    // A zero-unit anchor is below every band, so the band arm routes it into resizedToUnit -- which must
    // still refuse it rather than dividing by the intersection width.
    CHECK(Frame().resizedIntoBand(Range<int>{540, 720}).empty());
}

TEST_CASE("Frame::resizedToUnit returns the frame untouched for a degenerate request") {
    const Frame source = Frame::fixed(solid(1080, 1920, Color(0, 0, 0)));
    CHECK(source.resizedToUnit(0).size() == Size<int>{1080, 1920});
    CHECK(source.resizedToUnit(-540).size() == Size<int>{1080, 1920});
    CHECK(Frame().resizedToUnit(540).empty());  // the empty sentinel frame
}

// --- What bounds the resize, now that the destination-area ceiling is gone --------------------------------
//
// resizedToUnit used to end with `if (destination area > 64e6) return *this;` -- untested, unlogged, and
// indistinguishable from success at the seam. It was measured to be unreachable as the pipeline is wired,
// and deleting it without writing down WHY would have traded an untested branch for an unstated assumption.
//
// The assumption, stated: the destination is `frame_area * (target / unit)^2`, and BOTH factors are
// properties of the frame's shape rather than of its resolution --
//
//   * `target` is a band bound, so it is 540 or 720 and never grows with the input;
//   * `unit` is never a small fraction of the frame, because every anchor the pipeline can install is
//     computed FROM the frame's own size.
//
// So doubling a capture's resolution does not double what cv::resize is asked for; it leaves it identical.
// The way back into the region the ceiling described is an anchor source that names a rectangle without
// deriving it from the frame -- which is what the first case below refuses, by name.

TEST_CASE("every anchor the pipeline installs is a bounded fraction of the frame's shorter side") {
    // The three sources, and the whole list of them: FrameAnchor::intersect is what every offline producer
    // emits and what a live producer emits with no pane latched, and the two pane candidates are what the
    // latch and the crop calibration choose between. (The calibrated correction is not a fourth source: it
    // is a refinement of a candidate, structurally within a few percent of it, and it is additionally gated
    // by isCropInsideFrame.) A NEW source belongs in this list; one that cannot be added is one that does
    // not derive its rectangle from the frame, and that is exactly the case this stands guard over.
    //
    // A QUARTER is a round bound, not a tight one: the tightest ratio over this grid is 81/256 = 0.3164, the
    // two-pane candidate on a square frame (it takes 9/16 of a 16:9 box that is itself 9/16 of the frame).
    const std::vector<int> extents{1, 2, 3, 5, 8, 13, 16, 29, 30, 64, 100, 180, 404, 540, 720,
                                   736, 1080, 1280, 1920, 2160, 2560, 3440, 3840, 5120, 7680, 14000};
    for (const int width : extents) {
        for (const int height : extents) {
            const Size<int> size{width, height};
            const int shorter = std::min(width, height);
            CAPTURE(width);
            CAPTURE(height);
            CHECK(4 * FrameAnchor::intersect(size).intersection().width() >= shorter);
            CHECK(4 * pane::onePaneCandidate(size).width() >= shorter);
            CHECK(4 * pane::twoPaneCandidate(size).width() >= shorter);
        }
    }
}

// NAMED TO MATCH THE QUOTE IN cv/frame.h. resizedToUnit's comment pins the two properties that replaced the
// deleted destination-area ceiling by quoting the case names verbatim; a case renamed out from under that
// quote leaves a reader searching for a test that does not exist and concluding the assumption is untested.
TEST_CASE("resizing into the band depends on the frame's shape, not on its pixel count") {
    const Range<int> band{540, 720};

    // FRAMES ARE BUILT WITH THE PRODUCTION CONSTRUCTOR, not Frame::fixed: `Frame(mat)` derives its anchor
    // through FrameAnchor::intersect, which is the anchor source under discussion. Frame::fixed installs the
    // whole frame as the intersection by fiat, and a test written on it would keep passing after the anchor
    // source stopped deriving from the frame -- i.e. it would pass for the wrong reason.
    //
    // The same 9:16 shape at three resolutions spanning 3.5x in width and 12x in area. The destination is
    // IDENTICAL at every one of them, because the unit grows with the frame and the band caps it at the same
    // bound: this is the property that makes "a large source asks cv::resize for a large destination" false.
    //
    // ALL THREE ARE ABOVE THE SHRINK ARM'S DEAD BAND, which is what makes them comparable at all. Below it a
    // frame is forwarded at its own size, so the destination does grow with the source -- but only up to the
    // threshold, which is itself a multiple of the bound and not of the source. That is why the budget below
    // is derived from `kShrinkDeadband * band.max()` rather than from `band.max()`: 736 used to be resampled
    // to 720 and is now forwarded, and the invariant has to cover the arm it takes now.
    const Size<int> reference = Frame(solid(1080, 1920, Color(0, 0, 0))).resizedIntoBand(band).size();
    for (const int width : {1080, 1920, 3840}) {
        const int height = static_cast<int>(std::lround(width * 16.0 / 9.0));
        CAPTURE(width);
        CHECK(Frame(solid(width, height, Color(0, 0, 0))).resizedIntoBand(band).size() == reference);
    }

    // And across shapes -- the four supported forms plus the one accept-ladder rung that actually takes the
    // upscale arm -- the destination stays inside the budget the invariant above predicts:
    // `(kShrinkDeadband * band.max())^2 * 10 * (longer / shorter)`, from unit >= 0.3164 * shorter. A frame
    // inside the dead band is forwarded whole, so the widest forwarded unit is the threshold rather than the
    // bound; the square of that ratio is why the budget is 2.25x what it was before the dead band. The
    // largest destination any of these forms asks for is 4.95 Mpx (the 21:9 ultrawide, whose 810-px unit now
    // sits inside the dead band and is forwarded at 3440x1440 instead of being resampled to 2276x1280), i.e.
    // still thirteen times below the 64 000 000 px the deleted branch refused; the 6 Mpx line below states
    // that margin as a number so a regression that reintroduces a resolution-dependent destination -- which
    // would be off by a factor of the source's area, not by a fifth -- is caught even where the derived
    // bound is still satisfied.
    const std::vector<Size<int>> forms{
        {404, 718},    // the accept-ladder rung below the band: the upscale arm
        {540, 960},    // the recognizer's reference shape
        {736, 1308},   // the primary golden clip
        {1080, 2520},  // the regression-grid capture
        {1920, 1080},  // landscape / fullscreen 1080p
        {2560, 1440},  // 1440p
        {3840, 2160},  // 4K
        {3440, 1440},  // ultrawide 21:9
    };
    for (const auto &form : forms) {
        const Frame resized = Frame(solid(form.width(), form.height(), Color(0, 0, 0))).resizedIntoBand(band);
        const long long destination = static_cast<long long>(resized.size().width()) * resized.size().height();
        const long long shorter = std::min(form.width(), form.height());
        const long long longer = std::max(form.width(), form.height());
        CAPTURE(form.width());
        CAPTURE(form.height());
        const long long threshold = static_cast<long long>(band.max() * Frame::kShrinkDeadband);
        CHECK(destination * shorter <= threshold * threshold * 10LL * longer);
        CHECK(destination <= 6LL * 1000 * 1000);
    }
}

}  // namespace
}  // namespace uma
