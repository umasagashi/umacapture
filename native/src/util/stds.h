#pragma once

#include <algorithm>

namespace uma::stds {

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
    std::transform(container.begin(), container.end(), std::back_inserter(out), func);
    return out;
}

template<typename OutContainer, typename InContainer, typename Function>
inline OutContainer transformed_inplace(const InContainer &container, Function func) {
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

template<typename Container>
inline void sort(Container &container) {
    std::sort(container.begin(), container.end());
}

inline bool starts_with(const std::string &subject, const std::string &query) {
    return subject.substr(0, query.length()) == query;
}

template<size_t start, size_t end, typename T, size_t in_n>
inline auto slice(const std::array<T, in_n> &array) {
    static_assert((end - start) <= in_n);
    std::array<T, end - start> out;
    std::copy(array.cbegin() + start, array.cbegin() + end, out.begin());
    return out;
}

#pragma clang diagnostic push
#pragma ide diagnostic ignored "UnusedParameter"
#pragma ide diagnostic ignored "UnusedLocalVariable"
template<
    typename Container,
    typename Function,
    typename Predicate,
    typename T = typename std::invoke_result<Function, typename Container::const_reference>::type>
inline std::optional<T> find_transformed_if(const Container &container, Function func, Predicate pred) {
    for (const auto &item : container) {
        const auto &mapped = func(item);
        if (pred(mapped)) {
            return mapped;
        }
    }
    return std::nullopt;
}
#pragma clang diagnostic pop

}  // namespace uma::stds
