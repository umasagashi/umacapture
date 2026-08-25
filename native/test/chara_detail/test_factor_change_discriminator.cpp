// Property tests for the factor-tab character-switch discriminator
// (CharaDetailSceneScraper::factorChangeRatio / isFactorChanged in chara_detail_scene_scraper.cpp).
//
// Why these exist at all: the discriminator's only other cover is the golden integration suite, which compares
// *record sets*. Three of the five clips that must trigger a reset produce zero records both with the rule and
// with the rule deleted, so their signal (the reset count) is invisible to that format
// (.notes/analysis/android-web-import/cpp/fix1-golden-intent.md). These tests assert the discriminator's
// property directly instead, so a future change to it fails here rather than silently.
//
// The property, stated without re-encoding today's constants:
//   * a resampling / requantisation-like perturbation of the SAME content is not a character switch;
//   * a glyph replacement IS one;
//   * and both hold at two capture scales, because the decision is a ratio over the diffed region and must not
//     become a function of the frame size.
// A fourth case pins the anti-vacuity direction: the same resample perturbation is large enough that the
// historical per-pixel cut of 15 would have called it a switch. That is the defect this calibration fixed, and
// it is what makes the first assertion non-trivial.
//
// The synthetic material is a blurred, text-like list rather than a hard-edged bitmap on purpose. Anti-aliasing
// in a real capture spreads a glyph edge over ~1px whatever the capture resolution (the same argument the
// scraper config makes for keeping flush_tolerance_px in pixels), and a half-pixel resample round trip is
// exactly a [1 2 1]/4 blur along the shifted axis, i.e. a quarter of the local second derivative. On a hard
// step edge that second derivative is unbounded and the proxy would model no real capture chain; on an
// anti-aliased one it is the small, edge-local residue that codec re-quantisation actually produces. The blur
// radius is therefore held constant across the two frame sizes while the list geometry scales with them.

#include <doctest/doctest.h>

#include <algorithm>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "types/shape.h"

