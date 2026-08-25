// Characterization tests for the chara-detail config deserialization.
//
// The config structs in chara_detail_config.h are wired to JSON via the EXTENDED_JSON_TYPE_NDC macro and are
// only exercised indirectly through the recognizer/scraper pipeline. These lock the serialization contract of
// the actually-shipped config against the committed assets: parsing the real JSON and re-serializing it must
// be stable (get -> to_json -> get -> to_json produces identical JSON), the same round-trip invariant the CLI
// `build` subcommand asserts at runtime.
//
// This reads the repo-committed config JSON under assets/config/chara_detail via TEST_ASSET_CONFIG_DIR, which
// CMake injects. That is a deliberate, narrow exception to the "no game assets" rule in test/README.md: those
// files are small, versioned config (not screenshots or ONNX models) and are themselves the contract here.

#include <doctest/doctest.h>

#include <filesystem>
#include <string>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "condition/serializer.h"
#include "util/json_util.h"

#ifndef TEST_ASSET_CONFIG_DIR
#error "TEST_ASSET_CONFIG_DIR must be defined by the build (see native/CMakeLists.txt)."
#endif

namespace uma::chara_detail {
namespace {

using json_util::Json;

std::filesystem::path configPath(const std::string &relative) {
    return std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / relative;
}

// Parses the committed config JSON into Config, re-serializes, and re-parses. A stable serializer produces
// identical JSON on both serialization passes.
template<typename Config>
void checkConfigRoundTrip(const std::string &relative) {
    const Json on_disk = json_util::read(configPath(relative));
    const Json first = Json(on_disk.get<Config>());
    const Json second = Json(first.get<Config>());
    CHECK(first == second);
}

TEST_CASE("scene_scraper config round-trips") {
    checkConfigRoundTrip<scraper_config::CharaDetailSceneScraperConfig>("scene_scraper.json");
}

TEST_CASE("scene_stitcher config round-trips") {
    checkConfigRoundTrip<stitcher_config::CharaDetailSceneStitcherConfig>("scene_stitcher.json");
}

TEST_CASE("recognizer config round-trips") {
    checkConfigRoundTrip<recognizer_config::CharaDetailRecognizerConfig>("recognizer.json");
}

TEST_CASE("scene_context condition tree round-trips") {
    // The committed scene_context.json root is itself the tagged condition tree the scene context is built
    // from, so conditionFromJson consumes it directly (as startPipeline does).
    const Json on_disk = json_util::read(configPath("scene_context.json"));
    const Json first = condition::serializer::conditionFromJson(on_disk)->toJson();
    const Json second = condition::serializer::conditionFromJson(first)->toJson();
    CHECK(first == second);
}

TEST_CASE("missing required keys are rejected") {
    const Json incomplete = {{"stretch_range", nullptr}};
    CHECK_THROWS(incomplete.get<stitcher_config::CharaDetailSceneStitcherConfig>());
}

}  // namespace
}  // namespace uma::chara_detail
