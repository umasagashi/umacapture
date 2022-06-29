#pragma once

#include <optional>
#include <string>
#include <vector>

#include "util/stds.h"

namespace uma::chara_detail::record {

struct Character {
    int icon;
    int character;
    int card;
    int rank;

    EXTENDED_JSON_TYPE_NDC(Character, icon, character, card, rank);
};

struct CharacterStatus {
    int speed;
    int stamina;
    int power;
    int guts;
    int intelligence;

    CharacterStatus() = default;

    CharacterStatus(int speed, int stamina, int power, int guts, int intelligence)
        : speed(speed)
        , stamina(stamina)
        , power(power)
        , guts(guts)
        , intelligence(intelligence) {}

    CharacterStatus(const std::array<int, 5> &status)  // NOLINT(google-explicit-constructor)
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

    GroundAptitude(int turf, int dirt)
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

    DistanceAptitude(int short_range, int mile_range, int middle_range, int long_range)
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

    StyleAptitude(int lead_pace, int with_pace, int off_pace, int late_charge)
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

    AptitudeSet(GroundAptitude ground, DistanceAptitude distance, StyleAptitude style)
        : ground(ground)
        , distance(distance)
        , style(style) {}

    AptitudeSet(const std::array<int, 10> &aptitudes)  // NOLINT(google-explicit-constructor)
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
    std::string version;
    std::string region;
    RecordId record_id;
    std::string trainer_id;
    std::string captured_date;
    std::optional<int> relation_bonus;

    EXTENDED_JSON_TYPE_NDC(Metadata, version, region, record_id, trainer_id, captured_date, relation_bonus);
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
