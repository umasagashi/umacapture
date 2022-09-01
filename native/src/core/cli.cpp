#include <filesystem>
#include <fstream>
#include <iostream>

#include <CLI11/CLI11.hpp>
#include <minimal_uuid4/minimal_uuid4.h>
#include <runner/window_recorder.h>
#include <runner/windows_config.h>

#include "builder/chara_detail_recognizer_builder.h"
#include "builder/chara_detail_scene_context_builder.h"
#include "builder/chara_detail_scene_scraper_builder.h"
#include "builder/chara_detail_scene_stitcher_builder.h"
#include "condition/serializer.h"
#include "core/native_api.h"
#include "cv/video_loader.h"
#include "util/json_util.h"
#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::cli {

template<typename T, typename ToJson, typename FromJson>
void buildJson(const std::filesystem::path &path, ToJson toJson, FromJson fromJson) {
    std::filesystem::create_directories(path.parent_path());

    auto context = T().build();
    json_util::Json json = toJson(context);
    io_util::write(path, json.dump(2));

    json_util::Json reconstructed_json = toJson(fromJson(json_util::Json::parse(io_util::read(path))));
    log_debug(reconstructed_json.dump(2));
    assert_(json == reconstructed_json);
}

json_util::Json createConfig(bool video_mode) {
    const std::filesystem::path config_dir = "../../assets/config";
    return {
        {"chara_detail",
         {
             {"scene_context", json_util::read(config_dir / "chara_detail" / "scene_context.json")},
             {"scene_scraper", json_util::read(config_dir / "chara_detail" / "scene_scraper.json")},
             {"scene_stitcher", json_util::read(config_dir / "chara_detail" / "scene_stitcher.json")},
             {"recognizer", json_util::read(config_dir / "chara_detail" / "recognizer.json")},
         }},
        {"platform", json_util::read(config_dir / "platform.json")},
        {"video_mode", video_mode},
        {"directory",
         {
             {"temp_dir", (std::filesystem::current_path() / "temp").string()},
             {"storage_dir", (std::filesystem::current_path() / "storage").string()},
             {"modules_dir", "../../sandbox/modules"},
         }},
        {"trainer_id", minimal_uuid4::Generator().uuid4().str()},
    };
}

void captureFromScreen() {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<cv::Mat, uint64>();
    const auto window_recorder = std::make_unique<windows::WindowRecorder>(connection);

    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([](const auto &message) { log_debug("CLI: {}", message); });
    connection->listen([&api](const auto &frame, uint64 timestamp) { api.updateFrame(frame, timestamp); });

    const auto config = createConfig(false);
    api.startEventLoop(config.dump());

    const auto windows_config = config["platform"]["windows"].get<windows::windows_config::WindowsConfig>();
    window_recorder->setConfig(windows_config.window_recorder.value());

    recorder_runner->start();
    window_recorder->startRecord();

    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void captureFromVideo(const std::vector<std::filesystem::path> &video_path_list) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<cv::Mat, uint64>();

    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([](const auto &message) { log_debug("CLI: {}", message); });
    connection->listen([&api](const auto &frame, uint64 timestamp) { api.updateFrame(frame, timestamp); });

    const auto config = createConfig(true);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    auto video = video::VideoLoader(connection);
    video.runBatch(video_path_list);

    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void stitchFromImages(const std::string &id) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");

    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([](const auto &message) { log_debug("CLI: {}", message); });

    const auto config = createConfig(true);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    api.stitch(id);

    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void recognizeFromImages(const std::string &id) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");

    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([](const auto &message) { log_debug("CLI: {}", message); });

    const auto config = createConfig(true);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    api.recognize(id);

    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

}  // namespace uma::cli

int main(int argc, char **argv) {
    uma::logger_util::init();

    vlog_trace(1, 2, 3);
    vlog_debug(1, 2, 3);
    vlog_info(1, 2, 3);
    vlog_warning(1, 2, 3);
    vlog_error(1, 2, 3);
    vlog_fatal(1, 2, 3);

    try {
        CLI::App command{"App description"};
        command.require_subcommand(1);

        auto build_command = command.add_subcommand("build", "build scene context");
        std::filesystem::path assets_dir;
        build_command->add_option("--assets_dir", assets_dir)->required();

        auto capture_command = command.add_subcommand("capture", "run capture mode");

        auto video_command = command.add_subcommand("video", "run capture mode from video");
        std::vector<std::filesystem::path> video_path_list;
        video_command->add_option("--video_path_list", video_path_list)->required();

        auto stitch_command = command.add_subcommand("stitch", "run capture mode from scraped images");
        std::string id;
        stitch_command->add_option("--id", id)->required();

        auto recognize_command = command.add_subcommand("recognize", "run recognizer mode from stitched images");
        recognize_command->add_option("--id", id)->required();

        CLI11_PARSE(command, argc, argv)

        if (build_command->parsed()) {
            uma::cli::buildJson<uma::tool::CharaDetailSceneContextBuilder>(
                assets_dir / "chara_detail" / "scene_context.json",
                [](const auto &obj) { return obj->toJson(); },
                [](const auto &json) { return uma::condition::serializer::conditionFromJson(json); });

            uma::cli::buildJson<uma::tool::CharaDetailSceneScraperBuilder>(
                assets_dir / "chara_detail" / "scene_scraper.json",
                [](const auto &obj) { return obj; },
                [](const auto &json) { return json; });

            uma::cli::buildJson<uma::tool::CharaDetailSceneStitcherBuilder>(
                assets_dir / "chara_detail" / "scene_stitcher.json",
                [](const auto &obj) { return obj; },
                [](const auto &json) { return json; });

            uma::cli::buildJson<uma::tool::CharaDetailRecognizerBuilder>(
                assets_dir / "chara_detail" / "recognizer.json",
                [](const auto &obj) { return obj; },
                [](const auto &json) { return json; });
        }

        if (capture_command->parsed()) {
            uma::cli::captureFromScreen();
        }

        if (video_command->parsed()) {
            uma::cli::captureFromVideo(video_path_list);
        }

        if (stitch_command->parsed()) {
            uma::cli::stitchFromImages(id);
        }

        if (recognize_command->parsed()) {
            uma::cli::recognizeFromImages(id);
        }
    } catch (std::exception &e) {
        std::cerr << e.what() << std::endl;
        exit(1);
    }

    spdlog::drop_all();
    return 0;
}
