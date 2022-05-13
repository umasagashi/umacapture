#include <filesystem>
#include <fstream>
#include <iostream>

#include "../../windows/runner/window_recorder.h"
#include "../../windows/runner/windows_config.h"
#include "util/json_utils.h"

#include "native_api.h"

using json = nlohmann::json;

std::string read(const std::string &path) {
    std::ifstream file(path);
    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

int main() {
    std::cout << "Hello, World!" << std::endl;

    auto connection = connection::make_connection<connection::QueuedConnection<const cv::Mat &>>();
    auto window_recorder = std::make_unique<recording::WindowRecorder>(connection);
    auto recorder_runner = connection::make_runner(connection);
    auto &api = NativeApi::instance();

    std::string config_string = read("../../assets/config/platform_config.json");
    api.setConfig(config_string);

    {
        const auto directory_config = std::filesystem::current_path() / "temp";
        std::filesystem::remove_all(directory_config);
        std::filesystem::create_directories(directory_config);
        api.setConfig(json{{"directory", directory_config.string()}}.dump());
    }

    {
        const auto config_json = json::parse(config_string);
        const auto windows_config_json = config_json.find("windows_config");
        assert(windows_config_json != config_json.end());
        const auto windows_config = windows_config_json->template get<config::WindowsConfig>();
        assert(windows_config.window_recorder.has_value());
        window_recorder->setConfig(windows_config.window_recorder.value());
    }

    api.setCallback([](const auto &message) { std::cout << "notify: " << message << std::endl; });
    connection->listen([&api](const auto &frame) { api.updateFrame(frame); });

    api.startEventLoop();
    recorder_runner->start();
    window_recorder->startRecord();

    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return 0;
}
