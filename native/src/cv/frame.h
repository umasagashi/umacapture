#pragma once

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/pane_mode_latch.h"
#include "types/color.h"
#include "types/range.h"
#include "types/shape.h"
#include "util/json_util.h"
#include "util/misc.h"
#include "util/stds.h"

namespace uma {

// Internal frame helpers. A named namespace (not an anonymous one) avoids giving every translation unit its
// own internal-linkage copy of these -- and, for BGR, its own distinct type -- when frame.h is included widely.
namespace frame_impl {

struct BGR {
    uchar b;
    uchar g;
    uchar r;

    static BGR clampFrom(const Color &color) noexcept {
        return {
            static_cast<uchar>(std::clamp(color.b(), 0, 255)),
            static_cast<uchar>(std::clamp(color.g(), 0, 255)),
            static_cast<uchar>(std::clamp(color.r(), 0, 255)),
        };
    }

    [[nodiscard]] Color toColor() const { return {r, g, b}; }

    [[nodiscard]] inline int difference(const BGR &other) const {
        int d = 0;
        d += (b > other.b) ? (b - other.b) : (other.b - b);
        d += (g > other.g) ? (g - other.g) : (other.g - g);
        d += (r > other.r) ? (r - other.r) : (other.r - r);
        return d;
    }

    inline bool operator<=(const BGR &other) const { return (r <= other.r) && (g <= other.g) && (b <= other.b); }

private:
    BGR(uchar b, uchar g, uchar r) noexcept
        : b(b)
        , g(g)
        , r(r) {}
};

inline Range<BGR> asBGRRange(const Range<Color> &color_range) {
    return {
        BGR::clampFrom(color_range.min()),
        BGR::clampFrom(color_range.max()),
    };
}

inline std::vector<double> linspace(double start, double end, int num) {
    assert_(num >= 2);
    // Backstop for release builds where assert_ is a no-op: num < 2 divides by zero and writes items[-1].
    if (num < 2) {
        throw std::invalid_argument("linspace: num must be >= 2");
    }
    const auto delta = (end - start) / (num - 1);
    std::vector<double> items(num);
    for (int i = 0; i < num - 1; i++) {
        items[i] = start + delta * i;
    }
    items[num - 1] = end;
    return items;
}

}  // namespace frame_impl

using namespace frame_impl;

class FrameAnchor {
public:
    static FrameAnchor intersect(const Size<int> &frame_size) {
        const Size<double> base = base_size.cast<double>();
        const Size<double> frame = frame_size.cast<double>();
        const Size<int> intersection = {
            std::min<int>(frame_size.width(), std::lround(frame.height() * base.width() / base.height())),
            std::min<int>(frame_size.height(), std::lround(frame.width() * base.height() / base.width())),
        };
        const Size<int> margin = (frame_size - intersection) / 2;
        return {frame_size, {margin.toPoint(), (frame_size - margin).toPoint()}};
    }

    static FrameAnchor fixed(const Size<int> &size) { return {size, {{0, 0}, size.toPoint()}}; }

    static FrameAnchor fixed(const Size<int> frame_size, const Rect<int> &intersection) {
        return {frame_size, intersection};
    }

    static FrameAnchor stretched(const Size<int> &frame_size, const Size<int> &screen_size) {
        const auto screen_anchor = intersect(screen_size);
        return {
            frame_size,
            {
                screen_anchor.intersection_.topLeft(),
                screen_anchor.intersection_.bottomRight() + (frame_size - screen_size).toPoint(),
            },
        };
    }

    [[nodiscard]] inline Point<double> absolute(const Point<double> &point) const {
        return {
            point.x() + offset_h[point.anchor().h()],
            point.y() + offset_v[point.anchor().v()],
            LayoutAnchor::ScreenStart,
        };
    }

    [[nodiscard]] inline Line<double> absolute(const Line<double> &line) const {
        return {absolute(line.p1()), absolute(line.p2())};
    }

    [[nodiscard]] inline Rect<double> absolute(const Rect<double> &rect) const {
        return {absolute(rect.topLeft()), absolute(rect.bottomRight())};
    }

    [[nodiscard]] inline Point<int> expand(const Point<double> &point) const { return (point * unit_size).round(); }

    [[nodiscard]] inline Point<double> mapFromFrame(const Point<int> &point) const {
        return point.cast<double>() / unit_size;
    }

