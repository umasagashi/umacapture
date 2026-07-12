#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
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
    cv::Mat gray;  // grayscale of `frame`, lazily cached like key_points/descriptors (see grayFrame)

    [[nodiscard]] bool empty() const { return frame.empty(); }
};

class ScrollBarOffsetEstimator {
public:
    ScrollBarOffsetEstimator(
        const Range<Color> &scroll_bar_bg_color_range,
        const Line<double> &scroll_bar_scan_line,
        const Range<Color> &scroll_bar_margin_color_range,
        double cap_offset,
        const scraper_config::ScrollBarThumbProbeConfig &thumb_probe);

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

private:
    // Placeholder-track geometry from one frame, all width-normalized. The thumb and track ends come from
    // colour runs along the scan line: the background run reaches the (dark) thumb, the margin run reaches
    // the (near-white) edge of the track. Measuring against the track, not the scan line, removes the
    // scan-line overshoot; only the thumb length carries the -2c cap correction (the caps cancel in
    // upper_gap since the thumb top and track top share the same cap geometry).
    struct TrackGeometry {
        double upper_gap;      // thumb_top - track_top, clamped >= 0 (overscroll pins the thumb to the top)
        double lower_gap;      // track_bottom - thumb_bottom, clamped >= 0 (~0 when the thumb bottom is pinned)
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
    const double cap_offset;
    const scraper_config::ScrollBarThumbProbeConfig thumb_probe;
};

// One local maximum of the 1-px keypoint-displacement histogram: a plausible vertical scroll offset,
// carrying the sub-pixel median of the displacements merged into the peak and how many matches support it.
struct OffsetCandidate {
    double offset;  // median of the peak's merged displacements (genuine peaks are ~1 px wide, so sub-pixel accurate)
    int count;      // matches merged into the peak (the peak bin and its +-1 px neighbours)
};

// Extracts scroll-offset candidates from raw keypoint vertical displacements via a 1-px-bin histogram:
// every local maximum whose merged count (peak bin + its +-1 px neighbours, absorbing spikes split across a
// bin boundary) reaches count_threshold becomes a candidate. Genuine offsets show up as razor-sharp 1-2 px
// spikes (sub-pixel keypoint localization noise is ~constant in pixels regardless of resolution), while
// mismatch noise is wide but sparse -- a few counts per bin -- and never forms a qualifying peak. Local-maxima
// detection is used instead of gap-based clustering deliberately: sparse noise bridging two nearby genuine
// peaks would chain them into one merged cluster with a wrong median, but it cannot turn a valley into a
// local maximum. The full range is considered, including zero and negative displacements, so a static frame
// yields a candidate at ~0 instead of a false positive elsewhere. Candidates are returned in ascending
// offset order; the caller decides between them on pixel evidence, not on count.
[[nodiscard]] std::vector<OffsetCandidate> detectOffsetCandidates(
    const std::vector<double> &displacements, size_t count_threshold);

class ImageOffsetEstimator {
public:
    struct ImageOffsetEstimatorConfig {
        double trust_ratio = 0.5;
        // A candidate offset is accepted only when overlaying the two frames at it reaches this normalized
        // cross-correlation. Measured genuine scrolls score >=0.91 and wrong alignments <=0.73 across all
        // golden clips, so 0.8 separates them with margin.
        double minimum_overlap_score = 0.8;
        // The overlap must be at least this fraction of the frame (crop) HEIGHT for the correlation to be
        // meaningful. A thinner band -- only possible when the scroll is nearly a full frame -- is too little
        // evidence to trust a large stitch on, and a near-uniform sliver can even correlate spuriously high
        // (measured: a 37 px sliver scoring 0.989 on a wrong offset).
        double minimum_overlap_fraction = 0.10;
        // Minimum merged match count for a displacement-histogram peak to become a candidate. This is a count,
        // and keypoint counts scale with resolution/content: measured on ~736 px-wide footage genuine peaks
        // carry 35-600 matches and noise bins <=9, but do not raise this on that evidence alone. Keep it low --
        // a spurious extra candidate is rejected by the overlap gate, while a missed genuine peak loses the frame.
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

    // Vertical content scroll between the frames, guess-free: keypoint matching proposes a short list of
    // displacement-histogram candidates (detectOffsetCandidates) and dense pixel overlap selects among them
    // (overlapScore). Neither side decides alone -- a keypoint majority can lock onto a periodic-row alias
    // (factor rows repeat every ~0.09 of the width), and a dense scan alone can spike on a thin sliver; each
    // covers the other's failure. Returns the winning candidate's sub-pixel offset, or nullopt when the
    // frames differ in size, yield too few features, or no candidate passes the overlap gate.
    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to) const;