namespace uma::chara_detail {
namespace {

// The per-pixel cut this calibration replaced. Referenced only to assert that the perturbation below is not a
// no-op image: at 15 the discriminator misclassified it, which is why the cut moved.
constexpr int kHistoricalPixelDiffCut = 15;

// Edge softness of the synthetic render, in pixels, held constant across frame sizes (see the file comment).
constexpr double kAntiAliasSigma = 1.2;

constexpr int kBackground = 230;
constexpr int kInk = 40;

// The whole frame: an empty rect is "the whole frame" to the area metrics in Frame.
const Rect<double> kWholeFrame{};

// A text-like factor list: `rows` rows of glyph blocks over a light background, anti-aliased. `variant` selects
// which glyph slots are inked, so two variants are two different characters' lists at identical geometry.
cv::Mat factorList(int width, int height, int variant) {
    cv::Mat image(height, width, CV_8UC3, cv::Scalar(kBackground, kBackground, kBackground));
    const int rows = 24;
    const int row_h = height / (rows + 2);
    const int glyph_w = std::max(2, width / 40);
    const int glyph_h = std::max(2, row_h / 2);
    const int slots = 30;
    for (int r = 0; r < rows; r++) {
        const int y = row_h * (r + 1);
        for (int s = 0; s < slots; s++) {
            // A deterministic, variant-dependent inking pattern. Both variants ink roughly half the slots, so
            // the two lists have comparable ink density and differ in *which* glyphs are where.
            const int h = (r * 7919 + s * 104729 + variant * 15485863) % 97;
            if (h % 3 == 0) {
                continue;
            }
            const int x = 4 + s * (width - 8) / slots;
            cv::rectangle(
                image,
                cv::Rect(x, y, std::min(glyph_w, width - x - 1), glyph_h),
                cv::Scalar(kInk, kInk, kInk),
                cv::FILLED);
        }
    }
    cv::GaussianBlur(image, image, cv::Size(0, 0), kAntiAliasSigma, kAntiAliasSigma);
    return image;
}

// A half-pixel resample round trip along x: shift by +0.5px and back with bilinear interpolation. This is the
// documented proxy for the re-quantisation of already-rendered pixels that a video encoder produces.
cv::Mat halfPixelResampleRoundTrip(const cv::Mat &image) {
    cv::Mat forward;
    cv::Mat back;
    const cv::Mat right = (cv::Mat_<double>(2, 3) << 1, 0, 0.5, 0, 1, 0);
    const cv::Mat left = (cv::Mat_<double>(2, 3) << 1, 0, -0.5, 0, 1, 0);
    cv::warpAffine(image, forward, right, image.size(), cv::INTER_LINEAR, cv::BORDER_REPLICATE);
    cv::warpAffine(forward, back, left, image.size(), cv::INTER_LINEAR, cv::BORDER_REPLICATE);
    return back;
}

double ratioAt(const cv::Mat &current, const cv::Mat &reference, int cut) {
    return Frame::fixed(current).diffStats(Frame::fixed(reference), kWholeFrame, cut).ratio();
}

double productionRatio(const cv::Mat &current, const cv::Mat &reference) {
    return CharaDetailSceneScraper::factorChangeRatio(Frame::fixed(current), Frame::fixed(reference), kWholeFrame);
}

// The two capture scales. 736x1308 is the width every recorded switch event was captured at; the smaller one is
// on the downscale ladder the reject population was measured across.
struct Scale {
    int width;
    int height;
};
constexpr Scale kScales[] = {{404, 718}, {736, 1308}};

}  // namespace

TEST_CASE("a resample/requantisation perturbation of the same list is not a character switch") {
    for (const auto &scale : kScales) {
        CAPTURE(scale.width);
        const cv::Mat list = factorList(scale.width, scale.height, 0);
        const cv::Mat perturbed = halfPixelResampleRoundTrip(list);
        const double ratio = productionRatio(perturbed, list);
        CAPTURE(ratio);
        CHECK_FALSE(CharaDetailSceneScraper::isFactorChanged(ratio));
    }
}

TEST_CASE("a glyph replacement is a character switch, at every capture scale") {
    for (const auto &scale : kScales) {
        CAPTURE(scale.width);
        const cv::Mat list_a = factorList(scale.width, scale.height, 0);
        const cv::Mat list_b = factorList(scale.width, scale.height, 1);
        const double ratio = productionRatio(list_b, list_a);
        CAPTURE(ratio);
        CHECK(CharaDetailSceneScraper::isFactorChanged(ratio));
    }
}

TEST_CASE("the glyph replacement survives the per-pixel cut that extinguishes the resample perturbation") {
    // The shape of the calibration, in one assertion: raising the cut costs the accept side almost nothing and
    // costs the reject side everything. Stated as a comparison between the two populations rather than against
    // a magic number, so it still holds if the cut is re-tuned inside its usable band.
    for (const auto &scale : kScales) {
        CAPTURE(scale.width);
        const cv::Mat list_a = factorList(scale.width, scale.height, 0);
        const cv::Mat list_b = factorList(scale.width, scale.height, 1);
        const cv::Mat perturbed = halfPixelResampleRoundTrip(list_a);

        const double reject_low = ratioAt(perturbed, list_a, kHistoricalPixelDiffCut);
        const double reject_prod = productionRatio(perturbed, list_a);
        const double accept_low = ratioAt(list_b, list_a, kHistoricalPixelDiffCut);
        const double accept_prod = productionRatio(list_b, list_a);
        CAPTURE(reject_low);
        CAPTURE(reject_prod);
        CAPTURE(accept_low);
        CAPTURE(accept_prod);

        // Anti-vacuity: the perturbation is a real, broad change of the pixels -- at the historical cut of 15 it
        // was above the area bar, i.e. it was classified as a character switch. That was the defect.
        CHECK(reject_low > 0.005);
        CHECK(CharaDetailSceneScraper::isFactorChanged(reject_low));
        // The production cut extinguishes it, while the glyph replacement keeps most of its population.
        CHECK(reject_prod < reject_low / 10.0);
        CHECK(accept_prod > accept_low / 2.0);
        // And the separation runs the right way round: the switch is far above the perturbation.
        CHECK(accept_prod > reject_prod * 10.0);
    }
}

TEST_CASE("an identical frame is never a character switch") {
    const cv::Mat list = factorList(736, 1308, 0);
    const double ratio = productionRatio(list, list);
    CHECK(ratio == doctest::Approx(0.0));
    CHECK_FALSE(CharaDetailSceneScraper::isFactorChanged(ratio));
}

TEST_CASE("a whole-frame brightness drift below the per-pixel cut is not a character switch") {
    // Every pixel changes, so the area bar alone cannot reject this; only the per-pixel cut can. A capture
    // chain that shifts levels slightly (gamma, a different YUV matrix, an encoder's DC drift) must not read as
    // a new character.
    const cv::Mat list = factorList(736, 1308, 0);
    cv::Mat drifted;
    list.convertTo(drifted, CV_8UC3, 1.0, 10.0);  // +10 per channel => per-pixel BGR distance 30, under the cut
    const double at_low_cut = ratioAt(drifted, list, kHistoricalPixelDiffCut);
    const double ratio = productionRatio(drifted, list);
    CAPTURE(at_low_cut);
    CAPTURE(ratio);
    CHECK(at_low_cut > 0.9);  // the historical cut saw it as a full-frame change
    CHECK_FALSE(CharaDetailSceneScraper::isFactorChanged(ratio));
}

TEST_CASE("a small high-contrast change is rejected by the area bar, not by the per-pixel cut") {
    // The mouse-cursor / lazily-loaded-row floor: high contrast, so it survives any per-pixel cut, but it
    // covers far less of the region than a list replacement does. This is the constraint that keeps the area
    // bar where it is.
    const cv::Mat list = factorList(736, 1308, 0);
    cv::Mat spotted = list.clone();
    cv::rectangle(spotted, cv::Rect(100, 100, 24, 32), cv::Scalar(0, 0, 0), cv::FILLED);
    const double ratio = productionRatio(spotted, list);
    CAPTURE(ratio);
    CHECK(ratio > 0.0);  // it is above the per-pixel cut
    CHECK_FALSE(CharaDetailSceneScraper::isFactorChanged(ratio));
}

}  // namespace uma::chara_detail