    [[nodiscard]] inline Rect<double> mapFromFrame(const Rect<int> &rect) const {
        return rect.cast<double>() / unit_size;
    }

    [[nodiscard]] inline double scaleFromPixels(int v) const { return static_cast<double>(v) / unit_size; }

    [[nodiscard]] inline int scaleToPixels(double v) const { return std::lround(v * unit_size); }

    [[nodiscard]] inline Point<int> mapToFrame(const Point<double> &point) const { return expand(absolute(point)); }

    [[nodiscard]] inline Line<int> mapToFrame(const Line<double> &line) const {
        return {mapToFrame(line.p1()), mapToFrame(line.p2())};
    }

    [[nodiscard]] inline Rect<int> mapToFrame(const Rect<double> &rect) const {
        return {mapToFrame(rect.topLeft()), mapToFrame(rect.bottomRight())};
    }

    [[nodiscard]] inline Rect<int> intersection() const { return intersection_; }

private:
    FrameAnchor(const Size<int> frame_size, const Rect<int> &intersection)
        : unit_size(intersection.width())
        , intersection_(intersection)
        , offset_h()
        , offset_v() {
        // A degenerate frame (the default/empty sentinel Frame, or a momentary 0-width capture) yields
        // unit_size == 0. Guard the reciprocal so the offset arrays stay finite (0) instead of inf/NaN; any
        // later coordinate math on such an anchor then trips the real bounds checks in bgrAt/view (a clean
        // throw) rather than feeding NaN into std::lround (undefined behavior).
        const double scale = unit_size > 0 ? 1. / unit_size : 0.;
        offset_h[ScreenStart] = 0.0;
        offset_h[ScreenLogicalEnd] = scale * frame_size.width();
        offset_h[ScreenPixelEnd] = scale * (frame_size.width() - 1);

        offset_h[IntersectStart] = scale * intersection.left();
        offset_h[IntersectLogicalEnd] = scale * intersection.right();
        offset_h[IntersectPixelEnd] = scale * (intersection.right() - 1);

        offset_v[ScreenStart] = 0;
        offset_v[ScreenLogicalEnd] = scale * frame_size.height();
        offset_v[ScreenPixelEnd] = scale * (frame_size.height() - 1);

        offset_v[IntersectStart] = scale * intersection.top();
        offset_v[IntersectLogicalEnd] = scale * intersection.bottom();
        offset_v[IntersectPixelEnd] = scale * (intersection.bottom() - 1);
    }

    int unit_size;
    std::array<double, 6> offset_h;
    std::array<double, 6> offset_v;
    Rect<int> intersection_;

    inline static Size<int> base_size = {540, 960};
};

struct FrameInfo {
    Rect<int> intersection;
    EXTENDED_JSON_TYPE_NDC(FrameInfo, intersection);
};

// A thin handle over a reference-counted cv::Mat. Copying a Frame is shallow: copies share the same pixel
// buffer (only the header/anchor are duplicated), which is why frames flow cheaply through the event queues
// across threads. Two ownership rules keep that sharing safe:
//   - Treat a Frame received from another thread as read-only. To modify it, clone() first (clone-on-write);
//     the in-place mutators (fill/paste) write through the shared buffer and would race other consumers.
//   - A producer that enqueues a Frame into the pipeline must hand over an independently owned buffer that
//     nothing else will overwrite. The live-capture producers satisfy this by allocating a fresh cv::Mat per
//     frame (cvtColor/resize outputs), so NativeApi::updateFrame forwards without cloning by design.
class Frame {
public:
    Frame()
        : image(cv::Mat())
        , timestamp_(0)
        , anchor_(FrameAnchor::fixed({0, 0})) {}

    explicit Frame(const cv::Mat &image)
        : image(image)
        , timestamp_(1)
        , anchor_(FrameAnchor::intersect(image.size())) {
        assert_(!this->image.empty());
        assert_(this->image.type() == CV_8UC3);
    }

    Frame(const cv::Mat &image, const uint64 timestamp)
        : image(image)
        , timestamp_(timestamp)
        , anchor_(FrameAnchor::intersect(image.size())) {
        assert_(!this->image.empty());
        assert_(this->image.type() == CV_8UC3);
    }

    inline static Frame fixed(const cv::Mat &image, uint64 timestamp) {
        return {image, timestamp, FrameAnchor::fixed({image.size()})};
    }

