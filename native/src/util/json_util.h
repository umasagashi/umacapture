#pragma once

#include <memory>
#include <optional>

#include <nlohmann/json.hpp>

#include "util/misc.h"

namespace nlohmann {

template<typename T>
struct adl_serializer<std::shared_ptr<T>> {
    static void to_json(json &j, const std::shared_ptr<T> &opt) {
        if (opt) {
            j = *opt;
        } else {
            j = nullptr;
        }
    }

    static void from_json(const json &j, std::shared_ptr<T> &opt) {
        if (j.is_null()) {
            opt = nullptr;
        } else {
            opt.reset(new T(j.get<T>()));
        }
    }
};

template<typename T>
struct adl_serializer<std::unique_ptr<T>> {
    static void to_json(json &j, const std::unique_ptr<T> &opt) {
        if (opt) {
            j = *opt;
        } else {
            j = nullptr;
        }
    }

    static void from_json(json &j, const std::unique_ptr<T> &opt) {
        if (j.is_null()) {
            opt = nullptr;
        } else {
            opt.reset(new T(j.get<T>()));
        }
    }
};

template<typename T>
struct adl_serializer<std::optional<T>> {
    static void to_json(json &j, const std::optional<T> &opt) {
        if (opt == std::nullopt) {
            j = nullptr;
        } else {
            j = *opt;
        }
    }

    static void from_json(const json &j, std::optional<T> &opt) {
        if (j.is_null()) {
            opt = std::nullopt;
        } else {
            opt = j.get<T>();
        }
    }
};

}  // namespace nlohmann

namespace uma::json_util {

using Json = nlohmann::ordered_json;

template<typename T>
using AsType = nlohmann::detail::identity_tag<T>;

template<typename T>
void optional_to_json(Json &json, const std::string &key, const std::optional<T> &value) {
    if (value) {
        json[key] = *value;
    }
}

template<typename T>
std::optional<T> optional_from_json_impl(const Json &json, const std::string &key) {
    const auto &it = json.find(key);
    if (it != json.end()) {
        return it->get<T>();
    } else {
        return std::nullopt;
    }
}

template<typename T>
void optional_from_json(const Json &json, const std::string &key, std::optional<T> &value) {
    value = optional_from_json_impl<T>(json, key);
}

template<typename T>
[[maybe_unused]] std::optional<T>
optional_from_json(const Json &json, const std::string &key, AsType<const std::optional<T>>) {
    return optional_from_json_impl<T>(json, key);
}

template<typename T>
[[maybe_unused]] std::optional<T>
optional_from_json(const Json &json, const std::string &key, AsType<std::optional<T>>) {
    return optional_from_json_impl<T>(json, key);
}

template<typename>
constexpr bool is_optional = false;

template<typename T>
constexpr bool is_optional<std::optional<T>> = true;

template<typename T>
constexpr bool is_optional<const std::optional<T>> = true;

template<typename T>
void extended_to_json(Json &json, const std::string &key, const T &value) {
    if constexpr (is_optional<T>) {
        optional_to_json(json, key, value);
    } else {
        json[key] = value;
    }
}

template<typename T>
void extended_from_json(const Json &json, const std::string &key, T &value) {
    if constexpr (is_optional<T>) {
        optional_from_json(json, key, value);
    } else {
        json.at(key).get_to(value);
    }
}

template<typename T>
T extended_from_json(const Json &json, const std::string &key, nlohmann::detail::identity_tag<T> tag) {
    if constexpr (is_optional<T>) {
        return optional_from_json(json, key, tag);
    } else {
        return json.at(key).get<T>();
    }
}

inline std::string trim(const std::string &key) {
    const auto &begin = key.find_first_not_of('_');
    const auto &end = key.find_last_not_of('_');
    return key.substr(begin, end - begin + 1);
}

// Internal use.
#define INTERNAL_EXTENDED_JSON_TO(v1) uma::json_util::extended_to_json(json, uma::json_util::trim(#v1), obj.v1);
#define INTERNAL_EXTENDED_JSON_FROM_NDC(v1) \
    uma::json_util::extended_from_json(json, uma::json_util::trim(#v1), uma::json_util::AsType<decltype(v1)>()),
#define INTERNAL_EXTENDED_JSON_ENUM(v1) {v1, #v1},

// A serializer for default constructible types.
//#define EXTENDED_JSON_TYPE(Type, ...) \
//    friend void to_json(uma::json_util::Json &json, const Type &obj) { \
//        NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(INTERNAL_EXTENDED_JSON_TO, __VA_ARGS__)) \
//    } \
//    friend void from_json(const uma::json_util::Json &json, Type &obj) { \
//        NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(INTERNAL_EXTENDED_JSON_FROM, __VA_ARGS__)) \
//    }

// A serializer for default constructible types with no parameters to store.
#define EXTENDED_JSON_TYPE_NO_ARGS_DC(Type, ...) \
    friend void to_json(uma::json_util::Json &json, const Type &obj) {} \
    friend void from_json(const uma::json_util::Json &json, Type &obj) {}

// A serializer for non default constructible types.
#define EXTENDED_JSON_TYPE_NDC(Type, ...) \
    friend void to_json(uma::json_util::Json &json, const Type &obj) { \
        NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(INTERNAL_EXTENDED_JSON_TO, __VA_ARGS__)) \
    } \
    friend Type from_json(const uma::json_util::Json &json, uma::json_util::AsType<Type>) { \
        return Type{NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(INTERNAL_EXTENDED_JSON_FROM_NDC, __VA_ARGS__))}; \
    }

// A serializer that stores enums as strings.
#define EXTENDED_JSON_TYPE_ENUM(Type, ...) \
    NLOHMANN_JSON_SERIALIZE_ENUM( \
        Type, {NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(INTERNAL_EXTENDED_JSON_ENUM, __VA_ARGS__))})

// A helper to make a serializable object streamable.
#define EXTENDED_JSON_TYPE_PRINTABLE(Type) \
    inline std::ostream &operator<<(std::ostream &outs, const Type &obj) { \
        return outs << #Type << uma::json_util::Json(obj); \
    }

// A helper to make a serializable single-parameter-template object streamable.
#define EXTENDED_JSON_TYPE_TEMPLATE_PRINTABLE(Type) \
    template<typename T> \
    inline std::ostream &operator<<(std::ostream &outs, const Type<T> &obj) { \
        return outs << #Type << "<" << typeid(T).name() << ">" << uma::json_util::Json(obj); \
    }

inline json_util::Json read(const std::filesystem::path &path) {
    return json_util::Json::parse(io_util::read(path));
}

inline void write(const std::filesystem::path &path, const json_util::Json &json, int indent = -1) {
    io_util::write(path, json.dump(indent));
}

inline std::filesystem::path decodePath(const json_util::Json &json) {
    return std::filesystem::u8path(json.get<std::string>());
}

}  // namespace uma::json_util
