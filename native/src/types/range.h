#pragma once

#include "util/json_utils.h"

namespace uma {

template<typename T>
class Range {
public:
    Range(const T &min, const T &max) noexcept
        : min_(min)
        , max_(max) {}

    [[nodiscard]] inline T min() const { return min_; }
    [[nodiscard]] inline T max() const { return max_; }

    inline bool contains(const T &value) const { return min_ <= value && value <= max_; }

    inline Range<T> operator+(const T &other) const { return {min_ + other, max_ + other}; }

    EXTENDED_JSON_TYPE_NDC(Range<T>, min_, max_);

private:
    T min_;
    T max_;
};
EXTENDED_JSON_TYPE_TEMPLATE_PRINTABLE(Range)

}
