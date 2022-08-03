#pragma once

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

#include "util/event_util.h"

namespace uma::chara_detail {

namespace stitcher_impl {

class ScrollAreaStitcher {
public:
    [[nodiscard]] cv::Mat stitch(const std::filesystem::path &input_dir) const {
        const auto &images = stds::transformed<std::vector<cv::Mat>>(
            imagePaths(input_dir), [](const auto &path) { return cv::imread(path.string(), -1); });
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
        const event_util::Listener<std::string> &on_stitch_ready,
        const event_util::Sender<std::string> &on_stitch_completed,
        const stitcher_config::CharaDetailSceneStitcherConfig &config)
        : scraping_root_dir(scraping_dir)
        , stitching_root_dir(stitching_dir)
        , on_stitch_ready(on_stitch_ready)
        , on_stitch_completed(on_stitch_completed)
        , config(config) {
        on_stitch_ready->listen([this](const auto &id) { stitch(id); });
    }

    void stitch(const std::string &id) {
        const auto input_dir = scraping_root_dir / id;
        const auto output_dir = stitching_root_dir / id;

        vlog_debug(input_dir.string(), output_dir.string());

        Frame base_image(cv::imread((input_dir / path_config.base.filename()).string(), -1));

        stitchTab(base_image, input_dir / path_config.skill.stem(), output_dir, path_config.skill);
        stitchTab(base_image, input_dir / path_config.factor.stem(), output_dir, path_config.factor);
        stitchTab(base_image, input_dir / path_config.campaign.stem(), output_dir, path_config.campaign);

        app::NativeApi::instance().rmdir(input_dir);
        on_stitch_completed->send(id);
    }

private:
    void stitchTab(
        const Frame &base_image,
        const std::filesystem::path &input_dir,
        const std::filesystem::path &output_dir,
        const PathEntry &path_entry) {
        // Stitch scroll area.
        auto scroll_area = Frame::fixed(scroll_area_stitcher.stitch(input_dir));
        const auto background_color = scroll_area.colorAt({0.5, 0.0, {ScreenStart, ScreenPixelEnd}});

        // Fill scroll bar.
        scroll_area.fill(config.scroll_bar_fill_rect, background_color);

        // Create canvas.
        const auto amount_of_stretch =
            scroll_area.size() - base_image.anchor().mapToFrame(config.scroll_area_rect).size();
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
        canvas.paste(
            config.tab_button_rect,
            Frame::fixed(cv::imread((input_dir / path_config.tab_button.filename()).string(), -1)));

        // Fill stains in base_image.
        // base_image was captured while scrolling, so fragments of the scrolling area will appear at the bottom or top edge.
        canvas.fill(config.scroll_area_upper_fill_rect, background_color);
        canvas.fill(config.scroll_area_lower_fill_rect, background_color);

        // Save stitched image and anchor info.
        app::NativeApi::instance().mkdir(output_dir);
        canvas.dump(output_dir / path_entry.filename());
    }

    const stitcher_config::CharaDetailSceneStitcherConfig config;
    const std::filesystem::path scraping_root_dir;
    const std::filesystem::path stitching_root_dir;
    const stitcher_impl::ScrollAreaStitcher scroll_area_stitcher;

    const event_util::Listener<std::string> on_stitch_ready;
    const event_util::Sender<std::string> on_stitch_completed;
};

}  // namespace uma::chara_detail
