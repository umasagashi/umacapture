#include <filesystem>
#include <fstream>
#include <iostream>

#include <CLI11/CLI11.hpp>
#include <runner/window_recorder.h>
#include <runner/windows_config.h>

#include "builder/chara_detail_scene_context_builder.h"
#include "builder/chara_detail_scene_scraper_builder.h"
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

json_util::Json createConfig() {
    const std::filesystem::path config_dir = "../../assets/config";
    return {
        {
            "chara_detail",
            {
                {"scene_context", json_util::read(config_dir / "chara_detail/scene_context.json")},
                {"scene_scraper", json_util::read(config_dir / "chara_detail/scene_scraper.json")},
                {"scraping_dir", (std::filesystem::current_path() / "scraping").generic_string()},
            },
        },
        {"platform", json_util::read(config_dir / "platform.json")},
    };
}

void captureFromScreen() {
    const auto recorder_runner = event_util::makeSingleThreadRunner(nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<cv::Mat, uint64>();
    const auto window_recorder = std::make_unique<windows::WindowRecorder>(connection);

    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([](const auto &message) { std::cout << "notify: " << message << std::endl; });
    connection->listen([&api](const auto &frame, uint64 timestamp) { api.updateFrame(frame, timestamp); });

    const auto config = createConfig();
    api.startEventLoop(config.dump());

    const auto windows_config = config["platform"]["windows"].get<windows::windows_config::WindowsConfig>();
    window_recorder->setConfig(windows_config.window_recorder.value());

    recorder_runner->start();
    window_recorder->startRecord();

    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void captureFromVideo(const std::filesystem::path &path) {
    const auto recorder_runner = event_util::makeSingleThreadRunner(nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<cv::Mat, uint64>();

    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([](const auto &message) { std::cout << "notify: " << message << std::endl; });
    connection->listen([&api](const auto &frame, uint64 timestamp) { api.updateFrame(frame, timestamp); });

    const auto config = createConfig();
    api.startEventLoop(config.dump());

    recorder_runner->start();

    auto video = video::VideoLoader(connection);
    video.run(path);

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
        std::filesystem::path video_path;
        video_command->add_option("--video_path", video_path)->required();

        CLI11_PARSE(command, argc, argv)

        vlog_debug(assets_dir.string(), video_path.string());

        if (build_command->parsed()) {
            uma::cli::buildJson<uma::tool::CharaDetailSceneContextBuilder>(
                assets_dir / "chara_detail" / "scene_context.json",
                [](const auto &obj) { return obj->toJson(); },
                [](const auto &json) { return uma::condition::serializer::conditionFromJson(json); });

            uma::cli::buildJson<uma::tool::CharaDetailSceneScraperBuilder>(
                assets_dir / "chara_detail" / "scene_scraper.json",
                [](const auto &obj) { return obj; },
                [](const auto &json) { return json; });
        }

        if (capture_command->parsed()) {
            uma::cli::captureFromScreen();
        }

        if (video_command->parsed()) {
            uma::cli::captureFromVideo(video_path);
        }
    } catch (std::exception &e) {
        std::cerr << e.what() << std::endl;
        exit(1);
    }

    spdlog::drop_all();
    return 0;
}
