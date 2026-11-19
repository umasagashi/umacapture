#pragma once

#include <optional>
#include <string>
#include <vector>

#include "cv/frame.h"
#include "util/json_util.h"

namespace uma::chara_detail {

// The resize facts of one scraped record, handed from the scene scraper to the stitcher as a file in the record's
// scraping directory (kScrapedFrameResizeFilename, beside base.png). The stitcher splits it into one
// TabFrameResize per tab image. A scraping directory without the file (one assembled by hand, or a write that
// failed) yields tab images without `frame_resize`.
inline const std::string kScrapedFrameResizeFilename = "frame_resize.json";  // NOLINT(cert-err58-cpp)

struct ScrapedFrameResize {
    std::optional<ForwardedFrameResize> base;
    std::vector<ForwardedFrameResizeCount> skill;
    std::vector<ForwardedFrameResizeCount> factor;
    std::vector<ForwardedFrameResizeCount> campaign;
};

inline void to_json(json_util::Json &json, const ScrapedFrameResize &scraped) {
    json = json_util::Json::object();
    json["base"] = scraped.base.has_value() ? json_util::Json(scraped.base.value()) : json_util::Json(nullptr);
    json["skill"] = scraped.skill;
    json["factor"] = scraped.factor;
    json["campaign"] = scraped.campaign;
}

inline void from_json(const json_util::Json &json, ScrapedFrameResize &scraped) {
    scraped.base = json.at("base").get<std::optional<ForwardedFrameResize>>();
    scraped.skill = json.at("skill").get<std::vector<ForwardedFrameResizeCount>>();
    scraped.factor = json.at("factor").get<std::vector<ForwardedFrameResizeCount>>();
    scraped.campaign = json.at("campaign").get<std::vector<ForwardedFrameResizeCount>>();
}

}  // namespace uma::chara_detail
