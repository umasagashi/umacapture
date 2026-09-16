#pragma once

#include "builder/builder_util.h"
#include "chara_detail/chara_detail_config.h"

namespace uma::tool {

class CharaDetailSceneScraperBuilder {
public:
    [[nodiscard]] chara_detail::scraper_config::CharaDetailSceneScraperConfig build() const {
        return {
            common(),
            friendCommon(),
            skillScanParameters(),
            factorScanParameters(),
            campaignScanParameters(),
            factorEndGreen(),
            // Base frame is captured only while the green title-bar banner is fully visible
            // (no snackbar overlay). Scan a short vertical span of the banner at x=0.8259,
            // y 60->40 px of the 736 px intersection. Both axes are intersection-relative so a surrounding
            // title bar or letterbox margin cannot move the scan away from the game banner. The banner is
            // character-independent,
            // unlike the illustration area above it.
            lineToY({0.8259, 60.0 / 736.0, {IS, IS}}, 40.0 / 736.0),
            headerBannerGreen(),
            100,
            factorHeader(),
        };
    }

private:
    // Vertical drop of the TAB BAR ALONE in the Friend layout, where a green "練習パートナー登録" button sits
    // above the tab bar. Pinned from the Friend tab bar at row 682 of the 736 px wide intersection vs. the
    // Standard tab bar at 0.7463, i.e. 132.7 px at that width.
    //
    // It applies to tab_button_rect and to nothing else. The scroll area below the tab bar drops by a
    // DIFFERENT amount (136.2 px; friendCommon derives it, and says from what), so the Friend layout is not a
    // rigid translation of the Standard one and no single shift can place both rects.
    static constexpr double friend_tab_bar_shift = 682.0 / 736.0 - 0.7463;

