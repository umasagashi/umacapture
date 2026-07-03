// Characterization tests for the scraping-box directory lifecycle.
//
// These lock the behavior that was previously coupled to the app::NativeApi singleton: the scraping
// boxes create (and, on reset, remove-then-recreate) their per-tab image directories. Directory
// operations are now injected as io_util::DirectoryHooks, so these tests drive them with fakes that
// record the requested paths instead of touching the real filesystem. This exercises the pipeline
// units that link only OpenCV (no ONNX / WinRT / singleton), per the harness scope in test/README.md.

#include <doctest/doctest.h>

#include <filesystem>
#include <vector>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "util/misc.h"

namespace uma::chara_detail {
namespace {

// Records the paths passed to the injected directory hooks, without touching the filesystem.
struct HookRecorder {
    std::vector<std::filesystem::path> made;
    std::vector<std::filesystem::path> removed;

    [[nodiscard]] io_util::DirectoryHooks hooks() {
        io_util::DirectoryHooks h;
        h.mkdir = [this](const std::filesystem::path &path) { made.push_back(path); };
        h.rmdir = [this](const std::filesystem::path &path) { removed.push_back(path); };
        return h;
    }
};

TEST_CASE("PageScrapingBox creates its image directory via the injected hook") {
    HookRecorder recorder;
    const std::filesystem::path dir = "unit_test_page_box";

    scraper_impl::PageScrapingBox box({}, dir, recorder.hooks());

    CHECK(recorder.made.size() == 1);
    CHECK(recorder.made.front() == dir);
    CHECK(recorder.removed.empty());
}

TEST_CASE("SceneScrapingBox creates one directory per tab") {
    HookRecorder recorder;
    const std::filesystem::path root = "unit_test_scene_box";

    scraper_impl::SceneScrapingBox box({}, {}, {}, record::RecordType::Standard, root, recorder.hooks());

    CHECK(recorder.made.size() == 3);
    CHECK(recorder.made[0] == root / path_config.skill.stem());
    CHECK(recorder.made[1] == root / path_config.factor.stem());
    CHECK(recorder.made[2] == root / path_config.campaign.stem());
    CHECK(recorder.removed.empty());
}

TEST_CASE("SceneScrapingBox::resetFactorBox removes then recreates only the factor tab dir") {
    HookRecorder recorder;
    const std::filesystem::path root = "unit_test_scene_box";
    const std::filesystem::path factor_dir = root / path_config.factor.stem();

    scraper_impl::SceneScrapingBox box({}, {}, {}, record::RecordType::Standard, root, recorder.hooks());
    recorder.made.clear();

    box.resetFactorBox();

    // The stale directory is cleared (so the fresh box numbers its fragments from zero again) and then
    // recreated -- both through the injected hooks, targeting only the factor tab.
    CHECK(recorder.removed.size() == 1);
    CHECK(recorder.removed.front() == factor_dir);
    CHECK(recorder.made.size() == 1);
    CHECK(recorder.made.front() == factor_dir);
}

}  // namespace
}  // namespace uma::chara_detail
