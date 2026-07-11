#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>

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
#include "cv/ffv1_reader.h"
#include "cv/ffv1_recorder.h"
#include "cv/video_loader.h"
#include "util/json_util.h"
#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::cli {

namespace {

// Tracks the wall-clock time of the most recent notify message from the pipeline. The one-shot subcommands
// (stitch/recognize/video) have no single "batch complete" signal to wait on -- video's record count is
// unknown up front and a silently-failing recognize emits no completion -- so they instead run until the
// pipeline goes quiet.
struct ActivityMonitor {
    mutable std::mutex mutex;
    std::chrono::steady_clock::time_point last_activity = std::chrono::steady_clock::now();

    void touch() {
        std::lock_guard<std::mutex> lock(mutex);
        last_activity = std::chrono::steady_clock::now();
    }

    [[nodiscard]] std::chrono::steady_clock::duration idleFor() const {
        std::lock_guard<std::mutex> lock(mutex);
        return std::chrono::steady_clock::now() - last_activity;
    }
};

// Run until the pipeline stops emitting notifications for kIdleGrace, then join the event loop so the process
// can exit. kIdleGrace must exceed the longest quiet gap during real processing, which is dominated by a
// single record's recognize pass; 10s is comfortably above that while keeping shutdown snappy.
void runUntilIdleThenJoin(app::NativeApi &api, ActivityMonitor &monitor) {
    constexpr auto kIdleGrace = std::chrono::seconds(10);
    // Reset the baseline so a slow pipeline start (e.g. model load with no notifications) cannot be mistaken
    // for an idle pipeline before the submitted work has had a chance to run.
    monitor.touch();
    while (api.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (monitor.idleFor() > kIdleGrace) {
            api.joinEventLoop();
            break;
        }
    }
}

// Live `capture` runs an unbounded loop, so it needs a clean stop signal: a hard kill would skip the
// recorder's flush + matroska trailer and leave a `--record` file unfinalized. This console handler lets
// Ctrl-C (and console close / logoff) break the loop so teardown runs. Set from the handler thread, polled
// by the capture loop; g_capture_finalized is set by the capture loop once teardown is done, so the
// handler can hold the process alive for the terminating events (see below).
std::atomic<bool> g_capture_stop_requested{false};
std::atomic<bool> g_capture_finalized{false};

BOOL WINAPI captureConsoleHandler(DWORD ctrl_type) {
    switch (ctrl_type) {
        // The process survives these: signal the loop and return so it finalizes on its own.
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT: g_capture_stop_requested.store(true); return TRUE;
        // Windows terminates the process as soon as the handler returns for these, so returning right after
        // setting the flag would kill the process before the 100 ms capture poll ever sees it. Block this
        // (handler-only) thread until the main thread reports teardown done; the OS enforces its own grace
        // deadline (~5 s close / ~20 s logoff-shutdown) regardless, so this is best-effort -- a worst-case
        // encoder drain (bounded at 30 s in Ffv1Recorder::close) can still be cut short.
        case CTRL_CLOSE_EVENT:
        case CTRL_LOGOFF_EVENT:
        case CTRL_SHUTDOWN_EVENT:
            g_capture_stop_requested.store(true);
            while (!g_capture_finalized.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            return TRUE;
        default: return FALSE;
    }
}

}  // namespace

template<typename T, typename ToJson, typename FromJson>
void buildJson(const std::filesystem::path &path, ToJson toJson, FromJson fromJson) {
    std::filesystem::create_directories(path.parent_path());

    auto context = T().build();
    json_util::Json json = toJson(context);
    io_util::write(path, json.dump(2));

    json_util::Json reconstructed_json = toJson(fromJson(json_util::Json::parse(io_util::read(path))));
    log_debug(reconstructed_json.dump(2));
    // Fail loudly (even in release) if the serializer round-trip drifts, so `build` never writes a config
    // that cannot be read back into an identical object.
    if (json != reconstructed_json) {
        throw std::runtime_error("buildJson round-trip mismatch: " + path.generic_string());
    }
}

// Directory inputs the pipeline needs, defaulting to the historical cwd-relative paths so the
// interactive subcommands keep working unchanged. The one-shot subcommands (video/stitch/recognize)
// expose these as CLI options so a test harness can point them at absolute paths and an isolated
// output dir, making a run independent of the working directory.
struct PipelinePaths {
    std::filesystem::path assets_dir = "../../assets/config";
    std::filesystem::path modules_dir = "../../sandbox/modules";
    // Root under which the run writes temp/ (scraped fragments) and storage/ (finished records).
    std::filesystem::path output_dir = ".";
};

json_util::Json createConfig(bool video_mode, const PipelinePaths &paths = {}) {
    const std::filesystem::path &config_dir = paths.assets_dir;
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
             {"temp_dir", (paths.output_dir / "temp").string()},
             {"storage_dir", (paths.output_dir / "storage").string()},
             {"modules_dir", paths.modules_dir.string()},
         }},
        {"trainer_id", minimal_uuid4::Generator().uuid4().str()},
    };
}

