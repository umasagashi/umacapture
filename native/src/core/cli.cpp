#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
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
#include "core/cli_run_report.h"
#include "core/native_api.h"
#include "core/pipeline_config.h"
#include "core/pipeline_drain.h"
#include "cv/ffv1_reader.h"
#include "cv/ffv1_recorder.h"
#include "cv/video_loader.h"
#include "stop_file_guard.h"
#include "util/json_util.h"
#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::cli {

namespace {

// Wait for the whole offline chain to DRAIN, then join the event loop so the process can exit.
//
// The barrier itself -- which stages are asked, in which order, and what the deadline means -- lives in
// core/pipeline_drain.h, together with the reason `recorder_runner` has to be one of those stages. Here it is
// only wired up and its verdict turned into a process outcome: a wedged stage becomes a throw, which main()
// prints and reports as a non-zero exit, so it cannot be mistaken for a successful run that simply produced
// fewer records.
void runUntilDrainedThenJoin(app::NativeApi &api, const event_util::EventRunner &recorder_runner) {
    if (runUntilDrainedThenJoin(offlineDrainBarrier(api, recorder_runner)) == DrainOutcome::TimedOut) {
        throw std::runtime_error("the pipeline did not drain within the deadline; results are incomplete");
    }
}

// The end-of-input signal for an offline subcommand, ON THE RECORDER RUNNER -- which is the whole point of
// routing it through a connection instead of calling api.endOfInput() from the producer's thread.
//
// VideoLoader::runBatch / Ffv1Reader::run return after their last ENQUEUE onto that runner, not after delivery
// (core/pipeline_drain.h makes the same point about the drain barrier), so at the moment they return whole
// frames can still be sitting one stage upstream of NativeApi. Calling endOfInput() there would close an open
// chara-detail scene while those frames were still queued and make a healthy clip report a truncation it did
// not have. Sent on this runner instead, the signal is dequeued strictly after every frame already sent on the
// frame connection -- one notifier queue orders every connection a runner owns (util/event_util.h) -- and
// NativeApi::endOfInput then posts onto the distributor runner behind the frames it has itself accepted.
//
// Must be created before the runner is started (makeConnection refuses afterwards) and sent after the producer
// has returned.
[[nodiscard]] event_util::Sender<> makeEndOfInputSignal(
    app::NativeApi &api, const event_util::SingleThreadMultiEventRunner &recorder_runner) {
    const auto connection = recorder_runner->makeConnection<>("end_of_input");
    connection->listen([&api]() { api.endOfInput(); });
    return connection;
}

// What this invocation observed on the notify stream, kept at file scope because main() composes the summary
// line AFTER the subcommand has returned or thrown -- including from a run that threw, which still owes an
// account of what it managed to report. One process runs one subcommand, so one report is the whole run.
RunReport g_run_report;

// Every notification goes two places: the log, as before, and the run report that becomes the machine-readable
// summary line and the classified exit code (core/cli_run_report.h).
//
// Installed through one function rather than repeated per subcommand so that a subcommand cannot be added with
// only half of it. A subcommand that logged but did not report would exit 0 while announcing a failure -- the
// exact silence this change exists to end.
void installNotifyCallback(app::NativeApi &api) {
    api.setNotifyCallback([](const auto &message) {
        g_run_report.observe(message);
        log_debug("CLI: {}", message);
    });
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

// The band the CLI's `--frame-resize` writes into `frame_resize`, so it asks for exactly the band the app
// asks for.
//
// DERIVED, not repeated: these used to be a second literal carrying the same number, kept in step by a
// comment alone. Aliasing the constants in core/pipeline_config.h makes the mirroring a fact of the code
// instead of a promise about it, so the one pair of C++ literals -- and the doctest that pins them -- cover
// the CLI too, and the two cannot drift apart without the test going red. That matters more here than
// anywhere else: cli.cpp carries `main()` and is therefore NOT linked into `umacapture_tests`, so a literal
// written out here would be guarded by nothing at all. The KEY NAMES are a separate matter and are NOT
// covered by that test -- see the `frame_resize` guard in test/integration/run.py, which is what reads back
// what this writer emits.
constexpr int kFrameResizeMinUnit = app::kDefaultFrameResizeMinUnit;
constexpr int kFrameResizeMaxUnit = app::kDefaultFrameResizeMaxUnit;

// Help text for the `--frame-resize` / `--no-frame-resize` flag pair, built from the constants above for the
// same reason they are derived: hand-written numbers in the help would go stale silently the next time the
// band moves. [off_tail] says what turning it OFF means for the subcommand being described.
[[nodiscard]] inline std::string frameResizeHelp(const std::string &off_tail) {
    return "hold the anchor unit of the frames forwarded to the scraper inside the "
         + std::to_string(kFrameResizeMinUnit) + "-" + std::to_string(kFrameResizeMaxUnit)
         + " px band, scaling up below it and down above it (on by default, matching the app's shipped "
           "setting; --no-frame-resize " + off_tail + ")";
}

// `detail_crop_calibration` arms the in-frame client-rect auto-calibration. It defaults on (matching the app,
// where the key is absent). Both offline producers default it on: they hand over full decoded pixels for the
// whole clip, and the latch is applied on the consumer side as the Frame anchor (see cv/video_loader.h --
// resolving it in the producer would make the delivered frames depend on thread scheduling).
//
// `frame_resize` arms the neutral frame-resize the app exposes as a setting, and it defaults ON for the same
// reason calibration does: the app ships it on, so this is the config a run has to build to answer the
// question the CLI is actually asked -- "what does the recognition core do with this clip?". It defaulted OFF
// while the app shipped it off; keeping that default once the app turned it on would make every CLI run, and
// every integration golden, a measurement of a configuration nobody uses, silently, unless the operator
// remembered a flag.
//
// It matters most on `replay`. Live `capture --record` tees the frames to the recorder BEFORE they reach the
// pipeline (the band is applied at the consumer's forward site, see chara_detail_scene_context.cpp), so a
// recording is always raw pixels: reproducing what that session recognized means replaying it under the same
// band the session ran with, which is now the same default on both sides. `--no-frame-resize` is the escape
// hatch for the opposite question -- what this clip looks like at its own resolution.
json_util::Json createConfig(
    bool video_mode,
    const PipelinePaths &paths = {},
    bool detail_crop_calibration = true,
    bool frame_resize = true) {
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
        {"detail_crop_calibration", detail_crop_calibration},
        {"frame_resize",
         {{"enabled", frame_resize}, {"min_unit", kFrameResizeMinUnit}, {"max_unit", kFrameResizeMaxUnit}}},
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
    // Clear any stale stop-file so a leftover from a previous run cannot end this one immediately.
    // FIRST, before the recorder, the window capturer or the event loop exist, because the guard can
    // refuse: a path that already holds something is not a stale sentinel and will not be deleted
    // (tool/stop_file_guard.h explains what it removes and why it is decided that way). Throwing here
    // is a run that never started; the behaviour it replaces could delete a recording that cannot be
    // made again.
    if (!stop_file.empty()) {
        const auto clearance = tool::clearStaleStopFile(stop_file);
        if (clearance.clearance == tool::StopFileClearance::Refused) {
            throw std::runtime_error(clearance.reason);
        }
        if (clearance.clearance == tool::StopFileClearance::Cleared) {
            log_info("{}", clearance.reason);
        }
    }

    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<Frame, Size<int>>();
    auto &api = app::NativeApi::instance();
    const auto window_recorder = std::make_unique<windows::WindowRecorder>(
        connection,
        [&api](const Size<int> &size) { return api.frameShapingSnapshot(size); },
        record_path ? windows::windows_impl::ShapingMode::AnchorOnly
                    : windows::windows_impl::ShapingMode::CropPixels);
    installNotifyCallback(api);

    // Optional debug recorder: record the full, pre-crop client pixels to lossless FFV1 for later replay.
    // WindowRecorder uses AnchorOnly in this mode, so live recognition still receives the latched pane anchor
    // while this tee sees a stable full-size pixel matrix. FFV1 stores pixels, not Frame anchor metadata.
    // The encoder is built lazily on the first frame; a construction failure disables recording, not capture.
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
    // The stale stop-file was already cleared (or refused) at the top of this function -- see there.
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
    auto &api = app::NativeApi::instance();
    const auto window_recorder = std::make_unique<windows::WindowRecorder>(
        connection,
        [&api](const Size<int> &size) { return api.frameShapingSnapshot(size); });

    const auto config = createConfig(false);
    const auto windows_config = config["platform"]["windows"].get<windows::windows_config::WindowsConfig>();
    window_recorder->setConfig(windows_config.window_recorder.value());

    const auto error = window_recorder->takeScreenshot(output_path);
    if (!error.empty()) {
        throw std::runtime_error(error);
    }
    log_info("Screenshot saved to {}", output_path.string());
}

void captureFromVideo(
    const std::vector<std::filesystem::path> &video_path_list,
    const PipelinePaths &paths,
    bool detail_crop_calibration = true,
    bool frame_resize = true,
    const std::optional<color::ColorMatrix> &diagnostic_matrix = std::nullopt) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<Frame, Size<int>>();

    auto &api = app::NativeApi::instance();
    installNotifyCallback(api);
    connection->listen([&api](const auto &frame, const auto &size) { api.updateFrame(frame, size); });
    const auto end_of_input = makeEndOfInputSignal(api, recorder_runner);

    // VideoLoader decodes and sends; it resolves no pane decision (cv/video_loader.h). Every frame recognition
    // sees is therefore a pure function of the clip: the two Block-mode queues change read-ahead only, never
    // order or content, and the latched pane is applied on the single distributor thread.
    const auto config = createConfig(true, paths, detail_crop_calibration, frame_resize);
    log_info("detail crop calibration: {}", detail_crop_calibration ? "enabled" : "disabled");
    log_info("frame resize: {}", frame_resize ? "enabled" : "disabled");
    if (diagnostic_matrix.has_value()) {
        log_info("colour matrix: {} (diagnostic planar decode)",
                 diagnostic_matrix.value() == color::ColorMatrix::Bt709 ? "bt709" : "bt601");
    }
    api.startEventLoop(config.dump());

    recorder_runner->start();

    auto video = video::VideoLoader(connection, diagnostic_matrix);
    video.runBatch(video_path_list);
    // The clip list is exhausted. Behind the frames still on the recorder runner -- see makeEndOfInputSignal.
    end_of_input->send();

    runUntilDrainedThenJoin(api, recorder_runner);
}

// Replay starts from full recorded pixels and runs pane detection/calibration by default. Ffv1Reader keeps
// those pixels intact for the whole recording; once the pane latch is available it is the consumer that
// changes the Frame anchor for downstream geometry.
// Legacy FFV1 files recorded before full-frame capture carry no format marker and may already contain shaped
// pixels. They are indistinguishable at decode time; use --no-calibrate if re-detecting such a clip is harmful.
void replayFromRecording(
    const std::filesystem::path &record_path,
    const PipelinePaths &paths,
    bool detail_crop_calibration = true,
    bool frame_resize = true) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    const auto connection = recorder_runner->makeConnection<Frame, Size<int>>();

