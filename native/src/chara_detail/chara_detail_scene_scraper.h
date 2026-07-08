#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include <minimal_uuid4/minimal_uuid4.h>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/record_info.h"
#include "util/event_util.h"
#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::chara_detail {

namespace scraper_impl {

template<typename T>
inline bool updateUntilReady(T &subject, const Frame &frame) {
    if (subject->ready()) {
        return false;
    }
    subject->update(frame);
    return subject->ready();
}

template<typename T>
inline bool readyAfterUpdate(T &subject, const Frame &frame) {
    subject.update(frame);
    return subject.ready();
}

struct FrameDescriptor {
    Frame frame;             // content crop: image matching + capture
    Frame scroll_bar_frame;  // full-width scrollbar band: scrollbar geometry only
    std::vector<cv::KeyPoint> key_points;
    cv::Mat descriptors;

    [[nodiscard]] bool empty() const { return frame.empty(); }
};

class ScrollBarOffsetEstimator {
public:
    ScrollBarOffsetEstimator(
        const Range<Color> &scroll_bar_bg_color_range,
        const Line<double> &scroll_bar_scan_line,
        const Range<Color> &scroll_bar_margin_color_range,
        double viewport,
        double cap_offset);

    [[nodiscard]] bool hasScrollbar(const Frame &frame) const;

    // Scroll position as a fraction of the scrollable range: 0 at the very top, 1 at the bottom. Derived
    // from the true placeholder track (upper_gap / (track_span - thumb_length)), so the config scan line's
    // deliberate overshoot past the track no longer biases it. nullopt when no scrollbar is present.
    [[nodiscard]] std::optional<double> position(const Frame &frame) const;

    // Fraction of the placeholder track above the thumb (thumb top relative to the track top). It is ~0 when
    // the content is scrolled to the very top and grows as the user scrolls down, independent of the thumb's
    // length. Returns nullopt when no scrollbar is present (a short, non-scrollable page). Used to detect a
    // completed tab snapping back to the top after a character switch.
    [[nodiscard]] std::optional<double> topMargin(const Frame &frame) const;

    // Content-pixel scroll offset between two frames: the placeholder-track upper_gap difference over a
    // shared (cap-corrected) thumb length, scaled by the true viewport. The fixed track top cancels in the
    // difference, so this delta form keeps low per-frame noise. The primary guess that seeds the image
    // matcher for stitching. nullopt when either frame has no scrollbar or on a mid-scroll resolution change.
    [[nodiscard]] std::optional<double> estimate(const Frame &from, const Frame &to) const;

    // Content-pixel scroll offset between two frames, computed from each frame's OWN thumb length, so it
    // stays correct across a thumb-length change (unlike estimate()'s shared-length delta). Used as the
    // recovery guess when estimate() fails because the game lazily re-scaled the thumb (factor
    // inheritance history appended mid-scroll). nullopt when either frame has no scrollbar.
    [[nodiscard]] std::optional<double> scrollOffsetGuess(const Frame &from, const Frame &to) const;

private:
    // Placeholder-track geometry from one frame, all width-normalized. The thumb and track ends come from
    // colour runs along the scan line: the background run reaches the (dark) thumb, the margin run reaches
    // the (near-white) edge of the track. Measuring against the track, not the scan line, removes the
    // scan-line overshoot; only the thumb length carries the -2c cap correction (the caps cancel in
    // upper_gap since the thumb top and track top share the same cap geometry).
    struct TrackGeometry {
        double upper_gap;      // thumb_top - track_top, clamped >= 0 (overscroll pins the thumb to the top)
        double track_span;     // track_bottom - track_top (the placeholder length)
        double thumb_logical;  // thumb tip-to-tip length - 2 * cap_offset, guaranteed > 0
    };

    [[nodiscard]] std::optional<TrackGeometry> trackGeometry(const Frame &frame) const;

    // TrackGeometry from the colour runs along one scan column. trackGeometry() picks the column
    // (trackCenterX, falling back to the config line) and delegates here.
    [[nodiscard]] std::optional<TrackGeometry> geometryAt(const Frame &frame, const Line<double> &scan_line) const;

