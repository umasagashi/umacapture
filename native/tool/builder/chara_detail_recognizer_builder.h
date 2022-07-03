#pragma once

#include "builder/builder_util.h"
#include "chara_detail/chara_detail_config.h"

namespace uma::tool {

using namespace uma::chara_detail::recognizer_config;

class CharaDetailRecognizerBuilder {
public:
    [[nodiscard]] CharaDetailRecognizerConfig build() const {
        return {
            statusHeader(),
            skillTab(),
            factorTab(),
            campaignTab(),
        };
    }

private:
    [[nodiscard]] std::string getModulePath(const std::string &key) const { return key + "/prediction.onnx"; }

    [[nodiscard]] StatusHeaderConfig statusHeader() const {
        return {
            {
                getModulePath("evaluation_value"),
                Rect<double>{{0.1389, 0.3722, IS}, {0.2556, 0.4000, IS}},
            },
            {
                getModulePath("status_value"),
                {
                    Rect<double>{{0.1074, 0.4833, IS}, {0.1944, 0.5111, IS}},
                    Rect<double>{{0.2926, 0.4833, IS}, {0.3796, 0.5111, IS}},
                    Rect<double>{{0.4778, 0.4833, IS}, {0.5648, 0.5111, IS}},
                    Rect<double>{{0.6630, 0.4833, IS}, {0.7500, 0.5111, IS}},
                    Rect<double>{{0.8481, 0.4833, IS}, {0.9352, 0.5111, IS}},
                },
            },
            {
                getModulePath("aptitude"),
                {
                    Rect<double>{{0.3407, 0.5648, IS}, {0.3685, 0.5926, IS}},
                    Rect<double>{{0.5241, 0.5648, IS}, {0.5519, 0.5926, IS}},

                    Rect<double>{{0.3407, 0.6204, IS}, {0.3685, 0.6481, IS}},
                    Rect<double>{{0.5241, 0.6204, IS}, {0.5519, 0.6481, IS}},
                    Rect<double>{{0.7074, 0.6204, IS}, {0.7352, 0.6481, IS}},
                    Rect<double>{{0.8907, 0.6204, IS}, {0.9185, 0.6481, IS}},

                    Rect<double>{{0.3407, 0.6759, IS}, {0.3685, 0.7037, IS}},
                    Rect<double>{{0.5241, 0.6759, IS}, {0.5519, 0.7037, IS}},
                    Rect<double>{{0.7074, 0.6759, IS}, {0.7352, 0.7037, IS}},
                    Rect<double>{{0.8907, 0.6759, IS}, {0.9185, 0.7037, IS}},
                },
            },
        };
    }

    [[nodiscard]] SkillTabConfig skillTab() const {
        const double top_offset = 0.8685 - 0.8444;
        const double bottom_offset = 0.8963 - 0.8444;
        const auto left_rect = Rect<double>{{0.1019, top_offset, {IS, SS}}, {0.4296, bottom_offset, {IS, SS}}};
        const auto right_rect = Rect<double>{{0.5667, top_offset, {IS, SS}}, {0.8944, bottom_offset, {IS, SS}}};
        return {
            getModulePath("skill"),
            Range<Color>{{235, 235, 235}, {255, 255, 255}},
            Rect<double>{{0.0000, 0.8278, IS}, {0.0, -0.2426, {IPE, ILE}}},
            left_rect,
            right_rect,
            0.9352 - 0.8444,
            0.0,
            0.9519 - 0.9148,
            {
                getModulePath("skill_level"),
                Rect<double>{{0.4537 - left_rect.left(), top_offset}, {0.4815 - left_rect.left(), bottom_offset}},
            },
        };
    }

    [[nodiscard]] FactorTabConfig factorTab() const {
        const double scan_top = 0.9111;
        const double top_offset = 0.9259 - scan_top;
        const double bottom_offset = 0.9537 - scan_top;
        const auto left_rect = Rect<double>{{0.2426, top_offset, {IS, SS}}, {0.5519, bottom_offset, {IS, SS}}};
        const auto right_rect = Rect<double>{{0.6259, top_offset, {IS, SS}}, {0.9352, bottom_offset, {IS, SS}}};
        return {
            getModulePath("factor"),
            Range<Color>{{235, 235, 235}, {255, 255, 255}},
            Rect<double>{{0.0000, 0.8278, IS}, {0.0, -0.2426, {IPE, ILE}}},
            left_rect,
            right_rect,
            0.9852 - 0.9111,
            0.9019 - 0.8278,
            0.9981 - 0.9852,
            1.3704 - 1.3111,
            {
                getModulePath("factor_rank"),
                Rect<double>{
                    {0.3315 - left_rect.left(), 0.9556 - scan_top, SS},
                    {0.4259 - left_rect.left(), 0.9833 - scan_top, SS}},
            },
            {
                {
                    getModulePath("character"),
                    Rect<double>{{0.0481, 0.9056 - scan_top, {IS, SS}}, {0.1852, 1.0426 - scan_top, {IS, SS}}},
                },
                {
                    getModulePath("character_rank"),
                    Rect<double>{{0.1333, 0.8963 - scan_top, {IS, SS}}, {0.1833, 0.9463 - scan_top, {IS, SS}}},
                },
            },
        };
    }

