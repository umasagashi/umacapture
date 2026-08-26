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

namespace cd = uma::chara_detail;
namespace rec = uma::chara_detail::record;

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
            50,
            lineToY({-0.6501, -0.2148, ILE}, -0.1870),
            colorRange({250, 251, 250}, 30),
            {0.75, 1.0});
    }

    [[nodiscard]] ConditionBase tabBarButtons() const {
        return anyOf(
            {
                tabPageSelected(cd::SkillPage),
                tabPageSelected(cd::FactorPage),
                tabPageSelected(cd::CampaignPage),
            },
            "tab_page");
    }

    // The given tab (left/middle/right) is highlighted while the other two are not, matched in either
    // the Standard or the Friend layout — the bar sits at a different Y in each because the Friend
    // "register" button pushes it down. Named by tabPageTag so the scene context resolves the active
    // tab by name, not by branch position.
    [[nodiscard]] ConditionBase tabPageSelected(cd::TabPage page) const {
        return anyOf(
            {
                tabBarAt(standard_tab_bar_y, page),
                tabBarAt(friend_tab_bar_y, page),
            },
            cd::tabPageTag(page));
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

    // RecordType is two axes: the friend layout (a friend's hall of fame adds the green "register
    // practice partner" button) and the inheritance-only content signal (a mid-screen white gap where
    // a full training record shows data). Each branch is named with record::recordTypeTag, and the
    // scene context resolves the active type by looking that name up and testing met() — never by branch
    // position — so reordering the list here cannot silently remap a type.
    //
    // The branches are NOT all structurally exclusive: InheritanceOnly and FriendInheritance share the
    // (not friendLayout) and (inheritanceSignal) prefix and differ only by which owner marker is present
    // (the player's edit button vs the friend's "トレーナー" pill). Those two markers never appear
    // together in practice, but the boolean logic does not enforce it; if both were ever seen at once,
    // the scene context's first-match-in-enum-order resolution is the tie-breaker (InheritanceOnly wins,
    // and a Debug assert fires). So the enum VALUE order in chara_detail_record.h is load-bearing here.

    [[nodiscard]] ConditionBase standardRecordType() const {
        // Own, full training record: neither axis is set.
        return allOf({logicalNot(friendLayout()), logicalNot(inheritanceSignal())}, rec::recordTypeTag(rec::Standard));
    }

    [[nodiscard]] ConditionBase inheritanceOnlyRecordType() const {
        // Own, inheritance-only record. It shares the standard (unshifted) layout with a friend's
        // inheritance-only record; the two are told apart by which owner-specific marker is
        // present — here, the player's own edit button. Each inheritance branch keys off its own
        // positive marker, so when neither is visible yet (e.g. a tap effect right after opening)
        // no inheritance branch matches and the scene waits to begin rather than guessing. A
        // briefly hidden edit button therefore no longer mislabels the record as a friend's.
        return allOf(
            {logicalNot(friendLayout()), inheritanceSignal(), playerEditButton()},
            rec::recordTypeTag(rec::InheritanceOnly));
    }

    [[nodiscard]] ConditionBase friendStandardRecordType() const {
        // A friend's full training record.
        return allOf({friendLayout(), logicalNot(inheritanceSignal())}, rec::recordTypeTag(rec::FriendStandard));
    }

    [[nodiscard]] ConditionBase friendInheritanceRecordType() const {
        // A friend's inheritance-only record. It has no "register practice partner" button (so the
        // layout is not shifted and friendLayout() is false) and no player edit button. It is
        // identified positively by the friend "トレーナー" pill (friendInheritanceSignal()), which
        // the player's own record never shows. Keying off this positive signal — rather than the
        // mere absence of the edit button — stops a player's record from being mislabeled a
        // friend's while the edit button is briefly occluded.
        return allOf(
            {logicalNot(friendLayout()), inheritanceSignal(), friendInheritanceSignal()},
            rec::recordTypeTag(rec::FriendInheritance));
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
        // the friend layout and pushes the tab bar down, so detect both: the wide card-background
        // margins flanking the centered button, and the tab bar at the Friend Y.
        return allOf({
            friendRegisterMargins(),
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

    // The centered "練習パートナー登録" button leaves a tall band of plain card background on
    // each side of it. We detect that whitespace instead of the button's green fill: a similar
    // green appears elsewhere on the screen and is fiddly to tune, whereas the flanking margins
    // are a clean, uniform signal. A vertical scan line down each margin must stay within the
    // card background color for its full length. Either side alone is enough (OR), so a tap
    // effect covering one side still confirms the layout. On a Standard / inheritance-only record
    // the tab bar sits higher and full-width list content fills this Y, so neither scan line
    // stays uniform there.
    [[nodiscard]] ConditionBase friendRegisterMargins() const {
        return anyOf({
            backgroundColumn(164.0 / 736.0),  // left of the button
            backgroundColumn(563.0 / 736.0),  // right of the button
        });
    }

    [[nodiscard]] ConditionBase backgroundColumn(double x) const {
        const auto background = colorRange({250, 250, 250}, 12);
        return lineCheck(lineToY({x, 557.0 / 736.0, IS}, 648.0 / 736.0), background, full_length);
    }

    [[nodiscard]] ConditionBase playerEditButton() const {
        // The player's own hall-of-fame records show a round white "edit" button with a brown
        // pencil at the top-right of the header (you can edit your own entry); a friend's record
        // has none, leaving the plain cream card background there instead. Pinned to
        // player_inheritance.png (736 px wide): the pencil body runs diagonally from its tip
        // (lower-left) to the eraser (upper-right), and the circle around it is pure white. We
        // check a brown line along the pencil body and a parallel white line in the gap beside
        // it; the friend's uniform cream matches neither, so both checks together reject it.
        const auto pencil_brown = colorRange({150, 90, 40}, 55);
        const auto circle_white = colorRange({255, 255, 255}, 8);
        const Range<Color> along_pencil = {Color(-45), Color(45)};  // the pencil body is shaded
        return allOf({
            lineCheck(
                {{682.0 / 736.0, 272.0 / 736.0, IS}, {692.0 / 736.0, 262.0 / 736.0, IS}},
                pencil_brown,
                {0.7, 1.0},
                along_pencil),
            lineCheck(
                {{674.0 / 736.0, 265.0 / 736.0, IS}, {686.0 / 736.0, 253.0 / 736.0, IS}},
                circle_white,
                full_length),
        });
    }

    [[nodiscard]] ConditionBase friendInheritanceSignal() const {
        // A friend's hall-of-fame inheritance record shows a "トレーナー" pill in the header — a
        // cream rounded label with brown text — where the player's own record shows the character
        // art instead. Detect both the pill's cream background and its brown label text: the cream
        // check rejects the varied character-art backgrounds (some of which can hold brown-ish
        // pixels), and the brown check confirms the label. (Pinned to the label row y = 281 on a
        // 736 px wide frame.) A friend's FULL record shows the same pill, but that is FriendStandard
        // via friendLayout() and never reaches the inheritance branches, so it is irrelevant here.
        const auto cream = colorRange({235, 228, 222}, 30);
        const auto brown = colorRange({150, 90, 40}, 55);
        const double y = 281.0 / 736.0;
        return allOf({
            // The pill's cream background, in the margin between the rounded edge and the text.
            // Kept clear of the text's left edge so a slight horizontal shift of the label does not
            // let a character stroke break this uniform run.
            lineCheck(lineToX({260.0 / 736.0, y, IS}, 280.0 / 736.0), cream, full_length, {Color(-20), Color(20)}),
            // The brown label text just past the cream margin (lineColor = any pixel on the line).
            // It starts where the cream scan ends and stays short: the first character sits right
            // there, so a short line catches it while tolerating the text's slight horizontal shift,
            // and a longer line would risk picking up brown-ish pixels elsewhere in the background.
            lineColor(lineToX({280.0 / 736.0, y, IS}, 300.0 / 736.0), brown),
        });
    }

    [[nodiscard]] ConditionBase recordTypes() const {
        // Determines which record type fits, assuming all other conditions are met. The active type is
        // resolved by the scene context by branch NAME (record::recordTypeTag), so the order of this list
        // does not affect the mapping. The listing still follows the enum for readability; the enum VALUE
        // order is the tie-breaker for the overlapping inheritance branches (see the note above).
        return anyOf(
            {
                standardRecordType(),
                inheritanceOnlyRecordType(),
                friendStandardRecordType(),
                friendInheritanceRecordType(),
            },
            "record_type");
    }
};

}  // namespace uma::tool
