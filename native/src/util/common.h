#pragma once

#include <chrono>
#include <fstream>
#include <iostream>

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

namespace io {

inline std::string read(const std::string &path) {
    std::ifstream file(path);
    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

inline void write(const std::string &path, const std::string &text) {
    std::ofstream file;
    file.open(path, std::ios::out);
    file << text;
    file.close();
}

}  // namespace io