    [[nodiscard]] CampaignTabConfig campaignTab() const {
        return {
            {
                Rect<double>{{0.0000, 0.8278, IS}, {0.0, -0.2426, {IPE, ILE}}},
                Range<Color>{{218, 218, 218}, {248, 248, 248}},
            },
            supportCards(),
            familyTree(),
            campaignRecord(),
            races(),
        };
    }

    [[nodiscard]] SupportCardConfig supportCards() const {
        const double scan_top = 0.8685;

        const double icon_top = 0.8944 - scan_top;
        const double icon_bottom = 0.9889 - scan_top;

        const double label_top = 1.0204 - scan_top;
        const double label_top_friend = 0.9963 - scan_top;
        const double label_bottom = 1.0389 - scan_top;
        const double label_bottom_friend = 1.0148 - scan_top;

        return {
            getModulePath("support_card"),
            Point<double>{0.3148, 0.0000, {IS, SS}},
            {
                Rect<double>{{0.0685, icon_top, {IS, SS}}, {0.1630, icon_bottom, {IS, SS}}},
                Rect<double>{{0.2222, icon_top, {IS, SS}}, {0.3167, icon_bottom, {IS, SS}}},
                Rect<double>{{0.3741, icon_top, {IS, SS}}, {0.4685, icon_bottom, {IS, SS}}},
                Rect<double>{{0.5278, icon_top, {IS, SS}}, {0.6222, icon_bottom, {IS, SS}}},
                Rect<double>{{0.6815, icon_top, {IS, SS}}, {0.7759, icon_bottom, {IS, SS}}},
                Rect<double>{{0.8352, icon_top, {IS, SS}}, {0.9296, icon_bottom, {IS, SS}}},
            },
            {
                getModulePath("support_card_level"),
                {
                    Rect<double>{{0.1463, label_top, {IS, SS}}, {0.1741, label_bottom, {IS, SS}}},
                    Rect<double>{{0.3000, label_top, {IS, SS}}, {0.3278, label_bottom, {IS, SS}}},
                    Rect<double>{{0.4537, label_top, {IS, SS}}, {0.4815, label_bottom, {IS, SS}}},
                    Rect<double>{{0.6074, label_top, {IS, SS}}, {0.6352, label_bottom, {IS, SS}}},
                    Rect<double>{{0.7593, label_top, {IS, SS}}, {0.7870, label_bottom, {IS, SS}}},
                    Rect<double>{{0.9130, label_top_friend, {IS, SS}}, {0.9407, label_bottom_friend, {IS, SS}}},
                },
            },
            {
                getModulePath("support_card_rank"),
                {
                    Rect<double>{{0.0556, label_top, {IS, SS}}, {0.1167, label_bottom, {IS, SS}}},
                    Rect<double>{{0.2093, label_top, {IS, SS}}, {0.2704, label_bottom, {IS, SS}}},
                    Rect<double>{{0.3630, label_top, {IS, SS}}, {0.4241, label_bottom, {IS, SS}}},
                    Rect<double>{{0.5148, label_top, {IS, SS}}, {0.5759, label_bottom, {IS, SS}}},
                    Rect<double>{{0.6685, label_top, {IS, SS}}, {0.7296, label_bottom, {IS, SS}}},
                    Rect<double>{{0.8222, label_top_friend, {IS, SS}}, {0.8833, label_bottom_friend, {IS, SS}}},
                },
            },
            1.0667 - 0.8685,
        };
    }

