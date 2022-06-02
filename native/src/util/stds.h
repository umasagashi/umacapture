#pragma once

#include <algorithm>

namespace stds {

template<typename T>
inline T identical(const T &arg) {
    return arg;
}

template<typename Container, typename Function>
inline void for_each(const Container &container, Function func) {
    std::for_each(container.begin(), container.end(), func);
}

template<typename OutContainer, typename InContainer, typename Function>
inline OutContainer transformed(const InContainer &container, Function func) {
    OutContainer out;
    std::transform(container.begin(), container.end(), out.begin(), func);
    return out;
}

template<typename Container, typename Predicate>
inline typename Container::const_iterator find_if(const Container &container, Predicate pred) {
    return std::find_if(container.begin(), container.end(), pred);
}

template<typename Container, typename T>
inline typename Container::const_iterator find(const Container &container, const T &value) {
    return std::find(container.begin(), container.end(), value);
}

template<typename Container, typename Function>
inline bool all_of(const Container &container, Function func) {
    return std::all_of(container.begin(), container.end(), func);
}

template<typename Container>
inline bool all_of(const Container &container) {
    return std::all_of(container.begin(), container.end(), identical<bool>);
}

template<typename Container, typename Function>
inline bool any_of(const Container &container, Function func) {
    return std::any_of(container.begin(), container.end(), func);
}

template<typename Container>
inline bool any_of(const Container &container) {
    return std::any_of(container.begin(), container.end(), identical<bool>);
}

}  // namespace stds
