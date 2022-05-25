#include "condition/basic_condition.h"
#include "condition/cv_rule.h"
#include "condition/rule.h"

#include "serializer.h"

namespace serializer {

namespace {

const auto CONDITION_BUILDERS /* NOLINT(cert-err58-cpp)*/ = {
    Builder<ConditionBase>::create<condition::PlainCondition<Frame, rule::PointColor>>(),
    Builder<ConditionBase>::create<condition::PlainCondition<Frame, rule::LineLength>>(),
    Builder<ConditionBase>::create<condition::PlainCondition<Frame, rule::StableLineLength>>(),
    Builder<ConditionBase>::create<condition::NestedCondition<Frame, rule::Stable>>(),
    Builder<ConditionBase>::create<condition::ParallelCondition<Frame, rule::LogicalAnd>>(),
    Builder<ConditionBase>::create<condition::ParallelCondition<Frame, rule::LogicalOr>>(),
};

}

ConditionBase conditionFromJson(const json_utils::Json &json) {
    const auto type = json.at("type").get<std::string>();
    for (const auto &builder : CONDITION_BUILDERS) {
        if (builder.match(type)) {
            return builder.build(json);
        }
    }
    throw std::invalid_argument(type);
}

std::vector<ConditionBase> conditionArrayFromJson(const json_utils::Json &j) {
    std::vector<ConditionBase> out;
    for (const auto &item : j) {
        out.push_back(conditionFromJson(item));
    }
    return out;
}

json_utils::Json conditionArrayToJson(const std::vector<ConditionBase> &conditions) {
    std::vector<json_utils::Json> out;
    for (const auto &item : conditions) {
        out.push_back(item->toJson());
    }
    return out;
}

}  // namespace serializer
