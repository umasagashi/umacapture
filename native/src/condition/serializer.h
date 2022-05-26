#pragma once

#include <memory>
#include <vector>

#include "condition/condition.h"
#include "cv/frame.h"
#include "util/json_utils.h"

namespace serializer {

using ConditionBase = std::shared_ptr<condition::Condition<Frame>>;

template<typename Base>
class Builder {
public:
    template<typename T>
    static Builder create() {
        return {typeid(T).name(), [](const json_utils::Json &json) { return ConditionBase(T::fromJson(json)); }};
    }

    Builder(std::string type, std::function<Base(const json_utils::Json &)> func)
        : type(std::move(type))
        , func(std::move(func)) {}

    [[nodiscard]] bool match(const std::string &type) const { return type == this->type; }

    [[nodiscard]] Base build(const json_utils::Json &json) const { return func(json); }

private:
    const std::string type;
    const std::function<Base(const json_utils::Json &)> func;
};

ConditionBase conditionFromJson(const json_utils::Json &j);

std::vector<ConditionBase> conditionArrayFromJson(const json_utils::Json &j);

json_utils::Json conditionArrayToJson(const std::vector<ConditionBase> &conditions);

}  // namespace serializer
