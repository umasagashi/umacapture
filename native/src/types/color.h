#pragma once

#include <utility>

#include "util/json_utils.h"

namespace uma {

class Color {
public:
    Color(int r, int g, int b) noexcept
        : r_(r)
        , g_(g)
        , b_(b) {}

    explicit Color(int gray) noexcept
        : r_(gray)
        , g_(gray)
        , b_(gray) {}

    [[nodiscard]] inline int r() const { return r_; }
    [[nodiscard]] inline int g() const { return g_; }
    [[nodiscard]] inline int b() const { return b_; }

    inline bool operator<=(const Color &other) const {
        return (r_ <= other.r_) && (g_ <= other.g_) && (b_ <= other.b_);
    }

    inline Color &operator=(const Color &other) = default;

    inline Color operator+(const Color &other) const { return {r_ + other.r_, g_ + other.g_, b_ + other.b_}; }

    inline Color operator+(int other) const { return {r_ + other, g_ + other, b_ + other}; }
    inline Color operator-(int other) const { return {r_ - other, g_ - other, b_ - other}; }

    [[nodiscard]] inline Color clamp() const {
        return {
            std::clamp(r_, 0, 255),
            std::clamp(g_, 0, 255),
            std::clamp(b_, 0, 255),
        };
    }

    EXTENDED_JSON_TYPE_NDC(Color, r_, g_, b_);

private:
    int r_;
    int g_;
    int b_;
};
EXTENDED_JSON_TYPE_PRINTABLE(Color)

}