    // Overlays the two (grayscale, full-resolution) frames shifted by the vertical offset and returns the
    // normalized cross-correlation of their shared region. Symmetric in the shift sign: a point at row y in
    // `to` lands at row y + offset_pixels in `from`, so a negative offset (backward scroll) reverses the row
    // ranges, and zero compares the full frames -- a static frame therefore verifies at ~1 instead of needing
    // a special case. Returns 0 when the overlap is thinner than minimum_overlap_fraction of the height or
    // the sizes mismatch, which the caller treats as no evidence. Public for direct unit testing; production
    // callers go through estimate().
    [[nodiscard]] double overlapScore(const cv::Mat &from_gray, const cv::Mat &to_gray, long offset_pixels) const;

private:
    void detectKeyPoints(FrameDescriptor &descriptor) const;

    // Grayscale of the descriptor's content crop, computed once and cached on the descriptor (same lazy
    // pattern as detectKeyPoints), so per-candidate verification and the next frame's `from` role reuse it.
    static const cv::Mat &grayFrame(FrameDescriptor &descriptor);

    const cv::Ptr<cv::Feature2D> detector;
    const cv::Ptr<cv::FlannBasedMatcher> matcher;
    const double trust_ratio;
    const double minimum_overlap_score;
    const double minimum_overlap_fraction;
    const int minimum_key_points;
};

class ScrollAreaOffsetEstimator {
public:
    ScrollAreaOffsetEstimator(
        const ScrollBarOffsetEstimator &scroll_bar_offset_estimator, const ImageOffsetEstimator &image_offset_estimator);

    [[nodiscard]] std::optional<double> position(const FrameDescriptor &descriptor) const;

    // Content scroll offset between the frames, decided purely by the image estimator. The scroll bar is NOT
    // consulted: its guess is wrong exactly when it matters most (the thumb pins to the track bottom on the
    // terminating frame, collapsing the measured travel), and a keypoint window built on a wrong guess
    // rejects the true offset. The scroll-bar estimator remains only for position()/topMargin().
    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to) const;

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

    // Latch the terminating frame's newly revealed rows ABOVE the fired green bar, so the last factor and
    // its gap enter the stack even when the bar fired on the very frame they scrolled in (the green branch
    // returns before the regular addScrollArea latch). Rows at/below the bar are deliberately excluded:
    // they are trimmed anyway, and latching them would push post-bar background transitions into the
    // frontier history that trimScrollAreaToFactorEnd validates. Returns the offset the subsequent
    // trimScrollAreaToFactorEnd call must use (the latch moves the stack bottom to the bar top; without a
    // latch the passed offset is returned unchanged).
    [[nodiscard]] int latchUpToGreenTerminator(const Frame &frame, int offset_pixels);

    // Crop the factor fragments to the same bottom line the gray-completion path uses, once the green
    // terminator has fired. detectGreenTerminator only marks readiness; the last fragment still runs down
    // to the frame bottom (the fallback save in addScrollArea), leaving a variable amount of trailing
    // background below the last factor. The crop line comes from the maintained frontier
    // (frontier_stack_rows + the fixed margin), validated against the live bar top: the bar caps the crop,
    // and frontier evidence inconsistent with the bar position falls back to the previous transition (the
    // bar rendered early and its trailing background stole the last transition) or, failing that, to a
    // fail-safe crop at the bar top -- never past latched factor content. Ends in a full flush.
    void trimScrollAreaToFactorEnd(const Frame &frame, int offset_pixels);

    [[nodiscard]] bool scrollAreaReady() const;

    [[nodiscard]] bool ready() const;

private:
    // Stage (factor box) or write (other boxes) one scroll-area strip. The factor box delays its commit:
    // strips are staged as owning clones in pending_strips and only flushed to disk once they can no longer
    // be trimmed (flushExcess) or the tab terminates (flushAll), so trailing background latched during the
    // gray-run recognition lag never reaches disk and the terminator-time trim is a pure in-RAM operation.
    void saveIncremental(const Frame &frame);

    // Committed fragments on disk plus strips staged in RAM: the logical fragment count both terminator
    // paths and readiness reason about (the pre-delayed-commit image_count).
    [[nodiscard]] int fragmentCount() const;