    // Sub-pixel thumb centre x (width-normalized) from an AA intensity-weighted centroid over the thumb's
    // central rows, so the vertical scan self-centres on the thumb instead of trusting the fixed config x
    // (~10x more stable than a hard threshold; tolerates layout/resolution drift). nullopt when the thumb is
    // not found or the cap contrast is too low, so trackGeometry() falls back to the config column.
    [[nodiscard]] std::optional<double> trackCenterX(const Frame &frame) const;

    const Range<Color> scroll_bar_bg_color_range;
    const Line<double> scroll_bar_scan_line;
    const Range<Color> scroll_bar_margin_color_range;
    const double viewport;
    const double cap_offset;
};

class ImageOffsetEstimator {
public:
    struct ImageOffsetEstimatorConfig {
        double trust_ratio = 0.5;
        // Scroll is purely vertical, so a tiny horizontal translation is accepted as matching noise. A larger one is
        // verified by overlaying the frames (see estimate()) rather than trusted on the feature match alone.
        double horizontal_threshold = 1.5;
        // Half-width of the keypoint-acceptance window centred on the scroll-bar guess, as a fraction of the frame
        // width (the project's length unit) so it is resolution-independent. The guess error scales with the frame's
        // pixel size, so an absolute-pixel window would clip genuine matches on higher-resolution screens. Measured on
        // 736px-wide footage the worst genuine keypoint sits 0.0586*width from the guess and the tightest periodic-row
        // pitch is 0.0815*width, so 0.068 stays clear of both (it equals the previous 50px on that width).
        double vertical_threshold = 0.068;
        // When the horizontal translation exceeds horizontal_threshold, the vertical offset is confirmed by overlapping
        // the two frames and requiring at least this normalized cross-correlation. Measured genuine scrolls score
        // >=0.95 and wrong alignments <=0.56, so 0.8 separates them with margin.
        double minimum_overlap_score = 0.8;
        // The overlap must be at least this tall (as a fraction of the frame width, the project's length unit) for the
        // correlation to be meaningful. A thinner band -- only possible when the scroll is nearly a full frame -- is
        // too little evidence to trust a large stitch on, and a near-uniform sliver could even correlate spuriously.
        double minimum_overlap_height = 0.05;
        // Downscale factor applied before the overlap correlation. The renderer is not pixel-exact (sub-pixel shifts),
        // so averaging neighbours makes the score robust to that noise (and cheaper).
        int overlap_downscale = 4;
        int minimum_key_points = 10;
        int descriptor_channels = 3;
        float descriptor_threshold = 0.001f;
        int octaves = 2;
        int octave_layers = 1;
        int table_number = 3;
        int key_size = 12;
        int probe_level = 1;
    };

    explicit ImageOffsetEstimator(const ImageOffsetEstimatorConfig &config);

    ImageOffsetEstimator();

    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to, double guess) const;

private:
    void detectKeyPoints(FrameDescriptor &descriptor) const;

    // Overlays the two frames shifted by the vertical offset and returns the normalized cross-correlation of their
    // shared region. A point at row y in `to` lands at row y + offset_pixels in `from`, so those row ranges hold the
    // overlapping content. Returns 0 when the overlap is too thin to verify (a non-positive scroll, or a band shorter
    // than minimum_overlap_height of the frame width), which the caller treats as a failed match.
    [[nodiscard]] double overlapScore(const cv::Mat &from_frame, const cv::Mat &to_frame, long offset_pixels) const;

    const cv::Ptr<cv::Feature2D> detector;
    const cv::Ptr<cv::FlannBasedMatcher> matcher;
    const double trust_ratio;
    const double horizontal_threshold;
    const double minimum_overlap_score;
    const double minimum_overlap_height;
    const int overlap_downscale;
    const int minimum_key_points;
    const double vertical_threshold;
};

class ScrollAreaOffsetEstimator {
public:
    ScrollAreaOffsetEstimator(
        const ScrollBarOffsetEstimator &scroll_bar_offset_estimator, const ImageOffsetEstimator &image_offset_estimator);

    [[nodiscard]] std::optional<double> position(const FrameDescriptor &descriptor) const;

    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to) const;

    // Recovery estimate for when estimate() fails because the thumb re-scaled (factor inheritance
    // history appended mid-scroll): matches the two frames at scrollOffsetGuess, a guess valid across a
    // thumb-length change. Returns the image-verified offset, or nullopt if the frames do not match.
    [[nodiscard]] std::optional<double> estimateAcrossRescale(FrameDescriptor &from, FrameDescriptor &to) const;

