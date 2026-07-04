// Contract tests for the notification payloads NativeApi pushes to Dart.
//
// The Dart side dispatches on the "type" string and reads each message's keys by name, so a renamed key or
// tag is a silent break that the C++ type system cannot catch. These lock the exact JSON each builder emits.
// Both sides are parsed into json_util::Json and compared by value, so the checks are independent of the key
// ordering .dump() happens to produce. The expected side is written as a raw JSON literal (the actual wire
// format) rather than a nested brace-init to avoid nlohmann's object/array initializer-list ambiguity.

#include <doctest/doctest.h>

#include <string>
#include <vector>

#include "chara_detail/chara_detail_record.h"
#include "core/native_api_messages.h"
#include "util/json_util.h"

namespace uma::app::messages {
namespace {

using json_util::Json;

// Parses both the builder output and the expected raw JSON and checks value equality (order-independent).
void checkMessage(const std::string &built, const std::string &expected) {
    CHECK(Json::parse(built) == Json::parse(expected));
}

TEST_CASE("no-argument messages carry only their type tag") {
    checkMessage(captureStarted(), R"({"type":"onCaptureStarted"})");
    checkMessage(captureStopped(), R"({"type":"onCaptureStopped"})");
    checkMessage(charaDetailStarted(), R"({"type":"onCharaDetailStarted"})");
    checkMessage(charaDetailRestarted(), R"({"type":"onCharaDetailRestarted"})");
    checkMessage(charaDetailClosed(), R"({"type":"onCharaDetailClosed"})");
}

TEST_CASE("string-payload messages") {
    checkMessage(
        screenshotTaken("C:/tmp/shot.png", "ok"),
        R"({"type":"onScreenshotTaken","path":"C:/tmp/shot.png","result":"ok"})");
    checkMessage(error("boom"), R"({"type":"onError","message":"boom"})");
}

TEST_CASE("scroll messages") {
    checkMessage(scrollReady(3), R"({"type":"onScrollReady","index":3})");
    checkMessage(pageReady(2), R"({"type":"onPageReady","index":2})");
    checkMessage(scrollUpdated(1, 0.25), R"({"type":"onScrollUpdated","index":1,"progress":0.25})");
    checkMessage(scrollPosition(0, true), R"({"type":"onScrollPosition","index":0,"at_top":true})");
    checkMessage(scrollPosition(4, false), R"({"type":"onScrollPosition","index":4,"at_top":false})");
}

TEST_CASE("chara-detail record messages use the id/success keys") {
    checkMessage(charaDetailFinished("rec-1", true), R"({"type":"onCharaDetailFinished","id":"rec-1","success":true})");
    checkMessage(charaDetailFinished("rec-2", false), R"({"type":"onCharaDetailFinished","id":"rec-2","success":false})");
    checkMessage(charaDetailUpdated("rec-3"), R"({"type":"onCharaDetailUpdated","id":"rec-3"})");
}

TEST_CASE("frame report messages") {
    checkMessage(frameRateReported(59.94), R"({"type":"onFrameRateReported","fps":59.94})");
    checkMessage(
        frameSizeReported(Size<int>{1920, 1080}),
        R"({"type":"onFrameSizeReported","size":{"width":1920,"height":1080}})");
}

TEST_CASE("factor probe serializes each factor as id/star") {
    const std::vector<chara_detail::record::Factor> factors{{101, 3}, {202, 1}};
    checkMessage(
        factorProbe(factors, 2),
        R"({"type":"onFactorProbe","factors":[{"id":101,"star":3},{"id":202,"star":1}],"record_type":2})");
}

TEST_CASE("factor probe with no factors emits an empty array") {
    const Json parsed = Json::parse(factorProbe({}, 0));
    CHECK(parsed.at("factors").is_array());
    CHECK(parsed.at("factors").empty());
    CHECK(parsed.at("record_type") == 0);
}

}  // namespace
}  // namespace uma::app::messages
