// Behavioral tests for json_util's key helpers.
//
// trim strips the leading/trailing underscores the EXTENDED_JSON macros wrap around member names
// (e.g. `min_` -> `min`), which is what maps a private field to its stable JSON key. A regression
// here would silently rename every serialized key, so the underscore-stripping edges are pinned.
//
// The optional_*/extended_* templates are the per-field read/write primitives the EXTENDED_JSON_TYPE_NDC
// macro expands to. Their defining behavior is that a disengaged std::optional is OMITTED (not written as
// null) and that a missing OR explicitly-null key reads back as nullopt, while non-optional fields go
// through the plain nlohmann path and throw on a missing key. These are exercised indirectly by every
// record/config round-trip; pinning them directly guards the omit-vs-null asymmetry the wire format
// depends on. decodePath turns a JSON string into a filesystem path via u8path (UTF-8 aware).

#include <doctest/doctest.h>

#include <filesystem>
#include <optional>
#include <string>

#include "util/json_util.h"

namespace uma::json_util {
namespace {

TEST_CASE("trim removes surrounding underscores only") {
    CHECK(trim("___value___") == "value");
    CHECK(trim("_a_b_c_") == "a_b_c");  // interior underscores are kept
    CHECK(trim("value") == "value");  // nothing to strip
}

TEST_CASE("trim collapses an all-underscore or empty key to empty") {
    CHECK(trim("___").empty());
    CHECK(trim("").empty());
}

TEST_CASE("optional_to_json writes an engaged optional and omits a disengaged one") {
    Json json;
    optional_to_json(json, "present", std::optional<int>(7));
    optional_to_json(json, "absent", std::optional<int>(std::nullopt));

    REQUIRE(json.contains("present"));
    CHECK(json.at("present") == 7);
    // A disengaged optional is dropped entirely -- it is NOT written as null. This is the asymmetry the
    // wire format relies on to keep records compact and stable.
    CHECK_FALSE(json.contains("absent"));
}

TEST_CASE("optional_from_json reads a value, a missing key, and an explicit null") {
    Json json;
    json["value"] = 42;
    json["explicit_null"] = nullptr;

    // Reference-out overload.
    std::optional<int> out;
    optional_from_json(json, "value", out);
    CHECK(out == std::optional<int>(42));
    optional_from_json(json, "missing", out);
    CHECK_FALSE(out.has_value());
    optional_from_json(json, "explicit_null", out);
    CHECK_FALSE(out.has_value());  // an explicit null is treated the same as a missing key
}

TEST_CASE("optional_from_json return-tag overload mirrors the reference overload") {
    Json json;
    json["value"] = 42;

    CHECK(optional_from_json(json, "value", AsType<std::optional<int>>()) == std::optional<int>(42));
    CHECK_FALSE(optional_from_json(json, "missing", AsType<std::optional<int>>()).has_value());
    CHECK_FALSE(optional_from_json(json, "value", AsType<const std::optional<int>>()) == std::nullopt);
}

TEST_CASE("extended_to_json routes optionals through the omit path and plain values through the direct path") {
    Json json;
    extended_to_json(json, "plain", std::string("hello"));  // non-optional: written directly
    extended_to_json(json, "engaged", std::optional<int>(1));
    extended_to_json(json, "disengaged", std::optional<int>(std::nullopt));

    CHECK(json.at("plain") == "hello");
    CHECK(json.at("engaged") == 1);
    CHECK_FALSE(json.contains("disengaged"));
}

TEST_CASE("extended_from_json reads optional and non-optional fields") {
    Json json;
    json["count"] = 5;
    json["maybe"] = nullptr;

    int count = 0;
    extended_from_json(json, "count", count);
    CHECK(count == 5);

    std::optional<int> maybe = 99;
    extended_from_json(json, "maybe", maybe);
    CHECK_FALSE(maybe.has_value());

    // Return-tag overload.
    CHECK(extended_from_json(json, "count", AsType<int>()) == 5);
    CHECK_FALSE(extended_from_json(json, "maybe", AsType<std::optional<int>>()).has_value());
}

TEST_CASE("extended_from_json throws on a missing non-optional key") {
    const Json json = Json::object();
    int value = 0;
    CHECK_THROWS(extended_from_json(json, "required", value));
}

TEST_CASE("decodePath turns a JSON string into a filesystem path") {
    const Json json = "sub/dir/file.png";
    CHECK(decodePath(json) == std::filesystem::u8path("sub/dir/file.png"));
}

}  // namespace
}  // namespace uma::json_util