    [[nodiscard]] FamilyTreeConfig familyTree() const {
        const double scan_top = 1.1130;

        const double parent_top = 1.2167 - scan_top;
        const double parent_bottom = 1.3852 - scan_top;

        const double grand_upper_top = 1.1500 - scan_top;
        const double grand_upper_bottom = 1.2648 - scan_top;

        const double grand_lower_top = 1.3074 - scan_top;
        const double grand_lower_bottom = 1.4222 - scan_top;

        const double parent_rank_top = 1.2000 - scan_top;
        const double parent_rank_bottom = 1.2685 - scan_top;

        const double grand_upper_rank_top = 1.1370 - scan_top;
        const double grand_upper_rank_bottom = 1.1815 - scan_top;

        const double grand_lower_rank_top = 1.2944 - scan_top;
        const double grand_lower_rank_bottom = 1.3389 - scan_top;

        return {
            getModulePath("character"),
            Point<double>{0.3148, 0.0000, {IS, SS}},
            {
                Rect<double>{{0.0852, parent_top, {IS, SS}}, {0.2537, parent_bottom, {IS, SS}}},
                Rect<double>{{0.3389, grand_upper_top, {IS, SS}}, {0.4537, grand_upper_bottom, {IS, SS}}},
                Rect<double>{{0.3389, grand_lower_top, {IS, SS}}, {0.4537, grand_lower_bottom, {IS, SS}}},
            },
            {
                Rect<double>{{0.5426, parent_top, {IS, SS}}, {0.7111, parent_bottom, {IS, SS}}},
                Rect<double>{{0.7963, grand_upper_top, {IS, SS}}, {0.9111, grand_upper_bottom, {IS, SS}}},
                Rect<double>{{0.7963, grand_lower_top, {IS, SS}}, {0.9111, grand_lower_bottom, {IS, SS}}},
            },
            {
                getModulePath("character_rank"),
                {
                    Rect<double>{{0.1889, parent_rank_top, {IS, SS}}, {0.2574, parent_rank_bottom, {IS, SS}}},
                    Rect<double>{{0.4111, grand_upper_rank_top, {IS, SS}}, {0.4556, grand_upper_rank_bottom, {IS, SS}}},
                    Rect<double>{{0.4111, grand_lower_rank_top, {IS, SS}}, {0.4556, grand_lower_rank_bottom, {IS, SS}}},
                },
                {
                    Rect<double>{{0.6481, parent_rank_top, {IS, SS}}, {0.7167, parent_rank_bottom, {IS, SS}}},
                    Rect<double>{{0.8685, grand_upper_rank_top, {IS, SS}}, {0.9130, grand_upper_rank_bottom, {IS, SS}}},
                    Rect<double>{{0.8685, grand_lower_rank_top, {IS, SS}}, {0.9130, grand_lower_rank_bottom, {IS, SS}}},
                },
            },
            1.4667 - 1.1130,
        };
    }

    [[nodiscard]] CampaignRecordConfig campaignRecord() const {
        return {
            Point<double>{0.2537, 0.0000, {IS, SS}},
            1.0037 - 0.9593,
            {
                getModulePath("fans_value"),
                Rect<double>{{0.2926, 1.0167 - 1.0167, {IS, SS}}, {0.5278, 1.0444 - 1.0167, {IS, SS}}},
            },
            {
                getModulePath("scenario"),
                Rect<double>{{0.2926, 1.1296 - 1.1296, {IS, SS}}, {0.7648, 1.1574 - 1.1296, {IS, SS}}},
            },
            {
                getModulePath("trained_date"),
                Rect<double>{{0.2926, 1.2778 - 1.2778, {IS, SS}}, {0.5537, 1.3056 - 1.2778, {IS, SS}}},
            },
            1.3370 - 1.2778,
        };
    }

    [[nodiscard]] RaceConfig races() const {
        const double scan_top = 0.9259;
        return {
            Point<double>{0.2074, 0.0000, {IS, SS}},
            1.1000 - 0.9259,
            {
                getModulePath("race_title"),
                Rect<double>{{0.1574, 0.9352 - scan_top, {IS, SS}}, {0.7481, 0.9648 - scan_top, {IS, SS}}},
            },
            {
                getModulePath("race_place"),
                Rect<double>{{0.0685, 0.9981 - scan_top, {IS, SS}}, {0.5852, 1.0259 - scan_top, {IS, SS}}},
            },
            {
                getModulePath("race_turn"),
                Rect<double>{{0.4463, 1.0389 - scan_top, {IS, SS}}, {0.7815, 1.0667 - scan_top, {IS, SS}}},
            },
            {
                getModulePath("race_position"),
                Rect<double>{{0.7944, 0.9333 - scan_top, {IS, SS}}, {0.9259, 1.0648 - scan_top, {IS, SS}}},
            },
            {
                getModulePath("race_strategy"),
                Rect<double>{{0.1833, 1.0389 - scan_top, {IS, SS}}, {0.2407, 1.0667 - scan_top, {IS, SS}}},
            },
            {
                getModulePath("race_weather"),
                Rect<double>{{0.5907, 1.0000 - scan_top, {IS, SS}}, {0.6926, 1.0278 - scan_top, {IS, SS}}},
            },
        };
    }
};

}  // namespace uma::tool
