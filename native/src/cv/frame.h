#pragma once

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

    explicit BGR(const Color &color) noexcept
        : b(static_cast<uchar>(std::clamp(color.b(), 0, 255)))
        , g(static_cast<uchar>(std::clamp(color.g(), 0, 255)))
        , r(static_cast<uchar>(std::clamp(color.r(), 0, 255))) {}

    [[nodiscard]] Color toColor() const { return {r, g, b}; }

    inline bool operator<=(const BGR &other) const { return (r <= other.r) && (g <= other.g) && (b <= other.b); }
};

Range<BGR> asBGRRange(const Range<Color> &color_range) {
    return {
        BGR(color_range.min()),
        BGR(color_range.max()),
    };
}

class FrameAnchor {
public:
    static FrameAnchor create(const Size<int> &size) {
        Size<int> intersection = {
            std::min(size.width(), size.height() * constant::base_size.width() / constant::base_size.height()),
            std::min(size.height(), size.width() * constant::base_size.height() / constant::base_size.width()),
        };
        Size<int> margin = (size - intersection) / 2;
        std::array<int, 4> offset_h{};
        std::array<int, 4> offset_v{};

        offset_h[LayoutAnchor::ScreenStart] = 0;
        offset_h[LayoutAnchor::ScreenEnd] = size.width();
        offset_h[LayoutAnchor::IntersectStart] = margin.width();
        offset_h[LayoutAnchor::IntersectEnd] = size.width() - margin.width();

        offset_v[LayoutAnchor::ScreenStart] = 0;
        offset_v[LayoutAnchor::ScreenEnd] = size.height();
        offset_v[LayoutAnchor::IntersectStart] = margin.height();
        offset_v[LayoutAnchor::IntersectEnd] = size.height() - margin.height();

        return {intersection, offset_h, offset_v};
    }

    [[nodiscard]] inline Point<int> absolute(const Point<double> &point) const {
        return Point<int>{
            std::lround(point.x() * intersection.width()) + offset_h[point.anchor().h()],
            std::lround(point.y() * intersection.height()) + offset_v[point.anchor().v()],
            LayoutAnchor::ScreenStart,
        };
    }

private:
    FrameAnchor(const Size<int> &intersection, const std::array<int, 4> &offset_h, const std::array<int, 4> &offset_v)
        : intersection(intersection)
        , offset_h(offset_h)
        , offset_v(offset_v) {}

    Size<int> intersection;
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
        , timestamp(timestamp)
        , anchor(FrameAnchor::create(image.size())) {
        assert(!this->image.empty());
        assert(this->image.type() == CV_8UC3);
        assert(this->image.channels() == 3);
        assert(this->image.depth() == CV_8U);
        assert(this->image.elemSize() == 3);
        assert(this->image.elemSize1() == 1);
        assert(this->image.isContinuous());
    }

    [[nodiscard]] bool isIn(const Range<Color> &color_range, const Point<double> &point) const {
        return color_range.contains(colorAt(absolute(point)));
    }

    [[nodiscard]] std::optional<double> lengthIn(const Range<Color> &color_range, const Line<double> &line) const {
        const Range<BGR> &bgr_range = asBGRRange(color_range);
        const Line<int> &absolute_line = absolute(line);

        std::optional<double> length = std::nullopt;
        for (const auto &ratio : linspace(0., 1., (int) absolute_line.length())) {
            if (bgr_range.contains(bgrAt(absolute_line.pointAt(ratio)))) {
                length = ratio;
            } else {
                break;
            }
        }
        return length;
    }

    [[nodiscard]] inline Color colorAt(const Point<double> &point) const { return colorAt(absolute(point)); }

private:
    [[nodiscard]] inline Line<int> absolute(const Line<double> &line) const {
        return {absolute(line.p1()), absolute(line.p2())};
    }

    [[nodiscard]] inline Point<int> absolute(const Point<double> &point) const { return anchor.absolute(point); }

    [[nodiscard]] inline Color colorAt(const Point<int> &point) const { return bgrAt(point).toColor(); }
    [[nodiscard]] inline const BGR &bgrAt(const Point<int> &point) const { return bgrAt(point.x(), point.y()); }
    [[nodiscard]] inline const BGR &bgrAt(int x, int y) const { return image.ptr<BGR>(y)[x]; }

    const cv::Mat image;
    const uint64 timestamp;
    const FrameAnchor anchor;
};
