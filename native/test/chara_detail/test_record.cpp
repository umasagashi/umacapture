// Behavioral tests for chara_detail_record.h: the RecordType axis predicates and the JSON serialization
// contract of the CharaDetailRecord tree.
//
// isInheritanceOnly / isFriend split the four RecordType values into the two independent axes
// (content: full vs inheritance-only; owner: own vs friend) that downstream recognizer/scraper code
// branches on. They are pure enum logic -- no Frame, OpenCV, ONNX, or config -- so they are pinned
// here directly, without any of the recognizer stack.
//
// The record structs are wired to JSON via EXTENDED_JSON_TYPE_NDC and are the wire contract shared with
// the Dart side (record.json). End to end this is exercised only by the golden integration test, which is
// skipped in CI because it needs local clips and ONNX models. These round-trip tests pin the same contract
// as a CI-runnable regression guard: a full record survives get -> to_json -> get -> to_json unchanged
// (the invariant the CLI `build`/recognizer paths rely on), and the optional fields round-trip correctly
// in both the present and absent states -- a corruption here silently loses or renames a field on load.

#include <doctest/doctest.h>

#include <array>
#include <optional>
#include <string>
#include <vector>

#include "chara_detail/chara_detail_record.h"
#include "util/json_util.h"

namespace uma::chara_detail::record {
namespace {

using json_util::Json;

TEST_CASE("isInheritanceOnly is true only for the inheritance-only content axis") {
    CHECK_FALSE(isInheritanceOnly(Standard));
    CHECK(isInheritanceOnly(InheritanceOnly));
    CHECK_FALSE(isInheritanceOnly(FriendStandard));
    CHECK(isInheritanceOnly(FriendInheritance));
}

TEST_CASE("isFriend is true only for the friend owner axis") {
    CHECK_FALSE(isFriend(Standard));
    CHECK_FALSE(isFriend(InheritanceOnly));
    CHECK(isFriend(FriendStandard));
    CHECK(isFriend(FriendInheritance));
}

TEST_CASE("the two axes are independent across all four record types") {
    // Every (content, owner) combination is represented exactly once, so the two predicates together
    // uniquely identify each RecordType. This is the invariant downstream code relies on when it tests
    // one axis without enumerating every combination.
    CHECK((!isInheritanceOnly(Standard) && !isFriend(Standard)));
    CHECK((isInheritanceOnly(InheritanceOnly) && !isFriend(InheritanceOnly)));
    CHECK((!isInheritanceOnly(FriendStandard) && isFriend(FriendStandard)));
    CHECK((isInheritanceOnly(FriendInheritance) && isFriend(FriendInheritance)));
}

// Builds a fully populated record whose fields all carry distinct, easily recognizable values so the
// round-trip can assert content survived, not just that some JSON came back. The optional fields are left
// to each test to set/clear, so this leaves them at their defaults (all engaged where a value is given).
CharaDetailRecord makeRecord() {
    CharaDetailRecord record{};

    record.metadata = Metadata{
        "1.0.0",
        "japan",
        RecordId{"self-id", std::string("p1-id"), std::string("p2-id")},
        "trainer-42",
        "2026-07-04T00:00:00",
        "recognizer-9",
        "URA",
        2,
        std::optional<int>(15),
        std::optional<RecordType>(FriendStandard),
    };

    record.trainee = Character{101, 102, 103, 5, std::optional<RecordType>(Standard)};
    record.evaluation_value = 12345;
    record.status = CharacterStatus{std::array<int, 5>{1000, 900, 800, 700, 600}};
    record.aptitudes =
        AptitudeSet{std::array<int, 10>{7, 3, 8, 6, 5, 4, 2, 1, 9, 0}};
    record.skills = {Skill{201, std::optional<int>(3)}, Skill{202, std::nullopt}};
    record.factors = FactorSet{
        {Factor{301, 3}, Factor{302, 1}},
        {Factor{303, 2}},
        {Factor{304, 1}, Factor{305, 3}},
    };
    for (int i = 0; i < 6; i++) {
        record.support_cards[i] = SupportCard{400 + i, i % 5, i + 1};
    }
    record.family = Family{
        Parent{
            Character{500, 501, 502, 1, std::nullopt},
            Character{503, 504, 505, 2, std::nullopt},
            Character{506, 507, 508, 3, std::nullopt},
            std::optional<bool>(true)},
        Parent{
            Character{600, 601, 602, 1, std::nullopt},
            Character{603, 604, 605, 2, std::nullopt},
            Character{606, 607, 608, 3, std::nullopt},
            std::nullopt},
    };
    record.fans = 98765;
    record.scenario = Scenario{7};
    record.trained_date = "2026-01-02T03:04:05";
    record.races = {
        Race{1, 2, 3, 4, 5, 6, 7, 8, 9},
        Race{10, 11, 12, 13, 14, 15, 16, 17, 18},
    };

    return record;
}

TEST_CASE("a fully populated record round-trips through JSON unchanged") {
    const Json first = Json(makeRecord());
    const Json second = Json(first.get<CharaDetailRecord>());
    CHECK(first == second);
}

TEST_CASE("round-tripping preserves nested field values") {
    const CharaDetailRecord original = makeRecord();
    const auto restored = Json(original).get<CharaDetailRecord>();

    CHECK(restored.evaluation_value == 12345);
    CHECK(restored.fans == 98765);
    CHECK(restored.status.speed == 1000);
    CHECK(restored.status.intelligence == 600);
    CHECK(restored.aptitudes.ground.turf == 7);
    CHECK(restored.aptitudes.style.late_charge == 0);
    REQUIRE(restored.skills.size() == 2);
    CHECK(restored.skills[0].id == 201);
    CHECK(restored.factors.self.size() == 2);
    CHECK(restored.factors.parent2[1].id == 305);
    CHECK(restored.support_cards[5].id == 405);
    CHECK(restored.family.parent1.self.icon == 500);
    REQUIRE(restored.races.size() == 2);
    CHECK(restored.races[1].position == 18);
    CHECK(restored.metadata.record_id.self == "self-id");
}

TEST_CASE("an engaged optional serializes its value and round-trips") {
    const Skill skill{201, std::optional<int>(3)};
    const Json json = Json(skill);

    REQUIRE(json.contains("level"));
    CHECK(json.at("level") == 3);
    CHECK(json.get<Skill>().level == std::optional<int>(3));
}

TEST_CASE("a disengaged optional is omitted from the JSON and decodes back to nullopt") {
    const Skill skill{202, std::nullopt};
    const Json json = Json(skill);

    // optional_to_json omits the key entirely for a disengaged optional (it does not emit null), and
    // optional_from_json treats a missing key as nullopt -- so the absent state survives the round-trip.
    CHECK_FALSE(json.contains("level"));
    CHECK_FALSE(json.get<Skill>().level.has_value());
}

TEST_CASE("an explicit null optional decodes to nullopt") {
    // A record.json produced by a serializer that emits "key": null (e.g. the Dart side) must still decode
    // the absent optional, not throw. optional_from_json treats an explicit null the same as a missing key.
    Json json = Json(Skill{203, std::optional<int>(9)});
    json["level"] = nullptr;

    CHECK_FALSE(json.get<Skill>().level.has_value());
}

TEST_CASE("the optional RecordType on a nested Character round-trips in both states") {
    const Character with_type{1, 2, 3, 4, std::optional<RecordType>(FriendInheritance)};
    const auto restored_with = Json(with_type).get<Character>();
    REQUIRE(restored_with.record_type.has_value());
    CHECK(restored_with.record_type.value() == FriendInheritance);

    const Character without_type{1, 2, 3, 4, std::nullopt};
    const Json json_without = Json(without_type);
    CHECK_FALSE(json_without.contains("record_type"));
    CHECK_FALSE(json_without.get<Character>().record_type.has_value());
}

TEST_CASE("RecordType serializes by name, not by ordinal") {
    // record.json stores the enum NAME (EXTENDED_JSON_TYPE_ENUM_STRICT), which is order-independent, so a
    // future reorder of the enum values cannot silently remap stored records. Pin the on-the-wire spelling.
    CHECK(Json(Standard).get<std::string>() == "Standard");
    CHECK(Json(FriendInheritance).get<std::string>() == "FriendInheritance");
    CHECK(Json("InheritanceOnly").get<RecordType>() == InheritanceOnly);
}

TEST_CASE("an unknown RecordType name is rejected instead of silently mapping to the first value") {
    // The _STRICT variant throws on an unrecognized name; the stock nlohmann behavior would map it to the
    // first enumerator (Standard), which is data corruption for a load-bearing enum.
    CHECK_THROWS(Json("NotARecordType").get<RecordType>());
}

}  // namespace
}  // namespace uma::chara_detail::record
