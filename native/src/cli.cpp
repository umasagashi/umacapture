#include <filesystem>
#include <fstream>
#include <iostream>

#include <CLI11/CLI11.hpp>
#include <runner/window_recorder.h>
#include <runner/windows_config.h>
#include <scene_context/chara_detail_scene_context_builder.h>

#include "condition/serializer.h"
#include "util/common.h"
#include "util/json_utils.h"

#include "native_api.h"

void buildContext(const std::filesystem::path &root_dir) {
    try {
        std::filesystem::create_directories(root_dir);

        const std::string path = (root_dir / "chara_detail.json").generic_string();
        auto context = tool::CharaDetailSceneContextBuilder().build();
        json_utils::Json json = context->toJson();
        io::write(path, json.dump(2));

        auto reconstructed_context = serializer::conditionFromJson(json_utils::Json::parse(io::read(path)));
        json_utils::Json reconstructed_json = reconstructed_context->toJson();
        assert(json == reconstructed_json);
    } catch (std::exception &e) {
        std::cerr << e.what() << std::endl;
        exit(1);
    }

    exit(0);
}

void capture() {
    auto connection = connection::make_connection<connection::QueuedConnection<const cv::Mat &, uint64>>();
    auto window_recorder = std::make_unique<recording::WindowRecorder>(connection);
    auto recorder_runner = connection::make_runner(connection);
    auto &api = NativeApi::instance();

    std::string config_string = io::read("../../assets/config/platform_config.json");
    api.setConfig(config_string);

    {
        const auto directory_config = std::filesystem::current_path() / "temp";
        std::filesystem::remove_all(directory_config);
        std::filesystem::create_directories(directory_config);
        api.setConfig(json_utils::Json{{"directory", directory_config.string()}}.dump());
    }

    {
        const auto context_config = "../../assets/config/scene";
        api.setConfig(json_utils::Json{{"context", context_config}}.dump());
    }

    {
        const auto config_json = json_utils::Json::parse(config_string);
        const auto windows_config_json = config_json.find("windows_config");
        assert(windows_config_json != config_json.end());
        const auto windows_config = windows_config_json->template get<config::WindowsConfig>();
        assert(windows_config.window_recorder.has_value());
        window_recorder->setConfig(windows_config.window_recorder.value());
    }

    api.setCallback([](const auto &message) { std::cout << "notify: " << message << std::endl; });
    connection->listen([&api](const auto &frame, uint64 timestamp) { api.updateFrame(frame, timestamp); });

    api.startEventLoop();
    recorder_runner->start();
    window_recorder->startRecord();

    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

int main(int argc, char **argv) {
    CLI::App command{"App description"};
    command.require_subcommand(1);

    auto build_command = command.add_subcommand("build", "build scene context");
    std::string output_dir;
    build_command->add_option("--output_dir,-o", output_dir)->required();

    auto capture_command = command.add_subcommand("capture", "run capture mode");

    CLI11_PARSE(command, argc, argv)

    if (build_command->parsed()) {
        buildContext(output_dir);
    }

    if (capture_command->parsed()) {
        capture();
    }

    return 0;
}