private:
    const ScrollBarOffsetEstimator scroll_bar_offset_estimator;
    const ImageOffsetEstimator image_offset_estimator;
};

class PageScrapingBox {
public:
    PageScrapingBox(
        const std::vector<scraper_config::ScanParameter> &scan_parameters,
        const std::filesystem::path &image_dir,
        const io_util::DirectoryHooks &directory_hooks,
        std::optional<scraper_config::ScanParameter> end_green = std::nullopt);

    void addTabButton(const Frame &frame);

    void addScrollArea(const Frame &frame, int offset_pixels);

    void addScrollArea(const Frame &frame);

    void setScrollArea(const Frame &frame);

    // Presence check for the green "継承履歴" terminator bar, run once per frame independently of scroll
    // strips (see the definition for why the strip scanner cannot see the lazily-rendered bar). Scans a
    // region anchored to the scroll frontier (height - offset_pixels) extended back by the gray-tail
    // threshold, which structurally bounds it to the last factor's neighbourhood. Sets end_green_fired and
    // returns true once a green run of end_green->length is present there.
    bool detectGreenTerminator(const Frame &frame, int offset_pixels);

    // Crop the saved factor fragments to the same bottom line the gray-completion path uses, once the green
    // terminator has fired. detectGreenTerminator only marks readiness; the last saved fragment still runs
    // down to the frame bottom (the fallback save in addScrollArea), leaving a variable amount of trailing
    // background below the last factor. This scans up from the recorded green-bar top to the last factor's
    // bottom and trims the fragment stack to factorEndCropY(that), so the bottom margin is identical to the
    // gray-completion path regardless of which terminator ends the tab. A no-op unless the green terminator
    // fired and the saved content overshoots the crop line.
    void trimScrollAreaToFactorEnd(const Frame &frame, int offset_pixels);

    [[nodiscard]] bool scrollAreaReady() const;

    [[nodiscard]] bool ready() const;

private:
    void saveIncremental(const Frame &frame);

    // Scaled y at which the terminating fragment should be cropped for the factor box: a fixed margin below
    // run_start_scaled (the bottom of the last factor). Clamped within [scaled_top, terminator] so the rect
    // stays valid; the caller skips an empty one. Keeps the bottom margin constant regardless of whether
    // inheritance history follows the list. Both terminator paths (gray-sequence completion and the green
    // end-bar) feed their own last-factor-bottom through this one function so they crop to the same line.
    [[nodiscard]] double factorEndCropY(double run_start_scaled, double scaled_top, double terminator_scaled_y) const;

    const std::filesystem::path image_dir;
    const std::vector<scraper_config::ScanParameter> scan_parameters;

    std::vector<scraper_config::ScanParameter>::const_iterator current_scan;
    int current_length_pixels = 0;
    // Scaled y where the current scan's run of matching color began (its 0->1 transition), reset to the
    // strip top each frame. For the factor box the run that follows the last factor is the page-background
    // gap just below it, so this marks the bottom of the last factor.
    double current_run_start_scaled = 0.0;
    int image_count = 0;

    bool tab_button_ready = false;

    // Optional secondary terminator (factor box only): a green end-bar. Detected by detectGreenTerminator()
    // as a presence check over the lower scroll area, independently of the gray scan_parameters sequence.
    // When it fires, the scroll area is treated as ready even though the gray sequence is not fully consumed.
    const std::optional<scraper_config::ScanParameter> end_green;
    bool end_green_fired = false;
    // Top y (frame pixels) of the green run that fired detectGreenTerminator, or -1 if it has not fired.
    // trimScrollAreaToFactorEnd scans up from here to locate the last factor and crop the fragment stack.
    int green_terminator_top_pixels = -1;
};

class SceneScrapingBox {
public:
    SceneScrapingBox(
        const std::vector<scraper_config::ScanParameter> &skill_scans,
        const std::vector<scraper_config::ScanParameter> &factor_scans,
        const std::vector<scraper_config::ScanParameter> &campaign_scans,
        const scraper_config::ScanParameter &factor_end_green,
        const record::RecordType &record_type,
        const std::filesystem::path &image_dir,
        const io_util::DirectoryHooks &directory_hooks);

