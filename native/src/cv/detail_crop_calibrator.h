#pragma once

// Auto-calibration of the game's client rect from in-frame UI landmarks.
//
// WHY THIS EXISTS
//   The frame handed to the recognizer is supposed to be exactly the game's client area, but it can be off
//   by a few pixels: on web the browser window chrome is trimmed by a ratio heuristic (Chrome leaves a 1 px
//   border, Firefox ~10 px vertically / ~4 px horizontally), and on desktop the letterbox tolerance plus
//   rounding can shift it. Scene detection only tolerates dy -3..+3 px, dx -2..+1 px and width 657..666 at a
//   665-wide reference, so those few pixels break recognition outright.
//
//   This scans the character-detail dialog for three landmarks and reconstructs the true client rect, which
//   the caller can then install as an explicit intersection (FrameAnchor::fixed). It is deliberately
//   decoupled from the scene/condition machinery: it takes a plain cv::Mat plus the caller's current
//   intersection estimate and returns a rect or "no result". Wiring (when to run it, when to adopt the
//   result) belongs to the caller.
//
// CONTRACT
//   calibrateDetailCrop() never throws and never logs. It is expected to run on every frame while the
//   dialog is NOT open, so the common path must fail fast and cheap -- the header start-pixel check is the
//   intended early-out, and it gives up after two of its three columns fail, so the usual cost is two
//   single-pixel reads. Every anomaly (out-of-bounds start point, missing
//   landmark, disagreeing columns, a landmark that fails its consistency check) degrades to a status code.
//   Equally important, it must not return a CONFIDENT WRONG rect: the caller cannot tell one from a good
//   one, so the solved scale is cross-checked against an independent feature -- the stat band -- before the
//   result is reported. The band stage has four guards, not one, and they fire in this order:
//   BandOutOfFrame, BandLeftEdge, BandRightEdge, BandWidth. Which one a wrong scale trips depends on the
//   input, because the scale also places the edge search windows; see the tolerance paragraph above
//   calibrateDetailCrop. Do not restate this as "the width comparison refuses it" -- that was measured false.
//
// LANDMARKS
//   All constants below were measured on 12 full-dialog stills at 3 resolutions plus 4 real web frames; see
//   the survey under testdata/evidence/detail-crop-auto-calibration/. Normalized coordinates follow
//   FrameAnchor: pixel = intersection.topLeft + (xn, yn) * unit, where unit == intersection.width(), so
//   BOTH axes are divided by the width and a full-height 9:16 frame spans yn in [0, 1.7778].
//
//   (a) The boundary between the dialog's green header bar and the canvas below it (yn 0.12907). A 2-3 px
//       soft gradient, hence +-1 px absolute accuracy. In a 4:2:0 clip that softness is chroma sharing and
//       not anti-aliasing, which matters for how it moves under a decoder -- see the `g - b` note below.
//   (b) The bottom edge of the close button (yn 1.69057). A true 1 px step (255 -> 104), the crispest of
//       the three -- but also the most treacherous, because the button's TOP border (yn 1.5883) looks the
//       same and the canvas above the button looks like the button's interior. A scan that stops on the TOP
//       border solves the baseline from the wrong pair and comes out 6.6 % small; what refuses it is the
//       stat-band stage below -- though not necessarily by comparing widths, since a scale that small also
//       displaces the band's search windows and the edge scan can fail first. See the tolerance paragraph
//       above calibrateDetailCrop.
//   (c) The green band behind the 5 stats, used ONLY for its horizontal centre. Its left/right edges are
//       individually crisp, but the band *width* drifts 0.12 % across resolutions (the game pixel-snaps
//       this UI) while its centre is stable to 0.006 %. The scale therefore comes from the (a)-(b)
//       baseline alone; solving it from the band edges injects ~1 px of error.

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "types/shape.h"