    [[nodiscard]] chara_detail::scraper_config::SceneScraperConfig common() const {
        return {
            Rect<double>{{0.1, 0.0556, IS}, {0.9, 0.8074, IS}},
            Rect<double>{{0.0, 0.0, IS}, {0.0, 0.0, ILE}},
            Rect<double>{{0.0222, 0.7259, IS}, {0.9759, 0.8037, IS}},
            Rect<double>{{0.0000, 0.8093, IS}, {0.0000, -0.2426, {IPE, ILE}}},
            // scroll_bar_rect: full-width band for scrollbar detection, initially identical to scroll_area_rect.
            Rect<double>{{0.0000, 0.8093, IS}, {0.0000, -0.2426, {IPE, ILE}}},
            Rect<double>{{0.0222, 0.0000, IS}, {-0.0222, 0.0000, {ILE, IPE}}},
            Range<Color>{Color{123, 121, 140} + 30, {255, 255, 255}},
            // scroll_bar_scan_line.x sits on the thumb's true horizontal center (trackCenterX centroid across
            // 11 screenshots, width-normalized 0.96927); this is also the config-column fallback.
            Line<double>{{0.9693, 0.0092, IS}, {0.9693, -0.0092, {IS, ILE}}},
            0.01,
            0.05,
            // stationary_time_threshold: the region must stay still this long (ms) before it latches.
            //
            // TREAT THIS AS A FIXED CONSTRAINT, NOT AS A DIAL. Of the latch's two calibrated inputs this is
            // the one the USER pays for, in wall-clock time, on every capture. It is 200 because that is what
            // has shipped continuously since 8f70975 (2025-07-05) -- over a year of releases, and the only
            // live-capture evidence anyone holds is at this value. A 250 ms trial in 2026-08 was reverted
            // precisely because it treated this as the dial to turn: the margin it was bought for had already
            // been bought by expressing the budget below as an area FRACTION.
            // If the latch needs room, buy it on stationary_change_ratio_threshold, or by changing what is
            // measured. Not here.
            //
            // Why every measurement in this file understates the cost of widening it:
            //  * On a video import the dwell is MEDIA time. It consumes decoded frames, not the user's
            //    attention, so the sweeps and goldens below cannot see the cost at all. On live capture it is
            //    REAL time: the catcher is consulted once per tab to arm scroll-ready
            //    (ScrollableScrapingInterpreter::updateBefore) and once for the base image -- never per scroll
            //    step -- and there are three tabs (kAllTabPages), so +50 ms here is about +150 ms of holding
            //    the screen still per character.
            //  * The cost that bites harder is not the latency but the widened "please do not scroll yet"
            //    window, once per tab. Scroll-ready is what runs the factor tab's duplicate probe (the
            //    factor_scroll_ready listener in chara_detail_scene_scraper.cpp), so a user who scrolls before
            //    the dwell elapses never gets the early duplicate check. That loss is SILENT, and every
            //    millisecond added here makes it likelier. Nothing in this repo can measure it: the clips are recordings of scrolling that
            //    already happened, which is the closest proxy there is and is not the same thing.
            //
            // The measured ceiling is kept because it BOUNDS a future proposal, not because it licenses one:
            //  * at 300 ms -- and at 305, 310, 320, 330, 350 -- the `player_standard_2` GOLDEN produces no
            //    record at all, at every budget from 1.4e-5 to 5e-5. 295 is still fine, and so, non-
            //    monotonically, is 400: past the arming window the run falls back to the estimate path and
            //    completes. Do not read the region as convex. It has a hole, and the only reason anyone knows
            //    is that a golden case ran.
            //  * at 600 ms `player_inheritance_switch_with_tiny_scroll` drops from 1 factor reset to 0, and at
            //    1000 ms `player_standard_factor_tiny_scroll_switch_2` drops from 4 to 0 -- the must-fire
            //    contract, silently gone.
            200,
            // minimum_color_threshold: per-pixel BGR L1 gate (0-765) for "did this pixel move at all between
            // two consecutive frames". A sensor/codec-noise question, deliberately distinct from the factor
            // gate's kFactorChangePixelDiffThreshold (80), which asks the content question "is this pixel a
            // different colour than it was on another character's list".
            // It stays at 18 and cannot be the instrument against codec noise: requantisation on a phone
            // screen recording reaches per-pixel amplitude 114-133, so any gate high enough to erase it would
            // also be blind to real content. What makes that noise harmless is that it is *sparse relative to
            // the region* -- an area fact -- which is what the next constant expresses.
            18,
            // stationary_change_ratio_threshold: the area budget, as a FRACTION of the compared region.
            // "At most 0.0014 % of the region's pixels moved (above the gate above) since the previous frame"
            // -- about 12 pixels of the 845 936 px scroll area at 1080x2520, about 3 of the same area at 540p.
            //
            // THIS BLOCK IS THE CANONICAL RECORD OF THE LATCH'S CALIBRATION. The field in
            // chara_detail_config.h and the class comment on StationaryFrameCatcher in
            // chara_detail_scene_scraper.h point here rather than restating any of it: the same derivation
            // used to live in four places, and four copies of a calibration become four different stories.
            //
            // WHERE THE ONE SHARED VALUE IS USED. Production builds THREE catchers over THREE distinct rects,
            // feeding FOUR consumers: `scroll_area_stationary_rect` (chara_detail_scene_scraper.cpp, in
            // prepareScrollArea -- one catcher, copied into whichever of ScrollableScrapingInterpreter /
            // NonScrollableScrapingInterpreter that frame needs, so two consumer types from one construction),
            // `tab_button_rect` (SceneScraper::tab_button_catcher) and `base_image_stationary_rect` (inside
            // BaseFrameCatcher). A SceneScraper is built per tab, so the live instance count is larger than
            // three; the number that matters for a shared budget is the three rects, whose areas differ by an
            // order of magnitude.
            //
            // It was an absolute 100 -- a SUM of gated per-pixel distances, under the name
            // `stationary_color_threshold` -- and the change to a fraction fixes two separate faults of that
            // form.
            //  * The sum scales with the rect while the constant did not, so one number meant a different
            //    amount of stillness at each of the three rects the latch watches and at every capture size
            //    (1.18e-4 per pixel over the scroll area at 1080x2520, 1.43e-4 over the base image, 1.16e-3
            //    over the tab strip -- the tab strip ran 9.8x looser than the scroll area for no reason
            //    anyone had stated). Expressed the old way, the three input classes' settled floors are:
            //    FFV1 lossless exactly 0 on every frame at every site; desktop mp4 0-81; an Android screen
            //    recording 199-5436. The constant 100 sat *inside* the Android class.
            //  * The sum is amplitude-weighted, and that is what actually broke lossy phone input: the
            //    base-image region on a crf30 1080p re-encode moves ~130 pixels of 701 568 (0.019 %) at
            //    amplitudes 20-55, so the SUM reads ~3600 against a budget of 100 while the COUNT is 1.9e-4.
            //    The base catcher therefore never latched, `SceneScrapingBox::ready()` never saw base_ready,
            //    and the import scraped all three tabs and then wrote no record at all. Dropping the
            //    amplitude weighting is the fix; the budget barely had to move (see the map below).
            //
            // THE KEY WAS RENAMED BECAUSE ITS UNIT CHANGED, not because its value did. nlohmann's arithmetic
            // getter accepts a JSON float for an integer field and silently static_casts it
            // (vendor/nlohmann/json.hpp, get_arithmetic_value), so a binary compiled against the old uint64
            // `stationary_color_threshold` would have read 1.4e-05 as 0: no catcher would ever latch, and
            // every import would finish with no record and no error -- exactly the failure this change exists
            // to remove, reproduced by the fix for it. Under the new name both mismatched pairings instead
            // throw out_of_range.403 from json.at(), which startPipeline reports. Any future change to THIS
            // field's unit must rename it again; neither the parser nor the compiler will catch the mismatch.
            //
            // A count ratio, not a normalised sum: see kFactorChangeRatioThreshold's comment in
            // chara_detail_scene_scraper.h -- counting how many pixels changed is robust to the few
            // large-delta pixels a video source injects, which a magnitude average is not. Normalising the
            // sum would have fixed the area dependence and kept both the amplitude weighting and that
            // vulnerability.
            //
            // THE USABLE REGION IS TWO-DIMENSIONAL, BUT ONLY ONE AXIS IS FREE. This budget and the dwell above
            // move the same thing -- WHEN a catcher fires -- so the region has to be mapped in both. The dwell
            // is nevertheless fixed by the constraint written on it, so THIS is the value that gets tuned, and
            // the map exists to say what room it has at 200 ms. Mapped end to end by sweeping both over
            // `umacapture_cli video` and reading the resulting records (72 coarse runs plus 40 refining the
            // edges, one run per point, the shipped point repeated as a determinism control). Two clips set
            // the two edges; the other nine grid rungs sit nowhere near either.
            //
            //   dwell (ms) | usable budget    | note
            //   -----------+------------------+----------------------------------------------------------
            //     100-130  | NONE             | 540p corrupts at every budget tried
            //     150-200  | [1e-5, 2e-5]     | <- the operating point sits here, at 200 / 1.4e-5
            //     250-295  | [1e-5, 6e-5]     |
            //     300-350  | NONE             | player_standard_2 produces no record (see the dwell above)
            //        400   | [1e-5, 6e-5]     | works again; the region is NOT convex
            //        600   | [1e-5, >=5e-4]   | but the must-fire resets have gone by here
            //
            //  * BELOW 1e-5 the base-image catcher stops latching on a crf30 1080p Android re-encode
            //    (`reenc_1080p_crf30.mp4`) and that clip produces no record (measured: fails at 8e-6 and
            //    9e-6, works at 1e-5, at every dwell from 200 to 600). This failure is ANNOUNCED: the run
            //    emits onError "closed_before_completed".
            //    THE CLIP IS NOT KEPT: it is a rung of the encode/scale grid and exists in neither the
            //    scratch directory nor testdata/. Re-derive it from the pristine rung
            //    testdata/clips/grid/screen-20260802-214946.mp4 -- see the grid table in
            //    .claude/skills/native-change-verification/SKILL.md section 3 -- before re-measuring.
            //  * ABOVE the upper edge a crf23 540p re-encode of the same recording
            //    (`screen-20260802-214946_540p.mp4` -- NOT hq_540p.mp4, a different encode of the same
            //    width) latches its scroll-area catcher earlier and its record silently degrades from 108
            //    factors to 65, with the self/parent split wrong. This failure is SILENT: success is
            //    reported and the stitched image is visually identical.
            //    NOT KEPT EITHER, and for the same reason as the crf30 rung above: re-derive it from
            //    testdata/clips/grid/screen-20260802-214946.mp4 via the grid table before re-measuring.
            //
            // MARGINS AT THE SHIPPED POINT, stated plainly and not rounded up. At a dwell of 200 ms, measured
            // on those two clips: 1.4e-5 is 1.4x above the smallest budget that still works on the loud edge
            // (1e-5; 9e-6 and 8e-6 fail) and 1.79x below the smallest that fails on the silent one (2.5e-5;
            // 2e-5 still reads 108 factors). The two edges are not symmetric and the point is deliberately not
            // the geometric centre: the loud edge announces itself, the silent one does not.
            //
            // 2e-5 is the other candidate inside the band and is NOT chosen: it would leave 1.25x to the
            // silent edge. The pair therefore moves together or not at all -- a dwell restored to 200 with the
            // budget left at 2e-5 is a combination that has never been through the golden suite and sits one
            // sweep step from silent corruption.
            //
            // LATCH-TIME SLACK, the number an unrelated change is most likely to spend: at 1.4e-5 the 540p
            // clip stays correct down to a dwell of 150 ms and corrupts at 130, so there are 50 ms -- about
            // 1.5 frames at 30 fps -- below the shipped dwell before the SILENT failure begins, and about
            // 100 ms above it (295 still passes, 300 does not) before player_standard_2's announced one. That
            // is genuinely thin, and it is the price of a dwell the user pays for; it is not a reason to
            // widen the dwell, it is a reason for an unrelated change that moves a latch to be argued.
            //
            // AND SAY THIS PLAINLY: no point in the mapped region has a comfortable margin. What the fixed
            // dwell leaves is 1.4x / 1.79x on the budget and 50 ms / 100 ms on the latch time, and each edge
            // was found by a SINGLE clip. A third clip landing inside collapses it -- player_standard_2 did
            // exactly that to the dwell axis after the sweep had already called 300 ms safe.
            //
            // Do not read this as settled the way the factor gate's 7x is. It rests on two clips, it is a
            // property of when a settle ends, and no statistic separates a thing from its own limit. Nothing
            // in the unit suites pins the latch FRAME this point produces: test_scraper_estimators.cpp asserts
            // the latch's shape (a fraction, not an absolute), and the integration goldens assert record sets
            // on clips that sit nowhere near either edge. The two edges above are the whole of the evidence,
            // and re-measuring them means re-running those two clips.
            //
            // The per-pixel gate above cannot buy margin here: re-running the 540p failure at gates 30 and
            // 60 leaves it wrong at every budget from 5e-5 up, so the early latch is a low-count/high-
            // amplitude event, not a noise-amplitude one.
            //
            // Deliberately ONE shared value, with no per-site key. The tab strip escapes the codec floor
            // because it is flat, low-detail content that requantises to bit-identity, not because it had a
            // bigger budget; a separate key would have frozen in a 1.25x margin that two of fifteen measured
            // tab-button series came within 25 % of failing.
            0.000014,
            // Viewport V and cap offset c fit across player_standard/player_inheritance/friend_inheritance
            // (common layout): tip_len = 2c + V*slope, R^2 = 1.0 -> V = 543 px, c = 0.94 px at 736 px width.
            // Stored width-normalized: 543/736 = 0.738, 0.94/736 = 0.00126. c is a widget constant (shared).
            0.738,
            0.00126,
            // Placeholder track is faintly coloured (satisfies R < 228 or G < 228); the near-white scroll-area
            // margin flanking it is all channels >= 228. This box catches that margin and excludes the track,
            // so the top/bottom margin runs locate the track ends -- but only on a frame where the thumb is
            // not sitting on the end being located; see scroll_bar_track_color below and geometryAt.
            Range<Color>{{228, 228, 228}, {255, 255, 255}},
            // The placeholder track's own fill, used to ask whether any track is visible above the thumb tip
            // (geometryAt scans from the start of the column down to that tip). Measured over 31 clips / 17,022
            // forwarded frames: the track interior (451,275 samples, both anti-aliased rows excluded) spans
            // R 201-223, G 201-224, B 200-232 with p1/p99 of 207/213, 206/211, 209/217; the thumb body
            // (27,164 samples) tops out at 168/167/175; the near-white margin (86,348 samples) starts at 228.
            // The box below therefore clears the thumb's brightest tone by 5 levels and sits 20 below the
            // track's darkest, and it contained 451,266 / 451,275 = 99.998 % of the track interior against
            // 0 / 86,348 margin and 0 / 27,164 thumb-body samples.
            //
            // The upper bound is 234 and not 227, i.e. ABOVE the 228 margin floor, and the two boxes therefore
            // overlap on 228-234. That used to be free: the caller bracketed the samples by index between the
            // margin run's end and the thumb run's end, so no margin sample was ever offered to this box. It
            // is not free any more. The window's lower bound had to move to the start of the scan column --
            // the margin run's end advances over the very row a one-tip-pixel scroll uncovers, so a window
            // hung off it cannot see that scroll at all (geometryAt derives it) -- and the page margin is now
            // separated from this box by colour alone. Measured headroom: 7 levels (the darkest margin sample
            // over 3,506 at-top frames is 241, this ceiling is 234; a later 18-clip remeasure reproduces the
            // 241 over 3,669 at-top reads). Spending it fails toward a FALSE ALARM -- a genuine top reported
            // as scrolled -- and not toward a miss: with this ceiling lifted to 244, the first verdict change
            // was a false alarm in 47 of 47 diverging tab-runs and a miss in 0. The margin FLOOR below fails
            // the other way (toward a miss); see geometryAt, which sets both directions out. The 227 variant
            // was measured too and
            // reported nine false "no track" frames on the x1.335 rung, where the single exposed row is a
            // white/track blend at 232,227,228 and 227,221,228 -- but that rung is upscaled from 404 px,
            // below the shipped 540 px minimum, so what 234 buys over 227 is coverage outside the supported
            // range, and what it costs is half of the margin headroom above. Revisiting the bound is a
            // judgement about that trade, not a defect.
            Range<Color>{{180, 180, 180}, {234, 234, 234}},
            thumbProbe(),
            // Guess-window half-width for the scroll-guess veto (see ScrollAreaOffsetEstimator::estimate). ~0.10
            // of the width (~74 px at 736): safely above the worst measured V2 true-offset guess error (~41 px on
            // the tiny-thumb friend_standard_many_rental clip) yet far below the periodicity alias distance
            // (hundreds of px), so it rejects the far aliases without ever rejecting a genuine offset. Shared by
            // both layouts. That clip is a registered integration case (native/test/integration/cases.json,
            // input testdata/clips/golden/friend_standard_many_rental.mp4), so the material this bound was
            // derived from is also material the golden suite re-runs.
            0.10,
            // self_factor_prefix_length: how many of the trainee's own factors are read, from the top, off one
            // factor-tab frame. The character-switch rule reads both frames it compares under this one value
            // (recognizer_impl::SelfFactorWindow): the read stops at it, and the rows past it are never read.
            // This is the one home of its derivation; other comments point here instead of restating it.
            //
            // Why this many can be read: the rows that hold this many factors (two per row, so 7 rows here) lie
            // inside the scroll area on the frame, and content still remains below them. The margin is that
            // remainder as a share of the scroll area's height -- measured from the star-cell bottom of the
            // last row the value requires down to the area's bottom edge. Measured on the golden corpus
            // (player_standard; unit 736, a Release CLI run with the arguments run.py builds): 63 px of a 533 px
            // area, 11.8%. friendCommon's shorter area gets the same 11.8% from its own, smaller value (see
            // there). The margin is a share of pixels, not a count of factors: the number of factors that
            // happen to be readable beyond this value is not a margin, because nothing past the value is
            // compared. Rows further down are not promised to be readable at all, which is why the read is
            // cut here rather than read and then discarded. It is a property of the layout because the
            // scroll area is; the detail screen's layout is the same on portrait and landscape panes, so these
            // rows fit on both.
            //
            // The larger the value, the more collision-resistant the comparison -- two characters whose first
            // factors happen to coincide -- and the lower the row the read has to reach. It is 14 here and 10
            // in friendCommon() because this layout's scroll area shows more rows.
            14,
        };
    }