void captureFromScreen(
    const std::optional<std::filesystem::path> &record_path = std::nullopt,
    int duration_seconds = 0,
    const std::filesystem::path &stop_file = {}) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<Frame, Size<int>>();
    const auto window_recorder = std::make_unique<windows::WindowRecorder>(connection);

    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([](const auto &message) { log_debug("CLI: {}", message); });

    // Optional debug recorder: tee every captured frame to a lossless FFV1 .mkv for later replay. Built
    // lazily on the first frame (its size is not known before capture starts); a construction failure is
    // logged once and disables recording rather than aborting the capture.
    std::unique_ptr<video::Ffv1Recorder> recorder;
    bool recorder_failed = false;
    connection->listen([&](const auto &frame, const auto &original_size) {
        if (record_path && !recorder_failed) {
            if (!recorder) {
                try {
                    recorder = std::make_unique<video::Ffv1Recorder>(*record_path, frame.size());
                    log_info("Recording captured frames to {}", record_path->string());
                } catch (const std::exception &e) {
                    recorder_failed = true;
                    log_error("Failed to start frame recording: {}", e.what());
                }
            }
            if (recorder) {
                recorder->push(frame);
            }
        }
        api.updateFrame(frame, original_size);
    });

    const auto config = createConfig(false);
    api.startEventLoop(config.dump());

    const auto windows_config = config["platform"]["windows"].get<windows::windows_config::WindowsConfig>();
    window_recorder->setConfig(windows_config.window_recorder.value());

    recorder_runner->start();
    window_recorder->startRecord();

    // Ctrl-C / console close breaks the loop cleanly so the recorder can finalize (see captureConsoleHandler).
    g_capture_stop_requested.store(false);
    g_capture_finalized.store(false);
    SetConsoleCtrlHandler(&captureConsoleHandler, TRUE);
    // Clear any stale stop-file so a leftover from a previous run cannot end this one immediately.
    if (!stop_file.empty()) {
        std::error_code ec;
        std::filesystem::remove(stop_file, ec);
    }
    if (record_path) {
        log_info(
            "Recording... stop with Ctrl-C{}{}.",
            stop_file.empty() ? "" : " or by creating the stop-file",
            duration_seconds > 0 ? " (or wait for --duration)" : "");
    }
    const auto start = std::chrono::steady_clock::now();
    while (api.isRunning() && !g_capture_stop_requested.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (duration_seconds > 0
            && std::chrono::steady_clock::now() - start >= std::chrono::seconds(duration_seconds)) {
            break;
        }
        if (!stop_file.empty()) {
            std::error_code ec;
            if (std::filesystem::exists(stop_file, ec)) {
                log_info("Stop-file detected; finalizing recording.");
                break;
            }
        }
    }
    SetConsoleCtrlHandler(&captureConsoleHandler, FALSE);

    // Stop producing frames and drain the connection before finalizing the file, so no late listener call
    // races the recorder's trailer write.
    window_recorder->stopRecord();
    recorder_runner->join();
    if (recorder) {
        recorder->close();
    }
    // Release a console handler blocked on a terminating event (close/logoff/shutdown); the file is
    // finalized, so the process may die now.
    g_capture_finalized.store(true);
}

void screenshotFromScreen(const std::filesystem::path &output_path) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<Frame, Size<int>>();
    const auto window_recorder = std::make_unique<windows::WindowRecorder>(connection);

    const auto config = createConfig(false);
    const auto windows_config = config["platform"]["windows"].get<windows::windows_config::WindowsConfig>();
    window_recorder->setConfig(windows_config.window_recorder.value());

    const auto error = window_recorder->takeScreenshot(output_path);
    if (!error.empty()) {
        throw std::runtime_error(error);
    }
    log_info("Screenshot saved to {}", output_path.string());
}