    [[nodiscard]] std::shared_ptr<PageScrapingBox> skill_box() const;
    [[nodiscard]] std::shared_ptr<PageScrapingBox> factor_box() const;
    [[nodiscard]] std::shared_ptr<PageScrapingBox> campaign_box() const;

    // Discard and re-create a single tab's box, clearing its image directory so the fresh box numbers its
    // scroll-area fragments from zero again (PageScrapingBox writes 0-based filenames; reusing the directory
    // would let a stale fragment from the abandoned attempt survive and be picked up by the stitcher). The
    // returned box must be rebound into the tab's SceneScraper by the caller.
    std::shared_ptr<PageScrapingBox> resetSkillBox();
    std::shared_ptr<PageScrapingBox> resetFactorBox();
    std::shared_ptr<PageScrapingBox> resetCampaignBox();

    void addBase(const Frame &frame);

    [[nodiscard]] bool ready() const;

private:
    std::shared_ptr<PageScrapingBox> recreate(
        const std::vector<scraper_config::ScanParameter> &scans,
        const std::filesystem::path &stem,
        std::optional<scraper_config::ScanParameter> end_green = std::nullopt) const;

    const std::filesystem::path base_path;
    const std::filesystem::path image_dir;
    const record::RecordType record_type;
    const std::vector<scraper_config::ScanParameter> skill_scans;
    const std::vector<scraper_config::ScanParameter> factor_scans;
    const std::vector<scraper_config::ScanParameter> campaign_scans;
    const scraper_config::ScanParameter factor_end_green;
    const io_util::DirectoryHooks directory_hooks;

    std::shared_ptr<PageScrapingBox> skill_box_;
    std::shared_ptr<PageScrapingBox> factor_box_;
    std::shared_ptr<PageScrapingBox> campaign_box_;
    bool base_ready = false;
};

class StationaryFrameCatcher {
public:
    StationaryFrameCatcher(uint64 stationary_time, int minimum_color, uint64 stationary_color, const Rect<double> &rect);

    void update(const Frame &frame);

    [[nodiscard]] bool ready() const;

    [[nodiscard]] Frame fullSizeFrame() const;

    [[nodiscard]] Frame croppedFrame() const;

private:
    const Rect<double> target_rect;
    const uint64 stationary_time;
    const int minimum_color;
    const uint64 stationary_color;

    Frame previous_frame;
    std::optional<uint64> first_timestamp;
};

class ScrapingInterpreter {
public:
    virtual ~ScrapingInterpreter() = default;
    virtual void update(const Frame &frame) = 0;
    [[nodiscard]] virtual bool ready() const = 0;
    // Whether this tab has committed real capture progress (past a fleeting glance), so that switching away
    // from it before completion should discard the partial attempt.
    [[nodiscard]] virtual bool started() const = 0;
};

enum ReadyState {
    Null,
    Updatable,
    Ready,
};

class NonScrollableScrapingInterpreter : public ScrapingInterpreter {
public:
    NonScrollableScrapingInterpreter(
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const StationaryFrameCatcher &stationary_catcher,
        const Rect<double> &scroll_area_rect);

    // Receives the full frame; crops the content region internally (see ScrollableScrapingInterpreter::update).
    void update(const Frame &frame) override;

    [[nodiscard]] bool ready() const override;

    [[nodiscard]] bool started() const override;

private:
    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    const Rect<double> scroll_area_rect;
    ReadyState state = Updatable;
    bool has_updated = false;
};

class ScrollableScrapingInterpreter : public ScrapingInterpreter {
public:
    ScrollableScrapingInterpreter(
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const ScrollAreaOffsetEstimator &offset_estimator,
        const StationaryFrameCatcher &stationary_catcher,
        const Rect<double> &scroll_area_rect,
        const Rect<double> &scroll_bar_rect,
        double initial_scroll_threshold,
        double minimum_scroll_threshold,
        const event_util::Sender<> &on_scroll_ready,
        const event_util::Sender<double> &on_scroll_updated);

    // Receives the FULL frame each update. The content crop (scroll_area_rect) drives the stationary catcher,
    // image matcher and capture; the scroll-bar band (scroll_bar_rect) drives only the scrollbar estimator, so
    // the two regions are decoupled.
    void update(const Frame &frame) override;

    [[nodiscard]] bool ready() const override;