    inline static Frame fixed(const cv::Mat &image) { return fixed(image, 1); }

    inline static Frame stretched(const cv::Mat &image, uint64 timestamp, const Size<int> &screen_size) {
        return {image, timestamp, FrameAnchor::stretched({image.size()}, screen_size)};
    }

    inline static Frame stretched(const cv::Mat &image, const Size<int> &screen_size) {
        return stretched(image, 1, screen_size);
    }

    // Reads and validates a CV_8UC3 image from disk, reading the file bytes via an fstream (which opens the
    // wide path on Windows) and decoding in memory, so non-ASCII paths that cv::imread would mangle work.
    // cv::imdecode returns an empty Mat on a missing/corrupt file, and IMREAD_UNCHANGED decodes an alpha PNG
    // to CV_8UC4 or a grayscale one to CV_8UC1; the Frame ctor only asserts (a no-op in release), so fail
    // legibly here instead of constructing a Frame over an empty or wrong-channel Mat.
    [[nodiscard]] inline static cv::Mat decodeBgr(const std::filesystem::path &path) {
        std::ifstream file(path, std::ios::binary);
        if (!file) {
            throw std::runtime_error("Frame::decodeBgr: failed to open: " + path.generic_string());
        }
        const std::vector<uchar> buffer((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        const cv::Mat image = cv::imdecode(buffer, cv::IMREAD_UNCHANGED);
        if (image.empty()) {
            throw std::runtime_error("Frame::decodeBgr: failed to decode image: " + path.generic_string());
        }
        if (image.type() != CV_8UC3) {
            throw std::runtime_error("Frame::decodeBgr: image must be CV_8UC3: " + path.generic_string());
        }
        return image;
    }

    inline static Frame open(const std::filesystem::path &path) {
        std::filesystem::path info_path = path;
        info_path.replace_extension(".json");
        const auto frame_info = json_util::read(info_path);
        const auto image = decodeBgr(path);
        return {image, 1, FrameAnchor::fixed(image.size(), frame_info["intersection"].get<Rect<int>>())};
    }

    [[nodiscard]] inline bool empty() const { return image.empty(); }

    Frame(const Frame &other) noexcept = default;

    Frame &operator=(const Frame &other) noexcept = default;

    [[nodiscard]] inline Size<int> size() const { return image.size(); }

    [[nodiscard]] inline Rect<int> rect() const { return {{0, 0}, size().toPoint()}; }

    [[nodiscard]] inline int height() const { return size().height(); }

    [[nodiscard]] inline int width() const { return size().width(); }

    [[nodiscard]] inline const FrameAnchor &anchor() const { return anchor_; }

    // Carries the producer's pane-shaping decision through an asynchronous capture queue. Producers that do
    // no pane shaping leave this empty. DetailCropTracker validates a present snapshot at the actual
    // distributor-thread consumer boundary before interpreting this frame's anchor.
    [[nodiscard]] inline Frame withPaneModeSnapshot(const PaneModeLatch::Snapshot &snapshot) const {
        Frame guarded = *this;
        guarded.pane_mode_snapshot_ = snapshot;
        return guarded;
    }

    [[nodiscard]] inline const std::optional<PaneModeLatch::Snapshot> &paneModeSnapshot() const {
        return pane_mode_snapshot_;
    }

    [[nodiscard]] bool isIn(const Range<Color> &color_range, const Point<double> &point) const {
        return color_range.contains(colorAt(point));
    }

    [[nodiscard]] bool isIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<double> &mapped_line = anchor_.mapToFrame(line).cast<double>();

        // Sample at least the two endpoints; see isAllIn for the rationale (linspace is undefined below 2).
        const int samples = std::max(2, (int) mapped_line.length());
        return stds::any_of(linspace(0., 1., samples), [&](const auto &ratio) {
            const auto &p = mapped_line.pointAt(ratio).round();
            return bgr_range.contains(bgrAt(p.x(), p.y()));
        });
    }

    [[nodiscard]] bool isAllIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<double> &mapped_line = anchor_.mapToFrame(line).cast<double>();

        // Sample at least the two endpoints. linspace asserts num >= 2 (and writes out of bounds at num == 0, a
        // no-op assert in release), and an all_of over an empty/single-point range would report "all in" without
        // actually scanning the line. Clamping keeps a short or steeply-foreshortened line from passing vacuously.
        const int samples = std::max(2, (int) mapped_line.length());
        return stds::all_of(linspace(0., 1., samples), [&](const auto &ratio) {
            const auto &p = mapped_line.pointAt(ratio).round();
            return bgr_range.contains(bgrAt(p.x(), p.y()));
        });
    }