void captureFromVideo(const std::vector<std::filesystem::path> &video_path_list, const PipelinePaths &paths) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<Frame, Size<int>>();

    ActivityMonitor monitor;
    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([&monitor](const auto &message) {
        monitor.touch();
        log_debug("CLI: {}", message);
    });
    connection->listen([&api](const auto &frame, const auto &size) { api.updateFrame(frame, size); });

    const auto config = createConfig(true, paths);
    api.startEventLoop(config.dump());

    const auto windows_config = config["platform"]["windows"].get<windows::windows_config::WindowsConfig>();

    // Pick the crop the way live capture does, per clip: match each clip's frame aspect ratio against the
    // configured crop_profiles. A landscape game recording matches a profile and is cropped to the vertical
    // content region; a portrait phone recording matches nothing and is used uncropped. This replaces the old
    // manual horizontal/vertical toggle.
    const auto crop_profiles = windows_config.window_recorder.value().crop_profiles.value_or(
        std::vector<windows::windows_config::CropProfile>{});

    recorder_runner->start();

    auto video = video::VideoLoader(connection, [crop_profiles](const Size<int> &size) -> std::optional<Rect<double>> {
        const auto profile = windows::windows_config::matchCropProfile(crop_profiles, size);
        return profile.has_value() ? profile->crop_rect : std::nullopt;
    });
    video.runBatch(video_path_list);

    runUntilIdleThenJoin(api, monitor);
}

void replayFromRecording(const std::filesystem::path &record_path, const PipelinePaths &paths) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<Frame, Size<int>>();

    ActivityMonitor monitor;
    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([&monitor](const auto &message) {
        monitor.touch();
        log_debug("CLI: {}", message);
    });
    connection->listen([&api](const auto &frame, const auto &size) { api.updateFrame(frame, size); });

    // video_mode=true gives the pipeline a Block queue (no dropped frames) and disables the frame-stall
    // watchdog, so the replay is deterministic -- the recorded frames drive the recognition exactly as the
    // failed live capture did, paced by the queue rather than by wall-clock. No crop: recorded frames are
    // already pipeline-input form.
    const auto config = createConfig(true, paths);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    video::Ffv1Reader reader(record_path, connection);
    reader.run();

    runUntilIdleThenJoin(api, monitor);
}

void stitchFromImages(const std::string &id, const PipelinePaths &paths) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");

    ActivityMonitor monitor;
    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([&monitor](const auto &message) {
        monitor.touch();
        log_debug("CLI: {}", message);
    });

    const auto config = createConfig(true, paths);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    api.stitch({id, chara_detail::record::RecordType::Standard});

    runUntilIdleThenJoin(api, monitor);
}

void recognizeFromImages(const std::vector<std::string> &id_list, const PipelinePaths &paths) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");

    ActivityMonitor monitor;
    auto &api = app::NativeApi::instance();
    api.setNotifyCallback([&monitor](const auto &message) {
        monitor.touch();
        log_debug("CLI: {}", message);
    });

    const auto config = createConfig(true, paths);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    for (const auto &id : id_list) {
        api.recognize(id);
    }

    runUntilIdleThenJoin(api, monitor);
}

}  // namespace uma::cli

