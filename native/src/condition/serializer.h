#pragma once

#include <memory>
#include <vector>

#include "condition/condition.h"
#include "cv/frame.h"
#include "util/json_utils.h"

namespace uma {

namespace serializer {

using ConditionBase = std::shared_ptr<condition::Condition<Frame>>;

template<typename Base>
class Builder {
public:
    template<typename Impl>
    static Builder<Base> create();

    [[nodiscard]] bool match(const std::string &type) const { return type == target_type; }

    [[nodiscard]] Base build(const json_utils::Json &json) const { return func(json); }

    const std::string target_type;  // TODO: This is for debug.

private:
    [[maybe_unused]] Builder(const std::string &type, const std::function<Base(const json_utils::Json &)> &func)
        : target_type(type)
        , func(func) {}

    const std::function<Base(const json_utils::Json &)> func;
};

ConditionBase conditionFromJson(const json_utils::Json &j);

std::vector<ConditionBase> conditionArrayFromJson(const json_utils::Json &j);

json_utils::Json conditionArrayToJson(const std::vector<ConditionBase> &conditions);

}  // namespace serializer

}