    // Write the oldest staged strip as the next numbered fragment and pop it.
    void flushFront();

    // Flush staged strips down to tail_holdback_pixels. Strips older than the maximum possible
    // terminator-time trim can never be peeled, so committing them keeps memory bounded without
    // giving up the in-RAM trim.
    void flushExcess();

    // Terminal commit: drain the staged tail to disk. Must run before readiness is observable so the
    // stitcher (triggered on completion) sees the final fragment set.
    void flushAll();

    // Remove trim_rows from the bottom of the fragment stack: peel/crop the staged tail first, then fall
    // back to the on-disk fragments (unreachable while tail_holdback_pixels over-covers the trim bounds,
    // kept as a safety net). Never drops the sole remaining fragment (scrollAreaReady must stay satisfied).
    void trimTail(int trim_rows);

    // Shared core for both factor-end terminator paths: crop the fragment stack so its bottom lands the
    // fixed margin below the last factor, then flush. `crop_stack_rows` is the target stack height
    // (frontier + margin, already validated by the caller), clamped to the current stack so a stale or
    // overshooting value degrades to a no-op rather than an over-trim.
    void cropStackTo(int crop_stack_rows);

    const std::filesystem::path image_dir;
    const std::vector<scraper_config::ScanParameter> scan_parameters;

    std::vector<scraper_config::ScanParameter>::const_iterator current_scan;
    int current_length_pixels = 0;

    // Maintained frontier (factor box only): the stack row where the page-background run below the last
    // factor begins -- the crop reference both terminator paths reason from. Updated at latch time, on each
    // observed non-background -> background transition of the terminating scan: in-strip transitions record
    // the exact row, and a transition at a strip boundary (the run starts at the strip top while the
    // previous strip ended non-background) records the boundary, so a factor row ending exactly at a strip
    // edge is never over-trimmed. A run carried over from the previous strip does not move it. The previous
    // transition is kept because the green bar can render early enough to be latched, in which case the
    // background below the bar steals the last transition (see trimScrollAreaToFactorEnd). -1 = no evidence.
    int frontier_stack_rows = -1;
    int previous_frontier_stack_rows = -1;
    // Total rows in the fragment stack (staged + committed): the coordinate system of the frontier.
    int stack_rows = 0;

    // Delayed-commit tail (factor box only; other boxes write through). Owning clones -- Frame views share
    // the source buffer (see frame.h), and a staged strip outlives its source frame. Dropped, NOT flushed,
    // when the box is discarded: recreate()/release() abandon uncommitted strips by design, matching the
    // rmdir of the committed ones.
    std::deque<cv::Mat> pending_strips;
    int pending_rows = 0;
    // Fragments on disk; doubles as the next flush filename index so committed names stay contiguous.
    int committed_count = 0;
    // Minimum staged rows retained in RAM; set per-latch in addScrollArea from the worst-case trim depth.
    int tail_holdback_pixels = 0;

    bool tab_button_ready = false;

    // Optional secondary terminator (factor box only): a green end-bar. Detected by detectGreenTerminator()
    // as a presence check over the lower scroll area, independently of the gray scan_parameters sequence.
    // When it fires, the scroll area is treated as ready even though the gray sequence is not fully consumed.
    const std::optional<scraper_config::ScanParameter> end_green;
    bool end_green_fired = false;
    // Top y (frame pixels) of the green run that fired detectGreenTerminator, or -1 if it has not fired.
    // trimScrollAreaToFactorEnd uses it as the crop ceiling and to validate the frontier evidence.
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

    // Top-edge pixel row of the green "因子" section header, relative to the scroll-area crop (so it tracks the
    // content, not the scroll thumb). Scans the config band top-down for the first row that is mostly header
    // green. nullopt when the header is scrolled off or mid-animation (not flush), which maybeResetOnFactorChange
    // treats as "not at the top". Never throws on a scrolled-away frame. Compared against the reference in pixels,
    // valid because both are taken on same-size frames.
    [[nodiscard]] std::optional<int> factorHeaderTopY(const Frame &frame) const;

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
    // Header top-edge pixel row (see factorHeaderTopY) captured with factor_probe_reference; the flush gate
    // compares the current header row against it in pixels.
    std::optional<int> reference_header_y;
    std::optional<std::pair<TabPage, bool>> last_scroll_position_emitted;
};

}  // namespace uma::chara_detail