int main(int argc, char **argv) {
    uma::logger_util::init();

    int rc = 0;
    try {
        CLI::App command{"App description"};
        command.require_subcommand(1);

        auto build_command = command.add_subcommand("build", "build scene context");
        std::filesystem::path assets_dir;
        build_command->add_option("--assets_dir", assets_dir)->required();

        auto capture_command = command.add_subcommand("capture", "run capture mode");
        std::filesystem::path capture_record_path;
        capture_command->add_option(
            "--record", capture_record_path, "record every captured frame to a lossless FFV1 .mkv for replay");
        int capture_duration_seconds = 0;
        capture_command->add_option(
            "--duration", capture_duration_seconds, "stop capture automatically after N seconds (0 = until Ctrl-C)");
        std::filesystem::path capture_stop_file;
        capture_command->add_option(
            "--stop-file", capture_stop_file, "stop capture cleanly when this file appears (for scripted control)");

        auto screenshot_command =
            command.add_subcommand("screenshot", "capture a single screenshot from the game window");
        std::filesystem::path screenshot_output = "screenshot.png";
        screenshot_command->add_option("--output", screenshot_output, "output image path");

        // Directory options shared by the one-shot subcommands. Defaults reproduce the historical
        // cwd-relative behavior; a test harness overrides them with absolute paths and an isolated
        // output dir so a run is independent of the working directory.
        const auto addPipelinePathOptions = [](CLI::App *sub, uma::cli::PipelinePaths &paths) {
            sub->add_option("--assets_dir", paths.assets_dir, "config assets dir (default ../../assets/config)");
            sub->add_option("--modules_dir", paths.modules_dir, "ONNX modules dir (default ../../sandbox/modules)");
            sub->add_option("--output_dir", paths.output_dir, "root for temp/ and storage/ (default .)");
        };

        auto video_command = command.add_subcommand("video", "run capture mode from video");
        std::vector<std::filesystem::path> video_path_list;
        video_command->add_option("--video_path_list", video_path_list)->required();
        uma::cli::PipelinePaths video_paths;
        addPipelinePathOptions(video_command, video_paths);

        auto replay_command =
            command.add_subcommand("replay", "replay a recorded FFV1 .mkv through the recognition pipeline");
        std::filesystem::path replay_path;
        replay_command->add_option("--record", replay_path, "path to the recorded .mkv")->required();
        uma::cli::PipelinePaths replay_paths;
        addPipelinePathOptions(replay_command, replay_paths);

        auto stitch_command = command.add_subcommand("stitch", "run capture mode from scraped images");
        std::string stitch_id;
        stitch_command->add_option("--id", stitch_id)->required();
        uma::cli::PipelinePaths stitch_paths;
        addPipelinePathOptions(stitch_command, stitch_paths);

        auto recognize_command = command.add_subcommand("recognize", "run recognizer mode from stitched images");
        std::vector<std::string> recognize_id_list;
        recognize_command->add_option("--id", recognize_id_list)->required();
        uma::cli::PipelinePaths recognize_paths;
        addPipelinePathOptions(recognize_command, recognize_paths);

        CLI11_PARSE(command, argc, argv)

        if (build_command->parsed()) {
            uma::cli::buildJson<uma::tool::CharaDetailSceneContextBuilder>(
                assets_dir / "chara_detail" / "scene_context.json",
                [](const auto &obj) { return obj->toJson(); },
                [](const auto &json) { return uma::condition::serializer::conditionFromJson(json); });

            // fromJson deserializes back into the config struct (not an identity passthrough), so the
            // round-trip check in buildJson actually exercises the config serializer and can catch drift.
            uma::cli::buildJson<uma::tool::CharaDetailSceneScraperBuilder>(
                assets_dir / "chara_detail" / "scene_scraper.json",
                [](const auto &obj) { return obj; },
                [](const auto &json) {
                    return json.template get<uma::chara_detail::scraper_config::CharaDetailSceneScraperConfig>();
                });

            uma::cli::buildJson<uma::tool::CharaDetailSceneStitcherBuilder>(
                assets_dir / "chara_detail" / "scene_stitcher.json",
                [](const auto &obj) { return obj; },
                [](const auto &json) {
                    return json.template get<uma::chara_detail::stitcher_config::CharaDetailSceneStitcherConfig>();
                });

            uma::cli::buildJson<uma::tool::CharaDetailRecognizerBuilder>(
                assets_dir / "chara_detail" / "recognizer.json",
                [](const auto &obj) { return obj; },
                [](const auto &json) {
                    return json.template get<uma::chara_detail::recognizer_config::CharaDetailRecognizerConfig>();
                });
        }

        if (capture_command->parsed()) {
            std::optional<std::filesystem::path> record =
                capture_command->count("--record") > 0 ? std::optional{capture_record_path} : std::nullopt;
            uma::cli::captureFromScreen(record, capture_duration_seconds, capture_stop_file);
        }

        if (screenshot_command->parsed()) {
            uma::cli::screenshotFromScreen(screenshot_output);
        }

        if (video_command->parsed()) {
            uma::cli::captureFromVideo(video_path_list, video_paths);
        }

        if (replay_command->parsed()) {
            uma::cli::replayFromRecording(replay_path, replay_paths);
        }

        if (stitch_command->parsed()) {
            uma::cli::stitchFromImages(stitch_id, stitch_paths);
        }

        if (recognize_command->parsed()) {
            uma::cli::recognizeFromImages(recognize_id_list, recognize_paths);
        }
    } catch (std::exception &e) {
        // Set a failure code and fall through instead of exit(1) so normal unwinding runs and the cleanup
        // below still executes.
        std::cerr << e.what() << std::endl;
        rc = 1;
    }

    // A subcommand can throw after startEventLoop() has started the pipeline (e.g. VideoLoader failing to open
    // a file), leaving the event loop running. Join it here, while spdlog is still alive, so its teardown
    // logging is safe -- and before drop_all(), so the ~NativeApi atexit join finds nothing to do and never
    // logs through an already-destroyed logger (which would crash). No-op when nothing was started (e.g.
    // `build`) or when the subcommand already joined (stitch/recognize/video on success).
    uma::app::NativeApi::instance().joinEventLoop();

    spdlog::drop_all();
    return rc;
}
