// Tests for the lenient readers of the optional pipeline start-config keys.
//
// The point of these readers is that a bad value never aborts a capture session: it degrades to the
// documented default. So the cases that matter are "absent", "malformed", and "valid".

#include <doctest/doctest.h>

#include <chrono>
#include <limits>
#include <memory>
#include <optional>
#include <string>

#include "core/pipeline_config.h"

// AFTER the project header, unlike the usual grouping: util/logger_util.h (reached through the header above)
// defines SPDLOG_ACTIVE_LEVEL before it pulls in spdlog, so letting a spdlog header come first makes that a
// macro redefinition (MSVC C4005) and silently lowers the level this translation unit compiles logging at.
#include <spdlog/sinks/ringbuffer_sink.h>

namespace uma::app {
namespace {

using namespace std::chrono_literals;

constexpr int kIntMax = std::numeric_limits<int>::max();

// Redirects the default spdlog logger into a ring buffer for the lifetime of the object, so a case can
// assert on what was WARNED and not only on what was returned. Needed because a warning is the entire
// observable difference between "this input was reported" and "this input was silently normalized away":
// both return the same band. Restores the previous default logger on destruction, including when a CHECK
// throws, so one case cannot swallow another's output.
class LogCapture {
public:
    LogCapture()
        : previous_(spdlog::default_logger())
        , sink_(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(64)) {
        auto logger = std::make_shared<spdlog::logger>("test_capture", sink_);
        logger->set_level(spdlog::level::trace);
        spdlog::set_default_logger(logger);
    }

    ~LogCapture() { spdlog::set_default_logger(previous_); }

    LogCapture(const LogCapture &) = delete;
    LogCapture &operator=(const LogCapture &) = delete;

    [[nodiscard]] bool contains(const std::string &needle) const {
        for (const auto &line : sink_->last_formatted()) {
            if (line.find(needle) != std::string::npos) {
                return true;
            }
        }
        return false;
    }

private:
    std::shared_ptr<spdlog::logger> previous_;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> sink_;
};

TEST_CASE("readFrameStallTimeout defaults to 2000 ms when the key is absent") {
    const auto config = json_util::Json::parse(R"({"video_mode": false})");
    CHECK(readFrameStallTimeout(config) == 2000ms);
    CHECK(readFrameStallTimeout(config) == kDefaultFrameStallTimeout);
}

TEST_CASE("readFrameStallTimeout falls back to the default for a malformed value") {
    SUBCASE("wrong type: string") {
        CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": "3000"})")) == 2000ms);
    }
    SUBCASE("wrong type: boolean") {
        CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": true})")) == 2000ms);
    }
    SUBCASE("wrong type: null") {
        CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": null})")) == 2000ms);
    }
    SUBCASE("wrong type: object") {
        CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": {"ms": 3000}})")) == 2000ms);
    }
    SUBCASE("non-integer number") {
        CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": 1500.5})")) == 2000ms);
    }
    SUBCASE("zero is not a lesser kind of wrong than a string") {
        CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": 0})")) == 2000ms);
    }
    SUBCASE("negative") {
        CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": -1})")) == 2000ms);
    }
}

TEST_CASE("readFrameStallTimeout takes a valid positive value") {
    CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": 5000})")) == 5000ms);
    CHECK(readFrameStallTimeout(json_util::Json::parse(R"({"frame_stall_timeout_ms": 1})")) == 1ms);
}

// Equality helper: Range<int> has no operator==, and the bounds are what these cases are about anyway.
[[nodiscard]] bool bandIs(const std::optional<Range<int>> &band, int min, int max) {
    return band.has_value() && band->min() == min && band->max() == max;
}

TEST_CASE("readFrameResizeBand is disabled unless the block explicitly enables it") {
    SUBCASE("key absent") {
        CHECK_FALSE(readFrameResizeBand(json_util::Json::parse(R"({"video_mode": false})")).has_value());
    }
    SUBCASE("enabled absent") {
        CHECK_FALSE(readFrameResizeBand(json_util::Json::parse(R"({"frame_resize": {}})")).has_value());
    }
    SUBCASE("enabled false") {
        CHECK_FALSE(readFrameResizeBand(json_util::Json::parse(R"({"frame_resize": {"enabled": false}})")).has_value());
    }
    SUBCASE("block is not an object") {
        CHECK_FALSE(readFrameResizeBand(json_util::Json::parse(R"({"frame_resize": 540})")).has_value());
    }
    SUBCASE("enabled is not a boolean") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": "true", "min_unit": 320}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
}

// THE SHIPPED OPERATING POINT, AND THE WHOLE CONTRACT WITH THE APP. The literals are the point of this case,
// not a restatement of the constants: they are what makes moving the band without deciding to move it fail
// here, by name, instead of quietly changing what every platform recognizes. The second pair of CHECKs is
// what ties the literals to the constants the readers actually use. `kFrameResizeMinUnit` /
// `kFrameResizeMaxUnit` in core/cli.cpp are aliases of the same constants, so this case covers the CLI's
// `--frame-resize` band too -- cli.cpp carries `main()` and is not linked into this suite, so an alias is the
// only way it can be pinned from here.
//
// THE PAYLOAD NAMES NO BOUNDS, AND MUST NOT START TO. That is not brevity: it is exactly the block the
// Flutter app sends (`frameResizeConfig` in lib/src/core/platform_controller.dart emits `enabled` and
// nothing else, pinned by `the block carries exactly enabled, and nothing else` in
// test/frame_resize_band_test.dart). The app deliberately carries no copy of the bounds -- it has no UI for
// overriding them, and a second copy could only drift, silently, because the integration suite drives the
// CLI and never the app. So this case is the ONLY thing standing between the shipping app and the band it
// ships: it asserts that "enabled, and no bounds" resolves to 540-720. Adding `min_unit`/`max_unit` to the
// payload below would still pass while testing something the app never sends.
TEST_CASE("the shipped frame-resize band is 540-720 px") {
    const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true}})");
    CHECK(bandIs(readFrameResizeBand(config), 540, 720));
    CHECK(bandIs(readFrameResizeBand(config), kDefaultFrameResizeMinUnit, kDefaultFrameResizeMaxUnit));
}

