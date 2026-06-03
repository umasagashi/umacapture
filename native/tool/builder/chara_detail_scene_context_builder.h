#pragma once

#include "builder/builder_util.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/cv_rule.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "util/json_util.h"

namespace uma::tool {

class CharaDetailSceneContextBuilder {
public:
    [[nodiscard]] ConditionBase build() const {
        return allOf({
            titleBar(),
            closeButton(),
            tabBarButtons(),
            tabBarBorders(),
            recordTypes(),
        });
    }

private:
    [[nodiscard]] ConditionBase titleBar() const {
        const double y = 0.0870;
        return allOf({
            lineCheck(lineToX({0.0167, y, IS}, 0.0259), colorRange({100, 186, 0}, 30), full_length),
            lineCheck(lineToX({0.9830, y, IS}, 0.9738), colorRange({126, 204, 10}, 30), full_length),
        });
    }

    [[nodiscard]] ConditionBase closeButton() const {
        return stableLineCheck(
            50, lineToY({-0.6501, -0.2148, ILE}, -0.1870), colorRange({250, 251, 250}, 30), {0.75, 1.0});
    }

    [[nodiscard]] ConditionBase tabBarButtons() const {
        return anyOf(
            {
                tabPageSelected(0),  // SkillPage
                tabPageSelected(1),  // FactorPage
                tabPageSelected(2),  // CampaignPage
            },
            "tab_page");
    }

    // The tab at `selected` (0/1/2 = left/middle/right) is highlighted while the other two
    // are not, matched in either the Standard or the Friend layout — the bar sits at a
    // different Y in each because the Friend "register" button pushes it down.
    [[nodiscard]] ConditionBase tabPageSelected(int selected) const {
        return anyOf({
            tabBarAt(standard_tab_bar_y, selected),
            tabBarAt(friend_tab_bar_y, selected),
        });
    }

    [[nodiscard]] ConditionBase tabBarAt(double y, int selected) const {
        const auto selected_color = colorRange({165, 223, 5}, 30);
        const auto not_selected_color = colorRange({255, 255, 255}, 30);
        return allOf({
            leftTabButton(y, selected == 0 ? selected_color : not_selected_color),
            middleTabButton(y, selected == 1 ? selected_color : not_selected_color),
            rightTabButton(y, selected == 2 ? selected_color : not_selected_color),
        });
    }

    [[nodiscard]] ConditionBase tabButton(
        const Point<double> &left,
        double left_end,
        const Point<double> &right,
        double right_end,
        const Range<Color> &color_range) const {
        return anyOf({
            lineCheck(lineToX(left, left_end), color_range, full_length),
            lineCheck(lineToX(right, right_end), color_range, full_length),
        });
    }

    // Tab bar Y for the Standard / InheritanceOnly layout.
    const double standard_tab_bar_y = 0.7463;
    // Tab bar Y for the Friend layout: the green "練習パートナー登録" button between the
    // aptitudes and the tab bar pushes the bar down (pinned to friend.png row 682 of the
    // 736 px wide intersection).
    const double friend_tab_bar_y = 682.0 / 736.0;

    [[nodiscard]] ConditionBase leftTabButton(double y, const Range<Color> &color_range) const {
        return tabButton({0.0555, y, IS}, 0.0833, {0.3314, y, IS}, 0.3036, color_range);
    }

    [[nodiscard]] ConditionBase middleTabButton(double y, const Range<Color> &color_range) const {
        return tabButton({0.3499, y, IS}, 0.3777, {0.6479, y, IS}, 0.6202, color_range);
    }

    [[nodiscard]] ConditionBase rightTabButton(double y, const Range<Color> &color_range) const {
        return tabButton({0.6664, y, IS}, 0.6942, {0.9460, y, IS}, 0.9182, color_range);
    }

    [[nodiscard]] ConditionBase tabBarBorders() const {
        // There are two borders, but one may be hidden by the tap effect, so if the other is visible, consider it good.
        // Accept either layout (Standard or Friend tab bar Y).
        return anyOf({
            tabBorder({{0.3129, standard_tab_bar_y, IS}, {0.3684, standard_tab_bar_y, IS}}),
            tabBorder({{0.6294, standard_tab_bar_y, IS}, {0.6850, standard_tab_bar_y, IS}}),
            tabBorder({{0.3129, friend_tab_bar_y, IS}, {0.3684, friend_tab_bar_y, IS}}),
            tabBorder({{0.6294, friend_tab_bar_y, IS}, {0.6850, friend_tab_bar_y, IS}}),
        });
    }