    // Sub-pixel thumb-centre probe geometry for trackCenterX (self-centres the vertical scan on the thumb
    // instead of trusting the fixed config column). The spatial fields are fractions of the scroll-area crop
    // width, calibrated on 736 px footage where the pill is ~7 px wide: the centroid window spans 8 px, the
    // white reference sits 9 px out (2 px band), the darkest core is 2 px, and 3 px is skipped at each rounded
    // cap. max_sampled_rows (32) caps the row loop so a tall thumb stays cheap; minimum_contrast (20/255) is
    // the white-to-core gap a row needs to contribute; minimum_coverage (3) is the summed AA coverage a row's
    // centroid needs to be kept. The last three are counts/intensities, not spatial, so they do not scale.
    [[nodiscard]] chara_detail::scraper_config::ScrollBarThumbProbeConfig thumbProbe() const {
        return {
            8.0 / 736.0,
            9.0 / 736.0,
            2.0 / 736.0,
            2.0 / 736.0,
            3.0 / 736.0,
            32,
            20.0,
            3.0,
        };
    }

    // The Friend layout inserts a green "register practice partner" button above the tab bar, so the tab bar
    // and the scroll area both sit lower than on Standard. They do NOT move by the same amount, and the two
    // drops are measured from different things:
    //
    //   tab bar     -- friend_tab_bar_shift, pinned from the tab bar's own measured row (132.7 px at 736 px).
    //   scroll area -- the difference of the two viewports, below (136.2 px at 736 px).
    //
    // WHY THE SCROLL AREA'S DROP IS NOT A FREE MEASUREMENT. Its bottom edge does not move: it stays anchored
    // to the bottom of the screen (ILE), which is why the rect below keeps common()'s bottom_right verbatim
    // rather than restating it. A box that keeps its bottom and loses height has moved its top down by exactly
    // the height it lost, and the height it lost is the difference of the two visible content heights --
    // `viewport`. The white inset between the crop edge and the content is the same widget on both layouts and
    // cancels out of a difference, so this holds even though `viewport` is deliberately not the crop height
    // (chara_detail_config.h says so at its declaration).
    //
    // Deriving the scroll area from friend_tab_bar_shift instead is what once left this rect 3.4 px above the
    // content it crops, with the config asserting two different bottoms for the same box -- one via this top
    // plus its viewport, one via the shared bottom_right. Reading the drop off `viewport` removes that second
    // answer rather than correcting it: there is now one place the friend scroll area's height is stated, and
    // re-fitting the viewport moves the top with it. test_config.cpp asserts the relation against the SHIPPED
    // JSON, so regenerating this file wrongly -- or editing the builder and not regenerating -- is caught.
    //
    // The scroll-bar scan line, the scroll-area stationary rect and the scan parameters are all relative to
    // the cropped scroll area, so only the absolute, top-anchored rects move.
    [[nodiscard]] chara_detail::scraper_config::SceneScraperConfig friendCommon() const {
        auto config = common();
        config.tab_button_rect = {
            {0.0222, 0.7259 + friend_tab_bar_shift, IS}, {0.9759, 0.8037 + friend_tab_bar_shift, IS}};
        // The shorter friend scroll area has a smaller viewport: fit across friend_standard /
        // friend_standard_many_rental gives V = 407 px (0.553 width-normalized), R^2 = 1.0. Both fit points
        // are registered integration cases (native/test/integration/cases.json), so the two clips this
        // number was solved from are re-run by the golden suite. That fit is now also what places the scroll
        // area's top edge, and the 136 px it gives agrees with the drop measured straight off the pixels of
        // those same clips (135.9 px), which is an independent check on the value. cap_offset,
        // the margin and track colours and the guess-window margin are shared, unchanged from common()
        // (the two layouts draw the same widget; only where it sits and how much content it scrolls differ).
        const double friend_viewport = 0.553;
        const Rect<double> common_scroll_area = config.scroll_area_rect;
        const Point<double> common_top = common_scroll_area.topLeft();
        config.scroll_area_rect = {
            common_top.withY(common_top.y() + config.viewport - friend_viewport),
            common_scroll_area.bottomRight()};
        // Both layouts declare the band and the area as one region; friend is no exception. A band left where
        // the tab bar's shift put it would be a position derived from nothing that was ever measured.
        config.scroll_bar_rect = config.scroll_area_rect;
        config.viewport = friend_viewport;
        // How many self-factors one frame is read for (common() says what the value means and how its margin
        // is measured). This scroll area is the shorter one, so it holds fewer rows than Standard's, and the
        // value is 10, i.e. 5 rows. Measured on the golden corpus the same way
        // (friend_standard and friend_standard_many_rental; unit 736): 47 px remain below those rows in a 397 px
        // area, 11.8% -- the same share as common()'s.
        config.self_factor_prefix_length = 10;
        return config;
    }