    // Progress here means the tab reached scroll-ready and latched its first scroll-area fragment. A brief
    // glance that never settles into a stationary frame never sets is_scrolling, so it is not "started" and
    // switching away from it discards nothing.
    [[nodiscard]] bool started() const override;

private:
    void updateBefore(const Frame &frame);

    void startScrolling(const FrameDescriptor &valid_descriptor);

    void updateScrolling(const Frame &frame);

    const event_util::Sender<> on_scroll_ready;
    const event_util::Sender<double> on_scroll_updated;

    const ScrollAreaOffsetEstimator offset_estimator;
    const Rect<double> scroll_area_rect;
    const Rect<double> scroll_bar_rect;
    const double initial_scroll;
    const double minimum_scroll;

    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    FrameDescriptor initial_descriptor;
    FrameDescriptor previous_descriptor;
    ReadyState state = Updatable;
    bool is_scrolling = false;
};

class SceneScraper {
public:
    SceneScraper(
        const scraper_config::SceneScraperConfig &config,
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const event_util::Sender<> &on_scroll_ready,
        const event_util::Sender<double> &on_scroll_updated);

    void update(const Frame &frame);

    [[nodiscard]] bool ready() const;

    // Whether this tab committed real scroll-capture progress (see ScrapingInterpreter::started). False until
    // the tab has been displayed at least once (scroll_area_scraper is built lazily on the first frame).
    [[nodiscard]] bool started() const;

    // Fraction of the scroll track above the thumb for this tab's scroll area, or nullopt when the tab has not
    // been built yet or has no scrollbar. ~0 means scrolled to the very top. Safe to call in any state (it does
    // not mutate), unlike update()/the tab scraper accessor which assert Updatable.
    [[nodiscard]] std::optional<double> topMargin(const Frame &frame) const;

private:
    void build(const Frame &frame);

    void readyForStitch();

    const event_util::Sender<> on_scroll_ready;
    const event_util::Sender<double> on_scroll_updated;

    const scraper_config::SceneScraperConfig config;

    std::unique_ptr<StationaryFrameCatcher> tab_button_catcher;
    std::unique_ptr<ScrapingInterpreter> scroll_area_scraper;
    std::unique_ptr<ScrollBarOffsetEstimator> scroll_bar_estimator;
    std::shared_ptr<PageScrapingBox> scraping_box;
    ReadyState state = Null;
};

class BaseFrameCatcher {
public:
    BaseFrameCatcher(
        const StationaryFrameCatcher &base_frame_catcher,
        const Rect<double> &base_image_rect,
        const Line<double> &header_scan_line,
        const Range<Color> &header_color_range,
        const uint64 header_visible_time_threshold);

    void update(const Frame &frame);

    [[nodiscard]] bool ready() const;

    [[nodiscard]] Frame frame() const;

private:
    // The snackbar is treated as cleared only once the green title-bar banner has been fully
    // visible (every point on the scan line green) continuously for the threshold. Scanning the
    // banner keeps this independent of the character, whose illustration above the banner can be
    // near-white where the previous top scan mistook it for a snackbar. This only gates the
    // snackbar; the base frame still requires the header region to be stationary.
    [[nodiscard]] bool snackbarCleared() const;

    [[nodiscard]] bool isHeaderVisible(const Frame &frame) const;

    const Rect<double> base_image_rect;
    const Line<double> header_scan_line;
    const Range<Color> header_color_range;
    const uint64 header_visible_time_threshold;

    StationaryFrameCatcher base_frame_catcher;
    std::optional<uint64> header_visible_since;
    uint64 last_timestamp = 0;
};

}  // namespace scraper_impl

class CharaDetailSceneScraper {
public:
    CharaDetailSceneScraper(
        const event_util::Listener<SceneInfo> &on_opened,
        const event_util::Listener<Frame, SceneState> &on_updated,
        const event_util::Listener<> &on_closed,
        const event_util::Sender<RecordInfo> &on_closed_before_completed,
        const event_util::Sender<int> &on_scroll_ready,
        const event_util::Sender<int, double> &on_scroll_updated,
        const event_util::Sender<int, bool> &on_scroll_position,
        const event_util::Sender<int> &on_page_ready,
        const event_util::Sender<RecordInfo> &on_completed,
        const event_util::Sender<Frame, RecordInfo> &on_factor_probe,
        const event_util::Sender<> &on_restarted,
        const scraper_config::CharaDetailSceneScraperConfig &config,
        const std::filesystem::path &scraping_dir,
        const io_util::DirectoryHooks &directory_hooks);

