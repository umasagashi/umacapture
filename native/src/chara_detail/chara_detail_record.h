#pragma once

#include <array>
#include <optional>
#include <string>
#include <vector>

#include "util/json_util.h"
#include "util/stds.h"

namespace uma::chara_detail::record {

// The integer VALUE of each entry is a cross-layer contract — do not reorder or renumber it:
//   - the wire event sends static_cast<int>(record_type), and Dart reads it as RecordType.values[int];
//   - the Dart enum, its column labels, and saved column specs all map by this index;
//   - record.json stores the NAME (see EXTENDED_JSON_TYPE_ENUM below), which is order-independent.
// The scene context resolves which type is active by branch NAME, not position (see recordTypeTag and
// CharaDetailSceneContext), so reordering the condition branches cannot silently change the mapping;
// only this enum's value order is load-bearing, and it is pinned by the contract above.
enum RecordType {
    Standard = 0,
    InheritanceOnly = 1,
    FriendStandard = 2,
    FriendInheritance = 3,
};
EXTENDED_JSON_TYPE_ENUM(RecordType, Standard, InheritanceOnly, FriendStandard, FriendInheritance)

// Stable tag for each record-type branch in the scene-context condition tree. The builder names each
// branch with this tag and the scene context resolves the active type by looking the tag up and
// testing met(), so both sides MUST derive the name from this one function. The switch has no default
// on purpose: /we4062 (see native/CMakeLists.txt) promotes "enumerator not handled" to a compile
// error, so adding a RecordType that forgets a case here fails the build.
[[nodiscard]] inline std::string recordTypeTag(RecordType type) {
    switch (type) {
        case Standard: return "record_type.Standard";
        case InheritanceOnly: return "record_type.InheritanceOnly";
        case FriendStandard: return "record_type.FriendStandard";
        case FriendInheritance: return "record_type.FriendInheritance";
    }
    return "";  // out-of-range fallback; also silences C4715 (not all paths return a value)
}

// All record types in enum-value order. The order is the documented tie-breaker when overlapping
// branches could both match (see CharaDetailSceneContext::firstMet).
inline constexpr std::array<RecordType, 4> kAllRecordTypes{
    Standard,
    InheritanceOnly,
    FriendStandard,
    FriendInheritance,
};

// RecordType encodes two independent axes. The content axis (full training record vs
// inheritance-only) decides which data exists to recognize. The owner axis (own vs a friend's
// hall of fame) decides how the record is labelled. Note these axes are independent of the
// scrape layout: only a friend's FULL record shows the "register practice partner" button that
// shifts the tab bar and scroll area down, so the shifted coordinates apply to FriendStandard
// alone (see the scraper), not to every friend record. These predicates let downstream code
// test one axis without enumerating every combination.
[[nodiscard]] inline bool isInheritanceOnly(RecordType type) {
    return type == InheritanceOnly || type == FriendInheritance;
}

[[nodiscard]] inline bool isFriend(RecordType type) {
    return type == FriendStandard || type == FriendInheritance;
}

// Sentinel trainer_id for records whose owner is unknown. A friend's record captured from the
// player's own game exposes no recoverable trainer id (only externally shared/imported friend
// records carry the friend's real id), so it is stored with this nil UUID rather than the
// capturing player's id, which would otherwise misattribute the record's ownership. Mirrored by
// unknownTrainerId on the Dart side.
inline const std::string kUnknownTrainerId = "00000000-0000-0000-0000-000000000000";

struct Character {
    int icon;
    int character;
    int card;
    int rank;
    std::optional<RecordType> record_type;

    EXTENDED_JSON_TYPE_NDC(Character, icon, character, card, rank, record_type);
};

struct CharacterStatus {
    int speed;
    int stamina;
    int power;
    int guts;
    int intelligence;

    CharacterStatus() = default;

    [[maybe_unused]] CharacterStatus(
        const int speed, const int stamina, const int power, const int guts, const int intelligence)
        : speed(speed)
        , stamina(stamina)
        , power(power)
        , guts(guts)
        , intelligence(intelligence) {}

    [[maybe_unused]] CharacterStatus(const std::array<int, 5> &status)  // NOLINT(google-explicit-constructor)
        : speed(status[0])
        , stamina(status[1])
        , power(status[2])
        , guts(status[3])
        , intelligence(status[4]) {}

    EXTENDED_JSON_TYPE_NDC(CharacterStatus, speed, stamina, power, guts, intelligence);
};

struct GroundAptitude {
    int turf;
    int dirt;

    GroundAptitude() = default;

    [[maybe_unused]] GroundAptitude(const int turf, const int dirt)
        : turf(turf)
        , dirt(dirt) {}

    GroundAptitude(const std::array<int, 2> &aptitudes)  // NOLINT(google-explicit-constructor)
        : turf(aptitudes[0])
        , dirt(aptitudes[1]) {}

    EXTENDED_JSON_TYPE_NDC(GroundAptitude, turf, dirt);
};

struct DistanceAptitude {
    int short_range;
    int mile_range;
    int middle_range;
    int long_range;

    DistanceAptitude() = default;