    [[nodiscard]] Range<Color> scrollAreaBgColor() const { return colorRange({242, 243, 242}, 10); }

    [[nodiscard]] std::vector<chara_detail::scraper_config::ScanParameter> skillScanParameters() const {
        return {
            {0.0000, 0.6000, anyColor()},
            {0.0611, 0.0300, scrollAreaBgColor()},
        };
    }

    // The factor list is scrolled until it terminates. scan0 skips the first 361 px (the fixed
    // left illustration column plus the top green "因子" header). P1 then stops on a background-gray
    // run in col161 (x=0.2184) of at least 64 px: mid-list inter-row/inter-block gray gaps peak at
    // ~53-54 px, so 64 px clears them with ~10 px margin, while the true empty tail below the last
    // factor is 143-166 px so it still fires. (The old 18/29 px thresholds recurred throughout the
    // list and stopped the scroll mid-way.) The green-bar end signature is handled by factorEndGreen.
    [[nodiscard]] std::vector<chara_detail::scraper_config::ScanParameter> factorScanParameters() const {
        return {
            {0.0000, 0.4900, anyColor()},
            {0.2184, 64.0 / 736.0, scrollAreaBgColor()},
        };
    }

    // P2 end signature: when the factor list ends with a full-width green "継承履歴" bar (inheritance
    // history) instead of empty space, stop on green in the RIGHT factor column. x=0.6017 mirrors
    // col161 (0.2184) by the recognizer column offset (right_rect.left - left_rect.left =
    // 0.6259 - 0.2426 = 0.3833); no green factor card or character portrait ever renders in that
    // column, so its green noise floor is 0 px and a 5 px run (partial of the 24 px bar) cannot
    // false-fire. It is armed only after scan0 is consumed, so the top "因子" green header (inside
    // scan0's 361 px) cannot trigger it.
    [[nodiscard]] chara_detail::scraper_config::ScanParameter factorEndGreen() const {
        return {0.6017, 5.0 / 736.0, factorTabGreen()};
    }

