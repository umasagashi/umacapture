#pragma once

#include <filesystem>
#include <utility>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

#include "types/color.h"
#include "types/range.h"
#include "types/shape.h"
#include "util/common.h"
#include "util/json_utils.h"
#include "util/stds.h"

namespace {

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
    BGR(uchar b, uchar g, uchar r)
    noexcept
        : b(b)
        , g(g)
        , r(r) {}
};

Range<BGR> asBGRRange(const Range<Color> &color_range) {
    return {
        BGR::clampFrom(color_range.min()),
        BGR::clampFrom(color_range.max()),
    };
}

std::vector<double> linspace(double start, double end, int num) {
    assert_(num >= 2);
    const auto delta = (end - start) / (num - 1);
    std::vector<double> items(num);
    for (int i = 0; i < num - 1; i++) {
        items[i] = start + delta * i;
    }
    items[num - 1] = end;
    return items;
}

}  // namespace

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

    [[nodiscard]] inline Point<int> expand(const Point<double> &point) const { return (point * unit_size).round(); }

    [[nodiscard]] inline Point<double> shrink(const Point<int> &point) const {
        return point.cast<double>() / unit_size;
    }

    [[nodiscard]] inline Point<int> mapToFrame(const Point<double> &point) const { return expand(absolute(point)); }

    [[nodiscard]] inline Line<int> mapToFrame(const Line<double> &line) const {
        return {mapToFrame(line.p1()), mapToFrame(line.p2())};
    }

    [[nodiscard]] inline Rect<int> mapToFrame(const Rect<double> &rect) const {
        return {mapToFrame(rect.topLeft()), mapToFrame(rect.bottomRight())};
    }

    [[nodiscard]] static Size<int> baseSize() { return base_size; }

    static void setBaseSize(const Size<int> &size) { base_size = size; }

private:
    FrameAnchor(const Size<int> frame_size, const Rect<int> &intersection)
        : unit_size(intersection.width())
        , offset_h()
        , offset_v() {
        const double scale = 1. / unit_size;
        offset_h[LayoutAnchor::ScreenStart] = 0.0;
        offset_h[LayoutAnchor::ScreenEnd] = scale * (frame_size.width() - 1);
        offset_h[LayoutAnchor::IntersectStart] = scale * intersection.left();
        offset_h[LayoutAnchor::IntersectEnd] = scale * (intersection.right() - 1);

        offset_v[LayoutAnchor::ScreenStart] = 0;
        offset_v[LayoutAnchor::ScreenEnd] = scale * (frame_size.height() - 1);
        offset_v[LayoutAnchor::IntersectStart] = scale * intersection.top();
        offset_v[LayoutAnchor::IntersectEnd] = scale * (intersection.bottom() - 1);
    }

    int unit_size;
    std::array<double, 4> offset_h;
    std::array<double, 4> offset_v;

    inline static Size<int> base_size = {540, 960};
};

class Frame {
public:
    Frame(const cv::Mat &image, uint64 timestamp)
        : image(image)
        , timestamp_(timestamp)
        , anchor_(FrameAnchor::intersect(image.size())) {
        assert_(!this->image.empty());
        assert_(this->image.type() == CV_8UC3);
        assert_(this->image.channels() == 3);
        assert_(this->image.depth() == CV_8U);
        assert_(this->image.elemSize() == 3);
        assert_(this->image.elemSize1() == 1);
        assert_(this->image.isContinuous());
    }

    Frame(const cv::Mat &image, uint64 timestamp, const FrameAnchor &anchor)
        : image(image)
        , timestamp_(timestamp)
        , anchor_(anchor) {
        assert_(!this->image.empty());
        assert_(this->image.type() == CV_8UC3);
        assert_(this->image.channels() == 3);
        assert_(this->image.depth() == CV_8U);
        assert_(this->image.elemSize() == 3);
        assert_(this->image.elemSize1() == 1);
    }

