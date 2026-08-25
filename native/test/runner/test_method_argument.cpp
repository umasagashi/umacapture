// Tests for the platform-channel argument decoding used by the Windows runner (windows/runner/method_argument.h).
//
// The dispatcher used to read every argument as `*std::get_if<std::string>(call.arguments())`, which
// dereferences a null pointer for any payload that is not a string. The helper is templated on the value
// type so it can be exercised here against a stand-in variant that mirrors flutter::EncodableValue's
// alternatives (same order, same types), without pulling in the generated cpp_client_wrapper headers --
// those live under windows/flutter/ephemeral, which only exists after a Flutter Windows build.

#include <doctest/doctest.h>

#include <cstdint>
#include <map>
#include <string>
#include <variant>
#include <vector>

#include "runner/method_argument.h"

namespace uma::windows::method_argument {
namespace {

// Mirrors flutter::internal::EncodableValueVariant closely enough for the alternatives the helper names.
// The trailing list/map stand-ins cover the "other" bucket.
using FakeValue = std::variant<
    std::monostate,
    bool,
    int32_t,
    int64_t,
    double,
    std::string,
    std::vector<uint8_t>,
    std::vector<std::string>,
    std::map<std::string, std::string>>;

TEST_CASE("typeName names every scalar alternative, and the null pointer") {
    const FakeValue null_value{};
    const FakeValue boolean{true};
    const FakeValue small_int{int32_t{7}};
    const FakeValue big_int{int64_t{7}};
    const FakeValue number{1.5};
    const FakeValue text{std::string{"hello"}};
    const FakeValue bytes{std::vector<uint8_t>{1, 2}};

    CHECK(typeName<FakeValue>(nullptr) == "absent");
    CHECK(typeName(&null_value) == "null");
    CHECK(typeName(&boolean) == "bool");
    CHECK(typeName(&small_int) == "int32");
    CHECK(typeName(&big_int) == "int64");
    CHECK(typeName(&number) == "double");
    CHECK(typeName(&text) == "string");
    CHECK(typeName(&bytes) == "other");
}

TEST_CASE("decode hands a string payload to an argument-taking handler") {
    const FakeValue text{std::string{R"({"enabled":true,"cropped":false})"}};

    const auto decoded = decode("setCapturePreview", true, &text);

    CHECK(decoded.ok);
    CHECK(decoded.value == R"({"enabled":true,"cropped":false})");
    CHECK(decoded.error.empty());
}

TEST_CASE("decode rejects every non-string payload for an argument-taking handler") {
    // The regression: each of these used to be dereferenced as a string.
    const FakeValue null_value{};
    const FakeValue boolean{false};
    const FakeValue number{int64_t{42}};
    const FakeValue mapping{std::map<std::string, std::string>{{"a", "b"}}};

    for (const auto *payload : {&null_value, &boolean, &number, &mapping}) {
        const auto decoded = decode("setCapturePreview", true, payload);
        CHECK_FALSE(decoded.ok);
        CHECK(decoded.value.empty());
        // The rejection must be self-describing: it names the method and what actually arrived.
        CHECK(decoded.error.find("setCapturePreview") != std::string::npos);
        CHECK(decoded.error.find("expects a string argument") != std::string::npos);
    }

    CHECK(decode("setCapturePreview", true, &boolean).error.find("bool") != std::string::npos);
    CHECK(decode("setCapturePreview", true, &number).error.find("int64") != std::string::npos);
}

TEST_CASE("decode rejects a missing argument for an argument-taking handler") {
    // MethodCall::arguments() is documented to return NULL when the call carries no argument.
    const auto decoded = decode<FakeValue>("takeScreenshot", true, nullptr);

    CHECK_FALSE(decoded.ok);
    CHECK(decoded.error.find("absent") != std::string::npos);
}

TEST_CASE("decode accepts anything for a handler that takes no argument") {
    // startCapture / stopCapture / resetDetailCropCalibration keep working with the null Dart sends,
    // and would keep working if a caller ever attached a payload.
    const FakeValue null_value{};
    const FakeValue boolean{true};
    const FakeValue text{std::string{"ignored"}};

    for (const auto *payload : {&null_value, &boolean, &text}) {
        const auto decoded = decode("startCapture", false, payload);
        CHECK(decoded.ok);
        CHECK(decoded.value.empty());
        CHECK(decoded.error.empty());
    }

    const auto absent = decode<FakeValue>("startCapture", false, nullptr);
    CHECK(absent.ok);
    CHECK(absent.value.empty());
}

}  // namespace
}  // namespace uma::windows::method_argument