    // The green title-bar banner that gates the base frame (BaseFrameCatcher::isHeaderVisible). Consumed with
    // isAllIn, so EVERY sample on the scan line must land in the box -- one stray sample fails the whole check,
    // the base frame is never caught, and the record is silently lost. That makes this the least forgiving of
    // the three green predicates, so it gets the thickest margins.
    //
    // Sized against a measurement, like factorTabGreen() below, and written as explicit per-channel bounds
    // rather than colorRange(centre, delta) for the same reason: the measurement is not symmetric about any
    // centre. Measured over the pixels this scan actually accepts, across the 11 integration clips decoded
    // TWICE -- once BT.601, once BT.709 (`video --color_matrix`, the pair the dual-decode suite runs), 374
    // accepting scans in all:
    //
    //   BT.601  b  6..18   g 205..235   r 129..150
    //   BT.709  b  0..11   g 187..215   r 125..146
    //   union   b  0..18   g 187..235   r 125..150
    //
    // The matrix alone moves G by ~20 on the same clip (235 -> 215) and pushes B onto its 0 floor. The previous
    // range, colorRange({139, 221, 13}, 44) = r 95..183, g 177..255, b 0..57, left the G floor only +10 under
    // the worst measured pixel -- half the swing the matrix produces, the same defect that silently cost a whole
    // browser import in isHeaderGreen (cv/detail_crop_calibrator.h), where a G floor of 180 met a
    // browser-decoded 176. The bounds below clear the worst measured pixel by +55 (r floor), +45 (r ceiling),
    // +37 (g floor) and +67 (b ceiling). G's ceiling and B's floor are the uint8 endpoints: no uint8 sample can
    // fail them, so they carry no rejection risk and there is nothing to widen.
    //
    // What it has to stay separable from is the whitish save snackbar that overlays the banner
    // (R >= 231, G >= 229, B >= 234). G does not separate the two -- the snackbar's G overlaps the banner's --
    // so R and B are the discriminating channels, and both still reject it with room: R 231 sits 36 above the
    // new 195 ceiling, B 234 sits 149 above the new 85 ceiling. B also stays under the B=96 "greenish" dialog
    // canvas that bounds the other two green predicates, so all three agree on where green stops being green.
    //
    // Caveat on the reject side: no clip in the corpus exercises it. updateUntilReady stops calling the catcher
    // once the base frame is ready, so the scan only ever runs in the pre-ready window, and in all 22 runs it
    // accepted on every one of the 374 calls -- the snackbar never appears. The snackbar figures above are
    // inherited from the earlier reading that first sized this box, not re-measured here.
    [[nodiscard]] Range<Color> headerBannerGreen() const { return {{70, 150, 0}, {195, 255, 85}}; }

