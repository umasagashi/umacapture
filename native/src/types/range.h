#pragma once

#include <stdexcept>

#include "util/json_util.h"

namespace uma {

template<typename T>
class Range {
public:
    // Rejects an inverted range (min > max). Such a range makes contains() always false, which would silently
    // disable a rule; a config typo should surface as an error instead. Deserialization goes through this
    // constructor (EXTENDED_JSON_TYPE_NDC builds via Type{...}), so the throw lands during pipeline
    // construction and is reported to Dart via notifyError, not across the FFI boundary. For Range<Color> the
    // per-channel operator<= means any single inverted channel is rejected.
    Range(const T &min, const T &max)
        : min_(min)
        , max_(max) {
        if (!(min_ <= max_)) {
            throw std::invalid_argument("Range: min must be <= max");
        }
    }

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

}  // namespace uma