    [[nodiscard]] ConditionBase tabBorder(const Line<double> &cross_line) const {
        // Since the colors have already been checked in tabBarButtons, only the border will be checked here.
        return allOf({
            lineLength(cross_line, half_length),
            lineLength(cross_line.reversed(), half_length),
        });
    }

    // RecordType is two independent axes: the friend layout (a friend's hall of fame adds
    // the green "register practice partner" button) and the inheritance-only content signal
    // (a mid-screen white gap where a full training record shows data). The four branches
    // below are the mutually exclusive combinations, so their order within recordTypes()
    // only has to follow the enum, not rely on fall-through.

    [[nodiscard]] ConditionBase standardRecordType() const {
        // Own, full training record: neither axis is set.
        return allOf({logicalNot(friendLayout()), logicalNot(inheritanceSignal())});
    }

    [[nodiscard]] ConditionBase inheritanceOnlyRecordType() const {
        // Own, inheritance-only record.
        return allOf({logicalNot(friendLayout()), inheritanceSignal()});
    }

    [[nodiscard]] ConditionBase friendStandardRecordType() const {
        // A friend's full training record.
        return allOf({friendLayout(), logicalNot(inheritanceSignal())});
    }

    [[nodiscard]] ConditionBase friendInheritanceRecordType() const {
        // A friend's inheritance-only record. The only friend signal we have is the green
        // "register practice partner" button, which is absent on a friend's inheritance-only
        // screen, so this branch does not fire yet and such screens fall through to
        // InheritanceOnly above. Telling the two inheritance-only cases apart needs an extra
        // signal (TODO: add a friend-inheritance marker).
        return allOf({friendLayout(), inheritanceSignal()});
    }

    // Mid-screen white gap present only on inheritance-only records (the trained-data block
    // is absent), independent of the owner.
    [[nodiscard]] ConditionBase inheritanceSignal() const {
        return anyOf({
            lineCheck(lineToX({0.0500, 0.4981, IS}, 0.0963), colorRange({255, 255, 255}, 5), full_length),
            lineCheck(lineToX({0.8000, 0.4981, IS}, 0.8444), colorRange({255, 255, 255}, 5), full_length),
        });
    }

    [[nodiscard]] ConditionBase friendLayout() const {
        // A friend's hall-of-fame screen shows a green "練習パートナー登録" (register as practice
        // partner) button between the aptitudes and the tab bar. That button both identifies
        // the friend layout and pushes the tab bar down, so detect both: the button itself
        // and the tab bar at the Friend Y.
        return allOf({
            friendRegisterButton(),
            friendTabBar(),
        });
    }

    [[nodiscard]] ConditionBase friendTabBar() const {
        // Any one of the three tabs is highlighted at the Friend tab bar Y.
        return anyOf({
            tabBarAt(friend_tab_bar_y, 0),
            tabBarAt(friend_tab_bar_y, 1),
            tabBarAt(friend_tab_bar_y, 2),
        });
    }

    [[nodiscard]] ConditionBase friendRegisterButton() const {
        const double y = 620.0 / 736.0;  // button body row in friend.png
        const auto button_green = colorRange({110, 195, 10}, 50);
        const auto background = colorRange({250, 250, 250}, 12);
        return allOf({
            // Green button fill near the center.
            lineCheck(lineToX({0.4000, y, IS}, 0.4500), button_green, full_length),
            // The button is centered and does not reach the edges, so the left margin is
            // plain card background. (A Standard screen's full-width scroll column header
            // sits at a similar Y but would be green here — this check rejects it.)
            lineCheck(lineToX({0.1200, y, IS}, 0.1700), background, full_length),
        });
    }

    [[nodiscard]] ConditionBase recordTypes() const {
        // The following only determines which type fits, assuming all other conditions are met.
        // Branch order must match the RecordType enum: the active record_type is the index of
        // the first matching branch.
        return anyOf(
            {
                standardRecordType(),           // 0: Standard
                inheritanceOnlyRecordType(),    // 1: InheritanceOnly
                friendStandardRecordType(),     // 2: FriendStandard
                friendInheritanceRecordType(),  // 3: FriendInheritance
            },
            "record_type");
    }
};

}  // namespace uma::tool
