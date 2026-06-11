#pragma once

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include <stdexcept>
#include <vector>

#include "util/event_util.h"

namespace uma::chara_detail {

namespace stitcher_impl {

class ScrollAreaStitcher {
public:
    [[nodiscard]] cv::Mat stitch(const std::filesystem::path &input_dir) const {
        const auto paths = imagePaths(input_dir);
        // vconcat over an empty list, or one containing an empty/mismatched Mat (an imread failure on a corrupt
        // or partially-written scrape), throws deep inside OpenCV. Validate up front so the failure is legible.
        if (paths.empty()) {
            throw std::runtime_error("ScrollAreaStitcher::stitch: no scroll-area images in " + input_dir.string());
        }
        std::vector<cv::Mat> images;
        images.reserve(paths.size());
        for (const auto &path : paths) {
            cv::Mat image = cv::imread(path.string(), -1);
            if (image.empty()) {
                throw std::runtime_error("ScrollAreaStitcher::stitch: failed to read image: " + path.string());
            }
            images.push_back(image);
        }
        cv::Mat stitched;
        cv::vconcat(images, stitched);
        return stitched;
    }

private:
    [[nodiscard]] std::vector<std::filesystem::path> imagePaths(const std::filesystem::path &dir) const {
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
};

}  // namespace stitcher_impl

class CharaDetailSceneStitcher {
public:
    CharaDetailSceneStitcher(
        const std::filesystem::path &scraping_dir,
        const std::filesystem::path &stitching_dir,
        const event_util::Listener<RecordInfo> &on_stitch_ready,
        const event_util::Sender<RecordInfo> &on_stitch_completed,
        const stitcher_config::CharaDetailSceneStitcherConfig &config)
        : config(config)
        , scraping_root_dir(scraping_dir)
        , stitching_root_dir(stitching_dir)
        , on_stitch_ready(on_stitch_ready)
        , on_stitch_completed(on_stitch_completed) {
        on_stitch_ready->listen([this](const auto &info) { stitch(info); });
    }

    void stitch(const RecordInfo &info) const {
        const auto input_dir = scraping_root_dir / info.record_id;
        const auto output_dir = stitching_root_dir / info.record_id;

        vlog_debug(input_dir.string(), output_dir.string());

        Frame base_image(cv::imread((input_dir / path_config.base.filename()).string(), -1));

        stitchTab(base_image, input_dir / path_config.skill.stem(), output_dir, path_config.skill);
        stitchTab(base_image, input_dir / path_config.factor.stem(), output_dir, path_config.factor);
        stitchTab(base_image, input_dir / path_config.campaign.stem(), output_dir, path_config.campaign);

        app::NativeApi::instance().rmdir(input_dir);
        on_stitch_completed->send(info);
    }

private:
    void stitchTab(
        const Frame &base_image,
        const std::filesystem::path &input_dir,
        const std::filesystem::path &output_dir,
        const PathEntry &path_entry) const {
        const auto scroll_area_window_size = base_image.anchor().mapToFrame(config.scroll_area_rect).size();

        // For record types other than Standard, unnecessary tabs may be left empty.
        auto scroll_area = Frame::fixed(
            std::filesystem::is_empty(input_dir) ? createDummyImage(scroll_area_window_size)
                                                 : scroll_area_stitcher.stitch(input_dir));

        // Stitch scroll area.
        // auto scroll_area = Frame::fixed(scroll_area_stitcher.stitch(input_dir));
        const auto background_color = scroll_area.colorAt({0.5, 0.0, {ScreenStart, ScreenPixelEnd}});
        // const auto background_color = Color{255, 0, 0};

        // Fill scroll bar.
        scroll_area.fill(config.scroll_bar_fill_rect, background_color);

        // Create canvas.
        const auto amount_of_stretch = scroll_area.size() - scroll_area_window_size;
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
            canvas.paste(config.tab_button_rect, Frame::fixed(cv::imread(tab_path.string(), -1)));
        }

        // Fill stains in base_image.
        // base_image was captured while scrolling, so fragments of the scrolling area will appear at the bottom or top edge.
        canvas.fill(config.scroll_area_upper_fill_rect, background_color);
        canvas.fill(config.scroll_area_lower_fill_rect, background_color);

        // Save stitched image and anchor info.
        app::NativeApi::instance().mkdir(output_dir);
        canvas.dump(output_dir / path_entry.filename());
    }

    [[nodiscard]] static cv::Mat createDummyImage(const Size<int> &size) {
        // TODO: The color should be picked from other tabs.
        return {size.toCVSize(), CV_8UC3, cv::Scalar(243, 243, 243)};
    }

    const stitcher_config::CharaDetailSceneStitcherConfig config;
    const std::filesystem::path scraping_root_dir;
    const std::filesystem::path stitching_root_dir;
    const stitcher_impl::ScrollAreaStitcher scroll_area_stitcher;

    const event_util::Listener<RecordInfo> on_stitch_ready;
    const event_util::Sender<RecordInfo> on_stitch_completed;
};

}  // namespace uma::chara_detail
