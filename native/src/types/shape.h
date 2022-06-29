#pragma once

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

#include "util/json_util.h"

namespace uma {

enum LayoutAnchor {
    ScreenStart,
    ScreenLogicalEnd,
    ScreenPixelEnd,
    IntersectStart,
    IntersectLogicalEnd,
    IntersectPixelEnd,
};
EXTENDED_JSON_TYPE_ENUM(
    LayoutAnchor, ScreenStart, ScreenLogicalEnd, ScreenPixelEnd, IntersectStart, IntersectLogicalEnd, IntersectPixelEnd)

class Anchor {
public:
    [[maybe_unused]] Anchor(LayoutAnchor h, LayoutAnchor v) noexcept
        : h_(h)
        , v_(v) {}

    Anchor(LayoutAnchor both) noexcept  // NOLINT(google-explicit-constructor)
        : h_(both)
        , v_(both) {}

    Anchor() noexcept
        : h_(ScreenStart)
        , v_(ScreenStart) {}

    [[nodiscard]] inline LayoutAnchor h() const { return h_; }
    [[nodiscard]] inline LayoutAnchor v() const { return v_; }

    inline bool operator==(const Anchor &other) const { return (h_ == other.h_) && (v_ == other.v_); }
    inline bool operator==(const LayoutAnchor &other) const { return (h_ == other) && (v_ == other); }

    [[nodiscard]] inline bool isAbsolute() const { return h_ == ScreenStart && v_ == ScreenStart; }

    EXTENDED_JSON_TYPE_NDC(Anchor, h_, v_);

private:
    LayoutAnchor h_;
    LayoutAnchor v_;
};
EXTENDED_JSON_TYPE_PRINTABLE(Anchor)

template<typename T>
class Point {
public:
    Point(T x, T y, const Anchor &anchor) noexcept
        : x_(x)
        , y_(y)
        , anchor_(anchor) {}

    Point(T x, T y) noexcept
        : x_(x)
        , y_(y)
        , anchor_(ScreenStart) {}

    Point() noexcept = default;

    [[nodiscard]] inline bool empty() const { return x_ == 0 && y_ == 0; }

    [[nodiscard]] inline T x() const { return x_; }
    [[nodiscard]] inline T y() const { return y_; }
    [[nodiscard]] inline Anchor anchor() const { return anchor_; }

    [[nodiscard]] inline Point<T> withX(T x) const { return {x, y_, anchor_}; }
    [[nodiscard]] inline Point<T> withY(T y) const { return {x_, y, anchor_}; }

    [[maybe_unused]] [[nodiscard]] inline cv::Point_<T> toCVPoint() const {
        assert_(anchor_.isAbsolute());
        return {x_, y_};
    }

    inline Point<T> &operator=(const Point<T> &other) = default;

    template<typename S>
    [[nodiscard]] inline Point<S> cast() const {
        return {static_cast<S>(x_), static_cast<S>(y_), anchor_};
    }

    [[nodiscard]] inline Point<int> round() const { return {std::lround(x_), std::lround(y_), anchor_}; }

    inline Point<T> operator+(const Point<T> &other) const {
        assert_(anchor_ == other.anchor_);
        return {x_ + other.x_, y_ + other.y_, anchor_};
    }

    inline Point<T> operator-(const Point<T> &other) const {
        assert_(anchor_ == other.anchor_);
        return {x_ - other.x_, y_ - other.y_, anchor_};
    }

    inline Point<T> operator*(const T &other) const { return {x_ * other, y_ * other, anchor_}; }

    inline Point<T> operator/(const T &other) const { return {x_ / other, y_ / other, anchor_}; }

    [[nodiscard]] double distance(const Point<T> &other) const {
        assert_(anchor_ == other.anchor_);
        return std::sqrt(std::pow(x_ - other.x_, 2) + std::pow(y_ - other.y_, 2));
    }

    EXTENDED_JSON_TYPE_NDC(Point<T>, x_, y_, anchor_);

private:
    T x_;
    T y_;
    Anchor anchor_;
};
EXTENDED_JSON_TYPE_TEMPLATE_PRINTABLE(Point)

template<typename T>
class Size {
public:
    constexpr Size(T width, T height) noexcept
        : width_(width)
        , height_(height) {}

    Size(const cv::Size_<T> &size) noexcept  // NOLINT(google-explicit-constructor)
        : width_(size.width)
        , height_(size.height) {}

    [[nodiscard]] inline T width() const { return width_; }
    [[nodiscard]] inline T height() const { return height_; }

    [[maybe_unused]] [[nodiscard]] inline cv::Size_<T> toCVSize() const { return {width_, height_}; }
    [[nodiscard]] inline Point<T> toPoint() const { return {width_, height_}; }

    template<typename S>
    [[nodiscard]] inline Size<S> cast() const {
        return {static_cast<S>(width_), static_cast<S>(height_)};
    }

    [[nodiscard]] inline Size<int> round() const { return {std::lround(width_), std::lround(height_)}; }

    inline Size<T> &operator=(const Size<T> &other) = default;

    inline bool operator==(const Size<T> &other) const {
        return (width_ == other.width_) && (height_ == other.height_);
    }

    inline bool operator!=(const Size<T> &other) const { return !(*this == other); }

