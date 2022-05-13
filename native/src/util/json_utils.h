#ifndef NATIVE_JSON_UTILS_H
#define NATIVE_JSON_UTILS_H

#include <optional>

#include "vendor/nlohmann/json.hpp"

namespace json_utils {

template<class T>
void optional_to_json(nlohmann::json &json, const char *key, const std::optional<T> &value) {
    if (value) {
        json[key] = *value;
    }
}
template<class T>
void optional_from_json(const nlohmann::json &json, const char *key, std::optional<T> &value) {
    const auto &it = json.find(key);
    if (it != json.end()) {
        value = it->get<T>();
    } else {
        value = std::nullopt;
    }
}

template<typename>
constexpr bool is_optional = false;

template<typename T>
constexpr bool is_optional<std::optional<T>> = true;

template<typename T>
void extended_to_json(nlohmann::json &json, const char *key, const T &value) {
    if constexpr (is_optional<T>) {
        optional_to_json(json, key, value);
    } else {
        json[key] = value;
    }
}
template<typename T>
void extended_from_json(const nlohmann::json &json, const char *key, T &value) {
    if constexpr (is_optional<T>) {
        optional_from_json(json, key, value);
    } else {
        json.at(key).get_to(value);
    }
}

#define EXTENDED_JSON_TO(v1) json_utils::extended_to_json(nlohmann_json_j, #v1, nlohmann_json_t.v1);
#define EXTENDED_JSON_FROM(v1) json_utils::extended_from_json(nlohmann_json_j, #v1, nlohmann_json_t.v1);

#define EXTENDED_JSON_TYPE_INTRUSIVE(Type, ...) \
    friend void to_json(nlohmann::json &nlohmann_json_j, const Type &nlohmann_json_t) { \
        NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(EXTENDED_JSON_TO, __VA_ARGS__)) \
    } \
    friend void from_json(const nlohmann::json &nlohmann_json_j, Type &nlohmann_json_t) { \
        NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(EXTENDED_JSON_FROM, __VA_ARGS__)) \
    }

}  // namespace json_utils

#endif  //NATIVE_JSON_UTILS_H