namespace uma {

// Internal helpers for the calibrator. A named namespace (not an anonymous one) keeps a single definition
// across the translation units that include this header; mirrors frame_impl in cv/frame.h.
namespace detail_crop_impl {

// --- Landmark constants (see the header comment for provenance) --------------------------------------

// WHERE THE SCANS START
//   Both vertical scans must begin inside the region they are walking out of, so the start offset's real
//   budget is the two-sided margin to that region's edges. Measured over the 16 reference images, worst case
//   (normalized, and in px at unit 665):
//     header green   yn 0.04812 .. 0.12636   span 52.0 px
//     button interior yn 1.59248 .. 1.68837  span 63.8 px
//   The dominant real-world misalignment is a window title bar, which always puts the game content LOWER
//   than the assumed intersection and therefore moves the start point HIGHER within the real content. Both
//   starts are placed at 65 % of their span, biased that way -- see the tolerances on calibrateDetailCrop.

// (a) green header bar / canvas boundary.
inline constexpr double kHeaderBoundaryY = 0.12907;
inline constexpr double kHeaderScanStartY = 0.099;
inline constexpr double kHeaderScanSpanY = 0.10;
// The dialog title occupies xn 0.41-0.61, so the probes stay well clear of it. The leftmost probe of the
// original four (xn 0.20) was dropped; three columns are enough for a majority vote.
inline constexpr std::array<double, 3> kHeaderColumnsX{0.30, 0.70, 0.80};

// (b) close-button bottom edge.
inline constexpr double kButtonBoundaryY = 1.69057;
inline constexpr double kButtonScanStartY = 1.655;
// The span reaches 1.775, still short of the client's bottom edge at 1.7778, so a scan cannot walk out of
// the client area into whatever surrounds it. From the start the bottom border is 0.035 unit away, so this
// still reaches it with the content shifted as far as the start margins allow.
inline constexpr double kButtonScanSpanY = 0.12;
// The button glyphs end at xn 0.557 and the button itself at 0.684, leaving an empty white band at
// xn 0.565-0.675. The original four probes were 0.60/0.62/0.64/0.66; the middle two are merged into one, so
// three columns keep the same overall span with wider spacing between them.
inline constexpr std::array<double, 3> kButtonColumnsX{0.60, 0.63, 0.66};

// (c) 5-stat green band. The rows are the flat interior of the band (its full extent is 0.4239-0.4606).
inline constexpr double kBandRowTopY = 0.4266;
inline constexpr double kBandRowBottomY = 0.4592;
inline constexpr double kBandLeftX = 0.03252;
inline constexpr double kBandRightX = 0.96613;
inline constexpr double kBandCentreX = 0.49933;
// prof[x] = mean_y(G) - mean_y(B) over the band rows: ~181 on the band, -9..+4 outside the dialog. Half the
// plateau leaves ~90 units of margin on both sides.
inline constexpr double kBandEdgeThreshold = 90.0;
// Half-width of the search window around each expected edge. Keeps a green in-game background outside the
// dialog from capturing the outermost crossing.
inline constexpr double kBandSearchRadiusX = 0.05;
// How far the measured band width may differ from the width the vertical scale predicts. The band is NOT
// used for the scale (it pixel-snaps, drifting 0.0008 normalized between resolutions), but comparing the two
// still catches an edge captured on the wrong feature: at a -37 px horizontal misalignment one edge lands
// ~40 px out, which would otherwise be reported as a confident 20 px error on `left`.
inline constexpr double kBandWidthTolerance = 0.01;

// How far apart (px) two probe columns may land and still be counted as agreeing. A mid-transition or
// animating frame shows up as a larger disagreement.
inline constexpr int kColumnAgreementTolerance = 2;

// The client area is 9:16, and `unit` is its width.
inline constexpr double kClientHeightPerWidth = 16.0 / 9.0;

// --- Pixel helpers -----------------------------------------------------------------------------------

struct Bgr {
    int b;
    int g;
    int r;
};

inline bool inBounds(const cv::Mat &image, int x, int y) {
    return x >= 0 && y >= 0 && x < image.cols && y < image.rows;
}

// Precondition: inBounds(image, x, y) and image.type() == CV_8UC3 (both checked by the callers).
inline Bgr bgrAt(const cv::Mat &image, int x, int y) {
    const cv::Vec3b &pixel = image.ptr<cv::Vec3b>(y)[x];
    return {pixel[0], pixel[1], pixel[2]};
}

// Header green. Three discriminating tests -- all on CHANNEL DIFFERENCES or on the one channel that
// locates the boundary -- plus a deliberately loose absolute box that is insurance only.
//
//   b <= 70        separates the header from the "greenish" canvas some dialogs have (54 inside vs 96
//                  outside), and it is what LOCATES the boundary: B is the channel that jumps across the
//                  soft header/canvas edge (real footage: 48 on the last header row, 91 on the
//                  first canvas one).
//   g - b >= 100   is the landmark-IDENTITY test: the header is a saturated green, so G stands far above B
//                  (142 inside vs 107 on the greenish canvas -- which `b <= 70` rejects by 26 on its own).
//                  It implies g >= 100 on its own, since b >= 0. It was 120 until a browser measurement
//                  moved it; see the second note below, which is the whole reason for the value.
//   g - r >= 40    is the second identity test, and the one that keeps R from being ignored entirely. R's
//                  ABSOLUTE range overlaps the canvas and is not usable on its own (which is all the
//                  original note meant); the DIFFERENCE is not, because the header green stands as far
//                  above R as it does above B. Measured over the 56 381 pixels the two tests above accept
//                  across 11 clips x 2 matrices, g - r runs 52..107 -- so the limit sits 12 below the worst
//                  real pixel, while the matrix itself only moves g - r by ~9 (61 BT.601 -> 52 BT.709 on
//                  that same worst pixel). The two pixels it newly rejects are not header at all: they are
//                  the gold "S" aptitude glyph, see the absolute box note below.
//
// Around those three the predicate carries an absolute range on all three channels, in the repo's usual
// shape (148 of the 151 absolute Range<Color> entries in assets/config fill in every channel). Apart from
// b's maximum -- which is `b <= 70` itself -- those bounds are INSURANCE, and are sized to be provably
// passive: g >= 125 against a measured worst of 169, r >= 40 against 100, r <= 200 against 142, i.e. at
// least 44 clear, more than twice the ~20-unit swing a YUV -> RGB matrix change puts on an absolute
// channel. That is what keeps them from ever becoming the deciding term the way `g >= 180` did. They were
// checked against all 1 116 018 pixels of the recorded probe strips: they change the verdict on none of
// them, so no clip in the corpus depends on them.
//
// A `g >= 180` FLOOR USED TO STAND HERE AND IT COST A WHOLE IMPORT, SILENTLY.
// 180 was read off BT.601-decoded footage. Browsers convert with BT.709 -- NOT by honouring a tag: every clip
// in this corpus is UNTAGGED (`color_space=unknown`, no `colr` box), and BT.709 is simply what a browser
// assumes for untagged content. That darkens this same green by ~20 on G (measured on the same pixels:
// portrait start (14, 219, 123) -> (8, 199, 118), landscape start (9, 194, 105) -> (4, 176, 101)) whatever
// the container says. A 2326x1340 landscape import therefore reads G=176 on the header plateau -- FOUR below
// the floor -- so every one of its 374 frames exited at HeaderStart and the run produced zero records, with no
// error reported anywhere. The dual-decode suite (native/test/integration/run_dual_decode.py) now pins exactly
// this. Do not try to recover the tag instead: cv/decoded_frame_to_bgr.h records that a browser's REPORTED
// `VideoFrame.colorSpace.matrix` does not follow the conversion it actually performed either.
//
// The floor is REMOVED rather than lowered, because an absolute channel level is precisely the quantity a
// YUV -> RGB matrix change moves; any replacement number would again be measured on one interpretation.
// The two remaining tests were re-measured against both interpretations over 22 CLI runs (11 clips x 2
// matrices, dumping all three probe columns of every calibrateDetailCrop call; survey under
// testdata/evidence/video-import-colour/):
//   * On all ten BT.601 golden trajectories every call's (status, boundary row) is exactly what the floor
//     produced, so the shipping CLI path does not move at all -- and lowering the floor to any value in
//     [120, 170] produces that same result, i.e. the floor had no discriminating power left. (A floor
//     of 175 does NOT: it still cuts the BT.709 gradient and the dual-decode case goes red again.)
//   * The floor was not only rejecting the landscape header, it was cutting through the header's own
//     bottom gradient and MOVING the boundary: under BT.709 it reported rows the BT.601 run never reports
//     (85 and 89 against 86 and 90 on friend_inheritance) and put the landscape boundary at 134 against
//     BT.601's 125. Without it the two matrices report the same set of rows on every portrait clip, and the
//     landscape boundary is 125 on 311 of 313 scans, i.e. BT.601's answer.
//   * b has no room to move: widening it to 80 changes 331 BT.601 header decisions. It sits ON the
//     transition by design, so its slack at the boundary is 0-2 whatever value it takes -- which is what a
//     boundary test looks like. A b <= 80 build was run to confirm this is not theory: it fails
//     integration_golden.player_standard_3 -- and only that one of the eleven goldens, which is why the
//     limits are pinned as literals below. g - b was read as the same kind of term at the time, and that
//     was WRONG: narrowing it to 90 does change one BT.601 decision, but 110 and 100 change none, and the
//     browser measurement in the next note shows that at 120 it was already cutting the boundary's own
//     transition row, which it was assumed to merely sit beside.
// Accepted volume across the whole edit: 8.15 % of the RGB cube with the floor -> 10.94 % with the floor
// gone -> 7.01 % once g - r >= 40 is added -> 5.24 % with the absolute box on top. Over those same 22 runs
// the relaxation admitted no new start pixel anywhere: the per-clip count of "this is not the dialog"
// early-outs is unchanged, except on the landscape clip under BT.709 where 315 scans that DO show the
// dialog stop being turned away.
//
// AND THEN `g - b >= 120` COST THE SAME IMPORT AGAIN, THE SAME WAY.
// Removing the floor was necessary and not sufficient. The 2326x1340 landscape clip still produced zero
// records when a real desktop Firefox 153 decoded it, and the exit had moved rather than gone: with the
// browser's own 374 frames carried into the CLI, isHeaderGreen now ACCEPTS the header (Ok on 311 of 345
// scanned frames) -- but 120 cuts the header's own bottom TRANSITION row, so the boundary is reported one
// row high.
//
// EVERY LANDSCAPE ROW NUMBER IN THIS COMMENT IS STATED IN THE CORRECTED GEOMETRY. That material was
// re-cut on 2026-08-18 (test/README.md, "the `_toppad` correction"): its 30 rows of window-decoration
// padding had been put at the BOTTOM, which a browser window share cannot produce, and were translated to
// the TOP. It is a pure vertical translation at unchanged frame size, so every landscape row here is the
// originally measured one PLUS 30, colours are untouched, and the solved scale is unchanged -- both
// landmarks move together, and the shift is even, so the 4:2:0 luma-pair / chroma-row pairing survives too.
// Frame 100, all three probe columns of the accepted pane candidate, transition row y = 124,
// with a nominal BT.709 conversion of the same source pixels in the middle for comparison:
//     x=524  Firefox (56,173,120) 117 | bt709 (50,171,119) 121 | bt601 (55,184,123) 129
//     x=818  Firefox (57,172,117) 115 | bt709 (51,171,116) 120 | bt601 (56,184,120) 128
//     x=892  Firefox (56,173,120) 117 | bt709 (50,171,119) 121 | bt601 (55,184,123) 129
//
// TWO THINGS ARE TRUE HERE AND NEITHER IS "ANTI-ALIASING" OR "BT.709". Both are worth stating, because
// each one on its own would size the limit wrongly.
//   (1) WHY ROW 124 IS SOFT. The source is yuv420p, so luma rows 124 and 125 SHARE one chroma sample --
//       chroma row 62, U=80 V=110, midway between the header's U=58 V=102 and the canvas's U=127 V=125 --
//       while luma barely moves across row 124 (Y = 143 -> 147 -> 170 on rows 123 / 124 / 125). Row 124 is
//       therefore header LUMA carrying MIXED CHROMA, which is why its G sinks BELOW BOTH neighbours
//       (195 -> 184 -> 211) while B and R rise. An anti-aliased blend of header and canvas cannot do that:
//       solving the blend fraction from B leaves a G residual of -5.6 / -18.5 / -20.8 on the three columns,
//       and a real blend would ramp every channel monotonically.
//       Row 125 is the same shared chroma with the CANVAS's luma, i.e. a BRIGHT GREEN RIM under the header
//       (g = 210..212, ABOVE the header plateau's own 194..195) rather than canvas. What stops the scan
//       there is `b <= 70` against b = 81..85, exactly as the boundary-locator note above claims.
//   (2) WHY 120 WAS ALREADY LOST. It had ZERO margin against an ideal BT.709 conversion, never mind a real
//       one: swscale with in_color_matrix=bt709 reads 121 / 120 / 121 on that row, so x=818 cleared 120 by
//       exactly 0. Firefox's decoder then rounds a further 4..5 off (117 / 115 / 117), and that is what
//       moved the row. So the cause is not the choice of BT.709 -- the matrix spent the entire budget, and
//       the rounding of whichever decoder implements it was always going to decide the verdict. A limit
//       sized against a nominal matrix is a limit with no room for the implementations of that matrix.
//
// Every other term passes on that row (b <= 70 by 13..14, g - r >= 40 by 12..15, absolute box passive) and
// row 125 is not green under any of the three interpretations (b = 81..85), so `b <= 70` still LOCATES the
// boundary exactly as documented; the only term that moved is this one. What follows is not a rejected
// frame but a shifted one, which is why nothing reported an error: boundary 124 instead of 125. The shifted
// scan does not merely start a row higher, it solves a DIFFERENT SCALE: header_y drops by one while
// button_y does not, so the landmark gap is 1152 rows instead of 1151 and
// scale = gap / (kButtonBoundaryY - kHeaderBoundaryY) = 737.752 instead of 737.112. Hence
// top = header_y - kHeaderBoundaryY * scale = +28.778 instead of +29.861, under a client height of 1312
// instead of 1310 -- and since DetailCropCalibration::toRect rounds origin and extent independently, the
// candidate is top 29 / bottom 1341 in a 1340-row frame. DetailCropTracker's containment gate
// (isCropInsideFrame in cv/detail_crop_tracker.h) rejected it on `rect.bottom() <= size.height()`, where the
// correct scan lands its bottom edge exactly on 1340 and is admitted by the half-open rule
// -> nothing latched -> onCharaDetailStarted never fired -> 0 records, again silently.
// SINCE FIXED, in the rounding rather than here: toRect(frame) absorbs exactly one row of its own
// independent-rounding overhang, so that candidate would now be pulled back to 1340 and adopted. That does
// NOT make this limit optional -- the shifted scan still solves the wrong scale (737.752), so what it buys
// is a 1-row-off geometry instead of silence; locating the boundary correctly is still this term's job.
// Measured before the material was corrected, i.e. with those 30 padding rows at the bottom instead of the
// top: the same two scans read rows 94 / 95, top came out at -1.222 against ~0, and the edge that rejected
// was `rect.top() >= 0`, on 310 of those 311 frames. The translation moves which edge catches it (the top
// numbers above are that arithmetic, not a re-measurement); that it is caught at all is unchanged.
//
// 100, not 117 (the largest limit at which that import recovers -- 118 still yields nothing). 117 is sized
// to the incident; 100 is sized to the mechanism. On the very pixels above, a browser's decode moves this
// term by 13 (128..129 -> 115..117) -- 8 of that the matrix, 4..5 of it the decoder's own rounding on top
// of the matrix -- so a limit 15 below the worst accepted browser pixel absorbs one further swing of the
// size that caused the bug, where 110 would absorb 5. The price was swept
// the same way the floor was, by dumping every calibrateDetailCrop call's (status, boundary row) over the
// BT.601 goldens: 110 and 100 change NONE of them, 90 changes one. The accepted set only grows as the limit
// falls, so a decision that does not flip at 100 cannot flip at any higher limit either -- 100 is the
// measured floor, and that one sweep covers the whole interval [100, 120]. Accepted volume 5.24 % -> 5.73 %
// of the cube.
//
// Firefox's own pixels are now a test asset rather than a story: integration_golden.firefox_landscape_2pane_ps5
// replays the 374 frames Firefox 153 handed to the core, losslessly recorded, and pins the resulting record
// against the swscale BT.601 baseline for the same clip (native/test/README.md says how the dump is
// reproduced). At 120 that case produces no record at all, which is what makes it the only automated test
// that sees this class of defect: the dual-decode suite varies the matrix, but a browser's decoder differs
// from `--color_matrix bt709` in its rounding too, and it was those 4..5 units of rounding that decided
// this one -- `--color_matrix bt709` alone still cleared 120, by 0 on the worst column.
// The absolute range, all three channels, in the repo's usual shape. Exactly ONE of its six bounds is
// tight and load-bearing -- b's maximum, which is the boundary locator described above. The other five are
// the loose insurance: b >= 0 and g <= 255 are the uint8 endpoints, and g >= 125 / r >= 40 / r <= 200 are
// sized to stay passive (see the note above). b deliberately does NOT get a second, looser maximum: `b <=
// 70` already IS b's absolute maximum, and anything above it would be unreachable dead code.
inline constexpr Bgr kHeaderGreenMin{0, 125, 40};
inline constexpr Bgr kHeaderGreenMax{70, 255, 200};

inline bool isHeaderGreen(const Bgr &pixel) {
    const bool in_range = pixel.b >= kHeaderGreenMin.b && pixel.b <= kHeaderGreenMax.b
                          && pixel.g >= kHeaderGreenMin.g && pixel.g <= kHeaderGreenMax.g
                          && pixel.r >= kHeaderGreenMin.r && pixel.r <= kHeaderGreenMax.r;
    return in_range && (pixel.g - pixel.b) >= 100 && (pixel.g - pixel.r) >= 40;
}

// White button interior (238-255 on every channel, with a diagonal gloss). NOTE this does NOT distinguish
// the button from the dialog canvas around it, which measures (250, 250, 250), so it cannot tell a start
// point placed on the button from one placed above it -- see the (b) note in the header comment.
inline bool isButtonInterior(const Bgr &pixel) {
    return std::min({pixel.r, pixel.g, pixel.b}) >= 200;
}

// Any dark row: the button's borders, but also window chrome, letterbox bars and dark game art.
inline bool isDarkRow(const Bgr &pixel) {
    return std::max({pixel.r, pixel.g, pixel.b}) < 160;
}

// A dark row that could be one of the button's borders. The brightness floor tells them apart from window
// chrome and letterbox: across all 16 reference images the button's borders never go below 93 on their
// darkest channel, while a browser window border or a letterbox bar measures 20-47. Without it, a scan that
// starts BELOW the button latches onto the frame's own 1 px border and reports a confident wrong scale.
inline bool isButtonBorder(const Bgr &pixel) {
    return isDarkRow(pixel) && std::min({pixel.r, pixel.g, pixel.b}) >= 70;
}

enum class ScanOutcome {
    Found,
    StartRejected,
    NotFound,
};

// Walks down column `x` from `start_y` for at most `span` rows and reports the first row satisfying
// `stop_pred`. `start_pred` gates the very first pixel: it is the cheap "is the dialog even here" test, and
// its rejection is reported separately so the caller can tell "wrong screen" from "landmark not found".
template<typename StartPredicate, typename StopPredicate>
ScanOutcome scanDown(
    const cv::Mat &image,
    int x,
    int start_y,
    int span,
    const StartPredicate &start_pred,
    const StopPredicate &stop_pred,
    int &found_y) {
    if (!inBounds(image, x, start_y) || !start_pred(bgrAt(image, x, start_y))) {
        return ScanOutcome::StartRejected;
    }
    const int end_y = std::min(start_y + span, image.rows);
    for (int y = start_y + 1; y < end_y; y++) {
        if (stop_pred(bgrAt(image, x, y))) {
            found_y = y;
            return ScanOutcome::Found;
        }
    }
    return ScanOutcome::NotFound;
}

// Why a set of probe columns did not produce a landmark.
enum class VoteOutcome {
    Agreed,
    NoStart,  // no column's start pixel passed its gate -- the cheap "this is not the dialog" exit
    NoLandmark,  // some column started, but none of them found the landmark
    NoMajority,  // columns found rows, but no two of them agree
};

// Majority vote over the (up to three) rows the probe columns reported.
//
// One bad column is expected in normal use -- the mouse cursor crossing a scan line, a UI element
// overlapping it, or one column landing on the transition row of a soft boundary -- and must not cost the
// whole calibration. So the rule is: at least two columns must agree within kColumnAgreementTolerance, and
// their consensus is used. A column that found nothing simply does not vote, which means two agreeing
// columns carry the result even when the third is blind. Nothing weaker would do: a single column deciding
// alone is exactly the silent-wrong-answer case this file is built to avoid.
inline VoteOutcome majorityVote(std::vector<int> rows, bool any_started, double &agreed) {
    if (rows.empty()) {
        return any_started ? VoteOutcome::NoLandmark : VoteOutcome::NoStart;
    }
    std::sort(rows.begin(), rows.end());
    if (rows.size() == 3 && (rows[2] - rows[0]) <= kColumnAgreementTolerance) {
        agreed = rows[1];  // all three agree; the median is the consensus
        return VoteOutcome::Agreed;
    }
    for (size_t i = 1; i < rows.size(); i++) {
        if ((rows[i] - rows[i - 1]) <= kColumnAgreementTolerance) {
            agreed = (rows[i - 1] + rows[i]) / 2.0;
            return VoteOutcome::Agreed;
        }
    }
    return VoteOutcome::NoMajority;
}

// prof[x] = mean_y(G) - mean_y(B) over rows [y_top, y_bottom], for x in [x_from, x_to].
// Precondition: the whole window is inside the image.
inline std::vector<double> greenProfile(const cv::Mat &image, int x_from, int x_to, int y_top, int y_bottom) {
    const int columns = x_to - x_from + 1;
    const int rows = y_bottom - y_top + 1;
    std::vector<double> profile(static_cast<size_t>(columns), 0.0);
    for (int y = y_top; y <= y_bottom; y++) {
        const cv::Vec3b *row = image.ptr<cv::Vec3b>(y);
        for (int i = 0; i < columns; i++) {
            const cv::Vec3b &pixel = row[x_from + i];
            profile[static_cast<size_t>(i)] += static_cast<double>(pixel[1]) - static_cast<double>(pixel[0]);
        }
    }
    for (auto &value : profile) {
        value /= rows;
    }
    return profile;
}

// Linear interpolation of the sub-pixel position at which the profile crosses `kBandEdgeThreshold` between
// two adjacent columns. The transition is ~3 px wide, so a whole-pixel edge would cost up to 0.5 px.
inline double interpolateCrossing(int x_low, double value_low, double value_high) {
    const double delta = value_high - value_low;
    if (delta == 0.0) {
        return x_low;
    }
    return x_low + (kBandEdgeThreshold - value_low) / delta;
}

// Locates the band edge inside [x_from, x_to] and writes its sub-pixel position to `edge`.
//
// `rising` picks which side is being measured: the left edge is the LEFTmost below->above crossing and the
// right edge the RIGHTmost above->below one, i.e. both walk inward from the outside of the search window.
// Combined with the window's limited half-width that is what keeps a green in-game background beside the
// dialog from capturing the edge.
inline bool
findBandEdge(const cv::Mat &image, int x_from, int x_to, int y_top, int y_bottom, bool rising, double &edge) {
    const auto profile = greenProfile(image, x_from, x_to, y_top, y_bottom);
    for (size_t step = 1; step < profile.size(); step++) {
        const size_t i = rising ? step : profile.size() - step;
        const double low = profile[i - 1];
        const double high = profile[i];
        const bool crossing = rising ? (low < kBandEdgeThreshold && high >= kBandEdgeThreshold)
                                     : (high < kBandEdgeThreshold && low >= kBandEdgeThreshold);
        if (crossing) {
            edge = interpolateCrossing(x_from + static_cast<int>(i) - 1, low, high);
            return true;
        }
    }
    return false;
}

}  // namespace detail_crop_impl

// Why a calibration attempt produced no result. `Ok` is the only success value; everything else is a silent
// "no calibration" -- none of them is an error condition, since the dialog being closed is the normal state.
enum class DetailCropStatus {
    Ok,
    UnsupportedImage,  // empty / non-CV_8UC3 mat, or a degenerate intersection
    HeaderStart,  // the header start pixel is not header green (the usual "dialog not open" exit)
    HeaderMissing,  // header green never ends within the scan span
    HeaderSpread,  // columns found the boundary but no two of them agree
    ButtonStart,  // the close-button start pixel is not white
    ButtonMissing,  // no border-coloured row within the scan span
    ButtonSpread,  // columns found a border but no two of them agree
    BandLeftEdge,  // no threshold crossing in the left search window
    BandRightEdge,  // no threshold crossing in the right search window
    BandWidth,  // the two edges are not the band's: their span disagrees with the vertical scale
    // The two below are defensive backstops, not expected states: once both vertical landmarks are found the
    // band rows always land between them and the baseline is always positive, so neither is reachable. They
    // stay to keep a malformed input from indexing outside the image or dividing by zero.
    BandOutOfFrame,  // the stat-band rows or search windows fall outside the image
    DegenerateScale,  // the reconstructed width is not a usable positive number
};

// The reconstructed client rect, in frame pixels, kept in floating point so a caller can report the
// sub-pixel residual. `width` is the `unit` a FrameAnchor built from this rect would use.
struct DetailCropCalibration {
    double left = 0.0;
    double top = 0.0;
    double width = 0.0;
    double height = 0.0;