    void build(const SceneInfo &info);

    void buildSession(record::RecordType record_type);

    void update(const Frame &frame, const SceneState &scene_state);

    void release();

private:
    // Discard the current session and start a fresh one with the given record type, without the detail
    // screen closing. Used when a character switch is inferred from on-screen content. The restart is
    // surfaced to the UI so it resets its capture progress just as on a fresh open.
    void resetSession(record::RecordType record_type);

    std::unique_ptr<scraper_impl::SceneScraper>
    makeTabScraper(TabPage tab_page, const std::shared_ptr<scraper_impl::PageScrapingBox> &box);

    [[nodiscard]] scraper_impl::SceneScraper *scraperOf(TabPage tab_page) const;

    [[nodiscard]] scraper_impl::SceneScraper *tabScraper(TabPage tab_page) const;

    // True once the given record type has been reported continuously for the debounce window; performs the
    // reset and returns true so the caller stops processing the current (mid-switch) frame.
    [[nodiscard]] bool handleRecordTypeChange(record::RecordType record_type, uint64 timestamp);

    // True when the current tab's scroll bar has sat at the very top for the debounce window. A completed
    // tab normally rests at the bottom, so this only becomes true after a switch (or a deliberate scroll
    // back up), both of which the spec discards.
    [[nodiscard]] bool detectCompletedTabAtTop(TabPage tab_page, const Frame &frame);

    // Emit the current tab's at-top position to the UI, edge-triggered so a stationary tab does not spam the
    // channel every frame. "At top" reuses the same top-margin threshold as the switch-detection rules; a tab
    // with no scrollbar (a short, non-scrollable page) or one not yet built counts as at the top, since there
    // is nothing to scroll away from.
    void notifyScrollPositionIfChanged(TabPage tab_page, const Frame &frame);

    void handleTabSwitchInProgress(TabPage tab_page);

    void rebuildTab(TabPage tab_page);

    // On the factor tab, diff the current stable top-of-page against the last probed reference. A large,
    // sustained change while at the top means the displayed character switched, so reset (the fresh session
    // re-probes). Reuses the stationary rect and its calibrated color thresholds as the change metric.
    void maybeResetOnFactorChange(const Frame &frame, record::RecordType record_type);

    // Top edge y of the green "因子" section header, as a width-normalized fraction relative to the scroll-area
    // crop (so it tracks the content, not the scroll thumb). Scans the config band top-down for the first row
    // that is mostly header green. nullopt when the header is scrolled off or mid-animation (not flush), which
    // maybeResetOnFactorChange treats as "not at the top". Never throws on a scrolled-away frame.
    [[nodiscard]] std::optional<double> factorHeaderTopY(const Frame &frame) const;

    void resetMonitors();

    [[nodiscard]] bool ready() const;

    void checkForCompleted();

    const event_util::Listener<SceneInfo> on_opened;
    const event_util::Listener<Frame, SceneState> on_updated;
    const event_util::Listener<> on_closed;

    const event_util::Sender<RecordInfo> on_closed_before_completed;
    const event_util::Sender<int> on_scroll_ready;  // When user can start scrolling.
    const event_util::Sender<int, double> on_scroll_updated;  // When user scrolling.
    const event_util::Sender<int, bool> on_scroll_position;  // Current tab's at-top position (edge-triggered).
    const event_util::Sender<int> on_page_ready;  // When each page is ready.
    const event_util::Sender<RecordInfo> on_completed;  // When all three pages are ready.
    const event_util::Sender<Frame, RecordInfo> on_factor_probe;  // Factor tab scroll-ready, for dedup.
    const event_util::Sender<> on_restarted;  // Mid-scene reset (inferred character switch).

