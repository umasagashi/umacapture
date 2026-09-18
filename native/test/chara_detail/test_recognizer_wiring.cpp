// Wiring tests for CharaDetailRecognizer: each of the three inputs its constructor subscribes to reaches the
// method it is meant to reach, and answers on the output it is meant to answer on.
//
// The recognizer here is the production one, built by its production constructor, so the subscriptions under test
// are the ones the app runs. Its predictors come from the test target's makePredictor
// (fake_predictor_factory.cpp), which loads no model: nothing below depends on what a prediction says, only on
// which channel answers, how often, and with which of the forwarded values. The config is the shipped
// recognizer.json. All connections are direct, so every send() delivers synchronously and no case waits.
//
// What these cases cannot see: a capture subscription (recognize_ready) that calls nothing at all passes case 3,
// because the capture path reports failure only to the log and success needs a full record on disk. The golden
// suite, whose every case produces records, is what catches that.

#include <doctest/doctest.h>

#include <cstddef>
#include <filesystem>
#include <functional>
#include <memory>
#include <random>
#include <string>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_recognizer.h"
#include "cv/frame.h"
#include "util/event_util.h"
#include "util/json_util.h"

namespace uma::chara_detail {
namespace {

// A listener that counts how many methods were registered on it, and forwards each registration to a real
// connection so that sending on that connection still reaches the recognizer.
template<typename... Args>
class CountingListener : public event_util::event_util_impl::ListenerInterface<Args...> {
public:
    explicit CountingListener(event_util::Connection<Args...> target)
        : target(std::move(target)) {}

    void listen(const std::function<void(Args...)> &method) override {
        ++registrations;
        target->listen(method);
    }

    int registrations = 0;

private:
    event_util::Connection<Args...> target;
};

// A record root no case creates: every record under it is missing, so recognize() fails at its first read.
std::filesystem::path missingRecordRoot() {
    static const auto root = std::filesystem::temp_directory_path()
                             / ("uma_recognizer_wiring_no_records_" + std::to_string(std::random_device{}()));
    return root;
}

recognizer_config::CharaDetailRecognizerConfig shippedRecognizerConfig() {
    const auto path = std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / "recognizer.json";
    return json_util::read(path).get<recognizer_config::CharaDetailRecognizerConfig>();
}

// Everything a case sends on and reads from, around one production recognizer.
struct Wiring {
    event_util::Connection<RecordInfo> recognize_ready = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<RecordInfo> recognize_completed = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<RecordInfo> update_ready = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<RecordInfo> update_completed = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<Frame, RecordInfo> factor_probe_ready = event_util::makeDirectConnection<Frame, RecordInfo>();
    event_util::Connection<std::vector<record::Factor>, int> factor_probe_completed =
        event_util::makeDirectConnection<std::vector<record::Factor>, int>();
    event_util::Connection<std::string> error = event_util::makeDirectConnection<std::string>();

    std::shared_ptr<CountingListener<RecordInfo>> recognize_ready_spy =
        std::make_shared<CountingListener<RecordInfo>>(recognize_ready);

    std::vector<RecordInfo> recognized;
    std::vector<RecordInfo> updated;
    // The record type each completed probe carried.
    std::vector<int> probes;
    std::vector<std::string> errors;

    std::unique_ptr<CharaDetailRecognizer> recognizer;

    Wiring() {
        recognize_completed->listen([this](const RecordInfo &info) { recognized.push_back(info); });
        update_completed->listen([this](const RecordInfo &info) { updated.push_back(info); });
        factor_probe_completed->listen(
            [this](const std::vector<record::Factor> &, int record_type) { probes.push_back(record_type); });
        error->listen([this](const std::string &message) { errors.push_back(message); });

        const auto config = shippedRecognizerConfig();
        const auto module_root = missingRecordRoot() / "modules";
        const auto factor_rows =
            std::make_shared<const recognizer_impl::FactorRowReader>(module_root, config.factor_tab);
        recognizer = std::make_unique<CharaDetailRecognizer>(
            "wiring_test_trainer",
            missingRecordRoot(),
            module_root,
            factor_rows,
            recognize_ready_spy,
            recognize_completed,
            update_ready,
            update_completed,
            factor_probe_ready,
            factor_probe_completed,
            error,
            config);
    }
};

// A factor-tab frame at the shipped geometry: the page background, the green header at the top of the scroll
// area, and two factor rows under it. Only its shape matters; what the fake predictors read from it does not.
constexpr int kFrameWidth = 736;
constexpr int kFrameHeight = 1308;
constexpr int kContentTop = 596;  // 0.8093 (the shipped scroll area's top) of the frame width

cv::Mat factorTabFrame() {
    cv::Mat mat(kFrameHeight, kFrameWidth, CV_8UC3, cv::Scalar(240, 240, 240));
    const auto band = [&mat](int x0, int x1, int y0, int y1, const cv::Scalar &bgr) {
        mat(cv::Rect(x0, y0, x1 - x0, y1 - y0)).setTo(bgr);
    };
    const int left_x0 = 175, left_x1 = 410, right_x0 = 455, right_x1 = 695;
    band(left_x0, right_x1, kContentTop + 15, kContentTop + 43, cv::Scalar(70, 200, 90));
    band(left_x0, left_x1, kContentTop + 61, kContentTop + 109, cv::Scalar(180, 180, 180));
    band(right_x0, right_x1, kContentTop + 61, kContentTop + 109, cv::Scalar(180, 180, 180));
    return mat;
}

TEST_CASE("a factor probe sent to the recognizer comes back on the completion channel with its record type") {
    REQUIRE_FALSE(std::filesystem::exists(missingRecordRoot()));
    Wiring wiring;
    const Frame frame = Frame::fixed(factorTabFrame());

    wiring.factor_probe_ready->send(frame, RecordInfo{"probe_record", record::RecordType::FriendStandard});

    REQUIRE(wiring.probes.size() == 1);
    CHECK(wiring.probes[0] == static_cast<int>(record::RecordType::FriendStandard));
    CHECK(wiring.errors.empty());
    CHECK(wiring.recognized.empty());
    CHECK(wiring.updated.empty());
}

TEST_CASE("an update request for a record that cannot be read is reported on the error channel") {
    REQUIRE_FALSE(std::filesystem::exists(missingRecordRoot()));
    Wiring wiring;

    wiring.update_ready->send(RecordInfo{"missing", record::RecordType::Standard});

    // The update path is the only one that reports a failure on this channel, so the message also proves the
    // request was routed to update mode.
    REQUIRE(wiring.errors.size() == 1);
    CHECK(wiring.errors[0].rfind("updateRecord failed for record_id=missing: ", 0) == 0);
    CHECK(wiring.updated.empty());
    CHECK(wiring.recognized.empty());
    CHECK(wiring.probes.empty());
    CHECK_FALSE(std::filesystem::exists(missingRecordRoot()));
}

TEST_CASE("the capture input is subscribed once and a failed capture does not report an update error") {
    REQUIRE_FALSE(std::filesystem::exists(missingRecordRoot()));
    Wiring wiring;

    CHECK(wiring.recognize_ready_spy->registrations == 1);

    // Capture mode reports a failure to the log only. An error here would mean this input reached update mode.
    wiring.recognize_ready->send(RecordInfo{"missing", record::RecordType::Standard});

    CHECK(wiring.errors.empty());
    CHECK(wiring.recognized.empty());
    CHECK(wiring.updated.empty());
    CHECK(wiring.probes.empty());
    CHECK_FALSE(std::filesystem::exists(missingRecordRoot()));
}

}  // namespace
}  // namespace uma::chara_detail