    [[maybe_unused]] DistanceAptitude(
        const int short_range, const int mile_range, const int middle_range, const int long_range)
        : short_range(short_range)
        , mile_range(mile_range)
        , middle_range(middle_range)
        , long_range(long_range) {}

    DistanceAptitude(const std::array<int, 4> &aptitudes)  // NOLINT(google-explicit-constructor)
        : short_range(aptitudes[0])
        , mile_range(aptitudes[1])
        , middle_range(aptitudes[2])
        , long_range(aptitudes[3]) {}

    EXTENDED_JSON_TYPE_NDC(DistanceAptitude, short_range, mile_range, middle_range, long_range);
};

struct StyleAptitude {
    int lead_pace;  // [JP] nige
    int with_pace;  // [JP] senkou
    int off_pace;  // [JP] sashi
    int late_charge;  // [JP] oikomi

    StyleAptitude() = default;

    [[maybe_unused]] StyleAptitude(const int lead_pace, const int with_pace, const int off_pace, const int late_charge)
        : lead_pace(lead_pace)
        , with_pace(with_pace)
        , off_pace(off_pace)
        , late_charge(late_charge) {}

    StyleAptitude(const std::array<int, 4> &aptitudes)  // NOLINT(google-explicit-constructor)
        : lead_pace(aptitudes[0])
        , with_pace(aptitudes[1])
        , off_pace(aptitudes[2])
        , late_charge(aptitudes[3]) {}

    EXTENDED_JSON_TYPE_NDC(StyleAptitude, lead_pace, with_pace, off_pace, late_charge);
};

struct AptitudeSet {
    GroundAptitude ground;
    DistanceAptitude distance;
    StyleAptitude style;

    AptitudeSet() = default;

    [[maybe_unused]] AptitudeSet(
        const GroundAptitude ground, const DistanceAptitude distance, const StyleAptitude style)
        : ground(ground)
        , distance(distance)
        , style(style) {}

    [[maybe_unused]] AptitudeSet(const std::array<int, 10> &aptitudes)  // NOLINT(google-explicit-constructor)
        : ground(stds::slice<0, 2>(aptitudes))
        , distance(stds::slice<2, 6>(aptitudes))
        , style(stds::slice<6, 10>(aptitudes)) {}

    EXTENDED_JSON_TYPE_NDC(AptitudeSet, ground, distance, style);
};

struct Skill {
    int id = {};
    std::optional<int> level;

    EXTENDED_JSON_TYPE_NDC(Skill, id, level);
};

struct Factor {
    int id;
    int star;

    EXTENDED_JSON_TYPE_NDC(Factor, id, star);
};

struct FactorSet {
    std::vector<Factor> self;
    std::vector<Factor> parent1;
    std::vector<Factor> parent2;

    EXTENDED_JSON_TYPE_NDC(FactorSet, self, parent1, parent2);
};

struct SupportCard {
    int id;
    int rank;
    int level;

    EXTENDED_JSON_TYPE_NDC(SupportCard, id, rank, level);
};

struct Parent {
    Character self;
    Character parent1;
    Character parent2;
    std::optional<bool> rental;

    EXTENDED_JSON_TYPE_NDC(Parent, self, parent1, parent2, rental);
};

struct Family {
    Parent parent1;
    Parent parent2;

    EXTENDED_JSON_TYPE_NDC(Family, parent1, parent2);
};

struct Scenario {
    int id;

    EXTENDED_JSON_TYPE_NDC(Scenario, id);
};

struct Race {
    int title;
    int place;
    int ground;
    int distance;
    int variation;
    int weather;
    int strategy;
    int turn;
    int position;

    EXTENDED_JSON_TYPE_NDC(Race, title, place, ground, distance, variation, weather, strategy, turn, position);
};

struct RecordId {
    std::string self;
    std::optional<std::string> parent1;
    std::optional<std::string> parent2;

    EXTENDED_JSON_TYPE_NDC(RecordId, self, parent1, parent2);
};

struct Metadata {
    std::string format_version;
    std::string region;
    RecordId record_id;
    std::string trainer_id;
    std::string captured_date;
    std::string recognizer_version;
    std::string stage;
    int strategy;
    std::optional<int> relation_bonus;
    std::optional<RecordType> record_type;

    EXTENDED_JSON_TYPE_NDC(
        Metadata,
        format_version,
        region,
        record_id,
        trainer_id,
        captured_date,
        recognizer_version,
        stage,
        strategy,
        relation_bonus,
        record_type);
};

struct CharaDetailRecord {
    Metadata metadata;

    Character trainee;
    int evaluation_value;
    CharacterStatus status;
    AptitudeSet aptitudes;
    std::vector<Skill> skills;
    FactorSet factors;
    std::array<SupportCard, 6> support_cards;
    Family family;
    int fans;
    Scenario scenario;
    std::string trained_date;
    std::vector<Race> races;

    EXTENDED_JSON_TYPE_NDC(
        CharaDetailRecord,
        metadata,
        trainee,
        evaluation_value,
        status,
        aptitudes,
        skills,
        factors,
        support_cards,
        family,
        fans,
        scenario,
        trained_date,
        races);
};

}  // namespace uma::chara_detail::record