    auto &api = app::NativeApi::instance();
    installNotifyCallback(api);
    connection->listen([&api](const auto &frame, const auto &size) { api.updateFrame(frame, size); });
    const auto end_of_input = makeEndOfInputSignal(api, recorder_runner);

    // video_mode=true gives the pipeline a Block queue (no dropped frames) and disables the frame-stall
    // watchdog; together with a producer that resolves no pane decision of its own (cv/ffv1_reader.h) the
    // replay is deterministic -- the frames recognition sees are a pure function of the recording, paced by
    // the queue rather than wall-clock. Nothing on this path ever crops pixels.
    const auto config = createConfig(true, paths, detail_crop_calibration, frame_resize);
    log_info("detail crop calibration: {}", detail_crop_calibration ? "enabled" : "disabled");
    log_info("frame resize: {}", frame_resize ? "enabled" : "disabled");
    api.startEventLoop(config.dump());

    recorder_runner->start();

    video::Ffv1Reader reader(record_path, connection);
    reader.run();
    // The recording is exhausted. Behind the frames still on the recorder runner -- see makeEndOfInputSignal.
    end_of_input->send();

    runUntilDrainedThenJoin(api, recorder_runner);
}

void stitchFromImages(const std::string &id, const PipelinePaths &paths) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");

    auto &api = app::NativeApi::instance();
    installNotifyCallback(api);

    const auto config = createConfig(true, paths);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    api.stitch({id, chara_detail::record::RecordType::Standard});

    runUntilDrainedThenJoin(api, recorder_runner);
}