TEST_CASE("readFrameResizeBand takes valid positive bounds") {
    CHECK(bandIs(
        readFrameResizeBand(
            json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": 320, "max_unit": 400}})")),
        320,
        400));
    // A degenerate band -- min == max -- is legal: it is the single-target behaviour this schema replaced,
    // still expressible, and Range<int> accepts it.
    CHECK(bandIs(
        readFrameResizeBand(
            json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": 540, "max_unit": 540}})")),
        540,
        540));
    SUBCASE("one bound named, the other left at its default") {
        CHECK(bandIs(
            readFrameResizeBand(json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": 400}})")),
            400,
            kDefaultFrameResizeMaxUnit));
        CHECK(bandIs(
            readFrameResizeBand(json_util::Json::parse(R"({"frame_resize": {"enabled": true, "max_unit": 1080}})")),
            kDefaultFrameResizeMinUnit,
            1080));
    }
    // The largest bound that survives the narrowing to int, so the range check must not reject it.
    const auto at_limit = "{\"frame_resize\": {\"enabled\": true, \"min_unit\": 1, \"max_unit\": "
                        + std::to_string(kIntMax) + "}}";
    CHECK(bandIs(readFrameResizeBand(json_util::Json::parse(at_limit)), 1, kIntMax));
}

// A malformed bound falls back to the DEFAULT -- which is "disabled" -- instead of silently substituting a
// shipped bound. (The 540s below are arbitrary malformed payloads, not the bound under test.)
TEST_CASE("readFrameResizeBand disables the resize for a malformed bound") {
    SUBCASE("wrong type: string") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": "540"}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    SUBCASE("wrong type: null") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true, "max_unit": null}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    SUBCASE("non-integer number") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": 540.5}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    SUBCASE("zero") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true, "max_unit": 0}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    SUBCASE("negative") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": -1}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    // is_number_integer() is true for 64-bit values too, so get<int>() would narrow these silently: 2^31
    // wraps to INT_MIN and 2^32 to 0. The int-range check is what keeps them out.
    SUBCASE("just above the int range") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true, "max_unit": 2147483648}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    SUBCASE("wraps to zero when narrowed") {
        const auto config = json_util::Json::parse(R"({"frame_resize": {"enabled": true, "max_unit": 4294967296}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    SUBCASE("beyond the signed 64-bit range") {
        const auto config =
            json_util::Json::parse(R"({"frame_resize": {"enabled": true, "max_unit": 18446744073709551615}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
    // Range<int>'s constructor THROWS on min > max. Letting it reach that constructor would abort
    // startPipeline over a config typo, which is the one thing this whole header exists to prevent.
    SUBCASE("inverted band") {
        const auto config =
            json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": 800, "max_unit": 600}})");
        CHECK_FALSE(readFrameResizeBand(config).has_value());
    }
}

// --- The legacy `unit` key --------------------------------------------------------------------------------
//
// `unit` meant "the width every forwarded frame is resized to". The band keys mean bounds. A writer still
// sending `unit` is therefore asking for something this reader no longer does, and the failure mode of NOT
// saying so is the one this repository has already paid for: a field whose meaning moved while its name
// stayed, with both sides silently disagreeing and nothing in the log to show for it. So the assertion here
// is on the WARNING, not just on the (defaulted) return value -- the return value alone is exactly what a
// silent fallback would also produce.
TEST_CASE("readFrameResizeBand warns about the legacy unit key instead of silently defaulting") {
    LogCapture log;
    // 999 is arbitrary: the whole point is that the legacy key's VALUE never reaches anything.
    const auto band = readFrameResizeBand(
        json_util::Json::parse(R"({"frame_resize": {"enabled": true, "unit": 999, "max_unit": 900}})"));

    CHECK(log.contains("frame_resize.unit"));
    // The keys it DOES understand are still honoured, and the legacy one contributes nothing.
    CHECK(bandIs(band, kDefaultFrameResizeMinUnit, 900));
}

TEST_CASE("the legacy unit key is reported even when the block is disabled") {
    // `enabled` says nothing about which schema the writer speaks, and a stale writer that happens to have
    // the resize switched off today is the same stale writer tomorrow.
    LogCapture log;
    CHECK_FALSE(
        readFrameResizeBand(json_util::Json::parse(R"({"frame_resize": {"enabled": false, "unit": 999}})"))
            .has_value());
    CHECK(log.contains("frame_resize.unit"));
}

TEST_CASE("a band-schema config produces no legacy warning") {
    // The negative half of the case above: without it, a `contains` that matched everything would pass.
    LogCapture log;
    CHECK(bandIs(
        readFrameResizeBand(
            json_util::Json::parse(R"({"frame_resize": {"enabled": true, "min_unit": 540, "max_unit": 720}})")),
        540,
        720));
    CHECK_FALSE(log.contains("frame_resize.unit"));
}

}  // namespace
}  // namespace uma::app