    // Origin and extent are rounded independently, so the rounded rect keeps the rounded width -- which is
    // the `unit` a FrameAnchor derives from it, and therefore the number scene detection is sensitive to.
    [[nodiscard]] Rect<int> toRect() const {
        const int rounded_left = static_cast<int>(std::lround(left));
        const int rounded_top = static_cast<int>(std::lround(top));
        return {
            Point<int>{rounded_left, rounded_top},
            Point<int>{
                rounded_left + static_cast<int>(std::lround(width)),
                rounded_top + static_cast<int>(std::lround(height))},
        };
    }

    // The same rect, with ONE row of the rounding above absorbed instead of paid for.
    //
    // WHY IT IS NEEDED. Because the origin and the extent are rounded independently,
    // `lround(top) + lround(height)` can exceed `lround(top + height)` by at most 1. Every supported capture
    // form is flush -- a 736x1308 phone capture has a true client height of 736 * 16/9 = 1308.444, and a
    // browser share puts a 16:9 box in the frame with the game filling it to the last row -- so the
    // CONTINUOUS solution already overhangs the frame by a fraction of a row on every clip measured, and
    // survives only because both lrounds happen to floor it. When one of them does not, the caller's
    // containment gate (isCropInsideFrame in cv/detail_crop_tracker.h) refuses the rect, nothing latches,
    // and the run produces no records and no error. That has happened on real footage: the `g - b >= 120`
    // incident recorded above solved top 29 / bottom 1341 in a 1340-row frame and lost the whole import
    // silently.
    //
    // WHAT IT DOES. It pulls the BOTTOM edge in by that one row and nothing else. `left`, `top` and the
    // WIDTH are bit-identical to toRect()'s -- the width is the `unit` every normalized coordinate is
    // divided by, so it must survive rounding untouched, which is the whole reason the rounding is
    // independent in the first place. An overhang of two rows or more is not this function's rounding and is
    // left in place for the gate to refuse, and so is a negative origin: the budget absorbed here is exactly
    // the budget the arithmetic above can create, which is a statement about this code rather than about any
    // clip.
    //
    // THE PRICE, stated because it is real. `intersection.bottom()` is not a mere bound: frame.h derives
    // offset_v[IntersectLogicalEnd] / [IntersectPixelEnd] from it, and those drive the scroll-area and
    // scroll-bar rects, the recognizer scan rects and the stitcher. So on a frame whose bottom edge is
    // pulled in, every bottom-anchored row moves by 1 px. That happens only on frames which today yield
    // nothing at all, so this trades a silent total loss for a silent <= 1 px vertical error.
    //
    // Frame::resizedToUnit (cv/frame.h) already has this shape -- it clamps its derived intersection back
    // inside the destination image rather than emitting one that overhangs.
    [[nodiscard]] Rect<int> toRect(const Size<int> &frame) const {
        const Rect<int> rect = toRect();
        if (rect.bottom() != frame.height() + 1) {
            return rect;
        }
        return {rect.topLeft(), Point<int>{rect.right(), frame.height()}};
    }
};

struct DetailCropResult {
    DetailCropStatus status = DetailCropStatus::UnsupportedImage;
    DetailCropCalibration calibration;

