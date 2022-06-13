#include "condition/basic_condition.h"
#include "condition/cv_rule.h"
#include "condition/rule.h"
#include "util/logger_util.h"

#include "serializer.h"

namespace uma::condition::serializer {

namespace {

const auto CONDITION_BUILDERS /* NOLINT(cert-err58-cpp)*/ = {
    Builder<ConditionBase>::create<PlainCondition<Frame, rule::PointColor>>(),
    Builder<ConditionBase>::create<PlainCondition<Frame, rule::LineLength>>(),
    Builder<ConditionBase>::create<PlainCondition<Frame, rule::StableLineLength>>(),
    Builder<ConditionBase>::create<NestedCondition<Frame, rule::Stable>>(),
    Builder<ConditionBase>::create<ParallelCondition<Frame, rule::LogicalAnd>>(),
    Builder<ConditionBase>::create<ParallelCondition<Frame, rule::LogicalOr>>(),
};

}

template<typename Base>
template<typename Impl>
Builder<Base> Builder<Base>::create() {
    return {
        condition::typeNameOf<Impl, typename Impl::input_type, typename Impl::rule_type, typename Impl::state_type>(),
        [](const json_util::Json &json) { return ConditionBase(Impl::fromJson(json)); },
    };
}

ConditionBase conditionFromJson(const json_util::Json &json) {
    const auto type = json.at("type").get<std::string>();
    spdlog::enable_backtrace(CONDITION_BUILDERS.size());
    for (const auto &builder : CONDITION_BUILDERS) {
        if (builder.match(type)) {
            spdlog::disable_backtrace();
            return builder.build(json);
        }
        log_error(builder.typeName());
    }
    spdlog::dump_backtrace();
    log_error("Unknown type: {}", type);
    throw std::invalid_argument(type);
}

std::vector<ConditionBase> conditionArrayFromJson(const json_util::Json &j) {
    std::vector<ConditionBase> out;
    for (const auto &item : j) {
        out.push_back(conditionFromJson(item));
    }
    return out;
}

json_util::Json conditionArrayToJson(const std::vector<ConditionBase> &conditions) {
    std::vector<json_util::Json> out;
    out.reserve(conditions.size());
    for (const auto &item : conditions) {
        out.push_back(item->toJson());
    }
    return out;
}

}  // namespace uma::condition::serializer
