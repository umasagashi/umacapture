#include "chara_detail/chara_detail_scene_stitcher.h"

#include <stdexcept>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/record_info.h"
#include "cv/frame.h"
#include "util/logger_util.h"
#include "util/stds.h"

namespace uma::chara_detail {

namespace {

// Reads and validates a CV_8UC3 image up front by delegating to Frame::decodeBgr, which reads the file bytes
// via a wide-path-safe fstream and rejects a missing/corrupt file or a non-3-channel decode (an alpha PNG
// decodes to CV_8UC4, a grayscale one to CV_8UC1). Wrapping either in a Frame only asserts (a no-op in
// release), which later misreads via bgrAt's 3-byte stride or throws deep inside cv::resize; fail legibly here.
cv::Mat readImageBGR(const std::filesystem::path &path) {
    return Frame::decodeBgr(path);
}

}  // namespace

namespace stitcher_impl {

cv::Mat ScrollAreaStitcher::stitch(const std::filesystem::path &input_dir) const {
    const auto paths = imagePaths(input_dir);
    // vconcat over an empty list, or one containing an empty/mismatched Mat (an imread failure on a corrupt
    // or partially-written scrape), throws deep inside OpenCV. Validate up front so the failure is legible.
    if (paths.empty()) {
        throw std::runtime_error("ScrollAreaStitcher::stitch: no scroll-area images in " + input_dir.string());
    }
    std::vector<cv::Mat> images;
    images.reserve(paths.size());
    for (const auto &path : paths) {
        images.push_back(readImageBGR(path));
    }
    cv::Mat stitched;
    cv::vconcat(images, stitched);
    return stitched;
}

std::vector<std::filesystem::path> ScrollAreaStitcher::imagePaths(const std::filesystem::path &dir) const {
    std::vector<std::filesystem::path> paths;
    for (const auto &entry : std::filesystem::directory_iterator(dir)) {
        if (entry.is_regular_file()
            && stds::starts_with(entry.path().filename().string(), path_config.scroll_area.stem())) {
            paths.push_back(entry.path());
        }
    }
    stds::sort(paths);
    return paths;
}

}  // namespace stitcher_impl

CharaDetailSceneStitcher::CharaDetailSceneStitcher(
    const std::filesystem::path &scraping_dir,
    const std::filesystem::path &stitching_dir,
    const event_util::Listener<RecordInfo> &on_stitch_ready,
    const event_util::Sender<RecordInfo> &on_stitch_completed,
    const event_util::Sender<RecordInfo> &on_stitch_failed,
    const stitcher_config::CharaDetailSceneStitcherConfig &config,
    const io_util::DirectoryHooks &directory_hooks)
    : config(config)
    , scraping_root_dir(scraping_dir)
    , stitching_root_dir(stitching_dir)
    , directory_hooks(directory_hooks)
    , on_stitch_ready(on_stitch_ready)
    , on_stitch_completed(on_stitch_completed)
    , on_stitch_failed(on_stitch_failed) {
    on_stitch_ready->listen([this](const auto &info) { stitch(info); });
}

void CharaDetailSceneStitcher::stitch(const RecordInfo &info) const {
    const auto input_dir = scraping_root_dir / info.record_id;
    const auto output_dir = stitching_root_dir / info.record_id;

    vlog_debug(input_dir.string(), output_dir.string());

    try {
        // A missing/partially-written or non-CV_8UC3 base.png decodes to an empty or wrong-channel Mat; wrapping
        // it in a Frame and then calling anchor()/size()/view()/bgrAt() on it misbehaves deep inside OpenCV.
        // readImageBGR validates up front so the failure is legible.
        const auto base_path = input_dir / path_config.base.filename();
        Frame base_image(readImageBGR(base_path));

        stitchTab(base_image, input_dir / path_config.skill.stem(), output_dir, path_config.skill);
        stitchTab(base_image, input_dir / path_config.factor.stem(), output_dir, path_config.factor);
        stitchTab(base_image, input_dir / path_config.campaign.stem(), output_dir, path_config.campaign);

        directory_hooks.rmdir(input_dir);
        on_stitch_completed->send(info);
    } catch (const std::exception &e) {
        // A tab throwing partway leaves output_dir with a half-written record that later reads as complete, and
        // the runner would otherwise just log and drop the exception -- the recognizer never runs and the UI
        // waits forever for onCharaDetailFinished. Remove the partial output (input_dir is kept for diagnosis)
        // and surface a terminal failure. rmdir is best-effort; do not let it mask the original error.
        log_error("stitch failed for record_id={}: {}", info.record_id, e.what());
        try {
            directory_hooks.rmdir(output_dir);
        } catch (const std::exception &cleanup_error) {
            log_error("stitch failed to clean up partial output for record_id={}: {}", info.record_id,
                cleanup_error.what());
        }
        on_stitch_failed->send(info);
    } catch (...) {
        // WinRT exceptions do not derive from std::exception, so the arm above would miss them and skip the
        // terminal notification -- leaving a half-written output and a UI waiting forever. Mirror the cleanup
        // and failure send for any non-std::exception throw.
        log_error("stitch failed for record_id={}: unknown exception", info.record_id);
        try {
            directory_hooks.rmdir(output_dir);
        } catch (...) {
            log_error("stitch failed to clean up partial output for record_id={}: unknown exception",
                info.record_id);
        }
        on_stitch_failed->send(info);
    }
}

void CharaDetailSceneStitcher::stitchTab(
    const Frame &base_image,
    const std::filesystem::path &input_dir,
    const std::filesystem::path &output_dir,
    const PathEntry &path_entry) const {
    const auto scroll_area_window_size = base_image.anchor().mapToFrame(config.scroll_area_rect).size();

    // For record types other than Standard, unnecessary tabs may be left empty -- and PageScrapingBox only
    // creates the directories it actually writes to, so an unscraped tab's input_dir may not exist at all.
    // std::filesystem::is_empty throws if the path is missing, so check existence first (a missing dir is
    // treated as empty, falling back to the dummy image) rather than letting the throw escape the stitcher
    // runner and terminate the process.
    const bool has_content = std::filesystem::exists(input_dir) && !std::filesystem::is_empty(input_dir);
    auto scroll_area =
        Frame::fixed(has_content ? scroll_area_stitcher.stitch(input_dir) : createDummyImage(scroll_area_window_size));

    const auto background_color = scroll_area.colorAt({0.5, 0.0, {ScreenStart, ScreenPixelEnd}});

    // Fill scroll bar.
    scroll_area.fill(config.scroll_bar_fill_rect, background_color);

    // Create canvas.
    const auto amount_of_stretch = scroll_area.size() - scroll_area_window_size;
    // A stitched scroll area shorter than the window makes amount_of_stretch negative, so the canvas below
    // would be a cv::Mat with negative height -- a raw cv::Exception deep inside OpenCV. Fail loud here so the
    // outer catch degrades to on_stitch_failed with a legible cause instead of an opaque OpenCV message.
    if (amount_of_stretch.height() < 0 || amount_of_stretch.width() < 0) {
        throw std::runtime_error(
            "stitched scroll area (" + std::to_string(scroll_area.width()) + "x"
            + std::to_string(scroll_area.height()) + ") is smaller than the window ("
            + std::to_string(scroll_area_window_size.width()) + "x"
            + std::to_string(scroll_area_window_size.height()) + ") for tab " + input_dir.string());
    }
    auto canvas =
        Frame::stretched(cv::Mat{(base_image.size() + amount_of_stretch).toCVSize(), CV_8UC3}, base_image.size());

    const auto stretch_top = config.stretch_range.p1();
    const auto stretch_bottom = config.stretch_range.p2();

    {  // Paste top of base_image.
        const Rect<double> rect = {
            {0.0, 0.0, {ScreenStart}},
            {0.0, stretch_top.y(), {ScreenPixelEnd, stretch_top.anchor().v()}},
        };
        canvas.paste(rect, base_image.view(rect));
    }

    {  // Paste middle of base_image with stretch.
        const Rect<double> rect = {
            {0.0, stretch_top.y(), {ScreenStart, IntersectStart}},
            {0.0, stretch_bottom.y(), {ScreenPixelEnd, IntersectLogicalEnd}},
        };
        // Though the same rect is given, but it is stretched to different sizes in canvas and base_image.
        canvas.paste(rect, base_image.view(rect));
    }

    {  // Paste bottom of base_image.
        const Rect<double> rect = {
            {0.0, stretch_bottom.y(), {ScreenStart, IntersectLogicalEnd}},
            {0.0, 0.0, {ScreenPixelEnd}},
        };
        canvas.paste(rect, base_image.view(rect));
    }

    {  // Paste scroll area.
        const Rect<double> rect = config.scroll_area_cropping_rect;
        canvas.view(config.scroll_area_rect).paste(rect, scroll_area.view(rect));
    }

    // Paste tab.
    // TODO: When the tab button image does not exist, it should be fetched from another record.
    if (const auto tab_path = input_dir / path_config.tab_button.filename(); std::filesystem::exists(tab_path)) {
        canvas.paste(config.tab_button_rect, Frame::fixed(readImageBGR(tab_path)));
    }

    // Fill stains in base_image.
    // base_image was captured while scrolling, so fragments of the scrolling area will appear at the bottom or top edge.
    canvas.fill(config.scroll_area_upper_fill_rect, background_color);
    canvas.fill(config.scroll_area_lower_fill_rect, background_color);

    // Save stitched image and anchor info.
    directory_hooks.mkdir(output_dir);
    canvas.dump(output_dir / path_entry.filename());
}

cv::Mat CharaDetailSceneStitcher::createDummyImage(const Size<int> &size) {
    // TODO: The color should be picked from other tabs.
    return {size.toCVSize(), CV_8UC3, cv::Scalar(243, 243, 243)};
}

}  // namespace uma::chara_detail