    [[nodiscard]] bool ok() const { return status == DetailCropStatus::Ok; }
};

// Scans `image` for the character-detail dialog's landmarks and reconstructs the game's client rect.
//
// `intersection` is the caller's current estimate (e.g. FrameAnchor::intersect(image.size())); every scan is
// placed relative to it. Measured tolerance of that estimate, per axis, at unit 665 -- the range over which
// the reconstruction stays within 1.5 px, each axis swept independently over the reference images. A
// POSITIVE delta means the caller's value is larger than the truth, so a positive dy is an estimate whose
// origin sits BELOW the real content:
//
//   vertical dy  -19 .. +19      horizontal dx  -32 .. +33      WIDTH dunit  -17 .. +13
//
// The width axis is the tight and dangerous one: the button's scan start carries 1.655x leverage on the
// caller's unit while the header's carries only 0.099x, so a unit error moves the button start point ~17x
// further, and far enough above the button the scan stops on its TOP border instead. That is the one way
// this function can be handed a self-consistent set of landmarks that is nevertheless wrong -- all three
// columns agree on the wrong row, so the spread check passes. What refuses it is the stat-band stage:
// solving the baseline from the top border instead of the bottom one gives a scale 6.6 % small
// ((1.5883 - 0.12907) / (1.69057 - 0.12907) = 0.9345), and the band is then scanned with that scale. Two of
// the stage's checks can catch it, and which one fires depends on the input:
//   - the search windows are centred on kBandLeftX / kBandRightX * scale with half-width
//     kBandSearchRadiusX * scale, so a scale this wrong can leave the true edge outside its own window,
//     which is reported as BandLeftEdge / BandRightEdge;
//   - if both edges are still found, kBandWidthTolerance rejects a relative scale error above
//     0.01 / (kBandRightX - kBandLeftX) = 1.07 %, which 6.6 % exceeds about six-fold.
// Measured on ONE input, and not claimed beyond it: the doctest "refuses a caller estimate narrow enough to
// fool the button scan" (test/cv/test_detail_crop_calibrator.cpp) -- a 540-unit synthetic dialog handed a
// 505 px estimate -- returns BandRightEdge. Consistent with that, the constants above put the solved scale
// at 504.6 and the right search window at x 463..513, while the band's right edge sits at x 522; so on that
// input the width comparison is never reached. Whether some other narrowing reaches it is unmeasured.
// Never throws; a failed scan is reported through DetailCropResult::status.
inline DetailCropResult calibrateDetailCrop(const cv::Mat &image, const Rect<int> &intersection) {
    using namespace detail_crop_impl;

    DetailCropResult result;
    if (image.empty() || image.type() != CV_8UC3 || intersection.width() <= 0) {
        result.status = DetailCropStatus::UnsupportedImage;
        return result;
    }

    const double unit = intersection.width();
    const double origin_x = intersection.left();
    const double origin_y = intersection.top();
    const auto toPixel = [](double value) { return static_cast<int>(std::lround(value)); };

    // Runs one landmark's probe columns and votes on the result. Stops as soon as two columns have failed,
    // since a majority is then out of reach -- that is the cheap exit taken on every frame with no dialog.
    const auto probeColumns = [&](const std::array<double, 3> &columns,
                                  int start_y,
                                  int span,
                                  const auto &start_pred,
                                  const auto &stop_pred,
                                  double &agreed) {
        std::vector<int> rows;
        bool any_started = false;
        size_t failures = 0;
        for (const double column : columns) {
            int found_y = 0;
            const auto outcome =
                scanDown(image, toPixel(origin_x + column * unit), start_y, span, start_pred, stop_pred, found_y);
            if (outcome == ScanOutcome::Found) {
                rows.push_back(found_y);
                any_started = true;
                continue;
            }
            any_started = any_started || outcome == ScanOutcome::NotFound;
            if (++failures >= 2) {
                break;
            }
        }
        return majorityVote(std::move(rows), any_started, agreed);
    };

    // --- (a) green header bar / canvas boundary ---
    double header_y = 0.0;
    switch (probeColumns(
        kHeaderColumnsX,
        toPixel(origin_y + kHeaderScanStartY * unit),
        toPixel(kHeaderScanSpanY * unit),
        [](const Bgr &pixel) { return isHeaderGreen(pixel); },
        [](const Bgr &pixel) { return !isHeaderGreen(pixel); },
        header_y)) {
        case VoteOutcome::NoStart: result.status = DetailCropStatus::HeaderStart; return result;
        case VoteOutcome::NoLandmark: result.status = DetailCropStatus::HeaderMissing; return result;
        case VoteOutcome::NoMajority: result.status = DetailCropStatus::HeaderSpread; return result;
        case VoteOutcome::Agreed: break;
    }

    // --- (b) close-button bottom edge ---
    double button_y = 0.0;
    switch (probeColumns(
        kButtonColumnsX,
        toPixel(origin_y + kButtonScanStartY * unit),
        toPixel(kButtonScanSpanY * unit),
        [](const Bgr &pixel) { return isButtonInterior(pixel); },
        [](const Bgr &pixel) { return isButtonBorder(pixel); },
        button_y)) {
        case VoteOutcome::NoStart: result.status = DetailCropStatus::ButtonStart; return result;
        case VoteOutcome::NoLandmark: result.status = DetailCropStatus::ButtonMissing; return result;
        case VoteOutcome::NoMajority: result.status = DetailCropStatus::ButtonSpread; return result;
        case VoteOutcome::Agreed: break;
    }

    // --- vertical solve: the two landmarks give both the scale and the vertical origin ---
    const double scale = (button_y - header_y) / (kButtonBoundaryY - kHeaderBoundaryY);
    if (!std::isfinite(scale) || scale <= 1.0) {
        result.status = DetailCropStatus::DegenerateScale;
        return result;
    }
    const double top = header_y - kHeaderBoundaryY * scale;

    // --- (c) 5-stat green band: horizontal centre only ---
    // The band rows are placed from the freshly solved (top, scale), not from the caller's intersection, so
    // a mis-anchored input frame does not drag the 24-row window off the band.
    const int band_top = toPixel(top + kBandRowTopY * scale);
    const int band_bottom = toPixel(top + kBandRowBottomY * scale);
    const int search_radius = std::max(1, toPixel(kBandSearchRadiusX * scale));
    // Clipped to the image, not rejected by it: when the dialog fills the frame exactly (the desktop case)
    // the left window would otherwise start at a negative column. Clipping keeps the crossing reachable, and
    // narrowing the window can only make the scan more conservative.
    const int left_from = std::max(0, toPixel(origin_x + kBandLeftX * scale) - search_radius);
    const int left_to = std::min(image.cols - 1, toPixel(origin_x + kBandLeftX * scale) + search_radius);
    const int right_from = std::max(0, toPixel(origin_x + kBandRightX * scale) - search_radius);
    const int right_to = std::min(image.cols - 1, toPixel(origin_x + kBandRightX * scale) + search_radius);
    if (band_top < 0 || band_bottom >= image.rows || band_bottom < band_top || left_from >= left_to
        || right_from >= right_to || left_to >= right_from) {
        result.status = DetailCropStatus::BandOutOfFrame;
        return result;
    }

    double left_edge = 0.0;
    if (!findBandEdge(image, left_from, left_to, band_top, band_bottom, true, left_edge)) {
        result.status = DetailCropStatus::BandLeftEdge;
        return result;
    }

    double right_edge = 0.0;
    if (!findBandEdge(image, right_from, right_to, band_top, band_bottom, false, right_edge)) {
        result.status = DetailCropStatus::BandRightEdge;
        return result;
    }

    // Sanity, not measurement: the band's width must agree with the one the vertical scale predicts.
    const double band_width_error = (right_edge - left_edge) - (kBandRightX - kBandLeftX) * scale;
    if (std::abs(band_width_error) > kBandWidthTolerance * scale) {
        result.status = DetailCropStatus::BandWidth;
        return result;
    }

    // --- reconstruct ---
    // The band contributes its CENTRE only; the scale stays the vertical one (see the header comment).
    const double left = (left_edge + right_edge) / 2.0 - kBandCentreX * scale;
    const double height = scale * kClientHeightPerWidth;

    result.status = DetailCropStatus::Ok;
    result.calibration = {left, top, scale, height};
    return result;
}

}  // namespace uma