    // The one green both factor-tab probes above and below look for: the "因子" section header and the
    // full-width "継承履歴" end bar. Written as explicit per-channel bounds instead of the usual
    // colorRange(centre, delta), because these bounds are sized against a MEASUREMENT and the measurement
    // is not symmetric about any centre.
    //
    // Measured over the pixels the two probes actually accept, across the 11 integration clips decoded
    // TWICE -- once BT.601, once BT.709 (`video --color_matrix`, the pair the dual-decode suite runs):
    // b 0..59, g 184..241, r 114..145. The previous range, colorRange({128, 222, 20}, 45)
    // = r 83..173, g 177..255, b 0..65, left only +7 on the G floor and +6 on the B ceiling. That is well
    // under the ~20 units a YUV -> RGB matrix change moves an absolute channel -- the same defect that
    // silently cost a whole import in isHeaderGreen (cv/detail_crop_calibrator.h), where a G floor of 180
    // met a browser-decoded 176. The bounds below clear the worst measured pixel by +34 (g floor),
    // +26 (b ceiling) and +44 / +45 (r), so each one survives the matrix swing with headroom left.
    //
    // B is the discriminating channel here, exactly as it is in isHeaderGreen, so its ceiling is the one
    // bound that cannot simply be pushed further out: the "greenish" dialog canvas of the same UI measures
    // B=96, and 85 stays clear of it. b's floor and g's ceiling are the uint8 endpoints.
    //
    // headerBannerGreen() above got the same treatment from the same 22 runs, but stays a SEPARATE box on
    // purpose: it is a different probe on a different screen, consumed with isAllIn instead of a run scan, and
    // it discriminates against the white save snackbar rather than the page background. The two boxes coming
    // out nearly equal is a consequence of it being the same UI green, not a coupling -- either may move on its
    // own measurement without dragging the other.
    [[nodiscard]] Range<Color> factorTabGreen() const { return {{70, 150, 0}, {190, 255, 85}}; }