    // Top margin (fraction of the true placeholder track above the thumb, from topMargin()) at or below which
    // the content is treated as scrolled to the very top. ~0 means flush with the top; the threshold tolerates
    // a thin idle band. Verify against footage (.notes/player_standard_sequential.mp4) when calibrating.
    //
    // Was 0.03 when topMargin() measured against the config scan line, whose deliberate overshoot past the
    // track biased the reading up by ~0.007. Once topMargin() moved to the true track (commit 0b56fc44) the
    // same physical position reads ~0.007 lower, so 0.03 admitted a thumb a hair below the top as "at top".
    // On the factor tab that spuriously fired maybeResetOnFactorChange when the inheritance history lazily
    // loaded: the reload re-scales the thumb to ~0.027 while the list content changes, and 0.03 gated it as a
    // character switch (friend_inheritance golden regression). A genuine switch is instead visible at the very
    // top (~0.002, before any reload) so it still fires; 0.02 sits in the gap between the two.
    static constexpr double kTopMarginThreshold = 0.02;
    // How long an inferred-switch signal (record-type change, completed tab at top, factor content change) must
    // persist before it commits a reset, so a transient misread during the switch animation cannot trigger one.
    static constexpr uint64 kMonitorDwellMs = 250;
    // A pixel counts as "changed" when its per-pixel BGR difference (0-765) exceeds this. The dominant
    // same-character noise is anti-aliasing / video-codec shimmer along text, star and icon edges -- broadly
    // scattered but LOW magnitude. Measured per-pixel-diff sweeps on two clips (373k-pixel region): that
    // shimmer is entirely below magnitude ~10-12 (a same-character frame reading 1.06% at X=5 collapses to
    // 0.04% at X=8 and 0% at X=12), whereas a real switch changes text glyphs -- high contrast, high magnitude
    // -- and barely moves (6.59% at X=5 -> 5.70% at X=15, ~87% retained). 15 sits just above the shimmer
    // ceiling, so raising the gate here (not the ratio below) is what suppresses the noise while keeping a real
    // switch intact -- including a similar-factor switch, whose smaller but still-high-magnitude text change
    // survives the gate where equal-ratio edge noise does not.
    static constexpr int kFactorChangePixelDiffThreshold = 15;
    // Fraction of the factor scroll area that must be "changed" (per X above) to treat the content as a
    // different character rather than noise. Counting *how many* pixels changed (a broad, contiguous area on a
    // real switch) instead of *how much* (a magnitude average a few large-delta pixels could dominate) is far
    // more robust to the spikes video sources inject. The 250ms dwell guards transient spikes. With X=15 the
    // only same-character residual is a moving mouse cursor (high contrast, so it survives the gate, but tiny:
    // ~0.10% of the region), while a real switch reads ~5.7%. 0.5% sits above that ~0.10% cursor floor yet well
    // below a real switch, low enough to also catch a weak (few-row / similar-factor) change that the old 1%
    // could miss. Verified end-to-end: .notes/player_standard.mp4 (same character) no longer resets, while the
    // .notes/player_standard_factor_only_1.mp4 switch still does.
    static constexpr double kFactorChangeRatioThreshold = 0.005;

    const scraper_config::CharaDetailSceneScraperConfig config;
    const std::filesystem::path scraping_root_dir;
    const io_util::DirectoryHooks directory_hooks;

    minimal_uuid4::Generator uuid_generator;

    RecordInfo current_record_info = {};
    Frame current_full_frame = {};
    event_util::Connection<> factor_scroll_ready;
    const scraper_config::SceneScraperConfig *active_common = nullptr;
    std::unique_ptr<scraper_impl::SceneScraper> skill_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> factor_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> campaign_scraper;
    std::unique_ptr<scraper_impl::BaseFrameCatcher> base_frame_catcher;
    std::shared_ptr<scraper_impl::SceneScrapingBox> scraping_box;
    scraper_impl::ReadyState scraping_state = scraper_impl::Null;

    // Switch-detection bookkeeping. Indexed by TabPage.
    std::array<bool, kAllTabPages.size()> tab_completed{};
    std::optional<TabPage> last_active_tab;
    std::optional<uint64> top_pending_since;
    std::optional<TabPage> top_pending_tab;
    std::optional<uint64> type_pending_since;
    std::optional<record::RecordType> type_pending_value;
    std::optional<uint64> factor_change_pending_since;
    Frame factor_probe_reference = {};
    // Header top y (see factorHeaderTopY) captured with factor_probe_reference; the flush gate compares the
    // current header y against it, so per-device layout differences cancel.
    std::optional<double> reference_header_y;
    std::optional<std::pair<TabPage, bool>> last_scroll_position_emitted;
};

}  // namespace uma::chara_detail