    inline Size<T> operator-(const Size<T> &other) const { return {width_ - other.width_, height_ - other.height_}; }
    inline Size<T> operator+(const Size<T> &other) const { return {width_ + other.width_, height_ + other.height_}; }
    inline Size<T> operator/(const Size<T> &other) const { return {width_ / other.width_, height_ / other.height_}; }

    inline Size<T> operator/(const T &other) const { return {width_ / other, height_ / other}; }
    inline Size<T> operator*(const T &other) const { return {width_ * other, height_ * other}; }

    EXTENDED_JSON_TYPE_NDC(Size<T>, width_, height_);

private:
    T width_;
    T height_;
};
EXTENDED_JSON_TYPE_TEMPLATE_PRINTABLE(Size)

template<typename T>
class Line1D {
public:
    Line1D(const T &p1, const T &p2) noexcept
        : p1_(p1)
        , p2_(p2) {}

    [[nodiscard]] inline T p1() const { return p1_; }
    [[nodiscard]] inline T p2() const { return p2_; }

    inline Line1D<T> &operator=(const Line1D<T> &other) = default;

    [[nodiscard]] inline T pointAt(double ratio) const { return (p2_ - p1_) * ratio + p1_; }

    [[nodiscard]] inline double length() const { return std::abs(p2_ - p1_); }

    //    [[nodiscard]] inline Line1D<T> reversed() const { return {p2_, p1_}; }

    inline Line1D<T> operator-(const Line1D<T> &other) const { return {p1_ - other.p1_, p2_ - other.p2_}; }

    EXTENDED_JSON_TYPE_NDC(Line1D<T>, p1_, p2_);

private:
    T p1_;
    T p2_;
};
EXTENDED_JSON_TYPE_TEMPLATE_PRINTABLE(Line1D)

template<typename T>
class Line {
public:
    Line(const Point<T> &p1, const Point<T> &p2) noexcept
        : p1_(p1)
        , p2_(p2) {}

    [[nodiscard]] inline Point<T> p1() const { return p1_; }
    [[nodiscard]] inline Point<T> p2() const { return p2_; }

    inline Line<T> &operator=(const Line<T> &other) = default;

    template<typename S>
    [[nodiscard]] inline Line<S> cast() const {
        return {p1_.template cast<S>(), p2_.template cast<S>()};
    }

    [[nodiscard]] inline Line<int> round() const { return {p1_.round(), p2_.round()}; }

    [[nodiscard]] inline Point<T> pointAt(const T &ratio) const { return (p2_ - p1_) * ratio + p1_; }

    [[nodiscard]] inline double length() const { return p1_.distance(p2_); }

    [[nodiscard]] inline Line<T> reversed() const { return {p2_, p1_}; }

    [[nodiscard]] inline Line1D<T> horizontal() const { return {p1_.x(), p2_.x()}; }
    [[nodiscard]] inline Line1D<T> vertical() const { return {p1_.y(), p2_.y()}; }

    inline Line<T> operator-(const Line<T> &other) const { return {p1_ - other.p1_, p2_ - other.p2_}; }

    inline Line<T> operator*(const T &other) const { return {p1_ * other, p2_ * other}; }
    inline Line<T> operator/(const T &other) const { return {p1_ / other, p2_ / other}; }

    EXTENDED_JSON_TYPE_NDC(Line<T>, p1_, p2_);

private:
    Point<T> p1_;
    Point<T> p2_;
};
EXTENDED_JSON_TYPE_TEMPLATE_PRINTABLE(Line)

template<typename T>
class Rect {
public:
    Rect(const Point<T> &top_left, const Point<T> &bottom_right) noexcept
        : top_left_(top_left)
        , bottom_right_(bottom_right) {}

    Rect() noexcept = default;

    [[nodiscard]] inline bool empty() const { return top_left_.empty() && bottom_right_.empty(); }

    inline Rect &operator=(const Rect &other) = default;

    [[nodiscard]] inline const Point<T> &topLeft() const { return top_left_; }
    [[nodiscard]] inline const Point<T> &bottomRight() const { return bottom_right_; }

    [[maybe_unused]] [[nodiscard]] inline cv::Rect_<T> toCVRect() const {
        return {top_left_.toCVPoint(), bottom_right_.toCVPoint()};
    }

    [[nodiscard]] inline T left() const { return top_left_.x(); }
    [[nodiscard]] inline T top() const { return top_left_.y(); }
    [[nodiscard]] inline T right() const { return bottom_right_.x(); }
    [[nodiscard]] inline T bottom() const { return bottom_right_.y(); }

    [[nodiscard]] inline T width() const { return bottom_right_.x() - top_left_.x(); }
    [[nodiscard]] inline T height() const { return bottom_right_.y() - top_left_.y(); }

    [[nodiscard]] inline Size<T> size() const { return {width(), height()}; }

    inline Rect<T> operator+(const Point<T> &other) const {
        assert_(other.anchor() == ScreenStart);
        return {
            top_left_ + Point<T>{other.x(), other.y(), top_left_.anchor()},
            bottom_right_ + Point<T>{other.x(), other.y(), bottom_right_.anchor()},
        };
    }

    EXTENDED_JSON_TYPE_NDC(Rect, top_left_, bottom_right_);

private:
    Point<T> top_left_;
    Point<T> bottom_right_;
};
EXTENDED_JSON_TYPE_TEMPLATE_PRINTABLE(Rect)

}  // namespace uma