    // The green "因子" section header is a precise "flush at the very top" sensor for maybeResetOnFactorChange:
    // it moves 1:1 with the factor list, so a tiny scroll shifts it ~10 px where the scroll thumb barely moves
    // (its travel is compressed by viewport/content). Probe a band x[0.12,0.93] of the scroll-area crop -- solid
    // header green across it, so requiring green over half the band (fraction > 0.5) still rejects a stray green
    // factor pill. Same UI green as factorEndGreen -- literally the same factorTabGreen(), see its note for how
    // its bounds are sized.
    //
    // THE BAND IS AN OCCLUSION BUDGET, NOT A LOCATION. It was x[0.65,0.88] -- picked as the narrowest strip that
    // is certainly header green -- and that is 0.15 W = 110 px of the crop's width, so a touch/tap effect wider
    // than that hides the whole probe and the header reads as absent. Widening to [0.12,0.93] does not move the
    // bar's edges: measured over 9 golden clips / 8,261 frames, the returned row, the bar's height and therefore
    // the scroll at which the sensor goes silent are identical under both bands (2 disagreeing frames, neither
    // at top). What it buys is the occlusion a scan survives, 110 px -> 368 px of tap diameter. The cost is the
    // scan, and it is two different numbers: the scan STOPS at the first over-threshold row, so a frame showing
    // the header costs 18 us -> 63 us, while a frame with no header anywhere pays the full crop, 886 us ->
    // 2890 us (8.8% of a 33 ms frame). The worst case is the common one on a scrolled tab, which is why
    // topOfContent is called once per frame and not once per consumer.
    //
    // The edges are the measured limits, not round numbers. Green occupancy on a real header row stays 0.916
    // here but falls to 0.806 at [0.05,0.99], spending headroom above the threshold; and the highest NON-header
    // row rises to 0.4094 here but to 0.4347 at [0.12,0.88], too close under 0.5 to keep. That lower figure is
    // the one to watch when the game adds factors: it is driven by the green factor pill, which is content.
    // flush_tolerance_px is in capture pixels (the header top-edge row). Live measurement (factor reset diag): a
    // real switch snaps to EXACTLY flush (0 px), whereas a same-character scroll of only ~4 px still spikes the
    // content diff to ~29 %. 1.5 px sits in that gap -- it rejects a >=2 px scroll while tolerating up to 1 px of
    // header-edge detection jitter on a genuine flush frame, so a real switch is still detected. Pixels, not a
    // width fraction, so it does not drift with capture resolution (a fraction would drop below 1 px on a smaller
    // capture and start missing real switches).
    [[nodiscard]] chara_detail::scraper_config::FactorHeaderConfig factorHeader() const {
        return {factorTabGreen(), 0.12, 0.93, 0.5, 1.5};
    }

    [[nodiscard]] std::vector<chara_detail::scraper_config::ScanParameter> campaignScanParameters() const {
        return {
            {0.0000, 1.0000, anyColor()},
            {0.9312, 0.0074, colorRange({255, 255, 255}, 5)},
            {0.9312, 0.0390, scrollAreaBgColor()},
        };
    }
};

}  // namespace uma::tool
