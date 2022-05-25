#ifndef NATIVE_COMMON_H
#define NATIVE_COMMON_H

#include <chrono>

#include "types/shape.h"

namespace chrono {

inline uint64_t timestamp() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}

}  // namespace chrono

namespace constant {

constexpr Size<int> base_size = {540, 960};

}

#endif  //NATIVE_COMMON_H
