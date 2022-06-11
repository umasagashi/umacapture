/**
    MIT License

    Copyright (c) 2022 umasagashi
    https://github.com/umasagashi/minimal_uuid4

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
 */

#ifndef MINIMAL_UUID4_H
#define MINIMAL_UUID4_H

#include <iomanip>
#include <random>
#include <sstream>
#include <string>

namespace minimal_uuid4 {

struct Uuid {
    uint64_t low;
    uint64_t high;

    [[nodiscard]] std::string hex() const {
        return (std::ostringstream() << std::hex << std::setfill('0') << std::setw(16) << low << high).str();
    }

    [[nodiscard]] std::string str() const {
        constexpr char s = '-';
        const auto &h = hex();
        return h.substr(0, 8) + s + h.substr(8, 4) + s + h.substr(12, 4) + s + h.substr(16, 4) + s + h.substr(20);
    }

    static_assert(sizeof(decltype(low)) * 8 == 64, "Does not work on this platform.");
    static_assert(sizeof(decltype(high)) * 8 == 64, "Does not work on this platform.");
};

class Generator {
public:
    Generator()
        : gen(device()) {}

    Uuid uuid4() {
        return {
            (gen() & 0xFFFFFFFFFFFF0FFF) | 0x0000000000004000,
            (gen() & 0x3FFFFFFFFFFFFFFF) | 0x8000000000000000,
        };
    }

private:
    std::random_device device;
    std::mt19937_64 gen;

    static_assert(sizeof(decltype(gen)::result_type) * 8 == 64, "Does not work on this platform.");
};

}  // namespace minimal_uuid4

#endif  //MINIMAL_UUID4_H
