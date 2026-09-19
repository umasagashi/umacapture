#pragma once

#include "builder/builder_util.h"

namespace uma::tool {

// THE SCROLL AREA OF THE STANDARD RECORD LAYOUT, WHICH IS ALSO WHERE A STITCHED IMAGE CARRIES ITS SCROLL AREA.
//
// One rect, read by every builder that places or reads the scroll area of the detail screen's tabs:
// - scene_scraper.json's common layout crops the live scroll area with it (friend_common derives its own from it);
// - scene_stitcher.json pastes the stitched strip at it (scroll_area_rect), and fills the stain just above it
//   (scroll_area_upper_fill_rect ends at its top edge, so the fill never reaches the strip's first row);
// - recognizer.json's skill, factor and campaign tabs read the stitched image from it (area).
//
// They have to be the same rect, not three equal literals: the recognizer finds the factor tab's banner by
// scanning down from `area`'s top edge on the stitched image, and the scraper decides the tab is at its head from
// the banner's row below the live scroll area's top edge. The two rows are the same row only while the stitcher
// pastes the strip exactly where the recognizer starts reading. A top edge moved in one builder and not the
// others shifts every stitched banner by the difference, silently: the recognizer tolerates the shift until the
// banner leaves its search window. test_config.cpp checks the shipped files against each other, and
// test_scene_stitcher.cpp checks that the banner's row survives stitching.
inline const Rect<double> standard_scroll_area_rect = {{0.0000, 0.8093, IS}, {0.0000, -0.2426, {IPE, ILE}}};

}  // namespace uma::tool