void recognizeFromImages(const std::vector<std::string> &id_list, const PipelinePaths &paths) {
    const auto recorder_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");

    auto &api = app::NativeApi::instance();
    installNotifyCallback(api);

    const auto config = createConfig(true, paths);
    api.startEventLoop(config.dump());

    recorder_runner->start();

    for (const auto &id : id_list) {
        api.recognize(id);
    }

    runUntilDrainedThenJoin(api, recorder_runner);
}

}  // namespace uma::cli

int main(int argc, char **argv) {
    uma::logger_util::init();

    // Set for the subcommands that start the pipeline, and left empty for the ones that do not (`build`,
    // `screenshot`): those never touch NativeApi, so there is no run to report and a summary line claiming
    // zero records for them would be a lie about a run that never happened.
    std::optional<uma::cli::RunInvocation> run;
    bool threw = false;
    try {
        CLI::App command{"App description"};
        command.require_subcommand(1);

        auto build_command = command.add_subcommand("build", "build scene context");
        std::filesystem::path assets_dir;
        build_command->add_option("--assets_dir", assets_dir)->required();

        auto capture_command = command.add_subcommand("capture", "run capture mode");
        std::filesystem::path capture_record_path;
        capture_command->add_option(
            "--record", capture_record_path, "record full pre-shaping client frames to lossless FFV1 for replay");
        int capture_duration_seconds = 0;
        capture_command->add_option(
            "--duration", capture_duration_seconds, "stop capture automatically after N seconds (0 = until Ctrl-C)");
        std::filesystem::path capture_stop_file;
        capture_command->add_option(
            "--stop-file",
            capture_stop_file,
            "stop capture cleanly when this file appears (for scripted control). A stale EMPTY file at that "
            "path is cleared at startup; a path that already holds anything else makes the run refuse to start "
            "rather than delete it");

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
        bool video_calibrate = true;
        video_command->add_flag(
            "--calibrate{true},!--no-calibrate",
            video_calibrate,
            "enable pane auto-calibration and shaping (on by default; --no-calibrate disables it)");
        bool video_frame_resize = true;
        video_command->add_flag(
            "--frame-resize{true},!--no-frame-resize",
            video_frame_resize,
            uma::cli::frameResizeHelp("recognises the clip's own resolution instead"));
        std::string video_color_matrix;
        video_command->add_option(
            "--color_matrix",
            video_color_matrix,
            "DIAGNOSTIC: decode the clip's own YUV planes and convert them with this matrix instead of "
            "letting OpenCV/swscale convert (which is always bt601, whatever the stream is tagged). "
            "bt601 reproduces the default to within one unit per channel (its limited-range luma ramp is "
            "deliberately coarsened; the records are unchanged). bt709 is the interpretation a browser applies, "
            "which it does by default and not by reading a tag. Used by test/integration/run_dual_decode.py to "
            "measure how much colour shift recognition tolerates; leave unset for the shipping behaviour.")
            ->check(CLI::IsMember({"bt601", "bt709"}));

        auto replay_command =
            command.add_subcommand("replay", "replay a recorded FFV1 .mkv through the recognition pipeline");
        std::filesystem::path replay_path;
        replay_command->add_option("--record", replay_path, "path to the recorded .mkv")->required();
        uma::cli::PipelinePaths replay_paths;
        addPipelinePathOptions(replay_command, replay_paths);
        bool replay_calibrate = true;
        replay_command->add_flag(
            "--calibrate{true},!--no-calibrate",
            replay_calibrate,
            "enable pane detection/calibration and anchor-only shaping (default for new capture --record files; "
            "legacy already-shaped clips may require --no-calibrate)");
        bool replay_frame_resize = true;
        replay_command->add_flag(
            "--frame-resize{true},!--no-frame-resize",
            replay_frame_resize,
            uma::cli::frameResizeHelp("replays the recording's own resolution instead"));

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
            // Assigned BEFORE the call, so a subcommand that throws still gets its summary line.
            run = uma::cli::RunInvocation{"capture", 0};
            std::optional<std::filesystem::path> record =
                capture_command->count("--record") > 0 ? std::optional{capture_record_path} : std::nullopt;
            uma::cli::captureFromScreen(record, capture_duration_seconds, capture_stop_file);
        }

        if (screenshot_command->parsed()) {
            uma::cli::screenshotFromScreen(screenshot_output);
        }

        if (video_command->parsed()) {
            run = uma::cli::RunInvocation{"video", static_cast<int64_t>(video_path_list.size())};
            std::optional<uma::color::ColorMatrix> matrix;
            if (video_color_matrix == "bt601") {
                matrix = uma::color::ColorMatrix::Bt601;
            } else if (video_color_matrix == "bt709") {
                matrix = uma::color::ColorMatrix::Bt709;
            }
            uma::cli::captureFromVideo(
                video_path_list, video_paths, video_calibrate, video_frame_resize, matrix);
        }

        if (replay_command->parsed()) {
            run = uma::cli::RunInvocation{"replay", 1};
            uma::cli::replayFromRecording(replay_path, replay_paths, replay_calibrate, replay_frame_resize);
        }

        if (stitch_command->parsed()) {
            run = uma::cli::RunInvocation{"stitch", 1};
            uma::cli::stitchFromImages(stitch_id, stitch_paths);
        }

        if (recognize_command->parsed()) {
            run = uma::cli::RunInvocation{"recognize", static_cast<int64_t>(recognize_id_list.size())};
            uma::cli::recognizeFromImages(recognize_id_list, recognize_paths);
        }
    } catch (std::exception &e) {
        // Record that the run did not finish and fall through instead of exit(1), so normal unwinding runs and
        // the cleanup below still executes. The exit code is decided in one place, below.
        std::cerr << e.what() << std::endl;
        threw = true;
    }

    // A subcommand can throw after startEventLoop() has started the pipeline (e.g. VideoLoader failing to open
    // a file), leaving the event loop running. Join it here, while spdlog is still alive, so its teardown
    // logging is safe -- and before drop_all(), so the ~NativeApi atexit join finds nothing to do and never
    // logs through an already-destroyed logger (which would crash). No-op when nothing was started (e.g.
    // `build`) or when the subcommand already joined (stitch/recognize/video on success).
    uma::app::NativeApi::instance().joinEventLoop();

    // THE RUN'S ACCOUNT OF ITSELF, after the event loop has been joined and therefore after every notification
    // it was going to send. The record count is read here for the same reason: it is only a fact once the
    // recognizer has finished with everything still in flight (NativeApi::recordsProduced says so), and reading
    // it early would undercount -- which for zero is the difference between a reported failure and a silent one.
    //
    // ON STDERR, NOT STDOUT, and this is the point where the two streams stop being interchangeable:
    //   * spdlog writes to stdout through its own sink (util/logger_util.cpp), so a std::cout line can be
    //     interleaved mid-line with a log record and stop being one parseable line at all;
    //   * a harness that shows only the tail of stderr on failure (test/integration/run.py) would otherwise
    //     have the verdict on the one stream it does not show;
    //   * main's own fatal message already goes here, so a run that threw keeps its two lines together.
    // Nothing is removed from stdout: the notifications themselves still log exactly as before.
    int rc = uma::cli::kExitOk;
    if (run.has_value()) {
        run->records = uma::app::NativeApi::instance().recordsProduced();
        // The geometry the run recognized at, read at the same point and for the same reason as the count
        // above: only after the drain barrier has every forwarded frame been observed.
        const auto geometry = uma::app::NativeApi::instance().forwardedFrameGeometry();
        run->forwarded_frames = geometry.frames;
        run->anchor_unit_min = geometry.min_unit;
        run->anchor_unit_max = geometry.max_unit;
        rc = uma::cli::g_run_report.exitCode(threw);
        run->exit_code = rc;
        std::cerr << uma::cli::g_run_report.summaryLine(run.value()) << std::endl;
    } else if (threw) {
        // `build` / `screenshot` run no pipeline, so they have no verdict to report -- only whether they threw.
        rc = uma::cli::kExitDidNotRun;
    }

    spdlog::drop_all();
    return rc;
}