    // Fraction of the sampled points along `line` whose colour falls in `color_range` (0-1). Mirrors isAllIn's
    // sampling (>= 2 points, one per pixel of length) but reports the ratio instead of a hard all/any, so a
    // caller can accept a band that is *mostly* one colour (e.g. a solid section header row) while rejecting a
    // narrow stray run of the same colour.
    [[nodiscard]] double fractionIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<double> &mapped_line = anchor_.mapToFrame(line).cast<double>();

        const int samples = std::max(2, (int) mapped_line.length());
        int inside = 0;
        for (const auto &ratio : linspace(0., 1., samples)) {
            const auto &p = mapped_line.pointAt(ratio).round();
            if (bgr_range.contains(bgrAt(p.x(), p.y()))) {
                inside++;
            }
        }
        return static_cast<double>(inside) / samples;
    }

    [[nodiscard]] std::optional<double> lengthIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<double> &mapped_line = anchor_.mapToFrame(line).cast<double>();

        // Sample at least the two endpoints; see isAllIn for the rationale (linspace is undefined below 2).
        const int samples = std::max(2, (int) mapped_line.length());
        std::optional<double> length = std::nullopt;
        for (const auto &ratio : linspace(0., 1., samples)) {
            const auto &p = mapped_line.pointAt(ratio).round();
            if (bgr_range.contains(bgrAt(p.x(), p.y()))) {
                length = ratio;
            } else {
                break;
            }
        }
        return length;
    }

    // Per-pixel difference statistics over `rect`, gated at `threshold`: a pixel is "changed" when its
    // per-pixel BGR difference (0-765) exceeds the threshold. Reports how *many* pixels changed (ratio),
    // so a caller can key off a broad-area change rather than a magnitude sum that a few large-delta
    // pixels can dominate.
    //
    // This is the only area-difference primitive in Frame. A sum-of-gated-distances sibling
    // (`pixelDifference`) used to sit here for the stationary latch; it was removed when the latch moved to
    // ratio(), because two rival difference conventions in one class invite exactly the confusion that made
    // the latch's absolute budget mean three different things at its three different rects (the census is in
    // chara_detail_scene_scraper.h, on StationaryFrameCatcher).
    struct DiffStats {
        uint64 changed = 0;  // pixels whose per-pixel diff exceeds the threshold
        uint64 total = 0;  // pixels examined

        // Fraction of examined pixels that changed (0-1).
        [[nodiscard]] double ratio() const { return total == 0 ? 0.0 : static_cast<double>(changed) / total; }
    };

    // Precondition: `other` shares this frame's anchor family (same construction path), so `rect` maps to the
    // same pixels in both. In general anchor is NOT a pure function of pixel size -- fixed()/stretched() frames
    // of equal size can have different anchors -- so the size check below is a proxy, not a full guarantee. It
    // holds because every caller diffs two live-capture frames (both intersect()-anchored), where equal size
    // does imply an equal anchor. Do not pass a mix of construction paths (e.g. a fixed()-derived stitched
    // frame against a live one): it would silently compare mismatched regions.
    [[nodiscard]] DiffStats diffStats(const Frame &other, const Rect<double> &rect, int threshold) const {
        // Both frames are indexed over the same rect; a size mismatch (e.g. a capture resolution change between
        // frames) would read out of bounds on the smaller image in release, where the assert is compiled out.
        if (this->size() != other.size()) {
            throw std::invalid_argument("diffStats: frame sizes do not match");
        }
        const auto mapped_rect = clampedMappedRect(rect);
        DiffStats stats;
        for (int y = mapped_rect.top(); y < mapped_rect.bottom(); y++) {
            for (int x = mapped_rect.left(); x < mapped_rect.right(); x++) {
                stats.total++;
                if (bgrAt(x, y).difference(other.bgrAt(x, y)) > threshold) {
                    stats.changed++;
                }
            }
        }
        return stats;
    }

    [[nodiscard]] inline Color colorAt(const Point<double> &point) const {
        const auto &p = anchor_.mapToFrame(point);
        return colorAt(p.x(), p.y());
    }

    [[nodiscard]] inline const cv::Mat &data() const { return image; }

    [[nodiscard]] inline uint64 timestamp() const { return timestamp_; }

    [[nodiscard]] inline Frame copy(const Rect<double> &rect) const { return view(rect).clone(); }

    [[nodiscard]] inline Frame view(const Rect<double> &rect) const {
        const auto &r = anchor_.mapToFrame(rect);
        return view(r.left(), r.top(), r.width(), r.height());
    }

    // Pixel-space counterpart to the normalized view above. The returned ROI has a fixed, full local anchor;
    // callers that retain it beyond the source buffer's lifetime must clone it.
    [[nodiscard]] inline Frame viewPixels(const Rect<int> &rect) const {
        return view(rect.left(), rect.top(), rect.width(), rect.height());
    }

    [[nodiscard]] inline Frame clone() const {
        Frame cloned{image.clone(), timestamp_, anchor_};
        cloned.pane_mode_snapshot_ = pane_mode_snapshot_;
        return cloned;
    }

    // A copy of this frame carrying an EXPLICIT intersection instead of the aspect-ratio guess the public
    // constructors derive (FrameAnchor::intersect). Shallow like any other Frame copy: only the anchor
    // differs, the pixel buffer is shared. Used by the detail-crop auto-calibration to re-anchor the live
    // stream onto the game's measured client rect; every downstream stage maps through frame.anchor(), so
    // the correction reaches the condition tree, the scraper and the recognizer without further plumbing.
    // The CALLER owns the containment check (see isCropInsideFrame in cv/detail_crop_tracker.h): an
    // intersection reaching outside the image makes the coordinate math below throw from bgrAt/view.
    [[nodiscard]] inline Frame reanchored(const Rect<int> &intersection) const {
        return {image, timestamp_, FrameAnchor::fixed(size(), intersection)};
    }

    // How far the frame's own unit may sit from a requested one before the resize is skipped as not worth
    // paying for: resizing over a negligible difference only blurs the image. The 3 px is inherited verbatim
    // from the Windows runner's original force-resize; what changed is the QUANTITY it measures (see
    // resizedToUnit). Public so the tests can pin the number and the behaviour to the same constant.
    static constexpr int kUnitTolerance = 3;

    // A copy of this frame rescaled so its anchor UNIT -- the intersection WIDTH, the single number every
    // normalized coordinate is multiplied by -- becomes exactly `unit` pixels. This is the pure seam behind
    // the "normalize the recognized image size" setting; it owns both halves of the operation (the pixel
    // resize and the matching intersection transform) so neither can drift from the other.
    //
    // ONE ISOTROPIC FACTOR. The scale is `unit / intersection.width()`, applied to both axes, because
    // FrameAnchor normalizes x AND y by the intersection width (see its unit_size). Scaling the axes
    // independently would leave the horizontal coordinates right and silently multiply every vertical one by
    // sy/sx. So the postcondition is "the unit is exactly `unit`", NOT "the frame is `unit` wide": the frame
    // keeps its own aspect ratio, and the intersection keeps its relative place inside it.
    //
    // Every edge is ROUNDED, never rounded up. `ceil` looks like the safe choice for the destination size
    // (it cannot lose a source pixel) but it is not: `frame_width * (unit / source_width)` is mathematically
    // exactly `unit` when the two widths are equal, yet in double precision e.g. 532 * (540.0/532) evaluates
    // to 540.0000000000001, so ceil yields 541 -- a 541-px image whose unit is pinned to 540, i.e. content
    // stretched one column wider than the coordinate system that addresses it. Rounding cannot overshoot that
    // way, and cannot undershoot either: the frame is never narrower than its own intersection, so
    // lround(frame_width * scale) >= unit always holds and nothing can overhang.
    //
    // The intersection's width is then pinned to `unit` (defensive: lround(source_width * scale) provably
    // equals it, so this is belt-and-braces rather than a distinct behaviour) and the other three edges are
    // clamped back inside the destination image, so the result still satisfies isCropInsideFrame
    // (cv/detail_crop_tracker.h) -- a single pixel of overhang would make every probe throw from bgrAt.
    //
    // Returns *this when the frame's unit is already within kUnitTolerance of the target, or when the input is
    // degenerate. Total: it never throws for any constructible Frame, and the postcondition is unconditional --
    // for any non-degenerate input the resulting unit IS `unit`, with no third outcome a caller has to allow for.
    //
    // NO DESTINATION-AREA CEILING, DELIBERATELY. There used to be one here (`destination area > 64e6 -> return
    // *this`, born with this function). It was untested, unlogged and indistinguishable from success at the
    // seam, and it was measured to be unreachable as the pipeline is wired: the band is consulted only for a
    // frame the condition tree already matched, and a frame extreme enough to reach the ceiling cannot get
    // there. Deleting it would have traded an untested branch for an unstated assumption, so the assumption is
    // written down instead -- as two properties, both pinned by name in test/cv/test_frame.cpp:
    //
    //   1. THE DESTINATION DEPENDS ON THE FRAME'S SHAPE, NOT ON ITS PIXEL COUNT. The destination area is
    //      `frame_area * (unit / W)^2`; scaling a frame and its intersection together leaves it unchanged. So
    //      no source resolution, however large, can make the destination large -- only an absurd aspect ratio
    //      could. ("resizing into the band depends on the frame's shape, not on its pixel count")
    //   2. W IS NEVER A SMALL FRACTION OF THE FRAME. Every anchor the pipeline installs is derived from the
    //      frame's own size -- FrameAnchor::intersect and the two candidates in cv/pane_mode.h -- so a tiny
    //      rectangle inside a huge frame is not constructible. ("every anchor the pipeline installs is a
    //      bounded fraction of the frame's shorter side")
    //
    // The way back into the region is an anchor source that names a rectangle WITHOUT deriving it from the
    // frame's geometry; that is exactly what property 2 refuses, by name, rather than leaving it to a constant.
    [[nodiscard]] inline Frame resizedToUnit(int unit) const {
        const Rect<int> source = anchor_.intersection();
        if (unit <= 0 || image.empty() || source.width() <= 0 || source.height() <= 0) {
            return *this;
        }
        // MEASURED ON THE UNIT, not on the frame. This tolerance used to compare the destination SIZE with
        // the current one (`target.difference_max(size()) <= 3`), which spends the same 3 px budget on
        // whichever of the two axes moves most -- and the frame is scaled by `unit / intersection.width()`,
        // so a one-pixel change of the unit becomes `frame_height / intersection_width` pixels of frame. For
        // the portrait phone captures this project actually reads, that ratio is 2.3 to 4.7, so the
        // "negligible difference" the tolerance was written to skip shrank to a fraction of a pixel of unit
        // and varied with the frame's aspect ratio -- i.e. the protection was quietly not delivered for the
        // material it exists for. The unit is the quantity the caller asks for and the only one every
        // normalized coordinate is divided by, so it is the quantity the tolerance belongs to.
        const int unit_difference = unit > source.width() ? unit - source.width() : source.width() - unit;
        if (unit_difference <= kUnitTolerance) {
            return *this;
        }
        const double scale = static_cast<double>(unit) / source.width();
        const Size<int> target{
            static_cast<int>(std::lround(size().width() * scale)),
            static_cast<int>(std::lround(size().height() * scale)),
        };
        if (target.width() <= 0 || target.height() <= 0) {
            return *this;
        }
        cv::Mat resized;
        cv::resize(image, resized, target.toCVSize(), 0, 0, cv::INTER_LINEAR);
        const int width = std::min(unit, target.width());
        const int height = std::clamp(static_cast<int>(std::lround(source.height() * scale)), 1, target.height());
        const int left = std::clamp(static_cast<int>(std::lround(source.left() * scale)), 0, target.width() - width);
        const int top = std::clamp(static_cast<int>(std::lround(source.top() * scale)), 0, target.height() - height);
        return {resized, timestamp_, FrameAnchor::fixed(target, {{left, top}, Size<int>{width, height}})};
    }

    // The band form of the transform above, and the form the pipeline actually configures: resize this
    // frame's anchor unit TOWARDS `band` -- scale UP to the lower bound when the unit is below it, scale DOWN
    // to the upper bound once the unit reaches kShrinkDeadband times that bound, and forward the frame
    // untouched anywhere else. TOWARDS, not INTO: the untouched arm covers everything from the lower bound up
    // to the shrink arm's fire point, so a frame somewhat above the upper bound is forwarded ABOVE the band.
    // That gap is deliberate and the paragraph on asymmetry below says why.
    //
    // THE DECISION LIVES HERE, WITH THE FRAME, and not at the pipeline's construction site, because it is
    // not resolvable there: which bound applies -- and whether either does -- is a function of this frame's
    // own intersection width, which the crop calibration can change from one frame to the next. Handing the
    // pipeline a band rather than a unit is what keeps that a property of the frame instead of a snapshot
    // taken once when the capture session started.
    //
    // Scaling UP is deliberate, not an accident of the lower bound: a small window is normalized up to the
    // recognizer's reference width rather than recognized at a width no model was trained near. It is not
    // clamped by any allocation ceiling; see resizedToUnit for the anchor invariant that bounds it instead.
    //
    // THE TWO ARMS ARE ASYMMETRIC ON PURPOSE, and the dead band below is why. The lower bound exists for
    // ACCURACY -- 540 is the recognizer's reference width, and no model has been trained near a width below
    // it -- so every frame under it is normalized, however small the correction. The upper bound exists for
    // COST: shrinking buys back downstream work, and a resample that shrinks by a few percent costs a full
    // pass over the frame to buy back a few percent of the stages behind it. So the shrink arm only fires
    // once the frame is a long way above the bound, and the lower arm has no dead band at all.
    [[nodiscard]] inline Frame resizedIntoBand(const Range<int> &band) const {
        const int unit = anchor_.intersection().width();
        if (unit < band.min()) {
            return resizedToUnit(band.min());
        }
        if (isWorthShrinkingTo(unit, band.max())) {
            return resizedToUnit(band.max());
        }
        return *this;
    }

    // The shrink arm's DEAD BAND, as a MULTIPLE of the band's upper bound rather than as an absolute width.
    //
    // A ratio, because the quantity that decides whether a shrink pays for itself is the ratio: the resample
    // costs one pass over the source and buys back `1 - (max/unit)^2` of the per-frame work behind it, and
    // that saving is a function of `unit / max` alone. An absolute threshold would say nothing about the
    // trade at any other bound, and would have to be re-derived -- silently, by whoever next moves the bound.
    //
    // ==> IF THE BAND'S UPPER BOUND MOVES, THIS THRESHOLD MOVES WITH IT: the shrink arm always fires at
    //     `max_unit * kShrinkDeadband`, so raising the bound to 900 raises the fire point to 1350.
    //
    // 1.5 is a chosen operating point, NOT an optimum, and it is deliberately not a config key. The band's
    // whole job is to stop the per-frame cost growing without limit on a high-resolution capture; the exact
    // point at which it starts is not a quantity this project has, or needs, an answer for, and no input in
    // the supported range fails differently on either side of it. A key would therefore add a way to get the
    // pipeline into a state nothing tests, in exchange for a number nobody can derive. Two facts place it:
    // it is above the measured cost cross-over on both reference platforms (so neither loses by waiting),
    // and 1080 -- what it resolves to at the shipped 720 bound -- is a standard phone-recording width, so
    // the captures the band exists for still take the shrink arm.
    static constexpr double kShrinkDeadband = 1.5;

    // `>=`, so a unit landing EXACTLY on the threshold shrinks. That edge is not academic: at the shipped
    // 720 bound it is 1080, i.e. the width of an ordinary phone screen recording, and those are the captures
    // the upper bound exists to hold down. Pinned at 1079/1080/1081 in test/cv/test_frame.cpp.
    [[nodiscard]] static constexpr bool isWorthShrinkingTo(int unit, int max_unit) {
        return unit >= max_unit * kShrinkDeadband;
    }

    // In-place mutator: writes through the shared cv::Mat buffer. Used deliberately to write to a parent
    // through a view (e.g. canvas.view(rect).fill(...)). See the class doc for the shared-buffer ownership
    // contract (clone before mutating a Frame that another thread may be reading).
    void fill(const Rect<double> &rect, const Color &color) {
        const auto &r = anchor_.mapToFrame(rect);
        cv::rectangle(image, r.toCVRect(), color.toCVScalar(), cv::FILLED);
    }

    // In-place mutator; see fill() for the shared-buffer ownership contract.
    void paste(const Rect<double> &rect, const Frame &source) {
        const auto &dest_rect = anchor_.mapToFrame(rect);
        // Real bounds check (mirrors view()): image(cvRect) with a ROI past the edge, or a negative-size rect,
        // throws a raw cv::Exception. Throw std::out_of_range instead so it degrades via the same path as
        // bgrAt/view (a dropped record through the recognizer/scraper try/catch).
        if (dest_rect.left() < 0 || dest_rect.top() < 0 || dest_rect.width() < 0 || dest_rect.height() < 0
            || dest_rect.right() > image.cols || dest_rect.bottom() > image.rows) {
            throw std::out_of_range("Frame::paste out of bounds");
        }
        cv::Mat mat;
        if (dest_rect.size() == source.size()) {
            // Same-size fast path shares the source header. If the source aliases THIS image's allocation, a
            // copyTo between overlapping regions of one buffer is undefined; clone the source in that case.
            mat = (source.image.u == image.u) ? source.image.clone() : source.image;
        } else {
            cv::resize(source.image, mat, dest_rect.size().toCVSize(), 0, 0, cv::INTER_LINEAR);
        }
        mat.copyTo(image(dest_rect.toCVRect()));
    }

    void save(const std::filesystem::path &path) const {
        // Encode in memory (format chosen by the extension) and write the bytes via an fstream (which opens the
        // wide path on Windows), so non-ASCII paths that cv::imwrite would mangle work. cv::imencode returns
        // false (without throwing) on an unknown format, and the fstream surfaces write failures; fail fast at
        // the write site so a missing fragment is reported here, not later on another thread when the stitcher
        // tries to read it back.
        std::vector<uchar> buffer;
        if (!cv::imencode(path.extension().string(), image, buffer)) {
            throw std::runtime_error("failed to encode image: " + path.generic_string());
        }
        std::ofstream file(path, std::ios::binary);
        if (!file) {
            throw std::runtime_error("failed to open image for write: " + path.generic_string());
        }
        file.write(reinterpret_cast<const char *>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
        file.flush();
        if (!file) {
            throw std::runtime_error("failed to write image: " + path.generic_string());
        }
    }

    void dump(const std::filesystem::path &path) const {
        save(path);
        std::filesystem::path info_path = path;
        info_path.replace_extension(".json");
        json_util::write(info_path, FrameInfo{anchor().intersection()}, 4);
    }

private:
    Frame(const cv::Mat &image, uint64 timestamp, const FrameAnchor &anchor)
        : image(image)
        , timestamp_(timestamp)
        , anchor_(anchor) {
        assert_(!this->image.empty());
        assert_(this->image.type() == CV_8UC3);
    }

    [[nodiscard]] inline Color colorAt(int x, int y) const { return bgrAt(x, y).toColor(); }

    [[nodiscard]] inline const BGR &bgrAt(int x, int y) const {
        // Real bounds check (not a Debug-only assert): an out-of-range access is undefined behavior in
        // release. Throwing degrades to a dropped record via the recognizer/scraper try/catch.
        if (y < 0 || y >= image.rows || x < 0 || x >= image.cols) {
            throw std::out_of_range("Frame::bgrAt out of bounds");
        }
        return image.ptr<BGR>(y)[x];
    }

    [[nodiscard]] inline Frame view(int x, int y, int width, int height) const {
        // Real bounds check (not a Debug-only assert): a ROI past the image edge is undefined behavior in
        // release. Throwing degrades to a dropped record via the recognizer/scraper try/catch.
        if (x < 0 || y < 0 || width < 0 || height < 0 || (x + width) > image.cols || (y + height) > image.rows) {
            throw std::out_of_range("Frame::view out of bounds");
        }
        return fixed(image({x, y, width, height}), timestamp_);
    }

    // Maps `rect` (normalized coordinates) to frame pixels and clips it to the image bounds. An empty rect
    // means "the whole frame". Used by the area metric (diffStats): a rect that reaches past
    // the frame edge should clip to the valid region, not throw mid-loop through bgrAt.
    [[nodiscard]] inline Rect<int> clampedMappedRect(const Rect<double> &rect) const {
        if (rect.empty()) {
            return this->rect();
        }
        const auto &mapped = anchor_.mapToFrame(rect);
        const int left = std::clamp(mapped.left(), 0, image.cols);
        const int top = std::clamp(mapped.top(), 0, image.rows);
        const int right = std::clamp(mapped.right(), left, image.cols);
        const int bottom = std::clamp(mapped.bottom(), top, image.rows);
        return {{left, top}, Point<int>{right, bottom}};
    }

    cv::Mat image;
    uint64 timestamp_;
    FrameAnchor anchor_;
    std::optional<PaneModeLatch::Snapshot> pane_mode_snapshot_;
};

}  // namespace uma