    Frame()
        : image(cv::Mat())
        , timestamp_(0)
        , anchor_(FrameAnchor::fixed({0, 0})) {}

    [[nodiscard]] inline bool empty() const { return image.empty(); }

    Frame(const Frame &other) noexcept = default;

    Frame &operator=(const Frame &other) noexcept = default;

    [[nodiscard]] inline Size<int> size() const { return image.size(); }

    [[nodiscard]] inline Rect<int> rect() const { return {{0, 0}, size().toPoint()}; }

    [[nodiscard]] inline int height() const { return size().height(); }

    [[nodiscard]] inline int width() const { return size().width(); }

    [[nodiscard]] inline const FrameAnchor &anchor() const { return anchor_; }

    [[nodiscard]] bool isIn(const Range<Color> &color_range, const Point<double> &point) const {
        return color_range.contains(colorAt(point));
    }

    [[nodiscard]] bool isIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<double> &mapped_line = anchor_.mapToFrame(line).cast<double>();

        return stds::any_of(linspace(0., 1., (int) mapped_line.length()), [&](const auto &ratio) {
            const auto &p = mapped_line.pointAt(ratio).round();
            return bgr_range.contains(bgrAt(p.x(), p.y()));
        });
    }

    [[nodiscard]] std::optional<double> lengthIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<double> &mapped_line = anchor_.mapToFrame(line).cast<double>();

        std::optional<double> length = std::nullopt;
        for (const auto &ratio : linspace(0., 1., (int) mapped_line.length())) {
            const auto &p = mapped_line.pointAt(ratio).round();
            if (bgr_range.contains(bgrAt(p.x(), p.y()))) {
                length = ratio;
            } else {
                break;
            }
        }
        return length;
    }

    [[nodiscard]] uint64 pixelDifference(const Frame &other, const Rect<double> &rect, int ignore_threshold) const {
        assert_(this->size() == other.size());
        const auto &mapped_rect = rect.empty() ? this->rect() : anchor_.mapToFrame(rect);
        uint64 total = 0;
        for (int y = mapped_rect.top(); y < mapped_rect.bottom(); y++) {
            for (int x = mapped_rect.left(); x < mapped_rect.right(); x++) {
                const auto &a = bgrAt(x, y);
                const auto &b = other.bgrAt(x, y);
                const auto d = a.difference(b);
                if (d > ignore_threshold) {
                    total += d;
                }
            }
        }
        return total;
    }

    [[nodiscard]] inline Color colorAt(const Point<double> &point) const {
        const auto &p = anchor_.mapToFrame(point);
        return colorAt(p.x(), p.y());
    }

    [[nodiscard]] inline const cv::Mat &data() const { return image; }

    [[nodiscard]] inline uint64 timestamp() const { return timestamp_; }

    [[nodiscard]] inline Frame copy(const Rect<double> &rect) const {
        const auto &r = anchor_.mapToFrame(rect);
        return copy(r.left(), r.top(), r.width(), r.height());
    }

    void save(const std::filesystem::path &path) const { cv::imwrite(path.generic_string(), image); }

private:
    [[nodiscard]] inline Color colorAt(int x, int y) const { return bgrAt(x, y).toColor(); }

    [[nodiscard]] inline const BGR &bgrAt(int x, int y) const {
        assert_(0 <= y && y < image.size().height);
        assert_(0 <= x && x < image.size().width);
        return image.ptr<BGR>(y)[x];
    }

    [[nodiscard]] inline Frame copy(int x, int y, int width, int height) const {
        assert_(0 <= y && (y + height) <= image.size().height);
        assert_(0 <= x && (x + width) <= image.size().width);
        return {image({x, y, width, height}).clone(), timestamp_, FrameAnchor::fixed({width, height})};
    }

    cv::Mat image;
    uint64 timestamp_;
    FrameAnchor anchor_;
};
