#pragma once

#include <filesystem>
#include <utility>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

#include "types/color.h"
#include "types/range.h"
#include "util/common.h"
#include "util/json_utils.h"

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

class FrameAnchor {
public:
    static FrameAnchor intersect(const Size<int> &size) {
        Size<int> intersection = {
            std::min(size.width(), size.height() * constant::base_size.width() / constant::base_size.height()),
            std::min(size.height(), size.width() * constant::base_size.height() / constant::base_size.width()),
        };
        const Size<int> margin = (size - intersection) / 2;
        return {size, {margin.toPoint(), (size - margin).toPoint()}};
    }

    static FrameAnchor fixed(const Size<int> &size) { return {size, {{0, 0}, size.toPoint()}}; }

    [[nodiscard]] inline Point<int> absolute(const Point<double> &point) const {
        return Point<int>{
            std::lround(point.x() * scale) + offset_h[point.anchor().h()],
            std::lround(point.y() * scale) + offset_v[point.anchor().v()],
            LayoutAnchor::ScreenStart,
        };
    }

private:
    FrameAnchor(const Size<int> frame_size, const Rect<int> &intersection)
        : scale(intersection.width())
        , offset_h()
        , offset_v() {
        offset_h[LayoutAnchor::ScreenStart] = 0;
        offset_h[LayoutAnchor::ScreenEnd] = frame_size.width();
        offset_h[LayoutAnchor::IntersectStart] = intersection.left();
        offset_h[LayoutAnchor::IntersectEnd] = intersection.right();

        offset_v[LayoutAnchor::ScreenStart] = 0;
        offset_v[LayoutAnchor::ScreenEnd] = frame_size.height();
        offset_v[LayoutAnchor::IntersectStart] = intersection.top();
        offset_v[LayoutAnchor::IntersectEnd] = intersection.bottom();
    }

    double scale;
    std::array<int, 4> offset_h;
    std::array<int, 4> offset_v;
};

std::vector<double> linspace(double start, double end, int num) {
    assert(num >= 2);
    const auto delta = (end - start) / (num - 1);
    std::vector<double> items(num);
    for (int i = 0; i < num - 1; i++) {
        items[i] = start + delta * i;
    }
    items[num - 1] = end;
    return items;
}

}  // namespace

class Frame {
public:
    Frame(const cv::Mat &image, uint64 timestamp)
        : image(image)
        , timestamp_(timestamp)
        , anchor(FrameAnchor::intersect(image.size())) {
        assert(!this->image.empty());
        assert(this->image.type() == CV_8UC3);
        assert(this->image.channels() == 3);
        assert(this->image.depth() == CV_8U);
        assert(this->image.elemSize() == 3);
        assert(this->image.elemSize1() == 1);
        assert(this->image.isContinuous());
    }

    Frame(const cv::Mat &image, uint64 timestamp, const FrameAnchor &anchor)
        : image(image)
        , timestamp_(timestamp)
        , anchor(anchor) {
        assert(!this->image.empty());
        assert(this->image.type() == CV_8UC3);
        assert(this->image.channels() == 3);
        assert(this->image.depth() == CV_8U);
        assert(this->image.elemSize() == 3);
        assert(this->image.elemSize1() == 1);
        //        assert(this->image.isContinuous());
    }

    Frame()
        : image(cv::Mat())
        , timestamp_(0)
        , anchor(FrameAnchor::fixed({0, 0})) {}

    [[nodiscard]] inline bool empty() const { return image.empty(); }

    Frame(const Frame &other) noexcept = default;

    Frame &operator=(const Frame &other) noexcept = default;

    [[nodiscard]] inline Size<int> size() const { return image.size(); }

    [[nodiscard]] inline Rect<int> rect() const { return {{0, 0}, size().toPoint()}; }

    [[nodiscard]] inline int height() const { return size().height(); }

    [[nodiscard]] inline int width() const { return size().width(); }

    [[nodiscard]] inline double scale() const { return 1. / width(); }

    [[nodiscard]] bool isIn(const Range<Color> &color_range, const Point<double> &point) const {
        return color_range.contains(colorAt(point));
    }

    [[nodiscard]] std::optional<double> lengthIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<int> &absolute_line = absolute(line);

        std::optional<double> length = std::nullopt;
        for (const auto &ratio : linspace(0., 1., (int) absolute_line.length())) {
            const auto &p = absolute_line.pointAt(ratio);
            if (bgr_range.contains(bgrAt(p.x(), p.y()))) {
                length = ratio;
            } else {
                break;
            }
        }
        return length;
    }

    [[nodiscard]] uint64 pixelDifference(const Frame &other, const Rect<double> &rect) const {
        assert(this->size() == other.size());
        const auto &r = rect.empty() ? this->rect() : absolute(rect);
        uint64 d = 0;
        for (int y = r.top(); y < r.bottom(); y++) {
            for (int x = r.left(); x < r.right(); x++) {
                const auto &a = bgrAt(x, y);
                const auto &b = other.bgrAt(x, y);
                d += a.difference(b);
            }
        }
        return d;
    }

    [[nodiscard]] inline Color colorAt(const Point<double> &point) const {
        const auto &p = absolute(point);
        return colorAt(p.x(), p.y());
    }

    [[nodiscard]] inline const cv::Mat &data() const { return image; }
    [[nodiscard]] inline uint64 timestamp() const { return timestamp_; }

    [[nodiscard]] inline Frame view(const Rect<double> &rect) const {
        const auto &r = absolute(rect);
        return view(r.left(), r.top(), r.width(), r.height());
    }

    [[nodiscard]] inline Frame clone() const { return {image.clone(), timestamp_, anchor}; }

    void save(const std::filesystem::path &path) const { cv::imwrite(path.generic_string(), image); }

private:
    [[nodiscard]] inline Line<int> absolute(const Line<double> &line) const {
        return {absolute(line.p1()), absolute(line.p2())};
    }

    [[nodiscard]] inline Rect<int> absolute(const Rect<double> &rect) const {
        return {absolute(rect.top_left()), absolute(rect.bottom_right())};
    }

    [[nodiscard]] inline Point<int> absolute(const Point<double> &point) const { return anchor.absolute(point); }

    [[nodiscard]] inline Color colorAt(int x, int y) const { return bgrAt(x, y).toColor(); }
    [[nodiscard]] inline const BGR &bgrAt(int x, int y) const {
        assert(0 <= y && y < image.size().height);
        assert(0 <= x && x < image.size().width);
        return image.ptr<BGR>(y)[x];
    }

    [[nodiscard]] inline Frame view(int x, int y, int width, int height) const {
        assert(0 <= y && (y + height) < image.size().height);
        assert(0 <= x && (x + width) < image.size().width);
        return {image({x, y, width, height}), timestamp_, FrameAnchor::fixed({width, height})};
    }

    cv::Mat image;
    uint64 timestamp_;
    FrameAnchor anchor;
};
